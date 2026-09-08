import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// UIKit artist detail surface matching the reference artist-first layout:
/// circular artist artwork, playback actions, a two-column album grid, and a separate
/// section for tracks that do not belong to an album.
@MainActor
public final class LibraryArtistDetailViewController: UIViewController {
    private enum AlbumDisplayMode {
        case grid
        case list
    }

    private enum Section: Hashable {
        case header
        case albums
        case noAlbumTracks
        case status
    }

    private enum Item: Hashable {
        case header
        case album(AlbumID)
        case noAlbumTrack(LibraryTrackRowIdentity)
        case status(String)
    }

    public let artistID: ArtistID
    public let library: any LibraryServing
    public let artworkServing: (any ArtworkServing)?
    private let mediaShareResolver: LibraryMediaShareResolver?
    public var onPlayTracks: (([MediaItemID], Bool) -> Void)?
    public var onPlayTrack: ((MediaItemID) -> Void)?
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)?
    public var onEnqueueTracks: (([MediaItemID]) -> Void)?
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)?
    public var onOpenAlbums: (([AlbumID]) -> Void)?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var pendingChangeTask: Task<Void, Never>?
    private var pendingAlbumRefresh = false
    private var pendingTrackRefresh = false
    private var pendingArtistRefresh = false
    private var pendingArtworkIDs = Set<ArtworkID>()
    private var artist: Artist?
    private var albums: [Album] = []
    private var albumGroups: [LibraryArtistDetailContent.AlbumGroup] = []
    private var tracks: [Track] = []
    private var noAlbumTrackRows: [(id: LibraryTrackRowIdentity, track: Track)] = []
    private var noAlbumTrackByRowID: [LibraryTrackRowIdentity: Track] = [:]
    private var loadState: LoadState = .loading
    private var albumByID: [AlbumID: Album] = [:]
    private var albumDisplayMode: AlbumDisplayMode = .grid
    private var albumSortDescriptor = AlbumSortDescriptor.default
    private var collectionActionTask: Task<Void, Never>?

    private enum LoadState: Equatable {
        case loading
        case loaded
        case empty
        case failed(String)
    }

    public init(
        artistID: ArtistID,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        self.artistID = artistID
        self.library = library
        self.artworkServing = artworkServing
        mediaShareResolver = mediaSourceResolver.map {
            LibraryMediaShareResolver(sourceResolver: $0)
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        super.init(nibName: nil, bundle: nil)
        title = nil
        restorationIdentifier = "library.artistDetail.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.artistDetail"
        navigationItem.largeTitleDisplayMode = .never
        updateNavigationItem()

        configureCollectionView()
        configureDataSource()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        renderSnapshot()
        observeLibraryChanges()
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        collectionView
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass
            || previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass
        else {
            return
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        pendingTrackRefresh = false
        collectionActionTask?.cancel()
        collectionActionTask = nil
    }

    deinit {
        loadTask?.cancel()
        libraryChangeTask?.cancel()
        pendingChangeTask?.cancel()
        collectionActionTask?.cancel()
    }

    private func updateNavigationItem() {
        let busy = collectionActionTask != nil
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: artist == nil || mediaShareResolver == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self else { return }
            self.shareTracks(for: .artist(self.artistID))
        }
        let displayMenu = UIMenu(
            title: "",
            options: [.displayInline],
            children: [
                UIAction(
                    title: L("网格"),
                    image: UIImage(systemName: "square.grid.2x2"),
                    state: albumDisplayMode == .grid ? .on : .off
                ) { [weak self] _ in self?.setAlbumDisplayMode(.grid) },
                UIAction(
                    title: L("列表"),
                    image: UIImage(systemName: "list.bullet"),
                    state: albumDisplayMode == .list ? .on : .off
                ) { [weak self] _ in self?.setAlbumDisplayMode(.list) },
            ]
        )
        let sortMenu = UIMenu(
            title: L("排序方式"),
            children: [
                UIAction(
                    title: L("标题"),
                    state: albumSortDescriptor.key == .title ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.title) },
                UIAction(
                    title: L("添加日期"),
                    state: albumSortDescriptor.key == .dateAdded ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.dateAdded) },
                UIAction(
                    title: L("年份"),
                    state: albumSortDescriptor.key == .year ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.year) },
            ]
        )
        let addTracksToPlaylist = onAddTracksToPlaylist
        let enqueueNextTracks = onEnqueueNextTracks
        let enqueueTracks = onEnqueueTracks
        let queueActions = [
            UIAction(
                title: L("添加到播放列表"),
                image: UIImage(systemName: "text.badge.plus"),
                attributes: addTracksToPlaylist == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                guard let self, let addTracksToPlaylist else { return }
                self.performArtistAction(addTracksToPlaylist)
            },
            UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: enqueueNextTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                guard let self, let enqueueNextTracks else { return }
                self.performArtistAction(enqueueNextTracks)
            },
            UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                attributes: enqueueTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                guard let self, let enqueueTracks else { return }
                self.performArtistAction(enqueueTracks)
            },
        ]
        let menu = UIMenu(
            children: [
                UIMenu(
                    title: "",
                    options: [.displayAsPalette, .displayInline],
                    preferredElementSize: .large,
                    children: [share]
                ),
                displayMenu,
                sortMenu,
                UIMenu(title: "", options: [.displayInline], children: queueActions),
            ]
        )
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.accessibilityLabel = L("艺人选项")
        item.accessibilityIdentifier = "library.artistDetail.menu"
        navigationItem.rightBarButtonItem = item
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        collectionView.alwaysBounceVertical = true
        // The album grid is the primary content container used by the
        // screenshot/BVT contract for artist detail.
        collectionView.accessibilityIdentifier = "library.artist.albums"
        collectionView.register(
            LibraryArtistDetailHeaderCell.self,
            forCellWithReuseIdentifier: LibraryArtistDetailHeaderCell.reuseIdentifier
        )
        collectionView.register(
            LibraryArtistDetailAlbumCell.self,
            forCellWithReuseIdentifier: LibraryArtistDetailAlbumCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionAlbumListCell.self,
            forCellWithReuseIdentifier: LibraryCollectionAlbumListCell.reuseIdentifier
        )
        collectionView.register(
            LibraryArtistDetailTrackCell.self,
            forCellWithReuseIdentifier: LibraryArtistDetailTrackCell.reuseIdentifier
        )
        collectionView.register(
            LibraryArtistDetailSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: LibraryArtistDetailSectionHeaderView.reuseIdentifier
        )
        collectionView.register(
            LibraryArtistDetailStatusCell.self,
            forCellWithReuseIdentifier: LibraryArtistDetailStatusCell.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            switch item {
            case .header:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryArtistDetailHeaderCell.reuseIdentifier,
                    for: indexPath
                )
                guard let header = cell as? LibraryArtistDetailHeaderCell else { return cell }
                header.configure(
                    artist: self.artist,
                    artworkServing: self.artworkServing,
                    isEnabled: !self.tracks.isEmpty,
                    play: { [weak self] in self?.playAll(shuffle: false) },
                    shuffle: { [weak self] in self?.playAll(shuffle: true) }
                )
                return header

            case let .album(albumID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: self.albumDisplayMode == .grid
                        ? LibraryArtistDetailAlbumCell.reuseIdentifier
                        : LibraryCollectionAlbumListCell.reuseIdentifier,
                    for: indexPath
                )
                guard let album = self.albumByID[albumID] else { return cell }
                let albumGroup = self.albumGroups.first { $0.album.id == albumID }
                if let albumCell = cell as? LibraryArtistDetailAlbumCell {
                    albumCell.configure(
                        album: album,
                        artworkServing: self.artworkServing,
                        onActivate: { [weak self] in
                            self?.onOpenAlbums?(albumGroup?.albumIDs ?? [albumID])
                        }
                    )
                    albumCell.accessibilityIdentifier = "library.artist.album.\(albumID.rawValue)"
                } else if let albumCell = cell as? LibraryCollectionAlbumListCell {
                    albumCell.configure(
                        album: album,
                        subtitle: album.releaseYear.map(String.init),
                        artworkServing: self.artworkServing
                    )
                    albumCell.accessibilityIdentifier = "library.artist.album.\(albumID.rawValue)"
                }
                return cell

            case let .noAlbumTrack(rowID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryArtistDetailTrackCell.reuseIdentifier,
                    for: indexPath
                )
                guard let track = self.noAlbumTrackByRowID[rowID],
                      let trackCell = cell as? LibraryArtistDetailTrackCell
                else { return cell }
                trackCell.configure(
                    track: track,
                    subtitle: self.artistSubtitle(for: track),
                    artworkServing: self.artworkServing,
                    menu: self.makeTrackContextMenu(for: track)
                )
                trackCell.accessibilityIdentifier = rowID.occurrence == 0
                    ? "library.artist.track.play.\(track.id.externalID)"
                    : "library.artist.track.play.\(track.id.externalID).\(rowID.occurrence)"
                return trackCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryArtistDetailStatusCell.reuseIdentifier,
                    for: indexPath
                )
                guard let statusCell = cell as? LibraryArtistDetailStatusCell else { return cell }
                statusCell.configure(status: status, retry: { [weak self] in
                    self?.loadTask?.cancel()
                    self?.loadTask = Task { @MainActor [weak self] in await self?.load() }
                })
                return statusCell
            }
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let self,
                  self.dataSource.sectionIdentifier(for: indexPath.section) == .noAlbumTracks
            else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: LibraryArtistDetailSectionHeaderView.reuseIdentifier,
                for: indexPath
            )
            guard let header = header as? LibraryArtistDetailSectionHeaderView else {
                return header
            }
            header.titleText = L("无专辑")
            return header
        }
        collectionView.delegate = self
    }

    private func renderSnapshot(reconfigure items: Set<Item> = []) {
        guard isViewLoaded else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        switch loadState {
        case .loading:
            snapshot.appendSections([.status])
            snapshot.appendItems([.status("loading")], toSection: .status)
        case .failed:
            snapshot.appendSections([.status])
            snapshot.appendItems([.status("failed")], toSection: .status)
        case .empty:
            snapshot.appendSections([.header, .status])
            snapshot.appendItems([.header], toSection: .header)
            snapshot.appendItems([.status("empty")], toSection: .status)
        case .loaded:
            snapshot.appendSections([.header])
            snapshot.appendItems([.header], toSection: .header)
            if !albums.isEmpty {
                snapshot.appendSections([.albums])
                snapshot.appendItems(albumGroups.map { .album($0.album.id) }, toSection: .albums)
            }
            if !noAlbumTrackRows.isEmpty {
                snapshot.appendSections([.noAlbumTracks])
                snapshot.appendItems(
                    noAlbumTrackRows.map { .noAlbumTrack($0.id) },
                    toSection: .noAlbumTracks
                )
            }
        }
        let previousSnapshot = dataSource.snapshot()
        let structureChanged = previousSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || previousSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let existingItems = Set(previousSnapshot.itemIdentifiers)
        let itemsToReconfigure = snapshot.itemIdentifiers.filter {
            items.contains($0) && existingItems.contains($0)
        }
        guard structureChanged || !itemsToReconfigure.isEmpty else { return }
        if #available(iOS 15.0, *), !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateNavigationItem()
        if structureChanged {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func observeLibraryChanges() {
        guard libraryChangeTask == nil else { return }
        libraryChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await library.makeChangeStream()
            for await change in stream {
                guard !Task.isCancelled else { return }
                self.enqueue(change)
            }
        }
    }

    private func enqueue(_ change: LibraryChange) {
        let categories = change.categories
        if categories.contains(.artists)
            && (change.affectedIDs.artistIDs.isEmpty || change.affectedIDs.artistIDs.contains(artistID)) {
            pendingArtistRefresh = true
        }
        if categories.contains(.albums) {
            // Album changes can add/remove an artist's albums even when the
            // producer cannot provide a typed album ID. Coalesce one query per
            // burst so metadata scans do not repeatedly rebuild the grid.
            pendingAlbumRefresh = true
        }
        if categories.contains(.tracks) || categories.contains(.deletions) {
            pendingTrackRefresh = true
        }
        pendingArtworkIDs.formUnion(change.affectedIDs.artworkIDs)
        schedulePendingChangeProcessing()
    }

    private func schedulePendingChangeProcessing() {
        guard pendingChangeTask == nil else { return }
        pendingChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pendingChangeTask = nil
                await self.processPendingChanges()
            } catch is CancellationError {
                self?.pendingChangeTask = nil
            } catch {
                self?.pendingChangeTask = nil
            }
        }
    }

    private func processPendingChanges() async {
        let refreshAlbums = pendingAlbumRefresh
        let refreshTracks = pendingTrackRefresh
        let refreshArtist = pendingArtistRefresh
        let artworkIDs = pendingArtworkIDs
        pendingAlbumRefresh = false
        pendingTrackRefresh = false
        pendingArtistRefresh = false
        pendingArtworkIDs.removeAll()

        if refreshTracks {
            await reloadTracks()
        } else if refreshAlbums {
            await reloadAlbums()
        }
        if refreshArtist {
            if let updated = try? await findArtist(artistID) {
                artist = updated
                renderSnapshot(reconfigure: [.header])
            }
        }
        if !artworkIDs.isEmpty {
            let affectedAlbumIDs: Set<AlbumID> = Set(albums.compactMap { album in
                guard let artworkID = album.artworkID,
                      artworkIDs.contains(artworkID) else { return nil }
                return album.id
            })
            if !affectedAlbumIDs.isEmpty {
                renderSnapshot(reconfigure: Set(affectedAlbumIDs.map { Item.album($0) }))
            }
            let affectedTrackRows: [Item] = noAlbumTrackRows.compactMap { row -> Item? in
                guard let artworkID = row.track.artworkID,
                      artworkIDs.contains(artworkID) else { return nil }
                return .noAlbumTrack(row.id)
            }
            if !affectedTrackRows.isEmpty {
                renderSnapshot(reconfigure: Set(affectedTrackRows))
            }
        }

        if pendingAlbumRefresh || pendingTrackRefresh || pendingArtistRefresh || !pendingArtworkIDs.isEmpty {
            schedulePendingChangeProcessing()
        }
    }

    private func reloadTracks() async {
        await reloadContent()
    }

    private func reloadAlbums() async {
        await reloadContent()
    }

    private func reloadContent() async {
        do {
            async let allTracks = loadAllTracks()
            async let allAlbums = loadAllAlbums()
            let (nextTracks, nextAlbums) = try await (allTracks, allAlbums)
            try Task.checkCancellation()

            let oldAlbumIDs = albumGroups.map { $0.album.id }
            let oldRows = noAlbumTrackRows.map(\.id)
            let oldAlbumsByID = albumByID

            tracks = LibraryArtistDetailContent.tracks(
                for: artistID,
                from: nextTracks,
                albums: nextAlbums
            )
            albumGroups = LibraryArtistDetailContent.albumGroups(
                for: artistID,
                tracks: tracks,
                from: nextAlbums
            )
            albums = albumGroups.map(\.album)
            updateNoAlbumTrackRows()
            albumByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
            loadState = albums.isEmpty && noAlbumTrackRows.isEmpty ? .empty : .loaded

            let changedAlbumIDs: Set<AlbumID> = Set(albums.compactMap { album in
                guard oldAlbumsByID[album.id] != album else { return nil }
                return album.id
            })
            let structureChanged = oldAlbumIDs != albumGroups.map { $0.album.id }
                || oldRows != noAlbumTrackRows.map(\.id)
            let affectedItems = Set(changedAlbumIDs.map { Item.album($0) })
                .union(noAlbumTrackRows.map { Item.noAlbumTrack($0.id) })
            renderSnapshot(
                reconfigure: structureChanged
                    ? [.header]
                    : affectedItems.union(Set([Item.header]))
            )
        } catch is CancellationError {
            return
        } catch {
            // Keep the current content visible when a background refresh fails.
        }
    }

    private func loadAllTracks() async throws -> [Track] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var result: [Track] = []
        while true {
            let page = try await library.browseTracks(
                matching: TrackQuery(sourceID: .local),
                page: request
            )
            result.append(contentsOf: page.elements)
            try Task.checkCancellation()
            guard let nextRequest = try page.nextPage(limit: request.limit) else { break }
            request = nextRequest
        }
        return result
    }

    private func loadAllAlbums() async throws -> [Album] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var result: [Album] = []
        while true {
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: .local, sort: albumSortDescriptor),
                page: request
            )
            result.append(contentsOf: page.elements)
            try Task.checkCancellation()
            guard let nextRequest = try page.nextPage(limit: request.limit) else { break }
            request = nextRequest
        }
        return result
    }

    private func findArtist(_ id: ArtistID) async throws -> Artist? {
        let page = try await library.browseArtists(
            matching: ArtistQuery(sourceID: .local),
            page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        return page.elements.first { $0.id == id }
    }

    private func load() async {
        loadState = .loading
        albums = []
        albumGroups = []
        tracks = []
        noAlbumTrackRows = []
        noAlbumTrackByRowID = [:]
        albumByID = [:]
        renderSnapshot()

        do {
            let request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            async let artistsPage = library.browseArtists(
                matching: ArtistQuery(sourceID: .local),
                page: request
            )
            async let allAlbums = loadAllAlbums()
            async let allTracks = loadAllTracks()
            let (artistPage, nextAlbums, nextTracks) = try await (artistsPage, allAlbums, allTracks)
            try Task.checkCancellation()
            artist = artistPage.elements.first(where: { $0.id == artistID })
            tracks = LibraryArtistDetailContent.tracks(
                for: artistID,
                from: nextTracks,
                albums: nextAlbums
            )
            albumGroups = LibraryArtistDetailContent.albumGroups(
                for: artistID,
                tracks: tracks,
                from: nextAlbums
            )
            albums = albumGroups.map(\.album)
            noAlbumTrackRows = LibraryTrackRowIdentity.rows(
                for: LibraryArtistDetailContent.noAlbumTracks(
                    from: tracks,
                    knownAlbumIDs: Set(nextAlbums.map(\.id))
                )
            )
            noAlbumTrackByRowID = Dictionary(
                uniqueKeysWithValues: noAlbumTrackRows.map { ($0.id, $0.track) }
            )
            albumByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
            loadState = albums.isEmpty && noAlbumTrackRows.isEmpty ? .empty : .loaded
            renderSnapshot()
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
            renderSnapshot()
        }
    }

    private func updateNoAlbumTrackRows() {
        noAlbumTrackRows = LibraryTrackRowIdentity.rows(
            for: LibraryArtistDetailContent.noAlbumTracks(
                from: tracks,
                knownAlbumIDs: Set(albumGroups.flatMap(\.albumIDs))
            )
        )
        noAlbumTrackByRowID = Dictionary(
            uniqueKeysWithValues: noAlbumTrackRows.map { ($0.id, $0.track) }
        )
    }

    private func artistSubtitle(for _: Track) -> String? {
        artist?.name
    }

    private func playAll(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        if let onPlayTracks {
            performArtistAction { itemIDs in
                onPlayTracks(itemIDs, shuffle)
            }
        } else {
            onPlayTrack?(tracks[0].id)
        }
    }

    private func performArtistAction(_ action: (([MediaItemID]) -> Void)?) {
        guard let action, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: .artist(self.artistID),
                    from: self.library
                )
                try Task.checkCancellation()
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法执行操作"),
                        message: L("这个艺人没有可用的歌曲。")
                    )
                    return
                }
                action(itemIDs)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法执行操作"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func setAlbumDisplayMode(_ mode: AlbumDisplayMode) {
        guard albumDisplayMode != mode else { return }
        albumDisplayMode = mode
        updateNavigationItem()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.reloadData()
    }

    private func setAlbumSort(_ key: AlbumSortKey) {
        guard albumSortDescriptor.key != key else { return }
        albumSortDescriptor = AlbumSortDescriptor(key: key)
        updateNavigationItem()
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.reloadAlbums()
        }
    }

    private func performAlbumAction(
        albumIDs: [AlbumID],
        action: (([MediaItemID]) -> Void)?
    ) {
        guard let action, !albumIDs.isEmpty, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: .albums(albumIDs),
                    from: self.library
                )
                try Task.checkCancellation()
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法执行操作"),
                        message: L("这张专辑没有可用的歌曲。")
                    )
                    return
                }
                action(itemIDs)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法执行操作"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func makeAlbumContextMenu(_ album: Album) -> UIMenu {
        let albumIDs = albumGroup(for: album.id)?.albumIDs ?? [album.id]
        let busy = collectionActionTask != nil
        let playTracks = onPlayTracks
        let addTracksToPlaylist = onAddTracksToPlaylist
        let enqueueNextTracks = onEnqueueNextTracks
        let enqueueTracks = onEnqueueTracks
        let play = UIAction(
            title: L("播放"),
            image: UIImage(systemName: "play.fill"),
            attributes: playTracks == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let playTracks else { return }
            self.performAlbumAction(albumIDs: albumIDs) { ids in
                playTracks(ids, false)
            }
        }
        let shuffle = UIAction(
            title: L("随机播放"),
            image: UIImage(systemName: "shuffle"),
            attributes: playTracks == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let playTracks else { return }
            self.performAlbumAction(albumIDs: albumIDs) { ids in
                playTracks(ids, true)
            }
        }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: mediaShareResolver == nil || busy ? [.disabled] : []
        ) {
            [weak self] _ in
            self?.shareTracks(for: .albums(albumIDs))
        }
        let delete = UIAction(
            title: L("删除专辑"),
            image: UIImage(systemName: "trash"),
            attributes: busy ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in
            self?.requestDeleteAlbums(album, albumIDs: albumIDs)
        }
        return UIMenu(children: [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [share]
            ),
            UIMenu(title: "", options: [.displayInline], children: [play, shuffle]),
            UIMenu(
                title: "",
                options: [.displayInline],
                children: [
                    UIAction(
                        title: L("添加到播放列表"),
                        image: UIImage(systemName: "text.badge.plus"),
                        attributes: addTracksToPlaylist == nil || busy ? [.disabled] : []
                    ) { [weak self] _ in
                        guard let self, let addTracksToPlaylist else { return }
                        self.performAlbumAction(albumIDs: albumIDs, action: addTracksToPlaylist)
                    },
                    UIAction(
                        title: L("下一首播放"),
                        image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                        attributes: enqueueNextTracks == nil || busy ? [.disabled] : []
                    ) { [weak self] _ in
                        guard let self, let enqueueNextTracks else { return }
                        self.performAlbumAction(albumIDs: albumIDs, action: enqueueNextTracks)
                    },
                    UIAction(
                        title: L("加入队列"),
                        image: UIImage(systemName: "text.append"),
                        attributes: enqueueTracks == nil || busy ? [.disabled] : []
                    ) { [weak self] _ in
                        guard let self, let enqueueTracks else { return }
                        self.performAlbumAction(albumIDs: albumIDs, action: enqueueTracks)
                    },
                ]
            ),
            UIMenu(title: "", options: [.displayInline], children: [delete]),
        ])
    }

    private func shareTracks(for target: LibraryCollectionQueueTarget) {
        guard let mediaShareResolver,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                let tracks = try await LibraryCollectionTrackLoader.tracks(
                    for: target,
                    from: self.library
                )
                let urls = try await mediaShareResolver.urls(for: tracks)
                try Task.checkCancellation()
                let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                if let popover = share.popoverPresentationController {
                    popover.sourceView = self.view
                    popover.sourceRect = CGRect(
                        x: self.view.bounds.midX,
                        y: self.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                }
                self.present(share, animated: true)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法分享"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func shareTrack(_ track: Track) {
        guard let mediaShareResolver,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                let urls = try await mediaShareResolver.urls(for: [track])
                try Task.checkCancellation()
                let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                if let popover = share.popoverPresentationController {
                    popover.sourceView = self.view
                    popover.sourceRect = CGRect(
                        x: self.view.bounds.midX,
                        y: self.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                }
                self.present(share, animated: true)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法分享歌曲"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func makeTrackContextMenu(for track: Track) -> UIMenu {
        let busy = collectionActionTask != nil
        let play = UIAction(
            title: L("播放"),
            image: UIImage(systemName: "play.fill"),
            attributes: onPlayTrack == nil || busy ? [.disabled] : []
        ) { [weak self] _ in self?.onPlayTrack?(track.id) }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: mediaShareResolver == nil || busy ? [.disabled] : []
        ) { [weak self] _ in self?.shareTrack(track) }
        let queueActions: [UIMenuElement] = [
            UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: onEnqueueNextTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in self?.onEnqueueNextTracks?([track.id]) },
            UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                attributes: onEnqueueTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in self?.onEnqueueTracks?([track.id]) },
            UIAction(
                title: L("添加到播放列表"),
                image: UIImage(systemName: "text.badge.plus"),
                attributes: onAddTracksToPlaylist == nil || busy ? [.disabled] : []
            ) { [weak self] _ in self?.onAddTracksToPlaylist?([track.id]) },
        ]
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: busy ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in self?.requestDeleteTrack(track) }
        return UIMenu(children: [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [share]
            ),
            UIMenu(title: "", options: [.displayInline], children: [play]),
            UIMenu(title: "", options: [.displayInline], children: queueActions),
            UIMenu(title: "", options: [.displayInline], children: [delete]),
        ])
    }

    private func requestDeleteTrack(_ track: Track) {
        guard collectionActionTask == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除歌曲？"),
            message: L("删除后将从资料库移除这首歌曲。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteTrack(track)
        })
        present(alert, animated: true)
    }

    private func deleteTrack(_ track: Track) {
        guard collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                _ = try await self.library.delete([track.id])
                self.tracks.removeAll { $0.id == track.id }
                self.updateNoAlbumTrackRows()
                self.loadState = self.albums.isEmpty && self.noAlbumTrackRows.isEmpty
                    ? .empty
                    : .loaded
                self.renderSnapshot(reconfigure: [.header])
                await self.reloadAlbums()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除歌曲"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func requestDeleteAlbums(_ album: Album, albumIDs: [AlbumID]) {
        guard collectionActionTask == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除专辑？"),
            message: L("将删除“%@”及其中的全部歌曲。", album.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteAlbums(albumIDs)
        })
        present(alert, animated: true)
    }

    private func deleteAlbums(_ albumIDs: [AlbumID]) {
        guard !albumIDs.isEmpty, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.updateNavigationItem()
            }
            do {
                let itemIDs = Set(try await LibraryCollectionTrackLoader.itemIDs(
                    for: .albums(albumIDs),
                    from: self.library
                ))
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法删除专辑"),
                        message: L("这张专辑没有可删除的歌曲。")
                    )
                    return
                }
                _ = try await self.library.delete(itemIDs)
                self.tracks.removeAll { itemIDs.contains($0.id) }
                self.updateNoAlbumTrackRows()
                self.albumGroups.removeAll { group in
                    !group.albumIDs.contains(where: albumIDs.contains)
                }
                self.albums = self.albumGroups.map(\.album)
                self.albumByID = Dictionary(uniqueKeysWithValues: self.albums.map { ($0.id, $0) })
                self.loadState = self.albums.isEmpty && self.noAlbumTrackRows.isEmpty
                    ? .empty
                    : .loaded
                self.renderSnapshot(reconfigure: [.header])
                await self.reloadAlbums()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除专辑"), message: error.localizedDescription)
            }
        }
        updateNavigationItem()
    }

    private func albumGroup(for albumID: AlbumID) -> LibraryArtistDetailContent.AlbumGroup? {
        albumGroups.first { $0.album.id == albumID }
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let section = self.dataSource?.snapshot().sectionIdentifiers[safe: sectionIndex]
            else { return nil }
            switch section {
            case .header:
                let size = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(280)
                )
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
                let result = NSCollectionLayoutSection(group: group)
                result.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.medium,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.medium,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return result
            case .albums:
                if self.albumDisplayMode == .list {
                    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                    configuration.showsSeparators = true
                    let result = NSCollectionLayoutSection.list(
                        using: configuration,
                        layoutEnvironment: environment
                    )
                    result.contentInsets = NSDirectionalEdgeInsets(
                        top: 0,
                        leading: MusicFreeSpacingTokens.contentInset,
                        bottom: MusicFreeSpacingTokens.xLarge,
                        trailing: MusicFreeSpacingTokens.contentInset
                    )
                    return result
                }

                let horizontalInset = MusicFreeSpacingTokens.contentInset
                let spacing: CGFloat = 15
                // Keep the columns fractional so UIKit resolves both cards
                // from the settled section width. Mixing collectionView.bounds
                // with custom frames here allowed the first layout pass to use
                // a stale width and produce one oversized card.
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.5),
                    heightDimension: .estimated(220)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(220)
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: groupSize,
                    subitems: [item, item]
                )
                group.interItemSpacing = .fixed(spacing)
                let result = NSCollectionLayoutSection(group: group)
                result.interGroupSpacing = spacing
                result.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: horizontalInset,
                    bottom: MusicFreeSpacingTokens.xLarge,
                    trailing: horizontalInset
                )
                return result
            case .noAlbumTracks:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = true
                configuration.headerMode = .supplementary
                let result = NSCollectionLayoutSection.list(
                    using: configuration,
                    layoutEnvironment: environment
                )
                result.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.xLarge,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return result
            case .status:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = false
                let result = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                result.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.large,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.large,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return result
            }
        }
    }
}

extension LibraryArtistDetailViewController: UICollectionViewDelegate {
    public func collectionView(
        _: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .album(albumID):
            onOpenAlbums?(albumGroup(for: albumID)?.albumIDs ?? [albumID])
        case let .noAlbumTrack(rowID):
            if let track = noAlbumTrackByRowID[rowID] {
                onPlayTrack?(track.id)
            }
        case .header, .status:
            break
        }
    }

    public func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let configuration: UIContextMenuConfiguration
        switch item {
        case let .album(albumID):
            guard let album = albumByID[albumID] else { return nil }
            configuration = UIContextMenuConfiguration(
                identifier: NSString(string: albumID.rawValue),
                previewProvider: nil
            ) { [weak self] _ in self?.makeAlbumContextMenu(album) }
        case let .noAlbumTrack(rowID):
            guard let track = noAlbumTrackByRowID[rowID] else { return nil }
            configuration = UIContextMenuConfiguration(
                identifier: NSString(string: "track-\(track.id.externalID)-\(rowID.occurrence)"),
                previewProvider: nil
            ) { [weak self] _ in self?.makeTrackContextMenu(for: track) }
        case .header, .status:
            return nil
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
}

@MainActor
private final class LibraryArtistDetailHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryArtistDetailHeaderCell"

    private let artworkView = MusicFreeUIKitArtworkView(
        placeholderSystemImage: "person.fill",
        cornerRadius: 72
    )
    private let titleLabel = UILabel()
    private let playButton = MusicFreeUIKitPillActionButton(title: L("播放"), systemImage: "play.fill")
    private let shuffleButton = MusicFreeUIKitPillActionButton(title: L("随机播放"), systemImage: "shuffle")
    private let buttonStack = UIStackView()
    private let stack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MusicFreeUIFontTokens.screenTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityIdentifier = "library.artist.header.title"

        buttonStack.axis = .horizontal
        buttonStack.spacing = MusicFreeSpacingTokens.small
        buttonStack.distribution = .fillEqually
        buttonStack.addArrangedSubview(playButton)
        buttonStack.addArrangedSubview(shuffleButton)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(buttonStack)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 144),
            artworkView.heightAnchor.constraint(equalToConstant: 144),
            buttonStack.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            shuffleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let targetWidth = layoutAttributes.size.width
        guard targetWidth > 0 else { return attributes }
        let targetSize = CGSize(
            width: targetWidth,
            height: UIView.layoutFittingCompressedSize.height
        )
        let fittedSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size.height = ceil(fittedSize.height)
        return attributes
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        titleLabel.text = nil
        playButton.onPrimaryAction = nil
        shuffleButton.onPrimaryAction = nil
    }

    func configure(
        artist: Artist?,
        artworkServing: (any ArtworkServing)?,
        isEnabled: Bool,
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) {
        let name = artist?.name ?? L("艺人详情")
        titleLabel.text = name
        titleLabel.accessibilityLabel = name
        artworkView.placeholderTitle = name
        artworkView.accessibilityLabel = L("%@ artist image", name)
        playButton.isEnabled = isEnabled
        shuffleButton.isEnabled = isEnabled
        playButton.onPrimaryAction = play
        shuffleButton.onPrimaryAction = shuffle
        playButton.accessibilityIdentifier = "library.artist.play"
        shuffleButton.accessibilityIdentifier = "library.artist.shuffle"

        artworkBinding.configure(
            artworkID: artist?.artworkID,
            maximumPixelDimension: 1_024,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryArtistDetailAlbumCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryArtistDetailAlbumCell"

    private let artworkView = MusicFreeUIKitArtworkView(fillsAvailableWidth: true)
    private let titleLabel = UILabel()
    private let yearLabel = UILabel()
    private let accessibilityButton = UIButton(type: .system)
    private let stack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)
    private var accessibilityAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        yearLabel.font = MusicFreeUIFontTokens.rowSubtitle
        yearLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        yearLabel.numberOfLines = 1
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(yearLabel)
        contentView.addSubview(stack)
        accessibilityButton.translatesAutoresizingMaskIntoConstraints = false
        accessibilityButton.backgroundColor = .clear
        accessibilityButton.alpha = 0.01
        accessibilityButton.accessibilityTraits = [.button]
        contentView.addSubview(accessibilityButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            accessibilityButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            accessibilityButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            accessibilityButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            accessibilityButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        if let accessibilityAction {
            accessibilityButton.removeAction(accessibilityAction, for: .primaryActionTriggered)
        }
        accessibilityAction = nil
        accessibilityButton.accessibilityLabel = nil
        accessibilityButton.accessibilityValue = nil
        artworkView.image = nil
        artworkView.isLoading = false
        titleLabel.text = nil
        yearLabel.text = nil
    }

    func configure(
        album: Album,
        artworkServing: (any ArtworkServing)?,
        onActivate: @escaping () -> Void
    ) {
        titleLabel.text = album.title
        yearLabel.text = album.releaseYear.map(String.init)
        yearLabel.isHidden = album.releaseYear == nil
        accessibilityLabel = album.title
        accessibilityValue = yearLabel.text
        accessibilityTraits = [.button]
        accessibilityButton.accessibilityLabel = album.title
        accessibilityButton.accessibilityValue = yearLabel.text
        accessibilityButton.accessibilityIdentifier = "library.artist.album.\(album.id.rawValue)"
        let action = UIAction { _ in onActivate() }
        accessibilityAction = action
        accessibilityButton.addAction(action, for: .primaryActionTriggered)
        artworkView.placeholderTitle = album.title
        artworkView.accessibilityLabel = L("%@ album artwork", album.title)

        artworkBinding.configure(
            artworkID: album.artworkID,
            maximumPixelDimension: 320,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryArtistDetailSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "LibraryArtistDetailSectionHeaderView"

    private let header = MusicFreeUIKitSectionHeaderView(title: "")

    var titleText: String = "" {
        didSet { header.titleText = titleText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class LibraryArtistDetailTrackCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryArtistDetailTrackCell"
    static let artworkPixelDimension = 160

    private let artworkView = MusicFreeUIKitArtworkView(
        fillsAvailableWidth: false,
        cornerRadius: MusicFreeLayoutMetrics.artworkCornerRadius
    )
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let moreButton = UIButton(type: .system)
    private let rowStack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 52),
            artworkView.heightAnchor.constraint(equalToConstant: 52),
        ])

        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        moreButton.accessibilityLabel = L("歌曲选项")
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = MusicFreeSpacingTokens.medium
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(artworkView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(moreButton)
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        titleLabel.text = nil
        subtitleLabel.text = nil
        moreButton.menu = nil
    }

    func configure(
        track: Track,
        subtitle: String?,
        artworkServing: (any ArtworkServing)?,
        menu: UIMenu
    ) {
        titleLabel.text = track.title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        accessibilityLabel = track.title
        accessibilityValue = subtitle
        accessibilityTraits = [.button]
        artworkView.accessibilityLabel = L("%@ album artwork", track.title)
        artworkView.placeholderTitle = track.title
        moreButton.menu = menu
        moreButton.accessibilityIdentifier = "library.artist.track.options.\(track.id.externalID)"

        artworkBinding.configure(
            artworkID: track.artworkID,
            sourceID: track.id.sourceID,
            maximumPixelDimension: Self.artworkPixelDimension,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryArtistDetailStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryArtistDetailStatusCell"
    private var stateView: UIView?

    func configure(status: String, retry: @escaping () -> Void) {
        stateView?.removeFromSuperview()
        let nextView: UIView
        switch status {
        case "loading":
            nextView = MusicFreeUIKitLoadingStateView(label: L("正在载入艺人"))
        case "failed":
            nextView = MusicFreeUIKitErrorStateView(
                message: L("无法载入艺人。"),
                retryTitle: L("重试"),
                retry: retry
            )
        default:
            nextView = MusicFreeUIKitEmptyStateView(
                title: L("暂无专辑"),
                message: L("这个艺人暂时没有专辑。"),
                systemImage: "square.stack"
            )
        }
        nextView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nextView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        stateView = nextView
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
