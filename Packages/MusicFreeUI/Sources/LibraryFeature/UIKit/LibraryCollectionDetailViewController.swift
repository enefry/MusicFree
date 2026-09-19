import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// Native UIKit detail surface for a library collection.
///
/// This controller deliberately keeps the first detail slice narrow: it owns
/// the collection header, filtered track query, playback actions and rendering
/// states. Editing/deletion/playlist actions remain feature follow-ups so the
/// migration can be validated one interaction boundary at a time.
@MainActor
public final class LibraryCollectionDetailViewController: UIViewController {
    public enum Kind: Hashable, Sendable {
        case album(AlbumID)
        case albums([AlbumID])
        case noAlbum
        case artist(ArtistID)
        case genre(GenreID)
        case folder(String)

        var systemImage: String {
            switch self {
            case .album, .albums: return "square.stack"
            case .noAlbum: return "rectangle.stack.badge.minus"
            case .artist: return "person.2"
            case .genre: return "guitars"
            case .folder: return "folder"
            }
        }

        var defaultTitle: String {
            switch self {
            case .noAlbum: return L("无专辑")
            case .albums: return L("专辑")
            default: return systemImage
            }
        }
    }

    private var isAlbumCollection: Bool {
        switch kind {
        case .album, .albums:
            return true
        default:
            return false
        }
    }

    private enum DetailSection: Hashable {
        case header
        case tracks
        case status
    }

    private enum DetailItem: Hashable {
        case header
        case track(MediaItemID)
        case status(String)
    }

    private enum LoadState: Equatable {
        case loading
        case loaded
        case empty
        case failed(String)
    }

    public let kind: Kind
    public let library: any LibraryServing
    public let artworkServing: (any ArtworkServing)?
    public let metadataEnrichment: (any MetadataEnrichmentServing)?
    private let mediaShareResolver: LibraryMediaShareResolver?
    public var onPlayTracks: (([MediaItemID], Bool) -> Void)?
    public var onPlayTrack: ((MediaItemID) -> Void)?
    public var onSelectTrack: ((MediaItemID) -> Void)?
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)?
    public var onEnqueueTracks: (([MediaItemID]) -> Void)?
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)?
    public var onAlbumUpdated: ((Album) -> Void)?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<DetailSection, DetailItem>!
    private var loadTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var pendingChangeTask: Task<Void, Never>?
    private var pendingTrackIDs = Set<MediaItemID>()
    private var pendingArtworkIDs = Set<ArtworkID>()
    private var pendingMetadataRefresh = false
    private var pendingStructuralRefresh = false
    private var viewModelObservation: AnyCancellable?
    private var loadState: LoadState = .loading
    private var tracks: [Track] = []
    private var trackByID: [MediaItemID: Track] = [:]
    private var artistNames: [ArtistID: String] = [:]
    private var collectionTitle: String
    private var collectionSubtitle: String?
    private var artworkID: ArtworkID?
    private var collectionAlbum: Album?
    private var knownAlbumIDs = Set<AlbumID>()
    private var favoriteMutationIDs: Set<MediaItemID> = []
    private var deletingTrackIDs: Set<MediaItemID> = []
    private var selectedTrackIDs: Set<MediaItemID> = []
    private var isEditingSelection = false
    private var renderedSelectedTrackIDs = Set<MediaItemID>()
    private var renderedIsEditingSelection = false
    private var pendingDeleteTrack: Track?
    private var collectionActionTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?

    public init(
        kind: Kind,
        title: String? = nil,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil
    ) {
        self.kind = kind
        self.library = library
        self.artworkServing = artworkServing
        self.metadataEnrichment = metadataEnrichment
        mediaShareResolver = mediaSourceResolver.map {
            LibraryMediaShareResolver(sourceResolver: $0)
        }
        collectionTitle = title ?? kind.defaultTitle
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        super.init(nibName: nil, bundle: nil)
        if isAlbumCollection {
            // Album detail repeats the title in the hero. The reference
            // navigation bar intentionally keeps only the back/menu actions.
            self.title = nil
        } else {
            self.title = title ?? kind.defaultTitle
        }
        restorationIdentifier = "library.collectionDetail.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.collectionDetail"
        navigationItem.largeTitleDisplayMode = .never

        configureCollectionView()
        configureDataSource()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        configureNavigationItems()
        renderSnapshot()
        observeLibraryChanges()
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    override public func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        collectionView
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass
        else {
            return
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        collectionActionTask?.cancel()
        collectionActionTask = nil
        shareTask?.cancel()
        shareTask = nil
    }

    deinit {
        loadTask?.cancel()
        libraryChangeTask?.cancel()
        pendingChangeTask?.cancel()
        collectionActionTask?.cancel()
        shareTask?.cancel()
    }

    private func configureNavigationItems() {
        if isEditingSelection {
            let doneItem = {
                if #available(iOS 26.0, *) {
                    UIBarButtonItem(
                        title: L("完成"),
                        style: .prominent,
                        target: self,
                        action: #selector(finishEditingSelection)
                    )
                } else {
                    UIBarButtonItem(
                        title: L("完成"),
                        image: nil,
                        target: self,
                        action: #selector(finishEditingSelection)
                    )
                }
            }()

            doneItem.accessibilityIdentifier = "library.collection.finishSelection"

            let deleteItem = UIBarButtonItem(
                barButtonSystemItem: .trash,
                target: self,
                action: #selector(requestDeleteSelectedTracks)
            )
            deleteItem.accessibilityLabel = L("删除所选歌曲")
            deleteItem.accessibilityIdentifier = "library.collection.deleteSelected"
            deleteItem.isEnabled = !selectedTrackIDs.isEmpty && deletingTrackIDs.isEmpty
            navigationItem.rightBarButtonItems = [doneItem, deleteItem]
        } else {
            let busy = collectionActionTask != nil
            let share = UIAction(
                title: L("分享"),
                image: UIImage(systemName: "square.and.arrow.up"),
                attributes: mediaShareResolver == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                self?.presentCollectionShareSheet()
            }
            let select = UIAction(
                title: L("选择歌曲"),
                image: UIImage(systemName: "checkmark.circle"),
                attributes: tracks.isEmpty || loadState != .loaded ? [.disabled] : []
            ) { [weak self] _ in
                self?.beginEditingSelection()
            }

            var managementActions: [UIMenuElement] = []
            if case .album = kind {
                managementActions.append(UIAction(
                    title: L("编辑专辑"),
                    image: UIImage(systemName: "pencil"),
                    attributes: collectionAlbum == nil ? [.disabled] : []
                ) { [weak self] _ in
                    self?.editAlbum()
                })
            }
            managementActions.append(select)

            let addToPlaylist = UIAction(
                title: L("添加到播放列表"),
                image: UIImage(systemName: "text.badge.plus"),
                attributes: onAddTracksToPlaylist == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                self?.performCollectionPlaylistAction()
            }
            let playNext = UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: onEnqueueNextTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                self?.performCollectionQueueAction(placement: .next)
            }
            let enqueue = UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                attributes: onEnqueueTracks == nil || busy ? [.disabled] : []
            ) { [weak self] _ in
                self?.performCollectionQueueAction(placement: .end)
            }
            var menuGroups: [UIMenuElement] = [
                UIMenu(
                    title: "",
                    options: [.displayAsPalette, .displayInline],
                    preferredElementSize: .large,
                    children: [share]
                ),
                UIMenu(title: "", options: [.displayInline], children: managementActions),
                UIMenu(
                    title: "",
                    options: [.displayInline],
                    children: [addToPlaylist, playNext, enqueue]
                ),
            ]
            if isAlbumCollection {
                let deleteAlbum = UIAction(
                    title: L("删除专辑"),
                    image: UIImage(systemName: "trash"),
                    attributes: busy ? [.destructive, .disabled] : [.destructive]
                ) { [weak self] _ in
                    self?.requestDeleteAlbum()
                }
                menuGroups.append(
                    UIMenu(title: "", options: [.displayInline], children: [deleteAlbum])
                )
            }
            let menu = UIMenu(children: menuGroups)
            let menuItem = UIBarButtonItem(
                image: UIImage(systemName: "ellipsis"),
                menu: menu
            )
            menuItem.accessibilityLabel = L("集合选项")
            menuItem.accessibilityIdentifier = "library.collection.menu"
            navigationItem.rightBarButtonItems = [menuItem]
        }
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "library.collectionDetail.collection"
        collectionView.register(
            LibraryCollectionDetailHeaderCell.self,
            forCellWithReuseIdentifier: LibraryCollectionDetailHeaderCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionDetailTrackCell.self,
            forCellWithReuseIdentifier: LibraryCollectionDetailTrackCell.reuseIdentifier
        )
        collectionView.register(
            LibraryCollectionDetailStatusCell.self,
            forCellWithReuseIdentifier: LibraryCollectionDetailStatusCell.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<DetailSection, DetailItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            switch item {
            case .header:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionDetailHeaderCell.reuseIdentifier,
                    for: indexPath
                )
                guard let headerCell = cell as? LibraryCollectionDetailHeaderCell else {
                    return cell
                }
                headerCell.configure(
                    title: self.collectionTitle,
                    subtitle: self.collectionSubtitle,
                    artworkID: self.artworkID,
                    placeholderSystemImage: self.kind.systemImage,
                    artworkServing: self.artworkServing,
                    isAlbumHero: {
                        switch self.kind {
                        case .album, .albums: return true
                        default: return false
                        }
                    }(),
                    isEnabled: !self.tracks.isEmpty,
                    play: { [weak self] in self?.playAll(shuffle: false) },
                    shuffle: { [weak self] in self?.playAll(shuffle: true) }
                )
                headerCell.accessibilityIdentifier = "library.collection.header"
                return headerCell

            case let .track(trackID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionDetailTrackCell.reuseIdentifier,
                    for: indexPath
                )
                guard let trackCell = cell as? LibraryCollectionDetailTrackCell,
                      let track = self.trackByID[trackID]
                else { return cell }
                let albumTrackNumber: String?
                if isAlbumCollection {
                    albumTrackNumber = LibraryAlbumTrackOrdering.displayNumber(
                        for: track,
                        in: self.tracks
                    ) ?? self.tracks.firstIndex(where: { $0.id == track.id }).map { String($0 + 1) }
                } else {
                    albumTrackNumber = nil
                }
                trackCell.configure(
                    track: track,
                    subtitle: self.subtitle(for: track),
                    artworkServing: self.artworkServing,
                    albumTrackNumber: albumTrackNumber,
                    isEditing: self.isEditingSelection,
                    isSelected: self.selectedTrackIDs.contains(track.id),
                    menu: self.makeTrackContextMenu(for: track)
                )
                trackCell.accessibilityIdentifier = "library.collection.track.play.\(track.id.externalID)"
                return trackCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryCollectionDetailStatusCell.reuseIdentifier,
                    for: indexPath
                )
                guard let statusCell = cell as? LibraryCollectionDetailStatusCell else {
                    return cell
                }
                statusCell.configure(
                    status: status,
                    title: self.collectionTitle,
                    retry: { [weak self] in
                        guard let self else { return }
                        self.loadTask?.cancel()
                        self.loadTask = Task { @MainActor [weak self] in
                            await self?.load()
                        }
                    }
                )
                statusCell.accessibilityIdentifier = "library.collectionDetail.status"
                return statusCell
            }
        }
        collectionView.delegate = self
    }

    private func renderSnapshot(reconfigure items: Set<DetailItem> = []) {
        guard isViewLoaded else { return }
        var snapshot = NSDiffableDataSourceSnapshot<DetailSection, DetailItem>()
        switch loadState {
        case .loading:
            snapshot.appendSections([.status])
            snapshot.appendItems([.status("loading")], toSection: .status)
        case .failed:
            snapshot.appendSections([.status])
            snapshot.appendItems([.status("failed")], toSection: .status)
        case .empty:
            snapshot.appendSections([.status])
            snapshot.appendItems([.status("empty")], toSection: .status)
        case .loaded:
            snapshot.appendSections([.header, .tracks])
            snapshot.appendItems([.header], toSection: .header)
            snapshot.appendItems(tracks.map { .track($0.id) }, toSection: .tracks)
        }

        let previousSnapshot = dataSource.snapshot()
        let structureChanged = previousSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || previousSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let existingItems = Set(previousSnapshot.itemIdentifiers)
        var itemsToReconfigure = snapshot.itemIdentifiers.filter {
            items.contains($0) && existingItems.contains($0)
        }
        let selectionChanged = renderedIsEditingSelection != isEditingSelection
            || renderedSelectedTrackIDs != selectedTrackIDs
        if selectionChanged {
            let changedSelectionIDs: Set<MediaItemID>
            if renderedIsEditingSelection != isEditingSelection {
                changedSelectionIDs = Set(tracks.map(\.id))
            } else {
                changedSelectionIDs = renderedSelectedTrackIDs
                    .symmetricDifference(selectedTrackIDs)
            }
            itemsToReconfigure.append(contentsOf: snapshot.itemIdentifiers.filter { item in
                guard case let .track(trackID) = item else { return false }
                return changedSelectionIDs.contains(trackID) && existingItems.contains(item)
            })
        }
        renderedSelectedTrackIDs = selectedTrackIDs
        renderedIsEditingSelection = isEditingSelection
        configureNavigationItems()
        guard structureChanged || !itemsToReconfigure.isEmpty else { return }
        if #available(iOS 15.0, *), !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
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
        let trackCategories: Set<LibraryChangeCategory> = [
            .tracks, .artwork, .deletions,
        ]
        if !categories.isDisjoint(with: trackCategories) {
            pendingTrackIDs.formUnion(change.affectedIDs.trackIDs)
            pendingArtworkIDs.formUnion(change.affectedIDs.artworkIDs)
            // A producer without typed IDs may have added/removed a track.
            // Defer one bounded query until the burst settles instead of
            // rebuilding the detail surface for every metadata item.
            if change.affectedIDs.trackIDs.isEmpty {
                pendingStructuralRefresh = true
            }
        }

        switch kind {
        case let .album(id):
            if change.affectedIDs.albumIDs.contains(id) || categories.contains(.albums) {
                pendingMetadataRefresh = true
            }
        case let .albums(ids):
            if !change.affectedIDs.albumIDs.isDisjoint(with: ids) || categories.contains(.albums) {
                pendingMetadataRefresh = true
            }
        case .noAlbum:
            if categories.contains(.albums) {
                pendingStructuralRefresh = true
            }
        case let .artist(id):
            if change.affectedIDs.artistIDs.contains(id) || categories.contains(.artists) {
                pendingMetadataRefresh = true
            }
        case let .genre(id):
            if change.affectedIDs.genreIDs.contains(id) || categories.contains(.genres) {
                pendingMetadataRefresh = true
            }
        case .folder:
            if categories.contains(.deletions) || categories.contains(.tracks) {
                pendingStructuralRefresh = pendingStructuralRefresh || change.affectedIDs.trackIDs.isEmpty
            }
        }

        // A related artist-name update changes only the detail header/subtitles
        // when that artist is actually used by the visible collection.
        let visibleArtistIDs = Set(tracks.flatMap(\.artistIDs))
        if !visibleArtistIDs.isDisjoint(with: change.affectedIDs.artistIDs) {
            pendingMetadataRefresh = true
        }
        schedulePendingChangeProcessing()
    }

    private func schedulePendingChangeProcessing() {
        guard pendingChangeTask == nil else { return }
        pendingChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50000000)
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
        let trackIDs = pendingTrackIDs
        let artworkIDs = pendingArtworkIDs
        let metadataRefresh = pendingMetadataRefresh
        let structuralRefresh = pendingStructuralRefresh
        pendingTrackIDs.removeAll()
        pendingArtworkIDs.removeAll()
        pendingMetadataRefresh = false
        pendingStructuralRefresh = false

        if structuralRefresh {
            await reloadTracksPreservingSurface()
        } else if !trackIDs.isEmpty {
            await refreshTracks(trackIDs)
        }

        if metadataRefresh {
            await loadCollectionMetadata(from: tracks)
            renderSnapshot(reconfigure: [.header])
        } else if !artworkIDs.isEmpty {
            let affected = tracks.contains { track in
                guard let artworkID = track.artworkID else { return false }
                return artworkIDs.contains(artworkID)
            }
            if affected {
                renderSnapshot(reconfigure: [.header])
            }
        }

        if !pendingTrackIDs.isEmpty || pendingMetadataRefresh || pendingStructuralRefresh {
            schedulePendingChangeProcessing()
        }
    }

    private func reloadTracksPreservingSurface() async {
        guard !isEditingSelection else { return }
        do {
            let loadedTracks = orderedTracks(try await loadTracks())
            guard !Task.isCancelled else { return }
            tracks = loadedTracks
            trackByID = Dictionary(uniqueKeysWithValues: loadedTracks.map { ($0.id, $0) })
            selectedTrackIDs = selectedTrackIDs.intersection(Set(loadedTracks.map(\.id)))
            loadState = loadedTracks.isEmpty ? .empty : .loaded
            await loadCollectionMetadata(from: loadedTracks)
            renderSnapshot(reconfigure: [.header])
        } catch is CancellationError {
            return
        } catch {
            // Keep the visible surface intact on a background refresh error.
        }
    }

    private func refreshTracks(_ ids: Set<MediaItemID>) async {
        guard !ids.isEmpty else { return }
        var nextTracks = tracks
        var changedTrackIDs = Set<MediaItemID>()
        var structureChanged = false

        for id in ids {
            guard !Task.isCancelled else { return }
            let updated = try? await library.track(id: id)
            if let updated, trackMatchesCollection(updated) {
                if let index = nextTracks.firstIndex(where: { $0.id == id }) {
                    if nextTracks[index] != updated {
                        nextTracks[index] = updated
                        changedTrackIDs.insert(id)
                    }
                } else {
                    nextTracks.append(updated)
                    structureChanged = true
                }
            } else if nextTracks.contains(where: { $0.id == id }) {
                nextTracks.removeAll { $0.id == id }
                structureChanged = true
            }
        }

        guard structureChanged || !changedTrackIDs.isEmpty else { return }
        tracks = orderedTracks(nextTracks)
        trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        selectedTrackIDs = selectedTrackIDs.intersection(Set(tracks.map(\.id)))
        loadState = tracks.isEmpty ? .empty : .loaded
        if structureChanged {
            await loadCollectionMetadata(from: tracks)
            renderSnapshot(reconfigure: [.header])
        } else {
            // Track metadata/artwork changes only reconfigure the affected
            // rows; the collection header and untouched rows stay mounted.
            renderSnapshot(reconfigure: Set(changedTrackIDs.map(DetailItem.track)))
        }
    }

    private func trackMatchesCollection(_ track: Track) -> Bool {
        guard track.id.sourceID == .local else { return false }
        switch kind {
        case let .album(id): return track.albumID == id
        case let .albums(ids): return track.albumID.map(ids.contains) == true
        case .noAlbum:
            guard let albumID = track.albumID else { return true }
            return !knownAlbumIDs.contains(albumID)
        case let .artist(id): return track.artistIDs.contains(id)
        case let .genre(id): return track.genreIDs.contains(id)
        case let .folder(path): return track.folderPath == path
        }
    }

    private func load() async {
        loadState = .loading
        tracks = []
        artistNames = [:]
        trackByID = [:]
        knownAlbumIDs = []
        renderSnapshot()

        do {
            let loadedTracks = try await loadTracks()
            try Task.checkCancellation()
            tracks = orderedTracks(loadedTracks)
            trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            await loadCollectionMetadata(from: tracks)
            try Task.checkCancellation()
            loadState = tracks.isEmpty ? .empty : .loaded
            if isAlbumCollection {
                // Keep the album title exclusively in the hero header.
            } else if title == nil || title == kind.systemImage {
                title = collectionTitle
            }
            renderSnapshot()
        } catch is CancellationError {
            return
        } catch {
            tracks = []
            trackByID = [:]
            loadState = .failed(error.localizedDescription)
            renderSnapshot()
        }
    }

    private var collectionQueueTarget: LibraryCollectionQueueTarget {
        switch kind {
        case let .album(id): return .album(id)
        case let .albums(ids): return .albums(ids)
        case .noAlbum: return .noAlbum
        case let .artist(id): return .artist(id)
        case let .genre(id): return .genre(id)
        case let .folder(path): return .folder(path)
        }
    }

    private func performCollectionQueueAction(placement: LibraryCollectionQueuePlacement) {
        let action = placement == .next ? onEnqueueNextTracks : onEnqueueTracks
        guard let action, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.configureNavigationItems()
            }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: self.collectionQueueTarget,
                    from: self.library
                )
                try Task.checkCancellation()
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法更新播放队列"),
                        message: L("这个集合没有可加入播放队列的歌曲。")
                    )
                    return
                }
                action(itemIDs)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(
                    title: L("无法更新播放队列"),
                    message: error.localizedDescription
                )
            }
        }
        configureNavigationItems()
    }

    private func performCollectionPlaylistAction() {
        guard let action = onAddTracksToPlaylist, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.configureNavigationItems()
            }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: self.collectionQueueTarget,
                    from: self.library
                )
                try Task.checkCancellation()
                guard !itemIDs.isEmpty else {
                    self.presentMessage(
                        title: L("无法添加到播放列表"),
                        message: L("这个集合没有可添加到播放列表的歌曲。")
                    )
                    return
                }
                action(itemIDs)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(
                    title: L("无法添加到播放列表"),
                    message: error.localizedDescription
                )
            }
        }
        configureNavigationItems()
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentCollectionShareSheet() {
        guard let mediaShareResolver,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.configureNavigationItems()
            }
            do {
                let tracks = try await LibraryCollectionTrackLoader.tracks(
                    for: self.collectionQueueTarget,
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
        configureNavigationItems()
    }

    private func requestDeleteAlbum() {
        guard isAlbumCollection,
              collectionActionTask == nil,
              presentedViewController == nil
        else { return }
        let alert = UIAlertController(
            title: L("删除专辑？"),
            message: L("将删除“%@”及其中的全部歌曲。", collectionTitle),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteAlbum()
        })
        present(alert, animated: true)
    }

    private func deleteAlbum() {
        guard isAlbumCollection, collectionActionTask == nil else { return }
        collectionActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.collectionActionTask = nil
                self.configureNavigationItems()
            }
            do {
                let itemIDs = Set(try await LibraryCollectionTrackLoader.itemIDs(
                    for: self.collectionQueueTarget,
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
                try Task.checkCancellation()
                self.navigationController?.popViewController(animated: true)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除专辑"), message: error.localizedDescription)
            }
        }
        configureNavigationItems()
    }

    @objc private func editAlbum() {
        guard case .album = kind,
              let collectionAlbum,
              presentedViewController == nil,
              !isEditingSelection
        else { return }

        let editor = LibraryAlbumMetadataEditorViewController(
            album: collectionAlbum,
            library: library,
            artworkServing: artworkServing,
            metadataEnrichment: metadataEnrichment,
            onSaved: { [weak self] updated in
                guard let self else { return }
                self.collectionAlbum = updated
                self.collectionTitle = updated.title
                self.artworkID = updated.artworkID ?? self.tracks.first?.artworkID
                self.collectionSubtitle = L("%d tracks", self.tracks.count)
                self.title = updated.title
                self.onAlbumUpdated?(updated)
                self.renderSnapshot()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.reloadTracksPreservingSurface()
                }
            }
        )
        let navigationController = UINavigationController(rootViewController: editor)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        present(navigationController, animated: true)
    }

    private func loadTracks() async throws -> [Track] {
        let page = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        switch kind {
        case let .album(albumID):
            return try await LibraryCollectionTrackLoader.tracks(
                for: .album(albumID),
                from: library
            )
        case let .albums(albumIDs):
            return try await LibraryCollectionTrackLoader.tracks(
                for: .albums(albumIDs),
                from: library
            )
        case .noAlbum:
            let content = try await LibraryCollectionTrackLoader.noAlbumContent(from: library)
            knownAlbumIDs = content.knownAlbumIDs
            return content.tracks
        case let .artist(artistID):
            return try await library.browseTracks(
                matching: TrackQuery(sourceID: .local, artistID: artistID),
                page: page
            ).elements
        case let .genre(genreID):
            return try await library.browseTracks(
                matching: TrackQuery(sourceID: .local, genreID: genreID),
                page: page
            ).elements
        case let .folder(path):
            let tracks = try await library.browseTracks(
                matching: TrackQuery(sourceID: .local),
                page: page
            ).elements
            return tracks.filter { $0.folderPath == path }
        }
    }

    private func loadCollectionMetadata(from tracks: [Track]) async {
        switch kind {
        case let .album(albumID):
            if let album = try? await findAlbum(albumID) {
                collectionAlbum = album
                collectionTitle = album.title
                artworkID = album.artworkID ?? tracks.first?.artworkID
                let names = try? await LibraryArtistNameLoader.load(
                    artistIDs: Set(album.artistIDs + tracks.flatMap(\.artistIDs)),
                    sourceID: .local,
                    from: library
                )
                artistNames = names ?? [:]
                var parts = album.artistIDs.compactMap { artistNames[$0] }
                if let albumType = album.albumType {
                    parts.append(albumTypeTitle(albumType))
                }
                if let year = album.releaseYear { parts.append(String(year)) }
                collectionSubtitle = parts.isEmpty ? L("%d tracks", tracks.count) : parts.joined(separator: " · ")
            }
        case let .albums(albumIDs):
            let albums = (try? await findAlbums(albumIDs)) ?? []
            guard let firstAlbum = albums.first else {
                collectionTitle = L("专辑")
                artworkID = tracks.first?.artworkID
                collectionSubtitle = L("%d tracks", tracks.count)
                return
            }
            collectionAlbum = nil
            collectionTitle = firstAlbum.title
            artworkID = albums.compactMap(\.artworkID).first ?? tracks.first?.artworkID
            let artistIDs = albums.flatMap(\.artistIDs) + tracks.flatMap(\.artistIDs)
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(artistIDs),
                sourceID: .local,
                from: library
            )) ?? [:]
            var parts = Array(Set(albums.flatMap(\.artistIDs))).compactMap { artistNames[$0] }
            if let albumType = albums.compactMap(\.albumType).first {
                parts.append(albumTypeTitle(albumType))
            }
            if let year = albums.compactMap(\.releaseYear).first {
                parts.append(String(year))
            }
            collectionSubtitle = parts.isEmpty ? L("%d tracks", tracks.count) : parts.joined(separator: " · ")
        case .noAlbum:
            collectionTitle = L("无专辑")
            artworkID = tracks.first?.artworkID
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(tracks.flatMap(\.artistIDs)),
                sourceID: .local,
                from: library
            )) ?? [:]
            collectionSubtitle = L("%d tracks", tracks.count)
        case let .artist(artistID):
            if let artist = try? await findArtist(artistID) {
                collectionTitle = artist.name
                artworkID = artist.artworkID ?? tracks.first?.artworkID
            }
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(tracks.flatMap(\.artistIDs)),
                sourceID: .local,
                from: library
            )) ?? [:]
            collectionSubtitle = L("%d tracks", tracks.count)
        case let .genre(genreID):
            if let genre = try? await findGenre(genreID) {
                collectionTitle = genre.name
            }
            artworkID = tracks.first?.artworkID
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(tracks.flatMap(\.artistIDs)),
                sourceID: .local,
                from: library
            )) ?? [:]
            collectionSubtitle = L("%d tracks", tracks.count)
        case let .folder(path):
            collectionTitle = path
            artworkID = tracks.first?.artworkID
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(tracks.flatMap(\.artistIDs)),
                sourceID: .local,
                from: library
            )) ?? [:]
            collectionSubtitle = L("%d tracks", tracks.count)
        }
    }

    private func findAlbum(_ id: AlbumID) async throws -> Album? {
        try await LibraryAlbumLoader.load(albumID: id, sourceID: .local, from: library)
    }

    private func findAlbums(_ ids: [AlbumID]) async throws -> [Album] {
        let page = try await library.browseAlbums(
            matching: AlbumQuery(sourceID: .local),
            page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        let wanted = Set(ids)
        return page.elements.filter { wanted.contains($0.id) }
    }

    private func findArtist(_ id: ArtistID) async throws -> Artist? {
        let page = try await library.browseArtists(
            matching: ArtistQuery(sourceID: .local),
            page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        return page.elements.first { $0.id == id }
    }

    private func findGenre(_ id: GenreID) async throws -> Genre? {
        let page = try await library.browseGenres(
            matching: GenreQuery(sourceID: .local),
            page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        return page.elements.first { $0.id == id }
    }

    private func orderedTracks(_ tracks: [Track]) -> [Track] {
        switch kind {
        case .album, .albums:
            return LibraryAlbumTrackOrdering.ordered(tracks)
        default:
            return tracks.sorted {
                let lhs = LibrarySortSupport.normalizedSortValue($0.sortTitle ?? $0.title)
                let rhs = LibrarySortSupport.normalizedSortValue($1.sortTitle ?? $1.title)
                if lhs != rhs { return lhs < rhs }
                return $0.id < $1.id
            }
        }
    }

    private func subtitle(for track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func albumTypeTitle(_ value: AlbumType) -> String {
        switch value {
        case .album: return L("专辑")
        case .single: return L("单曲")
        case .extendedPlay: return "EP"
        case .compilation: return L("精选集")
        case .soundtrack: return L("原声带")
        case .live: return L("现场录音")
        case .unknown: return L("专辑")
        }
    }

    private func playAll(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        if let onPlayTracks {
            onPlayTracks(tracks.map(\.id), shuffle)
        } else {
            onPlayTrack?(tracks[0].id)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let section = self.dataSource?.snapshot().sectionIdentifiers[safe: sectionIndex]
            else { return nil }

            switch section {
            case .header:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    // Let the cell's Auto Layout content determine the hero
                    // height. The fitting override below provides the
                    // concrete height after the collection view knows its
                    // width, which avoids the first-pass jump caused by a
                    // large placeholder estimate.
                    heightDimension: .estimated(420)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.medium,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.medium,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return layoutSection
            case .tracks:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = true
                let layoutSection = NSCollectionLayoutSection.list(
                    using: configuration,
                    layoutEnvironment: environment
                )
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.large,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return layoutSection
            case .status:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = false
                let layoutSection = NSCollectionLayoutSection.list(
                    using: configuration,
                    layoutEnvironment: environment
                )
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.large,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.large,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                return layoutSection
            }
        }
    }
}

extension LibraryCollectionDetailViewController: UICollectionViewDelegate {
    public func collectionView(
        _: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .track(trackID) = item
        else { return }
        if isEditingSelection {
            selectedTrackIDs.insert(trackID)
            renderSnapshot()
            return
        }
        if let onPlayTrack {
            onPlayTrack(trackID)
        } else {
            onSelectTrack?(trackID)
        }
    }

    public func collectionView(
        _: UICollectionView,
        didDeselectItemAt indexPath: IndexPath
    ) {
        guard isEditingSelection,
              let item = dataSource.itemIdentifier(for: indexPath),
              case let .track(trackID) = item
        else { return }
        selectedTrackIDs.remove(trackID)
        renderSnapshot()
    }

    public func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .track(trackID) = item,
              let track = trackByID[trackID],
              deletingTrackIDs.isEmpty,
              favoriteMutationIDs.contains(track.id) == false
        else { return nil }

        let configuration = UIContextMenuConfiguration(
            identifier: NSString(string: track.id.externalID),
            previewProvider: nil
        ) { [weak self] _ in
            self?.makeTrackContextMenu(for: track)
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    private func makeTrackContextMenu(for track: Track) -> UIMenu {
        let favorite = UIAction(
            title: track.isFavorite ? L("取消收藏") : L("收藏"),
            image: UIImage(systemName: track.isFavorite ? "star.slash" : "star"),
            state: track.isFavorite ? .on : .off
        ) { [weak self] _ in
            self?.toggleFavorite(track)
        }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.presentShareSheet(for: track)
        }
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: [.destructive]
        ) { [weak self] _ in
            self?.requestDelete(track)
        }
        var actions: [UIMenuElement] = [
            UIAction(
                title: L("播放"),
                image: UIImage(systemName: "play.fill")
            ) { [weak self] _ in
                self?.onPlayTrack?(track.id)
            },
            UIAction(
                title: L("查看歌曲详情"),
                image: UIImage(systemName: "info.circle")
            ) { [weak self] _ in
                self?.onSelectTrack?(track.id)
            },
        ]
        if let enqueueNextTracks = onEnqueueNextTracks {
            actions.append(UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { _ in enqueueNextTracks([track.id]) })
        }
        if let enqueueTracks = onEnqueueTracks {
            actions.append(UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append")
            ) { _ in enqueueTracks([track.id]) })
        }
        if let onAddTracksToPlaylist {
            actions.append(UIAction(
                title: L("添加到播放列表"),
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in onAddTracksToPlaylist([track.id]) })
        }

        return UIMenu(children: [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [favorite, share]
            ),
            UIMenu(title: "", options: [.displayInline], children: actions),
            UIMenu(title: "", options: [.displayInline], children: [delete]),
        ])
    }

    private func toggleFavorite(_ track: Track) {
        guard favoriteMutationIDs.insert(track.id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.favoriteMutationIDs.remove(track.id) }
            do {
                let updated = try await self.library.setFavorite(!track.isFavorite, for: track.id)
                guard let index = self.tracks.firstIndex(where: { $0.id == updated.id }) else {
                    return
                }
                self.tracks[index] = updated
                self.trackByID[updated.id] = updated
                self.renderSnapshot()
            } catch {
                self.presentMessage(title: L("无法更新收藏"), message: error.localizedDescription)
            }
        }
    }

    private func requestDelete(_ track: Track) {
        guard deletingTrackIDs.isEmpty, presentedViewController == nil else { return }
        pendingDeleteTrack = track
        let alert = UIAlertController(
            title: L("删除歌曲？"),
            message: L("删除后将从资料库移除这首歌曲。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { [weak self] _ in
            self?.pendingDeleteTrack = nil
        })
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            guard let self, let pendingDeleteTrack = self.pendingDeleteTrack else { return }
            self.pendingDeleteTrack = nil
            self.delete(pendingDeleteTrack)
        })
        present(alert, animated: true)
    }

    private func delete(_ track: Track) {
        guard deletingTrackIDs.insert(track.id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.deletingTrackIDs.remove(track.id) }
            do {
                _ = try await self.library.delete([track.id])
                self.tracks.removeAll { $0.id == track.id }
                self.trackByID.removeValue(forKey: track.id)
                self.selectedTrackIDs.remove(track.id)
                self.loadState = self.tracks.isEmpty ? .empty : .loaded
                self.renderSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除歌曲"), message: error.localizedDescription)
            }
        }
    }

    @objc private func beginEditingSelection() {
        guard !tracks.isEmpty, loadState == .loaded, deletingTrackIDs.isEmpty else { return }
        isEditingSelection = true
        collectionView.allowsMultipleSelection = true
        configureNavigationItems()
        renderSnapshot()
    }

    @objc private func finishEditingSelection() {
        guard deletingTrackIDs.isEmpty else { return }
        isEditingSelection = false
        selectedTrackIDs.removeAll()
        collectionView.allowsMultipleSelection = false
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        configureNavigationItems()
        renderSnapshot()
    }

    @objc private func requestDeleteSelectedTracks() {
        guard !selectedTrackIDs.isEmpty, deletingTrackIDs.isEmpty else { return }
        let count = selectedTrackIDs.count
        let alert = UIAlertController(
            title: L("删除所选歌曲？"),
            message: L("将从资料库移除 %d 首歌曲。", count),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteSelectedTracks()
        })
        present(alert, animated: true)
    }

    private func deleteSelectedTracks() {
        let itemIDs = selectedTrackIDs
        guard !itemIDs.isEmpty, deletingTrackIDs.isEmpty else { return }
        deletingTrackIDs = itemIDs
        configureNavigationItems()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.deletingTrackIDs.subtract(itemIDs)
                self.configureNavigationItems()
            }
            do {
                _ = try await self.library.delete(itemIDs)
                self.tracks.removeAll { itemIDs.contains($0.id) }
                self.trackByID = Dictionary(uniqueKeysWithValues: self.tracks.map { ($0.id, $0) })
                self.selectedTrackIDs.removeAll()
                self.isEditingSelection = false
                self.collectionView.allowsMultipleSelection = false
                self.loadState = self.tracks.isEmpty ? .empty : .loaded
                self.renderSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除歌曲"), message: error.localizedDescription)
            }
        }
    }

    private func presentShareSheet(for track: Track) {
        guard let mediaShareResolver, shareTask == nil else {
            if mediaShareResolver == nil {
                presentMessage(title: L("无法分享歌曲"), message: L("媒体文件解析服务不可用。"))
            }
            return
        }
        shareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.shareTask = nil }
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
    }
}

@MainActor
private final class LibraryCollectionDetailHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionDetailHeaderCell"

    private let artworkView = MusicFreeUIKitArtworkView(fillsAvailableWidth: true)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let yearAccessibilityLabel = UILabel()
    private let playButton = MusicFreeUIKitPillActionButton(title: L("播放"), systemImage: "play.fill")
    private let shuffleButton = MusicFreeUIKitPillActionButton(title: L("随机播放"), systemImage: "shuffle")
    private let buttonStack = UIStackView()
    private let stack = UIStackView()
    private var fullWidthButtonStackConstraint: NSLayoutConstraint!
    private var albumPlayWidthConstraint: NSLayoutConstraint!
    private var albumShuffleWidthConstraint: NSLayoutConstraint!
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)
    private var isAlbumHero = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = MusicFreeUIFontTokens.screenTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.isHidden = true

        // The rendered subtitle can wrap to a second line for multiple
        // artists or Dynamic Type. Keep a separate, non-visual
        // accessibility node for the year so UI tests and VoiceOver can
        // address the metadata fields independently without changing the
        // reference layout.
        yearAccessibilityLabel.isAccessibilityElement = true
        yearAccessibilityLabel.textColor = .clear
        yearAccessibilityLabel.backgroundColor = .clear
        yearAccessibilityLabel.alpha = 0.01
        yearAccessibilityLabel.translatesAutoresizingMaskIntoConstraints = true
        yearAccessibilityLabel.accessibilityIdentifier = "library.collection.header.year"
        yearAccessibilityLabel.font = MusicFreeUIFontTokens.rowSubtitle
        contentView.addSubview(yearAccessibilityLabel)

        buttonStack.axis = .horizontal
        buttonStack.spacing = MusicFreeSpacingTokens.small
        buttonStack.alignment = .center
        buttonStack.addArrangedSubview(playButton)
        buttonStack.addArrangedSubview(shuffleButton)

        stack.axis = .vertical
        // The reference layout uses a centered, non-full-width hero artwork.
        // Keeping the stack centered prevents a square artwork view from
        // stretching into a wide rectangle when the collection cell is
        // wider than the artwork target.
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(buttonStack)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            artworkView.widthAnchor.constraint(
                equalTo: contentView.widthAnchor,
                multiplier: 0.674
            ),
            artworkView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            // A centered stack does not constrain label intrinsic widths.
            // Explicit label widths keep long titles and multi-artist
            // metadata inside the hero instead of shifting the buttons.
            titleLabel.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            shuffleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        fullWidthButtonStackConstraint = buttonStack.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        fullWidthButtonStackConstraint.isActive = true
        albumPlayWidthConstraint = playButton.widthAnchor.constraint(equalToConstant: 145)
        albumShuffleWidthConstraint = shuffleButton.widthAnchor.constraint(equalToConstant: 52)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.layoutIfNeeded()
        // Keep the accessibility-only node out of Auto Layout's intrinsic
        // height calculation. Its tiny, nearly transparent frame is placed
        // immediately below the metadata line so UI automation/VoiceOver can
        // find the release year independently from the artist label.
        let width: CGFloat = 40
        let height: CGFloat = 18
        yearAccessibilityLabel.frame = CGRect(
            x: max(0, contentView.bounds.width - width),
            y: max(0, subtitleLabel.frame.maxY + 1),
            width: width,
            height: height
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        isAlbumHero = false
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        yearAccessibilityLabel.text = nil
        yearAccessibilityLabel.accessibilityLabel = nil
        yearAccessibilityLabel.accessibilityValue = nil
        playButton.onPrimaryAction = nil
        shuffleButton.onPrimaryAction = nil
    }

    func configure(
        title: String,
        subtitle: String?,
        artworkID: ArtworkID?,
        placeholderSystemImage: String,
        artworkServing: (any ArtworkServing)?,
        isAlbumHero albumHero: Bool,
        isEnabled: Bool,
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) {
        isAlbumHero = albumHero
        titleLabel.text = title
        titleLabel.accessibilityIdentifier = "library.collection.header.title"
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        subtitleLabel.accessibilityIdentifier = "library.collection.header.artist"
        let artistValue = subtitle?
            .split(separator: " · ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        subtitleLabel.accessibilityLabel = artistValue ?? subtitle
        subtitleLabel.accessibilityValue = subtitle
        let yearValue = subtitle?
            .split(separator: " · ", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) })
        yearAccessibilityLabel.text = yearValue
        yearAccessibilityLabel.accessibilityLabel = yearValue
        yearAccessibilityLabel.accessibilityValue = yearValue
        playButton.accessibilityIdentifier = "library.collection.play"
        shuffleButton.accessibilityIdentifier = "library.collection.shuffle"
        accessibilityLabel = title
        accessibilityValue = subtitle
        accessibilityTraits = [.header]
        artworkView.accessibilityLabel = L("%@ collection artwork", title)
        artworkView.placeholderTitle = title
        artworkView.placeholderSystemImage = placeholderSystemImage
        playButton.isEnabled = isEnabled
        shuffleButton.isEnabled = isEnabled
        playButton.onPrimaryAction = play
        shuffleButton.onPrimaryAction = shuffle
        applyControlStyle(isAlbumHero: albumHero)

        artworkBinding.configure(
            artworkID: artworkID,
            maximumPixelDimension: 1_024,
            serving: artworkServing
        )
    }

    private func applyControlStyle(isAlbumHero: Bool) {
        if isAlbumHero {
            // Album detail follows the reference hero: the visually primary
            // Play action sits between the compact shuffle affordance and the
            // trailing download/favorite affordance used by the reference.
            setButtonOrder([playButton, shuffleButton])
            buttonStack.distribution = .fill
            buttonStack.spacing = MusicFreeSpacingTokens.medium
            fullWidthButtonStackConstraint.isActive = false
            albumPlayWidthConstraint.isActive = true
            albumShuffleWidthConstraint.isActive = true
            shuffleButton.actionTitle = ""
            shuffleButton.tintColor = MusicFreeUIColorTokens.foregroundPrimary
            shuffleButton.setTitleColor(MusicFreeUIColorTokens.foregroundPrimary, for: .normal)
            shuffleButton.backgroundColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.45)
            shuffleButton.layer.borderWidth = 0
            shuffleButton.accessibilityLabel = L("随机播放")

            // The album hero's primary action is a high-contrast filled pill.
            // This remains readable in both light and dark appearance modes.
            playButton.tintColor = MusicFreeUIColorTokens.backgroundPrimary
            playButton.setTitleColor(MusicFreeUIColorTokens.backgroundPrimary, for: .normal)
            playButton.backgroundColor = MusicFreeUIColorTokens.foregroundPrimary
            playButton.layer.borderWidth = 0
            playButton.accessibilityLabel = L("播放")
        } else {
            // Artist/genre-style collection heroes use two equal-width pills.
            setButtonOrder([playButton, shuffleButton])
            buttonStack.distribution = .fillEqually
            buttonStack.spacing = MusicFreeSpacingTokens.small
            fullWidthButtonStackConstraint.isActive = true
            albumPlayWidthConstraint.isActive = false
            albumShuffleWidthConstraint.isActive = false
            shuffleButton.actionTitle = L("随机播放")
            shuffleButton.tintColor = MusicFreeUIColorTokens.accent
            shuffleButton.setTitleColor(MusicFreeUIColorTokens.accent, for: .normal)
            shuffleButton.backgroundColor = MusicFreeUIColorTokens.playerControl
            shuffleButton.layer.borderWidth = 0.5
            shuffleButton.accessibilityLabel = L("随机播放")

            playButton.tintColor = MusicFreeUIColorTokens.accent
            playButton.setTitleColor(MusicFreeUIColorTokens.accent, for: .normal)
            playButton.backgroundColor = MusicFreeUIColorTokens.playerControl
            playButton.layer.borderWidth = 0.5
            playButton.accessibilityLabel = L("播放")
        }
    }

    private func setButtonOrder(_ buttons: [UIView]) {
        for arrangedSubview in buttonStack.arrangedSubviews {
            buttonStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        buttons.forEach { buttonStack.addArrangedSubview($0) }
    }
}

@MainActor
private final class LibraryCollectionDetailTrackCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionDetailTrackCell"
    static let artworkPixelDimension = 160

    private let artworkView = MusicFreeUIKitArtworkView()
    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let moreButton = UIButton(type: .system)
    private let selectionIndicator = UIImageView()
    private let rowStack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    override init(frame: CGRect) {
        super.init(frame: frame)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        numberLabel.font = MusicFreeUIFontTokens.rowTitle
        numberLabel.textColor = MusicFreeUIColorTokens.foregroundTertiary
        numberLabel.textAlignment = .center
        numberLabel.numberOfLines = 1
        numberLabel.isHidden = true
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)
        numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        numberLabel.accessibilityTraits = [.staticText]
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.isHidden = true
        textStack.axis = .vertical
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
        rowStack.addArrangedSubview(numberLabel)
        rowStack.addArrangedSubview(artworkView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(moreButton)
        rowStack.addArrangedSubview(selectionIndicator)
        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            numberLabel.widthAnchor.constraint(equalToConstant: 40),
            artworkView.widthAnchor.constraint(equalToConstant: 52),
            artworkView.heightAnchor.constraint(equalToConstant: 52),
            selectionIndicator.widthAnchor.constraint(equalToConstant: 24),
            selectionIndicator.heightAnchor.constraint(equalToConstant: 24),
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
        numberLabel.text = nil
        numberLabel.accessibilityIdentifier = nil
        artworkView.image = nil
        artworkView.isLoading = false
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        moreButton.menu = nil
        moreButton.isHidden = false
        selectionIndicator.isHidden = true
    }

    func configure(
        track: Track,
        subtitle: String?,
        artworkServing: (any ArtworkServing)?,
        albumTrackNumber: String?,
        isEditing: Bool,
        isSelected: Bool,
        menu: UIMenu
    ) {
        let isAlbumTrack = albumTrackNumber != nil
        numberLabel.text = albumTrackNumber
        numberLabel.isHidden = !isAlbumTrack
        numberLabel.accessibilityIdentifier = isAlbumTrack
            ? "library.collection.track.number.\(track.id.externalID)"
            : nil
        numberLabel.accessibilityLabel = albumTrackNumber
        artworkView.isHidden = isAlbumTrack
        titleLabel.text = track.title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        accessibilityLabel = track.title
        accessibilityValue = subtitle
        accessibilityTraits = [.button]
        artworkView.accessibilityLabel = L("%@ album artwork", track.title)
        artworkView.placeholderTitle = track.title
        moreButton.menu = menu
        moreButton.accessibilityIdentifier = "library.collection.track.options.\(track.id.externalID)"
        moreButton.isHidden = isEditing
        selectionIndicator.isHidden = !isEditing
        selectionIndicator.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle"
        )
        selectionIndicator.tintColor = isSelected
            ? MusicFreeUIColorTokens.accent
            : MusicFreeUIColorTokens.foregroundTertiary
        accessibilityTraits = isEditing && isSelected ? [.button, .selected] : [.button]

        artworkBinding.configure(
            artworkID: track.artworkID,
            sourceID: track.id.sourceID,
            maximumPixelDimension: Self.artworkPixelDimension,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryCollectionDetailStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCollectionDetailStatusCell"
    private var stateView: UIView?

    func configure(status: String, title: String, retry: @escaping () -> Void) {
        stateView?.removeFromSuperview()
        let nextView: UIView
        switch status {
        case "loading":
            nextView = MusicFreeUIKitLoadingStateView(label: L("正在载入%@", title))
        case "failed":
            nextView = MusicFreeUIKitErrorStateView(
                message: L("无法载入%@。", title),
                retryTitle: L("重试"),
                retry: retry
            )
        default:
            nextView = MusicFreeUIKitEmptyStateView(
                title: title,
                message: L("这个条目暂时没有可播放的歌曲。"),
                systemImage: "music.note.list"
            )
        }
        nextView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nextView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        stateView = nextView
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
