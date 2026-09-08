import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// Library-wide local search results grouped like the system Music app:
/// mixed top results, albums, and songs.
@MainActor
final class LibrarySearchResultsViewController: UIViewController {
    private enum Scope: Int, CaseIterable {
        case topResults
        case albums
        case songs

        var title: String {
            switch self {
            case .topResults: L("library.search.topResults")
            case .albums: L("library.search.albums")
            case .songs: L("library.search.songs")
            }
        }
    }

    private enum Section: Hashable {
        case results
    }

    private enum Item: Hashable {
        case album(AlbumID)
        case track(MediaItemID)
        case status(String)
    }

    var onSelectAlbum: ((AlbumID) -> Void)?
    var onSelectTrack: ((MediaItemID) -> Void)?
    var onPlayTrack: ((MediaItemID) -> Void)?
    var onEnqueueNextTracks: (([MediaItemID]) -> Void)?
    var onEnqueueTracks: (([MediaItemID]) -> Void)?
    var onAddTracksToPlaylist: (([MediaItemID]) -> Void)?

    var contentScrollView: UIScrollView { collectionView }

    private let viewModel: LibraryViewModel
    private let artworkServing: (any ArtworkServing)?
    private let mediaShareResolver: LibraryMediaShareResolver?
    private let scopeControl = UIStackView()
    private var scopeButtons: [UIButton] = []
    private var selectedScope: Scope = .topResults
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observations = Set<AnyCancellable>()
    private var artistNames: [ArtistID: String] = [:]
    private var renderScheduled = false
    private var albumsByID: [AlbumID: Album] = [:]
    private var tracksByID: [MediaItemID: Track] = [:]
    private var shareTask: Task<Void, Never>?
    private var albumActionTask: Task<Void, Never>?

    init(
        viewModel: LibraryViewModel,
        artworkServing: (any ArtworkServing)?,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        self.viewModel = viewModel
        self.artworkServing = artworkServing
        mediaShareResolver = mediaSourceResolver.map {
            LibraryMediaShareResolver(sourceResolver: $0)
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        shareTask?.cancel()
        albumActionTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.search.results"
        configureScopeControl()
        configureCollectionView()
        configureDataSource()
        observeViewModel()
        renderSnapshot()
    }

    private func configureScopeControl() {
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.axis = .horizontal
        scopeControl.alignment = .fill
        scopeControl.distribution = .fill
        scopeControl.spacing = MusicFreeSpacingTokens.xSmall
        scopeButtons = Scope.allCases.map { scope in
            let button = UIButton(type: .system)
            button.tag = scope.rawValue
            button.accessibilityIdentifier = scope == .topResults
                ? "library.search.scope"
                : "library.search.scope.\(scope.rawValue)"
            button.addTarget(self, action: #selector(scopeChanged(_:)), for: .touchUpInside)
            scopeControl.addArrangedSubview(button)
            return button
        }
        updateScopeButtons()
        view.addSubview(scopeControl)

        NSLayoutConstraint.activate([
            scopeControl.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: MusicFreeSpacingTokens.contentInset
            ),
            scopeControl.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -MusicFreeSpacingTokens.contentInset
            ),
            scopeControl.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: MusicFreeSpacingTokens.small
            ),
            scopeControl.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            scopeControl.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "library.search.collection"
        collectionView.register(
            LibrarySearchResultCell.self,
            forCellWithReuseIdentifier: LibrarySearchResultCell.reuseIdentifier
        )
        collectionView.register(
            LibrarySearchStatusCell.self,
            forCellWithReuseIdentifier: LibrarySearchStatusCell.reuseIdentifier
        )
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(
                equalTo: scopeControl.bottomAnchor,
                constant: MusicFreeSpacingTokens.small
            ),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case let .album(albumID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibrarySearchResultCell.reuseIdentifier,
                    for: indexPath
                )
                guard let resultCell = cell as? LibrarySearchResultCell,
                      let album = self.albumsByID[albumID]
                else { return cell }
                resultCell.configure(
                    title: album.title,
                    subtitle: self.albumSubtitle(album),
                    artworkID: album.artworkID,
                    artworkSourceID: .local,
                    artworkServing: self.artworkServing,
                    accessory: .menu(self.makeAlbumContextMenu(for: album))
                )
                resultCell.accessibilityIdentifier = "library.search.album.\(albumID.rawValue)"
                resultCell.optionsAccessibilityIdentifier =
                    "library.search.album.options.\(albumID.rawValue)"
                return resultCell

            case let .track(trackID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibrarySearchResultCell.reuseIdentifier,
                    for: indexPath
                )
                guard let resultCell = cell as? LibrarySearchResultCell,
                      let track = self.tracksByID[trackID]
                else { return cell }
                resultCell.configure(
                    title: track.title,
                    subtitle: self.trackSubtitle(track),
                    artworkID: track.artworkID,
                    artworkSourceID: track.id.sourceID,
                    artworkServing: self.artworkServing,
                    accessory: .menu(self.makeTrackContextMenu(for: track))
                )
                resultCell.accessibilityIdentifier = "library.search.track.\(track.id.externalID)"
                resultCell.optionsAccessibilityIdentifier =
                    "library.search.track.options.\(track.id.externalID)"
                return resultCell

            case let .status(status):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LibrarySearchStatusCell.reuseIdentifier,
                    for: indexPath
                )
                guard let statusCell = cell as? LibrarySearchStatusCell else { return cell }
                statusCell.configure(
                    status: status,
                    retry: { [weak self] in self?.viewModel.retrySearch() }
                )
                statusCell.accessibilityIdentifier = "library.search.status.\(status)"
                return statusCell
            }
        }
    }

    private func observeViewModel() {
        let update: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRender()
            }
        }
        observations.insert(viewModel.$searchTracks.sink { _ in update() })
        observations.insert(viewModel.$searchAlbums.sink { _ in update() })
        observations.insert(viewModel.$searchArtists.sink { _ in update() })
        observations.insert(viewModel.$searchState.sink { _ in update() })
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.renderScheduled = false
            self.renderSnapshot()
        }
    }

    private func renderSnapshot() {
        guard isViewLoaded else { return }

        albumsByID = Dictionary(uniqueKeysWithValues: viewModel.searchAlbums.map { ($0.id, $0) })
        tracksByID = Dictionary(uniqueKeysWithValues: viewModel.searchTracks.map { ($0.id, $0) })
        artistNames = Dictionary(uniqueKeysWithValues: viewModel.searchArtists.map {
            ($0.id, $0.name)
        })

        var items: [Item]
        switch selectedScope {
        case .topResults:
            items = viewModel.searchAlbums.prefix(2).map { .album($0.id) }
                + viewModel.searchTracks.map { .track($0.id) }
        case .albums:
            items = viewModel.searchAlbums.map { .album($0.id) }
        case .songs:
            items = viewModel.searchTracks.map { .track($0.id) }
        }

        if items.isEmpty {
            switch viewModel.searchState {
            case .idle:
                items = []
            case .loading:
                items = [.status("loading")]
            case .failed:
                items = [.status("failed")]
            case .empty, .loaded:
                items = [.status("empty")]
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.results])
        snapshot.appendItems(items, toSection: .results)
        let existingItems = Set(dataSource.snapshot().itemIdentifiers)
        let itemsToReconfigure = items.filter(existingItems.contains)
        if !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func albumSubtitle(_ album: Album) -> String {
        resultSubtitle(kind: L("library.search.albumKind"), artistIDs: album.artistIDs)
    }

    private func trackSubtitle(_ track: Track) -> String {
        resultSubtitle(kind: L("library.search.songKind"), artistIDs: track.artistIDs)
    }

    private func resultSubtitle(kind: String, artistIDs: [ArtistID]) -> String {
        let names = artistIDs.compactMap { artistNames[$0] }
        guard !names.isEmpty else { return kind }
        return "\(kind) · \(names.joined(separator: "、"))"
    }

    @objc private func scopeChanged(_ sender: UIButton) {
        guard let scope = Scope(rawValue: sender.tag), scope != selectedScope else { return }
        selectedScope = scope
        updateScopeButtons()
        renderSnapshot()
        collectionView.setContentOffset(
            CGPoint(x: -collectionView.adjustedContentInset.left, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
    }

    private func updateScopeButtons() {
        for button in scopeButtons {
            guard let scope = Scope(rawValue: button.tag) else { continue }
            let isSelected = scope == selectedScope
            var configuration = isSelected
                ? UIButton.Configuration.filled()
                : UIButton.Configuration.plain()
            configuration.title = scope.title
            configuration.baseForegroundColor = isSelected
                ? MusicFreeUIColorTokens.onAccent
                : MusicFreeUIColorTokens.foregroundPrimary
            configuration.baseBackgroundColor = isSelected
                ? MusicFreeUIColorTokens.accent
                : .clear
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: MusicFreeSpacingTokens.small,
                leading: MusicFreeSpacingTokens.medium,
                bottom: MusicFreeSpacingTokens.small,
                trailing: MusicFreeSpacingTokens.medium
            )
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                attributes in
                var attributes = attributes
                attributes.font = MusicFreeUIFontTokens.controlLabel
                return attributes
            }
            button.configuration = configuration
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        }
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
            UIAction(title: L("播放"), image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.onPlayTrack?(track.id)
            },
            UIAction(title: L("查看歌曲详情"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.onSelectTrack?(track.id)
            }
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
            UIMenu(title: "", options: [.displayInline], children: [delete])
        ])
    }

    private func makeAlbumContextMenu(for album: Album) -> UIMenu {
        let busy = albumActionTask != nil
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: mediaShareResolver == nil || busy ? [.disabled] : []
        ) { [weak self] _ in
            self?.shareAlbum(album)
        }
        let delete = UIAction(
            title: L("删除专辑"),
            image: UIImage(systemName: "trash"),
            attributes: busy ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in
            self?.requestDeleteAlbum(album)
        }
        return UIMenu(children: [
            UIMenu(title: "", options: [.displayInline], children: [share]),
            UIMenu(title: "", options: [.displayInline], children: [delete])
        ])
    }

    private func shareAlbum(_ album: Album) {
        guard let mediaShareResolver,
              albumActionTask == nil,
              presentedViewController == nil
        else { return }
        albumActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.albumActionTask = nil }
            do {
                let tracks = try await LibraryCollectionTrackLoader.tracks(
                    for: .album(album.id),
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

    private func requestDeleteAlbum(_ album: Album) {
        guard albumActionTask == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除专辑？"),
            message: L("将删除“%@”及其中的全部歌曲。", album.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteAlbum(album)
        })
        present(alert, animated: true)
    }

    private func deleteAlbum(_ album: Album) {
        guard albumActionTask == nil else { return }
        albumActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.albumActionTask = nil }
            do {
                let itemIDs = Set(try await LibraryCollectionTrackLoader.itemIDs(
                    for: .album(album.id),
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
                self.viewModel.retrySearch()
                self.viewModel.refresh(section: .albums)
                self.viewModel.refreshOverview()
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法删除专辑"), message: error.localizedDescription)
            }
        }
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

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = true
            return NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
        }
    }
}

extension LibrarySearchResultsViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        defer { collectionView.deselectItem(at: indexPath, animated: true) }
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        view.endEditing(true)
        switch item {
        case let .album(albumID):
            onSelectAlbum?(albumID)
        case let .track(trackID):
            if let onPlayTrack {
                onPlayTrack(trackID)
            } else {
                onSelectTrack?(trackID)
            }
        case .status:
            break
        }
    }

    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let identifier: NSString
        let menuProvider: () -> UIMenu?
        switch item {
        case .album(let albumID):
            guard let album = albumsByID[albumID] else { return nil }
            identifier = NSString(string: album.id.rawValue)
            menuProvider = { [weak self] in self?.makeAlbumContextMenu(for: album) }
        case .track(let trackID):
            guard let track = tracksByID[trackID] else { return nil }
            identifier = NSString(string: track.id.externalID)
            menuProvider = { [weak self] in self?.makeTrackContextMenu(for: track) }
        case .status:
            return nil
        }
        let configuration = UIContextMenuConfiguration(
            identifier: identifier,
            previewProvider: nil
        ) { _ in
            menuProvider()
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
}

@MainActor
private final class LibrarySearchResultCell: UICollectionViewCell {
    enum Accessory {
        case disclosure
        case menu(UIMenu)
    }

    static let reuseIdentifier = "LibrarySearchResultCell"
    private static let artworkPixelDimension = 180

    private let artworkView = MusicFreeUIKitArtworkView(
        fillsAvailableWidth: false,
        cornerRadius: MusicFreeLayoutMetrics.artworkCornerRadius
    )
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let disclosureView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let moreButton = UIButton(type: .system)
    private let accessoryContainer = UIView()
    private let rowStack = UIStackView()
    private lazy var artworkBinding = LibraryArtworkBinding(view: artworkView)

    var optionsAccessibilityIdentifier: String? {
        didSet { moreButton.accessibilityIdentifier = optionsAccessibilityIdentifier }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 60),
            artworkView.heightAnchor.constraint(equalToConstant: 60)
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

        disclosureView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        disclosureView.contentMode = .scaleAspectFit
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = MusicFreeUIColorTokens.foregroundPrimary
        moreButton.accessibilityLabel = L("歌曲选项")
        moreButton.showsMenuAsPrimaryAction = true
        for view in [disclosureView, moreButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accessoryContainer.widthAnchor.constraint(equalToConstant: 44),
            accessoryContainer.heightAnchor.constraint(equalToConstant: 44),
            disclosureView.widthAnchor.constraint(equalToConstant: 12),
            disclosureView.heightAnchor.constraint(equalToConstant: 20),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = MusicFreeSpacingTokens.medium
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(artworkView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(accessoryContainer)
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: MusicFreeSpacingTokens.contentInset
            ),
            rowStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
            rowStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: MusicFreeSpacingTokens.small
            ),
            rowStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -MusicFreeSpacingTokens.small
            )
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
        titleLabel.accessibilityIdentifier = nil
        titleLabel.isAccessibilityElement = false
        subtitleLabel.isAccessibilityElement = false
        disclosureView.removeFromSuperview()
        moreButton.removeFromSuperview()
        moreButton.menu = nil
        optionsAccessibilityIdentifier = nil
    }

    func configure(
        title: String,
        subtitle: String,
        artworkID: ArtworkID?,
        artworkSourceID: MediaSourceID,
        artworkServing: (any ArtworkServing)?,
        accessory: Accessory
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        // Keep the row interactive, but expose its visible title as a real
        // static text element. Making the cell itself the only accessibility
        // element hides the title label from UIKit/XCUIElement queries and
        // makes a valid album result look absent to VoiceOver and UI tests.
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = []
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityIdentifier = title
        subtitleLabel.isAccessibilityElement = !subtitle.isEmpty
        artworkView.accessibilityLabel = L("%@ album artwork", title)
        artworkView.placeholderTitle = title

        accessoryContainer.subviews.forEach { $0.removeFromSuperview() }
        let accessoryView: UIView
        switch accessory {
        case .disclosure:
            accessoryView = disclosureView
        case let .menu(menu):
            moreButton.menu = menu
            accessoryView = moreButton
        }
        accessoryContainer.addSubview(accessoryView)
        NSLayoutConstraint.activate([
            accessoryView.centerXAnchor.constraint(equalTo: accessoryContainer.centerXAnchor),
            accessoryView.centerYAnchor.constraint(equalTo: accessoryContainer.centerYAnchor)
        ])

        artworkBinding.configure(
            artworkID: artworkID,
            sourceID: artworkSourceID,
            maximumPixelDimension: Self.artworkPixelDimension,
            serving: artworkServing
        )
    }
}

@MainActor
private final class LibrarySearchStatusCell: UICollectionViewCell {
    static let reuseIdentifier = "LibrarySearchStatusCell"
    private var stateView: UIView?

    func configure(status: String, retry: @escaping () -> Void) {
        stateView?.removeFromSuperview()
        let nextView: UIView
        switch status {
        case "loading":
            nextView = MusicFreeUIKitLoadingStateView(label: L("正在搜索资料库"))
        case "failed":
            nextView = MusicFreeUIKitErrorStateView(
                message: L("无法搜索资料库。"),
                retryTitle: L("重试"),
                retry: retry
            )
        default:
            nextView = MusicFreeUIKitEmptyStateView(
                title: L("没有搜索结果"),
                message: L("请尝试其他专辑或歌曲名称。"),
                systemImage: "magnifyingglass"
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
