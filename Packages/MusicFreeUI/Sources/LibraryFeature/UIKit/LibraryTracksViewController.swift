import AppServices
import Combine
import DesignSystem
import MediaSourceAPI
import MusicDomain
import UIKit

/// A diffable-safe identity for a track row.
///
/// Playback history intentionally allows the same `MediaItemID` to appear
/// more than once because each row represents a separate playback session.
/// The occurrence disambiguates repeated IDs while keeping the underlying
/// track/action callbacks keyed by the original media item.
struct LibraryTrackRowIdentity: Hashable, Sendable {
    let itemID: MediaItemID
    let occurrence: Int

    static func rows(for tracks: [Track]) -> [(id: Self, track: Track)] {
        var nextOccurrenceByID: [MediaItemID: Int] = [:]
        return tracks.map { track in
            let occurrence = nextOccurrenceByID[track.id, default: 0]
            nextOccurrenceByID[track.id] = occurrence + 1
            return (
                id: Self(itemID: track.id, occurrence: occurrence),
                track: track
            )
        }
    }
}

/// Native UIKit list for Tracks, Favorites and Playback History.
///
/// The controller deliberately keeps all query, pagination and mutation state
/// inside the shared `LibraryViewModel`; UIKit only translates that state into
/// a diffable list and owns navigation/interaction callbacks. Library-wide
/// search lives on `LibraryHomeViewController`, not inside this song list.
@MainActor
public final class LibraryTracksViewController: UIViewController {
    private enum TrackListSortMode: Equatable {
        case title
        case artist
        case album
    }

    private struct TrackRenderInput: Equatable {
        let tracks: [Track]
        let state: LibraryLoadState
        let artistNames: [ArtistID: String]
        let albumNames: [AlbumID: String]
        let sortMode: TrackListSortMode
    }

    private struct TrackMetadataSignature: Hashable {
        let trackID: MediaItemID
        let artistIDs: [ArtistID]
        let albumID: AlbumID?
    }

    private enum TrackSection: Hashable {
        case actions
        case group(String)
        case status
    }

    private enum TrackItem: Hashable {
        case playbackActions
        case track(LibraryTrackRowIdentity)
        case status(String)
    }

    private final class TrackDataSource:
        UICollectionViewDiffableDataSource<TrackSection, TrackItem> {
        var indexTitlesProvider: () -> [String]? = { nil }
        var indexPathProvider: (String, Int) -> IndexPath = { _, _ in IndexPath(index: 0) }

        override func indexTitles(for collectionView: UICollectionView) -> [String]? {
            indexTitlesProvider()
        }

        override func collectionView(
            _ collectionView: UICollectionView,
            indexPathForIndexTitle title: String,
            at index: Int
        ) -> IndexPath {
            indexPathProvider(title, index)
        }
    }

    public let viewModel: LibraryViewModel
    public let section: LibrarySection
    public let artworkServing: (any ArtworkServing)?
    private let mediaShareResolver: LibraryMediaShareResolver?
    public var onSelectTrack: ((MediaItemID) -> Void)?
    public var onPlayTrack: ((MediaItemID) -> Void)?
    public var onPlayTracks: (([MediaItemID], Bool) -> Void)?
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)?
    public var onEnqueueTracks: (([MediaItemID]) -> Void)?
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)?

    private let collectionView: UICollectionView
//    private var sortButton: UIBarButtonItem?
//    private var moreButton: UIBarButtonItem?
    private var dataSource: TrackDataSource!
    private var viewModelObservations = Set<AnyCancellable>()
    private var renderObservationTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var artistNames: [ArtistID: String] = [:]
    private var albumNames: [AlbumID: String] = [:]
    private var metadataSignature: Set<TrackMetadataSignature> = []
    private var lastRenderInput: TrackRenderInput?
    private var renderedSubtitleByRowID: [LibraryTrackRowIdentity: String?] = [:]
    private var trackByRowID: [LibraryTrackRowIdentity: Track] = [:]
    private var orderedRows: [(id: LibraryTrackRowIdentity, track: Track)] = []
    private var orderedTracks: [Track] = []
    private var sortMode: TrackListSortMode = .title
    private var artworkPrefetchTasks: [LibraryTrackRowIdentity: Task<Void, Never>] = [:]
    private var shareTask: Task<Void, Never>?
    private let maximumConcurrentArtworkPrefetches = 4
    private let nextPagePreloadDistance = 50

    public init(
        viewModel: LibraryViewModel,
        section: LibrarySection,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
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
        restorationIdentifier = "library.\(section.rawValue).tracks.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.\(section.rawValue)"
        if viewModel.selection != section {
            viewModel.select(section)
        }
        updateNavigationAppearance()

        configureCollectionView()
        configureDataSource()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        observeViewModel()
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
        renderSnapshot()
        viewModel.loadIfNeeded(for: section)
        reloadMetadataIfNeeded()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // LibraryHomeViewController owns a single-row custom header and hides
        // the navigation bar.  Track sections are pushed onto that same
        // navigation stack, so explicitly restore the bar here; otherwise
        // UIKit keeps the search controller configured but visually hidden.
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if viewModel.selection != section {
            viewModel.select(section)
        }
        updateNavigationAppearance()
        viewModel.loadIfNeeded(for: section)
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass else {
            return
        }
        updateNavigationAppearance()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override public func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        collectionView
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        metadataTask?.cancel()
        metadataTask = nil
        metadataSignature = []
        artworkPrefetchTasks.values.forEach { $0.cancel() }
        artworkPrefetchTasks.removeAll(keepingCapacity: true)
        shareTask?.cancel()
        shareTask = nil
    }

    deinit {
        renderObservationTask?.cancel()
        metadataTask?.cancel()
        artworkPrefetchTasks.values.forEach { $0.cancel() }
        shareTask?.cancel()
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
        collectionView.prefetchDataSource = self
        collectionView.register(
            LibraryTracksCell.self,
            forCellWithReuseIdentifier: LibraryTracksCell.reuseIdentifier
        )
        collectionView.register(
            LibraryTracksActionCell.self,
            forCellWithReuseIdentifier: LibraryTracksActionCell.reuseIdentifier
        )
        collectionView.register(
            LibraryTracksStatusCell.self,
            forCellWithReuseIdentifier: LibraryTracksStatusCell.reuseIdentifier
        )
        collectionView.register(
            LibraryTracksHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: LibraryTracksHeaderView.reuseIdentifier
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateNavigationMenus()
    }

    func menuFor(image: UIImage?, children: [UIAction], additionPrepare: (UIBarButtonItem) -> Void) -> UIBarButtonItem? {
        var item: UIBarButtonItem? = nil
        if children.count > 1 {
            item = UIBarButtonItem(image: image, menu: UIMenu(children: children))
        } else if let first = children.first {
            item = UIBarButtonItem(image: first.image ?? image, primaryAction: first)
        }
        if let item {
            additionPrepare(item)
        }
        return item
    }

    func updateNavigationMenus() {
        let metadata = [
            (
                UIImage(systemName: "line.3.horizontal.decrease.circle"),
                [
                    UIAction(
                        title: L("歌曲名称"),
                        state: sortMode == .title ? .on : .off
                    ) { [weak self] _ in self?.setSortMode(.title) },
                    UIAction(
                        title: L("艺人"),
                        state: sortMode == .artist ? .on : .off
                    ) { [weak self] _ in self?.setSortMode(.artist) },
                    UIAction(
                        title: L("专辑"),
                        state: sortMode == .album ? .on : .off
                    ) { [weak self] _ in self?.setSortMode(.album) },
                ],
                "library.tracks.sort"
            ),
            (
                UIImage(systemName: "ellipsis"),
                [
                    UIAction(
                        title: L("刷新资料库"),
                        image: UIImage(systemName: "arrow.clockwise")
                    ) { [weak self] _ in self?.refreshTriggered() },
                ],
                "library.tracks.options"
            ),
        ]
        var items: [UIBarButtonItem] = []
        for meta in metadata {
            if let item = menuFor(image: meta.0, children: meta.1, additionPrepare: { item in
                item.tintColor = MusicFreeUIColorTokens.accent
                item.accessibilityLabel = meta.2
                item.accessibilityIdentifier = meta.2
            }) {
                items.append(item)
            }
        }
        navigationItem.rightBarButtonItems = items
    }

    private func configureDataSource() {
        let dataSource = TrackDataSource(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case .playbackActions:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryTracksActionCell.reuseIdentifier,
                    for: indexPath
                )
                guard let actionCell = cell as? LibraryTracksActionCell else { return cell }
                actionCell.configure(
                    isEnabled: !self.orderedTracks.isEmpty,
                    play: { [weak self] in self?.playAll(shuffle: false) },
                    shuffle: { [weak self] in self?.playAll(shuffle: true) }
                )
                return actionCell

            case let .track(rowID):
                guard let track = self.trackByRowID[rowID] else { return nil }
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryTracksCell.reuseIdentifier,
                    for: indexPath
                )
                guard let trackCell = cell as? LibraryTracksCell else { return cell }
                trackCell.configure(
                    track: track,
                    subtitle: self.subtitle(for: track),
                    artworkServing: self.artworkServing,
                    menu: self.makeTrackContextMenu(for: track)
                )
                trackCell.accessibilityIdentifier = rowID.occurrence == 0
                    ? "library.track.play.\(track.id.externalID)"
                    : "library.track.play.\(track.id.externalID).\(rowID.occurrence)"
                return trackCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibraryTracksStatusCell.reuseIdentifier,
                    for: indexPath
                )
                guard let statusCell = cell as? LibraryTracksStatusCell else { return cell }
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
            guard kind == UICollectionView.elementKindSectionHeader,
                  let self,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section),
                  case let .group(title) = section
            else { return nil }

            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: LibraryTracksHeaderView.reuseIdentifier,
                for: indexPath
            )
            guard let header = header as? LibraryTracksHeaderView else { return header }
            header.titleText = title
            return header
        }
        dataSource.indexTitlesProvider = { [weak self] in
            self?.sectionIndexTitles()
        }
        dataSource.indexPathProvider = { [weak self] title, index in
            self?.indexPath(forSectionIndexTitle: title, at: index) ?? IndexPath(index: 0)
        }
        self.dataSource = dataSource
        collectionView.delegate = self
    }

    private func observeViewModel() {
        viewModelObservations.removeAll()
        let observedSection = section

        let scheduleRender: () -> Void = { [weak self] in
            guard let self else { return }
            self.renderObservationTask?.cancel()
            self.renderObservationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.renderSnapshot()
                self.reloadMetadataIfNeeded()
                self.collectionView.refreshControl?.endRefreshing()
                self.renderObservationTask = nil
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
        case .tracks:
            viewModelObservations.insert(viewModel.$tracks.sink { _ in scheduleRender() })
        case .favorites:
            viewModelObservations.insert(viewModel.$favoriteTracks.sink { _ in scheduleRender() })
        case .recent:
            viewModelObservations.insert(viewModel.$recentTracks.sink { _ in scheduleRender() })
            viewModelObservations.insert(viewModel.$playbackHistory.sink { _ in scheduleRender() })
        default:
            break
        }
    }

    private func renderSnapshot() {
        guard isViewLoaded else { return }

        updateNavigationMenus()

        let visibleTracks = viewModel.tracks(for: section)
        let renderInput = TrackRenderInput(
            tracks: visibleTracks,
            state: viewModel.state(for: section),
            artistNames: artistNames,
            albumNames: albumNames,
            sortMode: sortMode
        )
        guard renderInput != lastRenderInput else { return }
        lastRenderInput = renderInput

        let previousTrackByRowID = trackByRowID
        let previousSubtitleByRowID = renderedSubtitleByRowID
        let sortedTracks = visibleTracks.sorted {
            let lhs = TrackSectionIndex.normalizedSortValue(sortValue(for: $0))
            let rhs = TrackSectionIndex.normalizedSortValue(sortValue(for: $1))
            let result = lhs.localizedStandardCompare(rhs)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.id.externalID.localizedStandardCompare($1.id.externalID)
                == .orderedAscending
        }
        orderedRows = LibraryTrackRowIdentity.rows(for: sortedTracks).map { row in
            (id: row.id, track: row.track)
        }
        orderedTracks = orderedRows.map(\.track)
        trackByRowID = Dictionary(uniqueKeysWithValues: orderedRows.map { ($0.id, $0.track) })
        renderedSubtitleByRowID = Dictionary(
            uniqueKeysWithValues: orderedRows.map { ($0.id, subtitle(for: $0.track)) }
        )

        var snapshot = NSDiffableDataSourceSnapshot<TrackSection, TrackItem>()
        if orderedTracks.isEmpty {
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
        } else {
            snapshot.appendSections([.actions])
            snapshot.appendItems([.playbackActions], toSection: .actions)

            let grouped = Dictionary(grouping: orderedRows) {
                TrackSectionIndex.title(for: sortValue(for: $0.track))
            }
            let keys = grouped.keys.sorted(by: TrackSectionIndex.areInAscendingOrder)
            for key in keys {
                snapshot.appendSections([.group(key)])
                snapshot.appendItems(
                    grouped[key, default: []].map { .track($0.id) },
                    toSection: .group(key)
                )
            }
        }

        let currentSnapshot = dataSource.snapshot()
        let structureChanged = currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let itemsToReconfigure = orderedRows.compactMap { row -> TrackItem? in
            guard previousTrackByRowID[row.id] != row.track
                || previousSubtitleByRowID[row.id] != renderedSubtitleByRowID[row.id]
            else {
                return nil
            }
            return .track(row.id)
        }

        guard structureChanged || !itemsToReconfigure.isEmpty else { return }
        if !structureChanged, !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func sectionIndexTitles() -> [String]? {
        let titles = dataSource.snapshot().sectionIdentifiers.compactMap { section -> String? in
            guard case let .group(title) = section else { return nil }
            return title
        }
        return titles.count > 1 ? titles : nil
    }

    private func indexPath(forSectionIndexTitle title: String, at index: Int) -> IndexPath {
        let snapshot = dataSource.snapshot()
        let sectionIdentifier: TrackSection
        if snapshot.sectionIdentifiers.contains(.group(title)) {
            sectionIdentifier = .group(title)
        } else if let fallbackTitle = sectionIndexTitles()?[safe: index] {
            sectionIdentifier = .group(fallbackTitle)
        } else {
            return IndexPath(index: 0)
        }
        guard let sectionIndex = snapshot.sectionIdentifiers.firstIndex(of: sectionIdentifier),
              !snapshot.itemIdentifiers(inSection: sectionIdentifier).isEmpty
        else { return IndexPath(index: 0) }
        return IndexPath(item: 0, section: sectionIndex)
    }

    private func reloadMetadataIfNeeded() {
        let tracks = orderedTracks
        let nextSignature = Set(tracks.map {
            TrackMetadataSignature(
                trackID: $0.id,
                artistIDs: $0.artistIDs,
                albumID: $0.albumID
            )
        })
        guard nextSignature != metadataSignature else { return }
        metadataSignature = nextSignature
        metadataTask?.cancel()
        guard !tracks.isEmpty else {
            artistNames = [:]
            albumNames = [:]
            return
        }

        let library = viewModel.library
        metadataTask = Task { @MainActor [weak self] in
            do {
                async let loadedArtistNames = LibraryArtistNameLoader.load(
                    for: tracks,
                    from: library
                )
                async let loadedAlbumNames = LibraryAlbumLoader.load(
                    albumIDs: Set(tracks.compactMap(\.albumID)),
                    sourceID: .local,
                    from: library
                )
                let (artistNames, albumNames) = try await (
                    loadedArtistNames,
                    loadedAlbumNames
                )
                guard let self, !Task.isCancelled else { return }
                self.artistNames = artistNames
                self.albumNames = albumNames
                self.renderSnapshot()
            } catch is CancellationError {
                return
            } catch {
                // Artist metadata is supplementary; the title list remains usable.
            }
        }
    }

    private func subtitle(for track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func sortValue(for track: Track) -> String {
        switch sortMode {
        case .title:
            return track.sortTitle ?? track.title
        case .artist:
            return subtitle(for: track) ?? track.title
        case .album:
            guard let albumID = track.albumID else { return L("无专辑") }
            return albumNames[albumID] ?? track.title
        }
    }

    private func setSortMode(_ mode: TrackListSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        lastRenderInput = nil
        renderSnapshot()
    }

    private func playAll(shuffle: Bool) {
        guard !orderedTracks.isEmpty else { return }
        if let onPlayTracks {
            onPlayTracks(orderedTracks.map(\.id), shuffle)
        } else {
            onPlayTrack?(orderedTracks[0].id)
        }
    }

    private func updateNavigationAppearance() {
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let section = self.dataSource?.snapshot().sectionIdentifiers[safe: sectionIndex]
            else { return nil }

            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = section != .status && section != .actions
            switch section {
            case .group:
                configuration.headerMode = self.traitCollection.horizontalSizeClass == .regular
                    ? .supplementary
                    : .none
            case .actions, .status:
                configuration.headerMode = .none
            }
            let layoutSection = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: section == .actions
                    ? MusicFreeSpacingTokens.medium
                    : MusicFreeSpacingTokens.small,
                leading: MusicFreeSpacingTokens.contentInset,
                bottom: section == .actions
                    ? MusicFreeSpacingTokens.small
                    : MusicFreeSpacingTokens.large,
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
}

extension LibraryTracksViewController: UICollectionViewDelegate {
    public func collectionView(
        _: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        guard case let .track(rowID) = item,
              let track = trackByRowID[rowID]
        else { return }
        // Match the existing SwiftUI TracksView contract: a normal tap is the
        // primary playback action. Details remain available from the native
        // context menu, preserving the established interaction while keeping
        // the UIKit migration visually/behaviorally compatible.
        if let onPlayTrack {
            onPlayTrack(track.id)
        } else {
            onSelectTrack?(track.id)
        }
    }

    public func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .track(rowID) = item,
              let track = trackByRowID[rowID]
        else { return nil }

        let configuration = UIContextMenuConfiguration(
            identifier: NSString(string: "\(track.id.externalID)-\(rowID.occurrence)"),
            previewProvider: nil
        ) { [weak self] _ in
            self?.makeTrackContextMenu(for: track)
        }
        if #available(iOS 16.0, *) {
            configuration.preferredMenuElementOrder = .fixed
        }
        return configuration
    }

    public func collectionView(
        _: UICollectionView,
        willDisplay _: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .track(rowID) = item,
              let rowIndex = orderedRows.firstIndex(where: { $0.id == rowID }),
              rowIndex >= max(0, orderedRows.count - nextPagePreloadDistance)
        else { return }
        viewModel.loadNextPage(for: section)
    }

    private func makeTrackContextMenu(for track: Track) -> UIMenu {
        let favorite = UIAction(
            title: track.isFavorite ? L("取消收藏") : L("收藏"),
            image: UIImage(systemName: track.isFavorite ? "star.slash" : "star"),
            state: track.isFavorite ? .on : .off
        ) { [weak self] _ in
            self?.viewModel.toggleFavorite(track)
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
        if let onEnqueueNextTracks {
            actions.append(UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { _ in onEnqueueNextTracks([track.id]) })
        }
        if let onEnqueueTracks {
            actions.append(UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append")
            ) { _ in onEnqueueTracks([track.id]) })
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

    private func requestDelete(_ track: Track) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除歌曲？"),
            message: L("删除后将从资料库移除这首歌曲。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.viewModel.library.delete([track.id])
                    self.viewModel.removeDeletedTrack(track.id)
                    self.renderSnapshot()
                } catch {
                    self.presentMessage(title: L("无法删除歌曲"), message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
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

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .default))
        present(alert, animated: true)
    }
}

extension LibraryTracksViewController: UICollectionViewDataSourcePrefetching {
    public func collectionView(
        _: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        guard let artworkServing else { return }
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case let .track(rowID) = item
            else {
                continue
            }

            if let rowIndex = orderedRows.firstIndex(where: { $0.id == rowID }),
               rowIndex >= max(0, orderedRows.count - nextPagePreloadDistance) {
                viewModel.loadNextPage(for: section)
            }

            guard artworkPrefetchTasks.count < maximumConcurrentArtworkPrefetches else {
                break
            }
            guard artworkPrefetchTasks[rowID] == nil,
                  let track = trackByRowID[rowID],
                  let artworkID = track.artworkID
            else {
                continue
            }

            artworkPrefetchTasks[rowID] = Task { @MainActor [weak self] in
                _ = await LibraryArtworkImagePipeline.shared.image(
                    artworkID: artworkID,
                    sourceID: track.id.sourceID,
                    maximumPixelDimension: LibraryTracksCell.artworkPixelDimension,
                    serving: artworkServing
                )
                self?.artworkPrefetchTasks[rowID] = nil
            }
        }
    }

    public func collectionView(
        _: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case let .track(rowID) = item
            else {
                continue
            }
            artworkPrefetchTasks[rowID]?.cancel()
            artworkPrefetchTasks[rowID] = nil
        }
    }
}

@MainActor
private final class LibraryTracksActionCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryTracksActionCell"

    private let playButton = MusicFreeUIKitPillActionButton(
        title: L("播放"),
        systemImage: "play.fill"
    )
    private let shuffleButton = MusicFreeUIKitPillActionButton(
        title: L("随机播放"),
        systemImage: "shuffle"
    )
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        playButton.accessibilityIdentifier = "library.tracks.play"
        shuffleButton.accessibilityIdentifier = "library.tracks.shuffle"

        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.small
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playButton)
        stack.addArrangedSubview(shuffleButton)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            shuffleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playButton.onPrimaryAction = nil
        shuffleButton.onPrimaryAction = nil
    }

    func configure(
        isEnabled: Bool,
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) {
        playButton.isEnabled = isEnabled
        playButton.onPrimaryAction = play
        shuffleButton.isEnabled = isEnabled
        shuffleButton.onPrimaryAction = shuffle
    }
}

@MainActor
private final class LibraryTracksHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "LibraryTracksHeaderView"
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
private final class LibraryTracksCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryTracksCell"
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
        moreButton.accessibilityIdentifier = "library.track.options.\(track.id.externalID)"

        artworkBinding.configure(
            artworkID: track.artworkID,
            sourceID: track.id.sourceID,
            maximumPixelDimension: Self.artworkPixelDimension,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryTracksStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryTracksStatusCell"
    private var stateView: UIView?

    func configure(
        status: String,
        section: LibrarySection,
        retry: @escaping () -> Void
    ) {
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
        case .favorites: return L("暂无收藏")
        case .recent: return L("暂无最近播放")
        default: return L("资料库为空")
        }
    }

    private func emptyMessage(for section: LibrarySection) -> String {
        switch section {
        case .favorites: return L("收藏的歌曲会显示在这里。")
        case .recent: return L("播放过的歌曲会显示在这里。")
        default: return L("导入本地音频后会显示在这里。")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
