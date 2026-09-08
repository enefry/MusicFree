import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import UIKit

/// UIKit list surface for the playlist feature.
///
/// The controller deliberately reuses `PlaylistListViewModel`, so CRUD,
/// validation, optimistic updates and error mapping stay in one place while
/// the screen itself no longer depends on SwiftUI layout/navigation.
@MainActor
public final class PlaylistListViewController: UIViewController {
    private enum Section: Hashable {
        case playlists
    }

    private enum Item: Hashable {
        case playlist(PlaylistID)
    }

    public let store: any PlaylistFeatureStore
    public let playback: any PlaylistFeaturePlaybackServing
    public let libraryServing: (any LibraryServing)?
    public let artworkServing: (any ArtworkServing)?
    let viewModel: PlaylistListViewModel

    /// The root shell supplies this callback so compact navigation and the
    /// regular split detail column can share the same detail controller.
    public var onSelectPlaylist: ((Playlist) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: UITableViewDiffableDataSource<Section, Item>!
    private var statusView: UIView?
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var pendingExternalReload = false
    private var renderedPlaylistSignatures: [PlaylistID: String] = [:]

    public init(
        store: any PlaylistFeatureStore,
        playback: any PlaylistFeaturePlaybackServing,
        libraryServing: (any LibraryServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil
    ) {
        self.store = store
        self.playback = playback
        self.libraryServing = libraryServing
        self.artworkServing = artworkServing
        viewModel = PlaylistListViewModel(store: store)
        super.init(nibName: nil, bundle: nil)
        title = L("播放列表")
        restorationIdentifier = "playlists.list.uikit"
    }

    public convenience init(
        playlistServing: any PlaylistServing,
        playbackServing: any PlaybackServing,
        libraryServing: (any LibraryServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil
    ) {
        self.init(
            store: AppServicesPlaylistStore(serving: playlistServing),
            playback: AppServicesPlaybackBridge(serving: playbackServing),
            libraryServing: libraryServing,
            artworkServing: artworkServing
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "playlists.list"

        configureTableView()
        configureDataSource()
        configureNavigationItems()
        render()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
            observeLibraryChanges()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeLibraryChanges()
        guard viewModel.loadState == .idle else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        mutationTask?.cancel()
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        tableView
    }

    deinit {
        loadTask?.cancel()
        mutationTask?.cancel()
        libraryChangeTask?.cancel()
    }

    private func observeLibraryChanges() {
        guard libraryChangeTask == nil, let libraryServing else { return }
        libraryChangeTask = Task { @MainActor [weak self] in
            let stream = await libraryServing.makeChangeStream()
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                guard change.categories.contains(.playlists) else { continue }
                if self.viewModel.isMutating {
                    self.pendingExternalReload = true
                    continue
                }
                await self.reloadFromExternalChange()
            }
        }
    }

    private func reloadFromExternalChange() async {
        guard !viewModel.isMutating else {
            pendingExternalReload = true
            return
        }
        await viewModel.load()
        guard !Task.isCancelled else { return }
        render()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.alwaysBounceVertical = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = MusicFreeUIColorTokens.separator
        tableView.accessibilityIdentifier = "playlists.list.table"
        tableView.register(
            PlaylistRowCell.self,
            forCellReuseIdentifier: PlaylistRowCell.reuseIdentifier
        )
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(
            self,
            action: #selector(refreshTriggered),
            for: .valueChanged
        )
        tableView.delegate = self

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, Item>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return nil }
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlaylistRowCell.reuseIdentifier,
                for: indexPath
            )
            guard let rowCell = cell as? PlaylistRowCell,
                  case let .playlist(playlistID) = item,
                  let playlist = self.viewModel.playlist(withID: playlistID)
            else {
                return cell
            }
            rowCell.configure(
                playlist: playlist,
                artworkServing: self.artworkServing,
                onActivate: { [weak self] in
                    self?.onSelectPlaylist?(playlist)
                },
                onContextMenu: { [weak self] in
                    guard let self else { return nil }
                    return UIMenu(children: [
                        UIAction(
                            title: L("重命名"),
                            image: UIImage(systemName: "pencil")
                        ) { [weak self] _ in
                            self?.presentRenameEditor(for: playlist)
                        },
                        UIAction(
                            title: L("删除"),
                            image: UIImage(systemName: "trash"),
                            attributes: [.destructive]
                        ) { [weak self] _ in
                            self?.requestDelete(playlist)
                        }
                    ])
                }
            )
            rowCell.accessibilityIdentifier = "playlists.open.\(playlist.id.rawValue)"
            return rowCell
        }
    }

    private func configureNavigationItems() {
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(createPlaylistTriggered)
        )
        addItem.accessibilityLabel = L("新建歌单")
        addItem.accessibilityIdentifier = "playlists.create"
        navigationItem.rightBarButtonItem = addItem
    }

    private func render() {
        guard isViewLoaded else { return }
        tableView.refreshControl?.endRefreshing()

        let nextSignatures = Dictionary(
            uniqueKeysWithValues: viewModel.playlists.map { playlist in
                (playlist.id, playlistRowSignature(playlist))
            }
        )

        if viewModel.playlists.isEmpty {
            renderedPlaylistSignatures = [:]
            tableView.isHidden = true
            switch viewModel.loadState {
            case .failed(let message):
                installStatusView(
                    MusicFreeUIKitErrorStateView(
                        title: L("歌单加载失败"),
                        message: message,
                        retryTitle: L("重试"),
                        retry: { [weak self] in self?.reload() }
                    )
                )
            case .empty:
                installStatusView(
                    MusicFreeUIKitEmptyStateView(
                        title: L("还没有歌单"),
                        message: L("创建一个歌单，整理喜欢的歌曲。"),
                        systemImage: "music.note.list",
                        actionTitle: L("新建歌单"),
                        onAction: { [weak self] in self?.presentCreateEditor() }
                    )
                )
            case .idle, .loading, .loaded:
                installStatusView(MusicFreeUIKitLoadingStateView(label: L("加载歌单")))
            }
            return
        }

        removeStatusView()
        tableView.isHidden = false
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.playlists])
        snapshot.appendItems(
            viewModel.playlists.map { .playlist($0.id) },
            toSection: .playlists
        )
        let previousSnapshot = dataSource.snapshot()
        let structureChanged = previousSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
            || previousSnapshot.itemIdentifiers != snapshot.itemIdentifiers
        let oldItems = Set(previousSnapshot.itemIdentifiers)
        let changedItems = snapshot.itemIdentifiers.compactMap { item -> Item? in
            guard oldItems.contains(item),
                  case let .playlist(id) = item,
                  renderedPlaylistSignatures[id] != nextSignatures[id]
            else { return nil }
            return item
        }
        renderedPlaylistSignatures = nextSignatures
        guard structureChanged || !changedItems.isEmpty else { return }
        if #available(iOS 15.0, *), !changedItems.isEmpty {
            snapshot.reconfigureItems(changedItems)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func playlistRowSignature(_ playlist: Playlist) -> String {
        [
            playlist.id.rawValue,
            playlist.name,
            playlist.sortName ?? "",
            playlist.artworkID?.rawValue ?? ""
        ].joined(separator: "\u{001F}")
    }

    private func installStatusView(_ nextView: UIView) {
        if let statusView, type(of: statusView) == type(of: nextView) {
            return
        }
        removeStatusView()
        nextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextView.topAnchor.constraint(equalTo: view.topAnchor),
            nextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        statusView = nextView
    }

    private func removeStatusView() {
        statusView?.removeFromSuperview()
        statusView = nil
    }

    private func reload() {
        guard mutationTask == nil else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
        }
    }

    @objc private func refreshTriggered() {
        reload()
    }

    @objc private func createPlaylistTriggered() {
        presentCreateEditor()
    }

    private func presentCreateEditor() {
        presentNameEditor(
            title: L("新建歌单"),
            initialName: nil,
            // Keep the UIKit editor's action label identical to the existing
            // SwiftUI PlaylistEditor and the visual-review contract.
            confirmTitle: L("保存")
        ) { [weak self] name in
            self?.mutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let created = await viewModel.createPlaylist(named: name)
                mutationTask = nil
                render()
                if pendingExternalReload {
                    pendingExternalReload = false
                    await reloadFromExternalChange()
                }
                if created, let playlist = viewModel.selectedPlaylist {
                    onSelectPlaylist?(playlist)
                } else {
                    presentMutationFailureIfNeeded()
                }
            }
        }
    }

    private func presentRenameEditor(for playlist: Playlist) {
        presentNameEditor(
            title: L("重命名歌单"),
            initialName: playlist.name,
            confirmTitle: L("保存")
        ) { [weak self] name in
            self?.mutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await viewModel.renamePlaylist(playlist.id, to: name)
                mutationTask = nil
                render()
                if pendingExternalReload {
                    pendingExternalReload = false
                    await reloadFromExternalChange()
                }
                presentMutationFailureIfNeeded()
            }
        }
    }

    private func presentNameEditor(
        title: String,
        initialName: String?,
        confirmTitle: String,
        onSubmit: @escaping (String) -> Void
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: title,
            message: L("最多 %d 个字符", PlaylistNameValidator.maximumLength),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = initialName
            textField.placeholder = L("名称")
            textField.clearButtonMode = .whileEditing
            textField.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        let saveAction = UIAlertAction(title: confirmTitle, style: .default) { [weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            onSubmit(value)
        }
        alert.addAction(saveAction)
        present(alert, animated: true)
    }

    private func presentMutationFailureIfNeeded() {
        guard case .failed(let message) = viewModel.mutationState else { return }
        let alert = UIAlertController(
            title: L("操作失败"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("好"), style: .default) { [weak self] _ in
            self?.viewModel.clearMutationState()
        })
        present(alert, animated: true)
    }

    private func requestDelete(_ playlist: Playlist) {
        let alert = UIAlertController(
            title: L("删除歌单？"),
            message: L("歌单和其中的排序关系会被删除。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.mutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await viewModel.deletePlaylist(playlist.id)
                mutationTask = nil
                render()
                if pendingExternalReload {
                    pendingExternalReload = false
                    await reloadFromExternalChange()
                }
                presentMutationFailureIfNeeded()
            }
        })
        present(alert, animated: true)
    }
}

extension PlaylistListViewController: UITableViewDelegate {
    public func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .playlist(playlistID) = item,
              let playlist = viewModel.playlist(withID: playlistID)
        else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectPlaylist?(playlist)
    }

    public func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .playlist(playlistID) = item,
              let playlist = viewModel.playlist(withID: playlistID)
        else { return nil }

        return UIContextMenuConfiguration(identifier: playlistID.rawValue as NSString) {
            nil
        } actionProvider: { [weak self] _ in
            let rename = UIAction(
                title: L("重命名"),
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in
                self?.presentRenameEditor(for: playlist)
            }
            let delete = UIAction(
                title: L("删除"),
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { [weak self] _ in
                self?.requestDelete(playlist)
            }
            return UIMenu(children: [rename, delete])
        }
    }
}

@MainActor
private final class PlaylistRowCell: UITableViewCell, UIContextMenuInteractionDelegate {
    static let reuseIdentifier = "PlaylistRowCell"

    private let rowView = MusicFreeUIKitMediaRowView(
        title: "",
        subtitle: L("歌单"),
        showsArtwork: true,
        placeholderSystemImage: "music.note.list"
    )
    private lazy var artworkBinding = PlaylistArtworkBinding(view: rowView.artworkSurface)
//    private let activationButton = UIButton(type: .system)
    private var onActivate: (() -> Void)?
    private var onContextMenu: (() -> UIMenu?)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        rowView.isUserInteractionEnabled = false
        rowView.exposesTextAccessibility = true
        rowView.translatesAutoresizingMaskIntoConstraints = false
        let accessory = UIImageView(
            image: UIImage(systemName: "chevron.forward")
        )
        accessory.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        accessory.contentMode = .scaleAspectFit
        accessory.translatesAutoresizingMaskIntoConstraints = false
        rowView.accessoryView = accessory
        contentView.addSubview(rowView)
        // Keep the visual row native while providing the same Button ->
        // StaticText accessibility hierarchy as SwiftUI NavigationLink.  A
        // UITableViewCell with `.button` traits is still exposed as `Cell` by
        // XCTest, so an explicit transparent UIButton is required for the
        // existing playlist locators and VoiceOver activation semantics.
//        activationButton.translatesAutoresizingMaskIntoConstraints = false
//        activationButton.backgroundColor = .red
//        activationButton.setTitleColor(.clear, for: .normal)
//        activationButton.addTarget(
//            self,
//            action: #selector(activate),
//            for: [.touchUpInside, .primaryActionTriggered]
//        )
//        activationButton.addInteraction(UIContextMenuInteraction(delegate: self))
//        contentView.addSubview(activationButton)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
//            activationButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
//            activationButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
//            activationButton.topAnchor.constraint(equalTo: contentView.topAnchor),
//            activationButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        playlist: Playlist,
        artworkServing: (any ArtworkServing)?,
        onActivate: @escaping () -> Void,
        onContextMenu: @escaping () -> UIMenu?
    ) {
        self.onActivate = onActivate
        self.onContextMenu = onContextMenu
        rowView.titleText = playlist.name
        rowView.subtitleText = L("歌单")
        rowView.titleAccessibilityIdentifier = playlist.name
        artworkBinding.configure(
            artworkID: playlist.artworkID,
            sourceID: MediaSourceID.local,
            maximumPixelDimension: 160,
            serving: artworkServing
        )
//        activationButton.setTitle(playlist.name, for: .normal)
//        activationButton.accessibilityLabel = playlist.name
//        activationButton.accessibilityIdentifier = "playlists.open.\(playlist.id.rawValue)"
//        activationButton.titleLabel?.accessibilityIdentifier = playlist.name
//        activationButton.accessibilityTraits = [.button]
        accessibilityLabel = nil
        accessibilityTraits = []
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkBinding.reset()
        onActivate = nil
        onContextMenu = nil
    }

    @objc private func activate() {
        onActivate?()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard onContextMenu?() != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.onContextMenu?()
        }
    }
}
