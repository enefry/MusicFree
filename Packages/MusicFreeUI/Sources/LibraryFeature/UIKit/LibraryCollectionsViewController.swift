import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// Stable presentation ordering for the Albums collection.
///
/// Tracks without an album are represented by a synthetic collection rather
/// than an Album model. Keeping that item first makes the entry discoverable
/// without requiring UIKit to materialize and scroll through every album cell.
enum LibraryAlbumCollectionDisplayItem: Equatable {
    case noAlbum
    case album(AlbumID)

    static func ordered(
        albumIDs: [AlbumID],
        includesNoAlbum: Bool
    ) -> [Self] {
        let noAlbumItems = includesNoAlbum ? [Self.noAlbum] : []
        return noAlbumItems + albumIDs.map(Self.album)
    }
}

/// Native UIKit browse surface for albums, artists, genres and folders.
///
/// The controller intentionally consumes the existing LibraryViewModel instead
/// of creating a second query/state machine. It is the next vertical slice
/// after the native Songs list: UIKit owns layout, cell reuse and navigation;
/// the feature model still owns loading, pagination and mutations.
@MainActor
public final class LibraryCollectionsViewController: UIViewController {
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "library-collections"
    )

    private enum AlbumDisplayMode: String {
        case grid
        case list
    }

    private enum CollectionSection: Hashable {
        case group(String)
        case content
        case status
    }

    private enum CollectionItem: Hashable {
        case album(AlbumID)
        case noAlbum
        case artist(ArtistID)
        case genre(GenreID)
        case folder(String)
        case status(String)
    }

    public let viewModel: LibraryViewModel
    public let section: LibrarySection
    public let artworkServing: (any ArtworkServing)?
    private let mediaShareResolver: LibraryMediaShareResolver?
    public var onSelectAlbum: ((AlbumID) -> Void)?
    public var onSelectNoAlbum: (() -> Void)?
    public var onSelectArtist: ((ArtistID) -> Void)?
    public var onSelectGenre: ((GenreID) -> Void)?
    public var onSelectFolder: ((String) -> Void)?
    public var onPlayTracks: (([MediaItemID], Bool) -> Void)?
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)?
    public var onEnqueueTracks: (([MediaItemID]) -> Void)?
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<CollectionSection, CollectionItem>!
    private var viewModelObservations = Set<AnyCancellable>()
    private var artistNameTask: Task<Void, Never>?
    private var artistNameRequestSignature: String?
    private var artistNames: [ArtistID: String] = [:]
    private var albumsByID: [AlbumID: Album] = [:]
    private var artistsByID: [ArtistID: Artist] = [:]
    private var genresByID: [GenreID: Genre] = [:]
    private var foldersByPath: [String: LibraryFolder] = [:]
    private var renderedItemSignatures: [CollectionItem: String] = [:]
    private var albumDisplayMode: AlbumDisplayMode = .grid
    private var collectionActionTask: Task<Void, Never>?
    private var initialLoadTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var noAlbumCountTask: Task<Void, Never>?
    private var noAlbumCountRefreshPending = false
    private var noAlbumTrackCount = 0
    private var hasLoadedNoAlbumCount = false
    private var initialPreparationCompleted = false

    public init(
        viewModel: LibraryViewModel,
        section: LibrarySection,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        precondition(
            [.albums, .artists, .genres, .folders].contains(section),
            "LibraryCollectionsViewController only supports browse sections"
        )
        self.viewModel = viewModel
        self.section = section
        self.artworkServing = artworkServing
        mediaShareResolver = mediaSourceResolver.map {
            LibraryMediaShareResolver(sourceResolver: $0)
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        super.init(nibName: nil, bundle: nil)
        title = section.title
        restorationIdentifier = "library.\(section.rawValue).uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.\(section.rawValue)"

        configureCollectionView()
        configureDataSource()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        observeViewModel()
        observeLibraryChanges()
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
        renderSnapshot()
        prepareAndLoadIfNeeded()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareAndLoadIfNeeded()
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        collectionActionTask?.cancel()
        collectionActionTask = nil
        initialLoadTask?.cancel()
        initialLoadTask = nil
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
        noAlbumCountTask?.cancel()
        noAlbumCountTask = nil
        noAlbumCountRefreshPending = false
    }

    deinit {
        artistNameTask?.cancel()
        collectionActionTask?.cancel()
        initialLoadTask?.cancel()
        libraryChangeTask?.cancel()
        noAlbumCountTask?.cancel()
    }

    private func prepareAndLoadIfNeeded() {
        guard initialLoadTask == nil else { return }

        initialLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.prepareForFirstLoad(of: self.section)
            guard !Task.isCancelled else { return }

            self.initialPreparationCompleted = true
            self.reloadNoAlbumTrackCount()
            self.reloadArtistNamesIfNeeded()
            self.renderSnapshot()
            self.initialLoadTask = nil
        }
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass else {
            return
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override public func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        collectionView
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        collectionView.alwaysBounceVertical = true
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addTarget(
            self,
            action: #selector(refreshTriggered),
            for: .valueChanged
        )
        collectionView.accessibilityIdentifier = "library.\(section.rawValue).collection"
        collectionView.register(
            LibraryCollectionAlbumCell.self,
            forCellWithReuseIdentifier: LibraryCollectionAlbumCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionAlbumListCell.self,
            forCellWithReuseIdentifier: LibraryCollectionAlbumListCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionNoAlbumCell.self,
            forCellWithReuseIdentifier: LibraryCollectionNoAlbumCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionArtistCell.self,
            forCellWithReuseIdentifier: LibraryCollectionArtistCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionTextCell.self,
            forCellWithReuseIdentifier: LibraryCollectionTextCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionsStatusCell.self,
            forCellWithReuseIdentifier: LibraryCollectionsStatusCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionsHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: LibraryCollectionsHeaderView.reuseIdentifier
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateNavigationItems()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<CollectionSection, CollectionItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case let .album(albumID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: self.albumDisplayMode == .grid
                        ? LibraryCollectionAlbumCell.reuseIdentifier
                        : LibraryCollectionAlbumListCell.reuseIdentifier,
                    for: indexPath
                )
                guard let album = self.albumsByID[albumID] else { return cell }
                if let albumCell = cell as? LibraryCollectionAlbumCell {
                    albumCell.configure(
                        album: album,
                        subtitle: self.albumSubtitle(for: album),
                        artworkServing: self.artworkServing,
                        artworkPixelDimension: self.albumArtworkPixelDimension
                    )
                    albumCell.accessibilityIdentifier = "library.album.open.\(albumID.rawValue)"
                } else if let albumCell = cell as? LibraryCollectionAlbumListCell {
                    albumCell.configure(
                        album: album,
                        subtitle: self.albumSubtitle(for: album),
                        artworkServing: self.artworkServing
                    )
                    albumCell.accessibilityIdentifier = "library.album.open.\(albumID.rawValue)"
                }
                return cell

            case .noAlbum:
                if self.albumDisplayMode == .grid {
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: LibraryCollectionNoAlbumCell.reuseIdentifier,
                        for: indexPath
                    )
                    guard let noAlbumCell = cell as? LibraryCollectionNoAlbumCell else {
                        return cell
                    }
                    noAlbumCell.configure(trackCount: self.noAlbumTrackCount)
                    noAlbumCell.accessibilityIdentifier = "library.album.noAlbum.open"
                    return noAlbumCell
                }

                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionTextCell.reuseIdentifier,
                    for: indexPath
                )
                guard let textCell = cell as? LibraryCollectionTextCell else { return cell }
                textCell.configure(
                    title: L("无专辑"),
                    subtitle: L("未归入专辑的歌曲"),
                    trailingText: L("%d tracks", self.noAlbumTrackCount),
                    systemImage: "rectangle.stack.badge.minus",
                    accessibilityLabel: L("无专辑")
                )
                textCell.accessibilityIdentifier = "library.album.noAlbum.open"
                return textCell

            case let .artist(artistID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionArtistCell.reuseIdentifier,
                    for: indexPath
                )
                guard let artistCell = cell as? LibraryCollectionArtistCell,
                      let artist = self.artistsByID[artistID]
                else { return cell }
                artistCell.configure(
                    artist: artist,
                    artworkServing: self.artworkServing
                )
                artistCell.accessibilityIdentifier = "library.artist.open.\(artistID.rawValue)"
                return artistCell

            case let .genre(genreID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionTextCell.reuseIdentifier,
                    for: indexPath
                )
                guard let textCell = cell as? LibraryCollectionTextCell,
                      let genre = self.genresByID[genreID]
                else { return cell }
                textCell.configure(
                    title: genre.name,
                    subtitle: nil,
                    systemImage: "guitars",
                    accessibilityLabel: genre.name
                )
                textCell.accessibilityIdentifier = "library.genre.open.\(genreID.rawValue)"
                return textCell

            case let .folder(path):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionTextCell.reuseIdentifier,
                    for: indexPath
                )
                guard let textCell = cell as? LibraryCollectionTextCell,
                      let folder = self.foldersByPath[path]
                else { return cell }
                textCell.configure(
                    title: LibrarySortSupport.leafName(of: folder.path),
                    subtitle: self.folderSubtitle(for: folder),
                    trailingText: L("%d tracks", folder.trackCount),
                    systemImage: "folder",
                    accessibilityLabel: folder.path
                )
                textCell.accessibilityIdentifier = "library.folder.open.\(path)"
                return textCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionsStatusCell.reuseIdentifier,
                    for: indexPath
                )
                guard let statusCell = cell as? LibraryCollectionsStatusCell else { return cell }
                statusCell.configure(
                    status: status,
                    section: self.section,
                    retry: { [weak self] in self?.viewModel.retry(section: self?.section) }
                )
                statusCell.accessibilityIdentifier = "library.\(self.section.rawValue).status"
                return statusCell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self,
                  kind == UICollectionView.elementKindSectionHeader,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section),
                  case let .group(title) = section
            else { return nil }

            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: LibraryCollectionsHeaderView.reuseIdentifier,
                for: indexPath
            )
            guard let header = header as? LibraryCollectionsHeaderView else { return header }
            header.titleText = title
            return header
        }
        collectionView.delegate = self
    }

    private func observeViewModel() {
        viewModelObservations.removeAll()
        let observedSection = section

        let scheduleRender: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderSnapshot()
                if self.initialPreparationCompleted {
                    self.reloadNoAlbumTrackCount()
                }
                self.reloadArtistNamesIfNeeded()
                self.collectionView.refreshControl?.endRefreshing()
            }
        }

        viewModelObservations.insert(
            viewModel.$states
                .map { $0[observedSection] ?? .idle }
                .removeDuplicates()
                .sink { _ in scheduleRender() }
        )
        viewModelObservations.insert(
            viewModel.$paginationErrors
                .map { $0[observedSection] }
                .removeDuplicates()
                .sink { _ in scheduleRender() }
        )

        switch section {
        case .albums:
            viewModelObservations.insert(viewModel.$albums.sink { _ in scheduleRender() })
            viewModelObservations.insert(
                viewModel.$albumSortDescriptor
                    .removeDuplicates()
                    .sink { [weak self] _ in self?.updateNavigationItems() }
            )
        case .artists:
            viewModelObservations.insert(viewModel.$artists.sink { _ in scheduleRender() })
        case .genres:
            viewModelObservations.insert(viewModel.$genres.sink { _ in scheduleRender() })
        case .folders:
            viewModelObservations.insert(viewModel.$folders.sink { _ in scheduleRender() })
        default:
            break
        }
    }

    private func observeLibraryChanges() {
        guard section == .albums, libraryChangeTask == nil else { return }
        libraryChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.viewModel.library.makeChangeStream()
            for await change in stream {
                guard !Task.isCancelled else { return }
                guard !change.categories.isDisjoint(with: [
                    .tracks,
                    .albums,
                    .deletions,
                ]) else {
                    continue
                }
                // A track-only commit can change the No Album collection even
                // when the Albums query itself has not changed. Re-query the
                // supplemental collection directly instead of relying on the
                // view model's album publisher to fire.
                self.reloadNoAlbumTrackCount()
            }
        }
    }

    private func renderSnapshot() {
        guard isViewLoaded else { return }

        var snapshot = NSDiffableDataSourceSnapshot<CollectionSection, CollectionItem>()
        albumsByID = [:]
        artistsByID = [:]
        genresByID = [:]
        foldersByPath = [:]

        switch section {
        case .albums:
            let albums = orderedAlbums
            albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
            let items = LibraryAlbumCollectionDisplayItem.ordered(
                albumIDs: albums.map(\.id),
                includesNoAlbum: hasLoadedNoAlbumCount && noAlbumTrackCount > 0
            ).map { item in
                switch item {
                case .noAlbum:
                    return CollectionItem.noAlbum
                case let .album(id):
                    return CollectionItem.album(id)
                }
            }
            if items.isEmpty {
                appendStatus(to: &snapshot)
            } else {
                snapshot.appendSections([.content])
                snapshot.appendItems(items, toSection: .content)
            }

        case .artists:
            let artists = orderedArtists
            artistsByID = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
            appendGroupedItems(
                artists,
                key: { LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) },
                item: { .artist($0.id) },
                to: &snapshot
            )

        case .genres:
            let genres = orderedGenres
            genresByID = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0) })
            appendGroupedItems(
                genres,
                key: { LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) },
                item: { .genre($0.id) },
                to: &snapshot
            )

        case .folders:
            let folders = orderedFolders
            foldersByPath = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
            appendGroupedItems(
                folders,
                key: { LibrarySortSupport.sectionTitle(for: LibrarySortSupport.leafName(of: $0.path)) },
                item: { .folder($0.path) },
                to: &snapshot
            )

        default:
            break
        }

        let nextSignatures = Dictionary(
            uniqueKeysWithValues: snapshot.itemIdentifiers.map { item in
                (item, collectionItemSignature(item))
            }
        )
        let previousSnapshot = dataSource.snapshot()
        let structureChanged = previousSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || previousSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let existingItems = Set(previousSnapshot.itemIdentifiers)
        let itemsToReconfigure = snapshot.itemIdentifiers.filter {
            existingItems.contains($0)
                && renderedItemSignatures[$0] != nextSignatures[$0]
        }
        renderedItemSignatures = nextSignatures
        guard structureChanged || !itemsToReconfigure.isEmpty else {
            return
        }
        if #available(iOS 15.0, *), !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if structureChanged {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func collectionItemSignature(_ item: CollectionItem) -> String {
        switch item {
        case let .album(id):
            guard let album = albumsByID[id] else { return "missing" }
            return [
                album.id.rawValue,
                album.title,
                album.sortTitle ?? "",
                album.artistIDs.map(\.rawValue).joined(separator: ","),
                album.artworkID?.rawValue ?? "",
                album.releaseYear.map(String.init) ?? "",
                album.trackCount.map(String.init) ?? "",
                albumSubtitle(for: album) ?? "",
            ].joined(separator: "\u{001F}")

        case .noAlbum:
            return "noAlbum\u{001F}\(noAlbumTrackCount)"

        case let .artist(id):
            guard let artist = artistsByID[id] else { return "missing" }
            return [
                artist.id.rawValue,
                artist.name,
                artist.sortName ?? "",
                artist.artworkID?.rawValue ?? "",
            ].joined(separator: "\u{001F}")

        case let .genre(id):
            guard let genre = genresByID[id] else { return "missing" }
            return [genre.id.rawValue, genre.name, genre.sortName ?? ""]
                .joined(separator: "\u{001F}")

        case let .folder(path):
            guard let folder = foldersByPath[path] else { return "missing" }
            return [
                folder.path,
                LibrarySortSupport.leafName(of: folder.path),
                folderSubtitle(for: folder) ?? "",
                String(folder.trackCount),
            ].joined(separator: "\u{001F}")

        case let .status(status):
            return status
        }
    }

    private func appendStatus(
        to snapshot: inout NSDiffableDataSourceSnapshot<CollectionSection, CollectionItem>
    ) {
        snapshot.appendSections([.status])
        let status: String
        switch viewModel.state(for: section) {
        case .idle, .loading:
            status = "loading"
        case .failed:
            status = "failed"
        case .empty, .loaded:
            status = "empty"
        }
        snapshot.appendItems([.status(status)], toSection: .status)
    }

    private func appendGroupedItems<Element>(
        _ elements: [Element],
        key: (Element) -> String,
        item: (Element) -> CollectionItem,
        to snapshot: inout NSDiffableDataSourceSnapshot<CollectionSection, CollectionItem>
    ) {
        guard !elements.isEmpty else {
            appendStatus(to: &snapshot)
            return
        }
        let grouped = Dictionary(grouping: elements, by: key)
        let keys = grouped.keys.sorted(by: LibrarySortSupport.areSectionTitlesInAscendingOrder)
        for key in keys {
            snapshot.appendSections([.group(key)])
            snapshot.appendItems(grouped[key, default: []].map(item), toSection: .group(key))
        }
    }

    private var orderedAlbums: [Album] {
        viewModel.albums
    }

    private var orderedArtists: [Artist] {
        viewModel.artists.sorted {
            let lhs = LibrarySortSupport.normalizedSortValue($0.sortName ?? $0.name)
            let rhs = LibrarySortSupport.normalizedSortValue($1.sortName ?? $1.name)
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }

    private var orderedGenres: [Genre] {
        viewModel.genres.sorted {
            let lhs = LibrarySortSupport.normalizedSortValue($0.sortName ?? $0.name)
            let rhs = LibrarySortSupport.normalizedSortValue($1.sortName ?? $1.name)
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }

    private var orderedFolders: [LibraryFolder] {
        viewModel.folders.sorted {
            let lhs = LibrarySortSupport.normalizedSortValue(LibrarySortSupport.leafName(of: $0.path))
            let rhs = LibrarySortSupport.normalizedSortValue(LibrarySortSupport.leafName(of: $1.path))
            if lhs != rhs { return lhs < rhs }
            return $0.path < $1.path
        }
    }

    private func reloadArtistNamesIfNeeded() {
        guard section == .albums else { return }
        let albums = orderedAlbums
        let artistIDs = Set(albums.flatMap(\.artistIDs))
        guard !artistIDs.isEmpty else {
            artistNameTask?.cancel()
            artistNameTask = nil
            artistNameRequestSignature = nil
            artistNames = [:]
            return
        }

        let missingIDs = artistIDs.subtracting(artistNames.keys)
        guard !missingIDs.isEmpty else { return }

        let requestSignature = missingIDs
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        guard artistNameRequestSignature != requestSignature else { return }

        artistNameTask?.cancel()
        artistNameRequestSignature = requestSignature
        let library = viewModel.library
        artistNameTask = Task { @MainActor [weak self] in
            do {
                let names = try await LibraryArtistNameLoader.load(
                    artistIDs: missingIDs,
                    sourceID: .local,
                    from: library
                )
                guard let self, !Task.isCancelled else { return }
                self.artistNames.merge(names) { _, new in new }
                self.artistNameTask = nil
                self.renderSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self?.artistNameTask = nil
                // Album titles remain useful when supplementary artist metadata fails.
            }
        }
    }

    private func reloadNoAlbumTrackCount() {
        guard section == .albums, initialPreparationCompleted else { return }
        noAlbumCountRefreshPending = true
        guard noAlbumCountTask == nil else { return }

        let library = viewModel.library
        noAlbumCountTask = Task { @MainActor [weak self] in
            defer { self?.noAlbumCountTask = nil }

            while !Task.isCancelled {
                guard let self else { return }
                self.noAlbumCountRefreshPending = false

                let count: Int?
                do {
                    count = try await self.loadNoAlbumTrackCountWithRetry(from: library)
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.error(
                        "no-album count query failed error=\(String(describing: error))"
                    )
                    count = nil
                }

                guard let count, !Task.isCancelled else { return }
                let changed = !self.hasLoadedNoAlbumCount || self.noAlbumTrackCount != count
                self.noAlbumTrackCount = count
                self.hasLoadedNoAlbumCount = true
                if changed {
                    self.renderSnapshot()
                }

                guard self.noAlbumCountRefreshPending else { return }
            }
        }
    }

    private func loadNoAlbumTrackCountWithRetry(
        from library: any LibraryServing
    ) async throws -> Int {
        // Documents scanning can publish its completion just before the
        // imported track becomes visible to a fresh browse query. Retry both
        // empty results and transient repository failures: a failed
        // supplemental query must not permanently hide the collection.
        let retryDelays: [UInt64] = [0, 250_000_000, 750_000_000, 1_500_000_000]
        var lastError: Error?
        for (index, delay) in retryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                let count = try await LibraryCollectionTrackLoader.tracks(
                    for: .noAlbum,
                    from: library
                ).count
                if count > 0 || index == retryDelays.index(before: retryDelays.endIndex) {
                    return count
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                Self.logger.warning(
                    "no-album count query attempt failed attempt=\(index + 1)"
                )
            }
        }
        if let lastError {
            throw lastError
        }
        return 0
    }

    private func albumSubtitle(for album: Album) -> String? {
        var parts = album.artistIDs.compactMap { artistNames[$0] }
        if let year = album.releaseYear {
            parts.append(String(year))
        }
        if let trackCount = album.trackCount {
            parts.append(L("%d tracks", trackCount))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func folderSubtitle(for folder: LibraryFolder) -> String? {
        LibrarySortSupport.parentPath(of: folder.path)
    }

    private var albumArtworkPixelDimension: Int {
        let width = max(collectionView.bounds.width, view.bounds.width)
        let tileWidth = max(1, (width - MusicFreeSpacingTokens.contentInset * 2 - 15) / 2)
        // Round up to a small number of reusable sizes; keep iPad covers sharp.
        let pixels = Int(ceil(tileWidth * max(traitCollection.displayScale, 1)))
        return min(2_048, max(256, ((pixels + 255) / 256) * 256))
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let identifier = self.dataSource?.snapshot().sectionIdentifiers[safe: sectionIndex]
            else { return nil }

            if self.section == .albums,
               identifier == .content,
               self.albumDisplayMode == .grid {
                // Albums are a full-width two-column grid.  The previous
                // layout used a half-width group containing a half-width
                // item, which made each card roughly one quarter of the
                // screen and left the entire right half empty.
                let horizontalInset = MusicFreeSpacingTokens.contentInset
                let spacing: CGFloat = 15
                let settledWidth = self.collectionView.bounds.width > 0
                    ? self.collectionView.bounds.width
                    : environment.container.effectiveContentSize.width
                let availableWidth = max(0, settledWidth - horizontalInset * 2)
                let itemWidth = floor(max(0, (availableWidth - spacing) / 2))
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth),
                    // The album tile's title and metadata are content-sized.
                    // An estimated height lets Auto Layout shrink rows when
                    // either value fits on one line, matching LazyVGrid's
                    // top-aligned row behavior in the reference screen.
                    heightDimension: .estimated(180)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(180)
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: groupSize,
                    repeatingSubitem: item,
                    count: 2
                )
                group.interItemSpacing = .fixed(spacing)
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = MusicFreeSpacingTokens.xLarge
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.small,
                    leading: horizontalInset,
                    bottom: MusicFreeSpacingTokens.xLarge,
                    trailing: horizontalInset
                )
                return layoutSection
            }

            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = identifier != .status
            configuration.headerMode = identifier == .content
                || identifier == .group("")
                || identifier == .status
                ? .none
                : .supplementary
            let layoutSection = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: MusicFreeSpacingTokens.small,
                leading: MusicFreeSpacingTokens.contentInset,
                bottom: MusicFreeSpacingTokens.large,
                trailing: MusicFreeSpacingTokens.contentInset
            )
            return layoutSection
        }
    }

    @objc private func refreshTriggered() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.refreshCheckingForImports(section: self.section)
            self.collectionView.refreshControl?.endRefreshing()
        }
    }

    private func updateNavigationItems() {
        guard isViewLoaded else { return }
        let refreshAction = UIAction(
            title: L("刷新资料库"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in self?.refreshTriggered() }

        let optionsItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [refreshAction])
        )
        optionsItem.accessibilityLabel = L("%@选项", section.title)
        optionsItem.accessibilityIdentifier = "library.\(section.rawValue).options"

        guard section == .albums else {
            navigationItem.rightBarButtonItems = [optionsItem]
            return
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
        let currentSort = viewModel.albumSortDescriptor.key
        let sortMenu = UIMenu(
            title: L("排序方式"),
            options: [.displayInline],
            children: [
                UIAction(
                    title: L("标题"),
                    state: currentSort == .title ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.title) },
                UIAction(
                    title: L("艺人"),
                    state: currentSort == .artistName ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.artistName) },
                UIAction(
                    title: L("添加日期"),
                    state: currentSort == .dateAdded ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.dateAdded) },
                UIAction(
                    title: L("年份"),
                    state: currentSort == .year ? .on : .off
                ) { [weak self] _ in self?.setAlbumSort(.year) },
            ]
        )
        let sortItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            menu: UIMenu(children: [displayMenu, sortMenu])
        )
        sortItem.accessibilityLabel = L("显示与排序")
        sortItem.accessibilityIdentifier = "library.albums.sort"
        navigationItem.rightBarButtonItems = [optionsItem, sortItem]
    }

    private func setAlbumDisplayMode(_ mode: AlbumDisplayMode) {
        guard albumDisplayMode != mode else { return }
        albumDisplayMode = mode
        updateNavigationItems()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        renderSnapshot()
        collectionView.reloadData()
    }

    private func setAlbumSort(_ key: AlbumSortKey) {
        viewModel.setAlbumSort(AlbumSortDescriptor(key: key))
        updateNavigationItems()
    }

    private func makeCollectionContextMenu(for item: CollectionItem) -> UIMenu? {
        let target: LibraryCollectionQueueTarget
        let title: String
        switch item {
        case let .album(id):
            guard let album = albumsByID[id] else { return nil }
            target = .album(id)
            title = album.title
        case .noAlbum:
            guard noAlbumTrackCount > 0 else { return nil }
            target = .noAlbum
            title = L("无专辑")
        case let .artist(id):
            guard let artist = artistsByID[id] else { return nil }
            target = .artist(id)
            title = artist.name
        case let .genre(id):
            guard let genre = genresByID[id] else { return nil }
            target = .genre(id)
            title = genre.name
        case let .folder(path):
            guard foldersByPath[path] != nil else { return nil }
            target = .folder(path)
            title = LibrarySortSupport.leafName(of: path)
        case .status:
            return nil
        }

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
            self.performCollectionAction(for: target) { ids in
                playTracks(ids, false)
            }
        }
        let shuffle = UIAction(
            title: L("随机播放"),
            image: UIImage(systemName: "shuffle"),
            attributes: playTracks == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let playTracks else { return }
            self.performCollectionAction(for: target) { ids in
                playTracks(ids, true)
            }
        }
        let addToPlaylist = UIAction(
            title: L("添加到播放列表"),
            image: UIImage(systemName: "text.badge.plus"),
            attributes: addTracksToPlaylist == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let addTracksToPlaylist else { return }
            self.performCollectionAction(for: target) { ids in
                addTracksToPlaylist(ids)
            }
        }
        let playNext = UIAction(
            title: L("下一首播放"),
            image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
            attributes: enqueueNextTracks == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let enqueueNextTracks else { return }
            self.performCollectionAction(for: target) { ids in
                enqueueNextTracks(ids)
            }
        }
        let enqueue = UIAction(
            title: L("加入队列"),
            image: UIImage(systemName: "text.append"),
            attributes: enqueueTracks == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let enqueueTracks else { return }
            self.performCollectionAction(for: target) { ids in
                enqueueTracks(ids)
            }
        }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: mediaShareResolver == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            self?.shareCollection(target)
        }
        var groups: [UIMenuElement] = [
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
                children: [addToPlaylist, playNext, enqueue]
            ),
        ]
        if case let .album(id) = item,
           let artistID = albumsByID[id]?.artistIDs.first,
           let onSelectArtist
        {
            let openArtist = UIAction(
                title: L("前往艺人"),
                image: UIImage(systemName: "person.crop.circle")
            ) { _ in onSelectArtist(artistID) }
            groups.append(UIMenu(title: "", options: [.displayInline], children: [openArtist]))
        }
        if case .album = target {
            let delete = UIAction(
                title: L("删除专辑"),
                image: UIImage(systemName: "trash"),
                attributes: busy ? [.destructive, .disabled] : [.destructive]
            ) { [weak self] _ in
                self?.requestDeleteAlbum(target: target, title: title)
            }
            groups.append(UIMenu(title: "", options: [.displayInline], children: [delete]))
        }
        return UIMenu(children: groups)
    }

    private func performCollectionAction(
        for target: LibraryCollectionQueueTarget,
        action: @escaping ([MediaItemID]) -> Void
    ) {
        guard collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.collectionActionTask = nil }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: target,
                    from: self.viewModel.library
                )
                try Task.checkCancellation()
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法执行操作"),
                        message: L("这个集合没有可用的歌曲。")
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
    }

    private func shareCollection(_ target: LibraryCollectionQueueTarget) {
        guard let mediaShareResolver,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.collectionActionTask = nil }
            do {
                let tracks = try await LibraryCollectionTrackLoader.tracks(
                    for: target,
                    from: self.viewModel.library
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
    }

    private func requestDeleteAlbum(target: LibraryCollectionQueueTarget, title: String) {
        guard case .album = target,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        let alert = UIAlertController(
            title: L("删除专辑？"),
            message: L("将删除“%@”及其中的全部歌曲。", title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteAlbum(target)
        })
        present(alert, animated: true)
    }

    private func deleteAlbum(_ target: LibraryCollectionQueueTarget) {
        guard case .album = target, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.collectionActionTask = nil }
            do {
                let itemIDs = Set(try await LibraryCollectionTrackLoader.itemIDs(
                    for: target,
                    from: self.viewModel.library
                ))
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法删除专辑"),
                        message: L("这张专辑没有可删除的歌曲。")
                    )
                    return
                }
                _ = try await self.viewModel.library.delete(itemIDs)
                self.viewModel.removeDeletedTracks(itemIDs)
                self.viewModel.refresh(section: .albums)
                self.viewModel.refreshOverview()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除专辑"), message: error.localizedDescription)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }
}

extension LibraryCollectionsViewController: UICollectionViewDelegate {
    public func collectionView(
        _: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .album(id): onSelectAlbum?(id)
        case .noAlbum: onSelectNoAlbum?()
        case let .artist(id): onSelectArtist?(id)
        case let .genre(id): onSelectGenre?(id)
        case let .folder(path): onSelectFolder?(path)
        case .status: break
        }
    }

    public func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              let menu = makeCollectionContextMenu(for: item)
        else { return nil }
        let configuration = UIContextMenuConfiguration(
            identifier: NSString(string: String(describing: item)),
            previewProvider: nil
        ) { _ in menu }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    public func collectionView(
        _: UICollectionView,
        willDisplay _: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              isLastContentItem(item)
        else { return }
        viewModel.loadNextPage(for: section)
    }

    private func isLastContentItem(_ item: CollectionItem) -> Bool {
        switch item {
        case let .album(id): return orderedAlbums.last?.id == id
        case .noAlbum: return false
        case let .artist(id): return orderedArtists.last?.id == id
        case let .genre(id): return orderedGenres.last?.id == id
        case let .folder(path): return orderedFolders.last?.path == path
        case .status: return false
        }
    }
}

@MainActor
final class LibraryCollectionAlbumListCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionAlbumListCell"

    private let artworkView = MusicFreeUIKitArtworkView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let rowStack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1

        textStack.axis = .vertical
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = MusicFreeSpacingTokens.medium
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(artworkView)
        rowStack.addArrangedSubview(textStack)
        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 56),
            artworkView.heightAnchor.constraint(equalToConstant: 56),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        titleLabel.text = nil
        subtitleLabel.text = nil
    }

    func configure(
        album: Album,
        subtitle: String?,
        artworkServing: (any ArtworkServing)?
    ) {
        titleLabel.text = album.title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        accessibilityLabel = album.title
        accessibilityValue = subtitle
        accessibilityTraits = [.button]
        artworkView.placeholderTitle = album.title
        artworkView.accessibilityLabel = L("%@ album artwork", album.title)
        artworkBinding.configure(
            artworkID: album.artworkID,
            maximumPixelDimension: 160,
            serving: artworkServing
        )
    }
}

@MainActor
final class LibraryCollectionAlbumCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionAlbumCell"

    private let artworkView = MusicFreeUIKitArtworkView(fillsAvailableWidth: true)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 2
        subtitleLabel.font = MusicFreeUIFontTokens.caption
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = true

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
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
        subtitleLabel.isHidden = true
    }

    func configure(
        album: Album,
        subtitle: String?,
        artworkServing: (any ArtworkServing)?,
        artworkPixelDimension: Int
    ) {
        titleLabel.text = album.title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        accessibilityLabel = album.title
        // Keep the artist as the cell's primary accessibility value.  The
        // visual subtitle may also contain year/track-count metadata, but the
        // browse-page contract exposes the artist as the stable secondary
        // value used by VoiceOver and UI regression locators.
        let artistValue = subtitle?
            .split(separator: " · ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        accessibilityValue = artistValue?.isEmpty == false ? artistValue : subtitle
        accessibilityHint = subtitle
        accessibilityTraits = [.button]
        artworkView.accessibilityLabel = L("%@ album artwork", album.title)
        artworkView.placeholderTitle = album.title
        artworkBinding.configure(
            artworkID: album.artworkID,
            maximumPixelDimension: artworkPixelDimension,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryCollectionNoAlbumCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionNoAlbumCell"

    private let artworkView = MusicFreeUIKitArtworkView(
        placeholderSystemImage: "rectangle.stack.badge.minus",
        fillsAvailableWidth: true
    )
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 2
        subtitleLabel.font = MusicFreeUIFontTokens.caption
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 2

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(trackCount: Int) {
        let title = L("无专辑")
        let subtitle = L("%d tracks", trackCount)
        artworkView.image = nil
        artworkView.isLoading = false
        artworkView.placeholderTitle = title
        artworkView.accessibilityLabel = L("无专辑封面")
        titleLabel.text = title
        subtitleLabel.text = subtitle
        accessibilityLabel = title
        accessibilityValue = subtitle
        accessibilityTraits = [.button]
    }
}

@MainActor
private final class LibraryCollectionArtistCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionArtistCell"

    private let artworkView = MusicFreeUIKitArtworkView()
    private let titleLabel = UILabel()
    private let stack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.placeholderSystemImage = "person.fill"
        artworkView.setContentHuggingPriority(.required, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 52),
            artworkView.heightAnchor.constraint(equalToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
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
    }

    func configure(artist: Artist, artworkServing: (any ArtworkServing)?) {
        titleLabel.text = artist.name
        accessibilityLabel = artist.name
        accessibilityTraits = [.button]
        artworkView.accessibilityLabel = L("%@ artist artwork", artist.name)
        artworkView.placeholderTitle = artist.name
        artworkBinding.configure(
            artworkID: artist.artworkID,
            maximumPixelDimension: 160,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryCollectionTextCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionTextCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let trailingLabel = UILabel()
    private let textStack = UIStackView()
    private let rowStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1
        trailingLabel.font = MusicFreeUIFontTokens.rowSubtitle
        trailingLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textStack.axis = .vertical
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = MusicFreeSpacingTokens.medium
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(iconView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(trailingLabel)
        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            iconView.heightAnchor.constraint(equalToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
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
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        trailingLabel.text = nil
        iconView.image = nil
    }

    func configure(
        title: String,
        subtitle: String?,
        trailingText: String? = nil,
        systemImage: String,
        accessibilityLabel: String
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        trailingLabel.text = trailingText
        trailingLabel.isHidden = trailingText?.isEmpty != false
        iconView.image = UIImage(systemName: systemImage)
        self.accessibilityLabel = accessibilityLabel
        accessibilityValue = [subtitle, trailingText]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityTraits = [.button]
    }
}

@MainActor
private final class LibraryCollectionsHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "LibraryCollectionsHeaderView"
    private let header = MusicFreeUIKitSectionHeaderView(title: "")

    var titleText: String = "" {
        didSet { header.titleText = titleText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
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
private final class LibraryCollectionsStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionsStatusCell"
    private var stateView: UIView?

    func configure(status: String, section: LibrarySection, retry: @escaping () -> Void) {
        stateView?.removeFromSuperview()
        let nextView: UIView
        switch status {
        case "loading":
            nextView = MusicFreeUIKitLoadingStateView(label: L("正在载入%@", section.title))
        case "failed":
            nextView = MusicFreeUIKitErrorStateView(
                message: L("无法载入%@。", section.title),
                retryTitle: L("重试"),
                retry: retry
            )
        default:
            nextView = MusicFreeUIKitEmptyStateView(
                title: emptyTitle(for: section),
                message: emptyMessage(for: section),
                systemImage: section.systemImage
            )
        }
        nextView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nextView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        stateView = nextView
    }

    private func emptyTitle(for section: LibrarySection) -> String {
        switch section {
        case .albums: return L("暂无专辑")
        case .artists: return L("暂无艺人")
        case .genres: return L("暂无流派")
        case .folders: return L("暂无文件夹")
        default: return L("资料库为空")
        }
    }

    private func emptyMessage(for section: LibrarySection) -> String {
        switch section {
        case .albums: return L("导入带有专辑信息的本地音频后会显示在这里。")
        case .artists: return L("导入带有艺人信息的本地音频后会显示在这里。")
        case .genres: return L("导入带有流派信息的本地音频后会显示在这里。")
        case .folders: return L("导入本地文件夹后会显示在这里。")
        default: return L("导入本地音频后会显示在这里。")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
