import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit
import UniformTypeIdentifiers

/// UIKit implementation of the Library home surface.
///
/// UIKit implementation of the complete Library entry surface. Section and
/// collection detail controllers are pushed by the root shell; no SwiftUI
/// fallback is used by the production route.
@MainActor
public final class LibraryHomeViewController: UIViewController {
    private enum HomeSection: Hashable {
        case navigation
        case recent
    }

    private enum HomeItem: Hashable {
        case section(LibrarySection)
        case album(String)
        case status(String)
    }

    public let viewModel: LibraryViewModel
    public let artworkServing: (any ArtworkServing)?
    public var onSelectSection: ((LibrarySection) -> Void)?
    public var onSelectAlbum: ((AlbumID) -> Void)? {
        didSet { searchResultsController.onSelectAlbum = onSelectAlbum }
    }
    public var onSelectTrack: ((MediaItemID) -> Void)? {
        didSet { searchResultsController.onSelectTrack = onSelectTrack }
    }
    public var onPlayTrack: ((MediaItemID) -> Void)? {
        didSet { searchResultsController.onPlayTrack = onPlayTrack }
    }
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)? {
        didSet { searchResultsController.onEnqueueNextTracks = onEnqueueNextTracks }
    }
    public var onEnqueueTracks: (([MediaItemID]) -> Void)? {
        didSet { searchResultsController.onEnqueueTracks = onEnqueueTracks }
    }
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)? {
        didSet { searchResultsController.onAddTracksToPlaylist = onAddTracksToPlaylist }
    }

    private let collectionView: UICollectionView
    private let searchResultsController: LibrarySearchResultsViewController
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: searchResultsController)
        controller.searchResultsUpdater = self
        controller.searchBar.delegate = self
        controller.searchBar.placeholder = L("library.search.placeholder")
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.returnKeyType = .search
        controller.searchBar.accessibilityIdentifier = "library.home.search"
        controller.searchBar.searchTextField.accessibilityIdentifier = "library.home.search"
        controller.obscuresBackgroundDuringPresentation = false
        return controller
    }()
    private let importStatusView = LibraryImportStatusView()
    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    private var viewModelObservations = Set<AnyCancellable>()
    private var importStateObservation: AnyCancellable?
    private var artistLoadTask: Task<Void, Never>?
    private var artistLoadRequestSignature: String?
    private var artistNames: [ArtistID: String] = [:]
    private var trackArtistNamesByAlbum: [AlbumID: String] = [:]
    private var renderedAlbumsByID: [String: Album] = [:]
    private var renderedAlbumSubtitles: [String: String?] = [:]
    private weak var presentedDocumentPicker: UIDocumentPickerViewController?

    public init(
        viewModel: LibraryViewModel,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        self.viewModel = viewModel
        self.artworkServing = artworkServing
        searchResultsController = LibrarySearchResultsViewController(
            viewModel: viewModel,
            artworkServing: artworkServing,
            mediaSourceResolver: mediaSourceResolver
        )
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
        title = L("资料库")
        restorationIdentifier = "library.home.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.home"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.setNavigationBarHidden(false, animated: false)

        configureNavigation()
        configureCollectionView()
        configureImportStatusView()
        // Register the real collection with the containing navigation/tab
        // chrome. This is required for iOS 26 to reserve the bottom accessory
        // and to drive the tab bar's scroll-collapse transition.
        setContentScrollView(collectionView, for: .bottom)
        configureDataSource()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        observeViewModel()
        observeImportState()
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
        renderSnapshot()
        updateSearchAvailability()
        updateSearchPresentation()
        viewModel.loadOverviewIfNeeded()
        reloadArtistNamesIfNeeded()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        updateSearchAvailability()
        viewModel.loadOverviewIfNeeded()
        Task { @MainActor [weak self] in
            await self?.viewModel.startObservingChanges()
        }
    }

    /// Expose the feature-owned collection to the containing tab bar. This is
    /// what lets iOS 26 collapse the floating Tab Bar/Mini Player chrome into
    /// its inline state during a scroll instead of leaving the chrome fixed.
    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        isSearchActive ? searchResultsController.contentScrollView : collectionView
    }

    private var isSearchActive: Bool {
        searchController.isActive
            && !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.horizontalSizeClass
                != traitCollection.horizontalSizeClass
        else {
            return
        }
        updateSearchAvailability()
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        collectionView.alwaysBounceVertical = true
//        collectionView.refreshControl = UIRefreshControl()
//        collectionView.refreshControl?.addTarget(
//            self,
//            action: #selector(refreshTriggered),
//            for: .valueChanged
//        )
        collectionView.accessibilityIdentifier = "library.home.collection"
        collectionView.register(
            UICollectionViewListCell.self,
            forCellWithReuseIdentifier: "LibraryHomeNavigationCell"
        )
        collectionView.register(
            LibraryHomeAlbumCell.self,
            forCellWithReuseIdentifier: "LibraryHomeAlbumCell"
        )
        collectionView.register(
            LibraryHomeStatusCell.self,
            forCellWithReuseIdentifier: "LibraryHomeStatusCell"
        )
        collectionView.register(
            LibraryHomeHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "LibraryHomeHeaderView"
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureNavigation() {
        definesPresentationContext = true

        let importItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.importTriggered() }
        )
        importItem.tintColor = MusicFreeUIColorTokens.accent
        importItem.accessibilityLabel = L("导入本地媒体")
        importItem.accessibilityIdentifier = "library.home.import"

        let refreshAction = UIAction(
            title: L("刷新资料库"),
            image: UIImage(systemName: "arrow.clockwise")
        ) { [weak self] _ in self?.refreshTriggered() }
        let menuItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [refreshAction])
        )
        menuItem.tintColor = MusicFreeUIColorTokens.accent
        menuItem.accessibilityLabel = L("资料库选项")
        menuItem.accessibilityIdentifier = "library.home.menu"
        navigationItem.rightBarButtonItems = viewModel.canImport
            ? [menuItem, importItem]
            : [menuItem]
    }

    private func updateSearchAvailability() {
        guard isViewLoaded else { return }
        let shouldShowNavigationSearch = traitCollection.horizontalSizeClass == .regular
        if shouldShowNavigationSearch {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
            navigationItem.preferredSearchBarPlacement = .automatic
            if #available(iOS 26.0, *) {
                navigationItem.searchBarPlacementAllowsToolbarIntegration = true
            }
        } else if navigationItem.searchController != nil {
            searchController.isActive = false
            navigationItem.searchController = nil
        }
    }

    private func configureImportStatusView() {
        view.addSubview(importStatusView)
        importStatusView.onCancel = { [weak self] in
            self?.viewModel.cancelImport()
        }
        importStatusView.onContinueImport = { [weak self] in
            self?.viewModel.continueImport()
        }
        importStatusView.onDismiss = { [weak self] in
            self?.viewModel.dismissImport()
        }

        NSLayoutConstraint.activate([
            importStatusView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: MusicFreeSpacingTokens.contentInset
            ),
            importStatusView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -MusicFreeSpacingTokens.contentInset
            ),
            importStatusView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            importStatusView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            importStatusView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<HomeSection, HomeItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case let .section(section):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "LibraryHomeNavigationCell",
                    for: indexPath
                )
                guard let listCell = cell as? UICollectionViewListCell else { return cell }
                var content = listCell.defaultContentConfiguration()
                content.text = section.title
                content.image = UIImage(systemName: section.systemImage)
                content.imageProperties.tintColor = MusicFreeUIColorTokens.accent
                content.textProperties.font = MusicFreeUIFontTokens.rowTitle
                content.textProperties.color = MusicFreeUIColorTokens.foregroundPrimary
                content.directionalLayoutMargins = MusicFreeSpacingTokens.rowInsets
                listCell.contentConfiguration = content
                listCell.accessories = [.disclosureIndicator()]
                listCell.accessibilityIdentifier = "library.home.section.\(section.rawValue)"
                listCell.accessibilityLabel = section.title
                listCell.accessibilityHint = L("打开%@", section.title)
                listCell.accessibilityTraits = [.button]
                return listCell

            case let .album(albumID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "LibraryHomeAlbumCell",
                    for: indexPath
                )
                guard let albumCell = cell as? LibraryHomeAlbumCell,
                      let album = self.viewModel.recentAlbums.first(where: { $0.id.rawValue == albumID })
                else { return cell }
                albumCell.configure(
                    album: album,
                    subtitle: self.albumSubtitle(album),
                    artworkServing: self.artworkServing
                )
                albumCell.accessibilityIdentifier = "library.home.album.\(albumID)"
                return albumCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "LibraryHomeStatusCell",
                    for: indexPath
                )
                guard let statusCell = cell as? LibraryHomeStatusCell else { return cell }
                statusCell.configure(
                    status: status,
                    retry: { [weak self] in self?.viewModel.refreshOverview() }
                )
                statusCell.accessibilityIdentifier = "library.home.recent.\(status)"
                return statusCell
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let section = self.dataSource.sectionIdentifier(for: indexPath.section),
                  section == .recent,
                  let header = collectionView.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: "LibraryHomeHeaderView",
                      for: indexPath
                  ) as? LibraryHomeHeaderView
            else { return nil }
            header.titleText = L("最近添加")
            return header
        }

        collectionView.delegate = self
    }

    private func observeViewModel() {
        viewModelObservations.removeAll()

        let scheduleRender: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderSnapshot()
                self.reloadArtistNamesIfNeeded()
                self.viewModel.loadOverviewIfNeeded()
                self.collectionView.refreshControl?.endRefreshing()
            }
        }

        viewModelObservations.insert(
            viewModel.$recentAlbums.sink { _ in scheduleRender() }
        )
        viewModelObservations.insert(
            viewModel.$overviewState.sink { _ in scheduleRender() }
        )
        viewModelObservations.insert(
            viewModel.$searchText.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateSearchPresentation()
                }
            }
        )
    }

    private func updateSearchPresentation() {
        guard isViewLoaded else { return }
        if searchController.searchBar.text != viewModel.searchText {
            searchController.searchBar.text = viewModel.searchText
        }
        setContentScrollView(
            isSearchActive ? searchResultsController.contentScrollView : collectionView,
            for: .bottom
        )
    }

    private func observeImportState() {
        importStateObservation = viewModel.$importState
            .combineLatest(viewModel.$importFailures)
            .sink { [weak self] stateAndFailures in
                let (state, failures) = stateAndFailures
                Task { @MainActor [weak self] in
                    guard let self,
                          self.viewModel.importState == state,
                          self.viewModel.importFailures == failures
                    else {
                        return
                    }
                    self.importStatusView.render(
                        state: state,
                        failures: failures
                    )
                }
            }
    }

    private func renderSnapshot() {
        guard isViewLoaded else { return }

        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        snapshot.appendSections([.navigation, .recent])
        snapshot.appendItems(
            [
                .section(.artists),
                .section(.albums),
                .section(.tracks),
                .section(.favorites),
                .section(.recent),
                .section(.genres),
                .section(.folders)
            ],
            toSection: .navigation
        )

        if viewModel.recentAlbums.isEmpty {
            let status: String
            switch viewModel.overviewState {
            case .idle, .loading:
                status = "loading"
            case .failed:
                status = "failed"
            case .empty, .loaded:
                status = "empty"
            }
            snapshot.appendItems([.status(status)], toSection: .recent)
        } else {
            snapshot.appendItems(
                viewModel.recentAlbums.map { .album($0.id.rawValue) },
                toSection: .recent
            )
        }

        // Artist names arrive asynchronously after the initial album tiles
        // are rendered.  The item identifiers stay stable, so applying a
        // snapshot alone does not ask UICollectionView to run the cell
        // provider again.  Reconfigure only identifiers already visible in
        // the current data source so the newly resolved subtitle is rendered
        // without disturbing diffable's insert/delete bookkeeping.
        let previousSnapshot = dataSource.snapshot()
        let structureChanged = previousSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || previousSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let existingItems = Set(previousSnapshot.itemIdentifiers)
        let currentAlbums = Dictionary(uniqueKeysWithValues: viewModel.recentAlbums.map {
            ($0.id.rawValue, $0)
        })
        let currentSubtitles = Dictionary(uniqueKeysWithValues: viewModel.recentAlbums.map {
            ($0.id.rawValue, albumSubtitle($0))
        })
        let itemsToReconfigure = viewModel.recentAlbums.compactMap { album -> HomeItem? in
            let item = HomeItem.album(album.id.rawValue)
            guard existingItems.contains(item) else { return nil }
            let albumChanged = renderedAlbumsByID[album.id.rawValue] != currentAlbums[album.id.rawValue]
            let subtitleChanged = renderedAlbumSubtitles[album.id.rawValue] != currentSubtitles[album.id.rawValue]
            return albumChanged || subtitleChanged ? item : nil
        }
        renderedAlbumsByID = currentAlbums
        renderedAlbumSubtitles = currentSubtitles
        guard structureChanged || !itemsToReconfigure.isEmpty else {
            return
        }
        if !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
        if structureChanged {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func reloadArtistNamesIfNeeded() {
        let albums = viewModel.recentAlbums
        let artistIDs = Set(albums.flatMap(\.artistIDs))
        if albums.isEmpty {
            artistLoadTask?.cancel()
            artistLoadTask = nil
            artistLoadRequestSignature = nil
            artistNames = [:]
            trackArtistNamesByAlbum = [:]
            return
        }
        let missingArtistIDs = artistIDs.subtracting(artistNames.keys)
        let unresolvedAlbums = albums.filter { album in
            let hasResolvedModelArtist = album.artistIDs.contains { artistNames[$0] != nil }
            return !hasResolvedModelArtist && trackArtistNamesByAlbum[album.id] == nil
        }
        guard !missingArtistIDs.isEmpty || !unresolvedAlbums.isEmpty else { return }

        let requestSignature = [
            missingArtistIDs.map(\.rawValue).sorted().joined(separator: ","),
            unresolvedAlbums.map { $0.id.rawValue }.sorted().joined(separator: ",")
        ].joined(separator: "|")
        guard artistLoadRequestSignature != requestSignature else { return }

        artistLoadTask?.cancel()
        artistLoadRequestSignature = requestSignature
        let library = viewModel.library
        artistLoadTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await LibraryArtistNameLoader.load(
                    artistIDs: missingArtistIDs,
                    sourceID: nil,
                    from: library
                )
                var albumSubtitles = self?.trackArtistNamesByAlbum ?? [:]

                // A legacy local import can persist the Album value before
                // its artistIDs are repaired, while the Track relation is
                // already complete. Resolve that relation for the tile so a
                // valid artist subtitle is not silently dropped.
                let albumsNeedingTrackFallback = unresolvedAlbums.filter { album in
                    !album.artistIDs.contains { loaded[$0] != nil }
                }
                if !albumsNeedingTrackFallback.isEmpty {
                    let albumIDs = Set(albumsNeedingTrackFallback.map(\.id))
                    let page = try await library.browseTracks(
                        matching: TrackQuery(
                            sourceID: .local,
                            sort: TrackSortDescriptor(
                                key: .dateAdded,
                                direction: .descending
                            )
                        ),
                        page: LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
                    )
                    var artistIDsByAlbum: [AlbumID: Set<ArtistID>] = [:]
                    for track in page.elements {
                        guard let albumID = track.albumID,
                              albumIDs.contains(albumID)
                        else { continue }
                        artistIDsByAlbum[albumID, default: []].formUnion(track.artistIDs)
                    }
                    let trackArtistIDs = Set(artistIDsByAlbum.values.joined())
                    let trackNames = try await LibraryArtistNameLoader.load(
                        artistIDs: trackArtistIDs,
                        sourceID: nil,
                        from: library
                    )
                    for (albumID, ids) in artistIDsByAlbum {
                        let names = ids.compactMap { trackNames[$0] }
                        if !names.isEmpty {
                            albumSubtitles[albumID] = names.joined(separator: "、")
                        }
                    }
                }

                guard let self, !Task.isCancelled else { return }
                self.artistNames.merge(loaded) { _, new in new }
                self.trackArtistNamesByAlbum = albumSubtitles
                self.artistLoadTask = nil
                self.renderSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self?.artistLoadTask = nil
                // Artist names are secondary metadata; album tiles remain useful
                // with only the title when this query is unavailable.
            }
        }
    }

    private func albumSubtitle(_ album: Album) -> String? {
        let names = album.artistIDs.compactMap { artistNames[$0] }
        if !names.isEmpty {
            return names.joined(separator: "、")
        }
        return trackArtistNamesByAlbum[album.id]
    }

    @objc private func refreshTriggered() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.refreshOverviewCheckingForImports()
            self.collectionView.refreshControl?.endRefreshing()
        }
    }

    @objc private func importTriggered() {
        guard viewModel.canImport, presentedDocumentPicker == nil else { return }

        let allowedContentTypes: [UTType]
        if ProcessInfo.processInfo.isiOSAppOnMac {
            allowedContentTypes = [.folder]
        } else {
            allowedContentTypes = [.audio, .folder]
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: false
        )
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presentedDocumentPicker = picker
        present(picker, animated: true)
    }
}

extension LibraryHomeViewController: UISearchBarDelegate {
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        viewModel.updateSearchText("")
    }
}

extension LibraryHomeViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        viewModel.updateSearchText(searchController.searchBar.text ?? "")
    }
}

extension LibraryHomeViewController: UIDocumentPickerDelegate {
    public func documentPicker(
        _: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        presentedDocumentPicker = nil
        guard !urls.isEmpty else { return }

        // The view model owns the security scope: it has to outlive this
        // callback because the importer enumerates from a detached task.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.startImport(urls: urls)
        }
    }

    public func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        presentedDocumentPicker = nil
    }
}

extension LibraryHomeViewController: UICollectionViewDelegate {
    public func collectionView(
        _: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .section(section):
            onSelectSection?(section)
        case let .album(albumID):
            onSelectAlbum?(AlbumID(rawValue: albumID))
        case .status:
            break
        }
        collectionView.deselectItem(at: indexPath, animated: true)
    }

}

private extension LibraryHomeViewController {
    func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sectionID = self.dataSource?.snapshot().sectionIdentifiers[safe: sectionIndex]
            if sectionID == .recent, !self.viewModel.recentAlbums.isEmpty {
                // Do not let the estimated/fractional group resolve against a
                // transient self-sizing width.  On iPhone 17 Pro the design
                // grid is 16pt inset + 16pt gap + two 173pt columns.
                let horizontalInset = MusicFreeSpacingTokens.contentInset * 2
                // Figma's 393pt reference places the second card at x=204:
                // 16 + 173 + 15 = 204.
                let interItemSpacing: CGFloat = 15
                // `effectiveContentSize` can be the provisional width of a
                // self-sizing section while the root TabBar is installing its
                // accessory.  That transient value was producing ~84pt
                // Recent tiles on a 393pt iPhone.  Resolve the grid from the
                // collection's settled bounds instead.
                let settledWidth = self.collectionView.bounds.width > 0
                    ? self.collectionView.bounds.width
                    : environment.container.effectiveContentSize.width
                let availableWidth = max(0, settledWidth - horizontalInset)
                let itemWidth = floor(
                    max(0, (availableWidth - interItemSpacing) / 2)
                )
                // The reference uses a fixed 173pt artwork with two text
                // lines beneath it. A fixed 228pt tile prevents the
                // self-sizing estimate from changing while the tab accessory
                // is being installed, which previously produced visibly tiny
                // or over-tall Recently Added cards on the first frame.
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth),
                    heightDimension: .absolute(228)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(228)
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: groupSize,
                    subitem: item,
                    count: 2
                )
                group.interItemSpacing = .fixed(interItemSpacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = MusicFreeSpacingTokens.xLarge
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.small,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.xLarge,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1),
                            // Keep the Apple Music-style breathing room
                            // between the section title and the first album
                            // row. An estimated header collapses to the
                            // label's intrinsic height on iOS 26, pulling the
                            // cards roughly 24pt too close to the title.
                            heightDimension: .absolute(68)
                        ),
                        elementKind: UICollectionView.elementKindSectionHeader,
                        alignment: .top
                    )
                ]
                return section
            }

            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = true
            configuration.headerMode = sectionID == .recent ? .supplementary : .none
            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            if sectionID == .recent {
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.small,
                    leading: MusicFreeSpacingTokens.contentInset,
                    bottom: MusicFreeSpacingTokens.xLarge,
                    trailing: MusicFreeSpacingTokens.contentInset
                )
            }
            return section
        }
    }
}

@MainActor
private final class LibraryHomeHeaderView: UICollectionReusableView {
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
            header.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class LibraryHomeAlbumCell: UICollectionViewCell {
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
        titleLabel.numberOfLines = 1
        subtitleLabel.font = MusicFreeUIFontTokens.caption
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1

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
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor)
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
    }

    func configure(
        album: Album,
        subtitle: String?,
        artworkServing: (any ArtworkServing)?
    ) {
        titleLabel.text = album.title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        artworkView.accessibilityLabel = L("%@ album artwork", album.title)
        artworkView.placeholderTitle = album.title
        artworkBinding.configure(
            artworkID: album.artworkID,
            maximumPixelDimension: 320,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibraryHomeStatusCell: UICollectionViewCell {
    private var stateView: UIView?

    func configure(status: String, retry: @escaping () -> Void) {
        stateView?.removeFromSuperview()
        let nextView: UIView
        switch status {
        case "loading":
            nextView = MusicFreeUIKitLoadingStateView(label: L("正在载入最近添加"))
        case "failed":
            nextView = MusicFreeUIKitErrorStateView(
                message: L("无法载入最近添加。"),
                retryTitle: L("重试"),
                retry: retry
            )
        default:
            nextView = MusicFreeUIKitEmptyStateView(
                title: L("暂无最近添加"),
                message: L("导入本地音乐后，最近加入的专辑会显示在这里。"),
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
            nextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        stateView = nextView
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
