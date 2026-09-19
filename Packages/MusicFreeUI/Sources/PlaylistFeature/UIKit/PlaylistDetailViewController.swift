import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import UIKit

/// UIKit detail surface for one playlist. The feature view model remains the
/// authority for ordering, CRUD and playback commands; this controller owns
/// only UIKit presentation and table interactions.
@MainActor
public final class PlaylistDetailViewController: UIViewController {
    public let playlist: Playlist
    public let store: any PlaylistFeatureStore
    public let playback: any PlaylistFeaturePlaybackServing
    public let libraryServing: (any LibraryServing)?
    public let artworkServing: (any ArtworkServing)?

    private let viewModel: PlaylistDetailViewModel
    private let candidateLoader: PlaylistTrackCandidateLoader
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView: PlaylistDetailHeaderView
    private var statusView: UIView?
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var candidateTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var pendingExternalReload = false
    private var isPresentingAddFlow = false
    private var renderedEntryIDs: [MediaItemID] = []
    private var renderedCandidateSignatures: [MediaItemID: String] = [:]

    public init(
        playlist: Playlist,
        store: any PlaylistFeatureStore,
        playback: any PlaylistFeaturePlaybackServing,
        libraryServing: (any LibraryServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil
    ) {
        self.playlist = playlist
        self.store = store
        self.playback = playback
        self.libraryServing = libraryServing
        self.artworkServing = artworkServing
        viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            store: store,
            playback: playback
        )
        candidateLoader = PlaylistTrackCandidateLoader(library: libraryServing)
        headerView = PlaylistDetailHeaderView(playlist: playlist)
        super.init(nibName: nil, bundle: nil)
        title = playlist.name
        restorationIdentifier = "playlists.detail.uikit"
    }

    public convenience init(
        playlist: Playlist,
        playlistServing: any PlaylistServing,
        playbackServing: any PlaybackServing,
        libraryServing: (any LibraryServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil
    ) {
        self.init(
            playlist: playlist,
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
        view.accessibilityIdentifier = "playlists.detail"
        navigationItem.largeTitleDisplayMode = .never

        configureTableView()
        configureHeader()
        configureNavigationItems()
        render()

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
            await loadCandidatesIfNeeded()
            observeLibraryChanges()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeTableHeaderIfNeeded()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        candidateTask?.cancel()
        mutationTask?.cancel()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeLibraryChanges()
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        tableView
    }

    deinit {
        loadTask?.cancel()
        candidateTask?.cancel()
        mutationTask?.cancel()
        libraryChangeTask?.cancel()
    }

    private func observeLibraryChanges() {
        guard libraryChangeTask == nil, let libraryServing else { return }
        libraryChangeTask = Task { @MainActor [weak self] in
            let stream = await libraryServing.makeChangeStream()
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                let playlistIDs = change.affectedIDs.playlistIDs
                let relevantPlaylistChange = change.categories.contains(.playlists)
                    && (playlistIDs.isEmpty || playlistIDs.contains(self.viewModel.playlistID))
                let relevantEntryChange = change.categories.contains(.playlistEntries)
                    && (playlistIDs.isEmpty || playlistIDs.contains(self.viewModel.playlistID))
                let metadataCategories: Set<LibraryChangeCategory> = [
                    .tracks, .artwork, .deletions
                ]
                let visibleTrackIDs = Set(self.viewModel.itemIDs)
                let relevantMetadataIDs = change.affectedIDs.trackIDs
                    .intersection(visibleTrackIDs)
                let relevantMetadataChange = !relevantMetadataIDs.isEmpty
                    && !change.categories.isDisjoint(with: metadataCategories)
                guard relevantPlaylistChange || relevantEntryChange || relevantMetadataChange else {
                    continue
                }
                if self.isPresentingAddFlow || self.viewModel.isEditing || self.viewModel.isMutating {
                    self.pendingExternalReload = true
                    continue
                }
                if relevantMetadataChange && !relevantPlaylistChange && !relevantEntryChange {
                    let changedIDs = await self.candidateLoader.refresh(trackIDs: relevantMetadataIDs)
                    self.reloadCandidateRows(changedIDs)
                } else {
                    await self.reloadFromExternalChange(change)
                }
            }
        }
    }

    private func reloadFromExternalChange(_ change: LibraryChange? = nil) async {
        guard !viewModel.isEditing, !viewModel.isMutating else {
            pendingExternalReload = true
            return
        }

        if change?.categories.contains(.playlists) == true {
            do {
                let playlists = try await store.loadPlaylists()
                guard !Task.isCancelled else { return }
                guard let updated = playlists.first(where: { $0.id == viewModel.playlistID }) else {
                    navigationController?.popViewController(animated: true)
                    return
                }
                viewModel.updatePlaylist(updated)
            } catch is CancellationError {
                return
            } catch {
                // Keep the currently visible playlist when an external read
                // fails; the next library change or pull-to-refresh retries.
            }
        }

        if change?.categories.contains(.playlistEntries) == true || change == nil {
            await viewModel.load()
        }
        guard !Task.isCancelled else { return }
        render()
    }

    private func applyPendingExternalReloadIfNeeded() async {
        guard pendingExternalReload else { return }
        pendingExternalReload = false
        await reloadFromExternalChange()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.alwaysBounceVertical = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.separatorColor = MusicFreeUIColorTokens.separator
        tableView.accessibilityIdentifier = "playlists.detail.table"
        tableView.register(
            PlaylistEntryCell.self,
            forCellReuseIdentifier: PlaylistEntryCell.reuseIdentifier
        )
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(
            self,
            action: #selector(refreshTriggered),
            for: .valueChanged
        )
        tableView.dataSource = self
        tableView.delegate = self

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureHeader() {
        headerView.onPlayAll = { [weak self] in self?.sendPlayback(.playAll) }
        headerView.onShuffle = { [weak self] in self?.sendPlayback(.shuffle) }
        headerView.accessibilityIdentifier = "playlists.detail.header"
        tableView.tableHeaderView = headerView
    }

    private func configureNavigationItems() {
        let add = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addTracksTriggered)
        )
        add.accessibilityLabel = L("添加歌曲")
        // Keep the sheet's container identifier unique.  Reusing
        // `playlists.addTracks` here makes XCTest's firstMatch resolve to the
        // obscured toolbar button instead of the presented list container.
        add.accessibilityIdentifier = "playlists.detail.addTracks"

        let edit = UIBarButtonItem(
            image: UIImage(systemName: "pencil"),
            style: .plain,
            target: self,
            action: #selector(editTriggered)
        )
        edit.accessibilityLabel = L("编辑歌单")
        edit.accessibilityIdentifier = "playlists.edit"
        navigationItem.rightBarButtonItems = [edit, add]
    }

    private func render() {
        guard isViewLoaded else { return }
        tableView.refreshControl?.endRefreshing()
        headerView.update(
            playlist: viewModel.playlist,
            entryCount: viewModel.entries.count,
            isEnabled: !viewModel.entries.isEmpty && !viewModel.isSendingCommand,
            artworkServing: artworkServing
        )
        navigationItem.title = viewModel.playlist.name

        if viewModel.entries.isEmpty {
            switch viewModel.loadState {
            case .failed(let message):
                tableView.isHidden = true
                tableView.tableFooterView = nil
                installStatusView(
                    MusicFreeUIKitErrorStateView(
                        title: L("歌单加载失败"),
                        message: message,
                        retryTitle: L("重试"),
                        retry: { [weak self] in self?.reload() }
                    )
                )
            case .empty:
                // Keep the table/header visible for an empty playlist.  The
                // SwiftUI reference renders the playlist artwork, title and
                // “0 tracks” header before the empty-state action; hiding the
                // table here removed that header entirely in the UIKit slice.
                tableView.isHidden = false
                removeStatusView()
                installEmptyFooter()
            case .idle, .loading, .loaded:
                tableView.isHidden = true
                tableView.tableFooterView = nil
                installStatusView(MusicFreeUIKitLoadingStateView(label: L("加载歌曲")))
            }
        } else {
            removeStatusView()
            tableView.isHidden = false
            tableView.tableFooterView = nil
            renderEntryRows()
            resizeTableHeaderIfNeeded()
        }
        updateEditingAppearance()
    }

    private func renderEntryRows() {
        let nextEntries = viewModel.orderedEntries
        let nextIDs = nextEntries.map(\.trackID)
        let nextSignatures = Dictionary(uniqueKeysWithValues: nextEntries.map { entry in
            (entry.trackID, candidateSignature(for: entry))
        })
        let structureChanged = renderedEntryIDs != nextIDs
        renderedEntryIDs = nextIDs
        let previousSignatures = renderedCandidateSignatures
        renderedCandidateSignatures = nextSignatures

        if structureChanged {
            tableView.reloadData()
            return
        }

        let changedRows = nextEntries.indices.compactMap { index -> IndexPath? in
            let trackID = nextEntries[index].trackID
            return previousSignatures[trackID] == nextSignatures[trackID]
                ? nil
                : IndexPath(row: index, section: 0)
        }
        let validRows = changedRows.filter { $0.row < tableView.numberOfRows(inSection: 0) }
        if !validRows.isEmpty {
            tableView.reloadRows(at: validRows, with: .none)
        }
    }

    private func reloadCandidateRows(_ trackIDs: Set<MediaItemID>) {
        guard !trackIDs.isEmpty, isViewLoaded, !tableView.isHidden else { return }
        var changedRows: [IndexPath] = []
        let entries = viewModel.orderedEntries
        for (index, entry) in entries.enumerated() where trackIDs.contains(entry.trackID) {
            renderedCandidateSignatures[entry.trackID] = candidateSignature(for: entry)
            changedRows.append(IndexPath(row: index, section: 0))
        }
        let validRows = changedRows.filter { $0.row < tableView.numberOfRows(inSection: 0) }
        if !validRows.isEmpty {
            tableView.reloadRows(at: validRows, with: .none)
        }
    }

    private func candidateSignature(for entry: PlaylistEntry) -> String {
        let candidate = candidateLoader.candidates.first { $0.id == entry.trackID }
        return [
            entry.trackID.externalID,
            candidate?.title ?? "",
            candidate?.subtitle ?? ""
        ].joined(separator: "\u{001F}")
    }

    private func installEmptyFooter() {
        let messageLabel = UILabel()
        messageLabel.text = L("添加歌曲后，就能从这里开始播放。")
        messageLabel.font = MusicFreeUIFontTokens.body
        messageLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let addButton = MusicFreeUIKitPillActionButton(
            title: L("添加歌曲"),
            systemImage: "plus"
        )
        addButton.accessibilityIdentifier = "playlists.addTracks.emptyAction"
        addButton.isEnabled = canPresentAddFlow
        addButton.onPrimaryAction = { [weak self] in self?.presentAddFlow() }

        let stack = UIStackView(arrangedSubviews: [messageLabel, addButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.large
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.xxLarge,
            leading: MusicFreeSpacingTokens.contentInset,
            bottom: MusicFreeSpacingTokens.xxLarge,
            trailing: MusicFreeSpacingTokens.contentInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let footer = UIView()
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: footer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor)
        ])
        let targetWidth = max(tableView.bounds.width, view.bounds.width)
        let targetSize = CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height)
        let height = footer.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        footer.frame = CGRect(x: 0, y: 0, width: targetWidth, height: max(height, 180))
        tableView.tableFooterView = footer
    }

    private func resizeTableHeaderIfNeeded() {
        guard let header = tableView.tableHeaderView,
              tableView.bounds.width > 0
        else { return }
        let targetSize = CGSize(
            width: tableView.bounds.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = header.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard abs(header.frame.height - size.height) > 0.5 else { return }
        header.frame.size = CGSize(width: tableView.bounds.width, height: size.height)
        tableView.tableHeaderView = header
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
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private func loadCandidatesIfNeeded() async {
        guard libraryServing != nil,
              candidateLoader.loadState == .idle,
              !candidateLoader.isLoading
        else { return }
        candidateTask?.cancel()
        candidateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await candidateLoader.load()
            guard !Task.isCancelled else { return }
            render()
        }
        await candidateTask?.value
    }

    @objc private func refreshTriggered() {
        reload()
    }

    @objc private func addTracksTriggered() {
        presentAddFlow()
    }

    private func presentAddFlow() {
        guard !isPresentingAddFlow, libraryServing != nil else { return }
        if candidateLoader.loadState == .idle {
            candidateTask?.cancel()
            candidateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await candidateLoader.load()
                guard !Task.isCancelled else { return }
                presentAddFlow()
            }
            return
        }
        guard candidateLoader.loadState == .loaded || candidateLoader.loadState == .empty else {
            return
        }
        isPresentingAddFlow = true
        let controller = PlaylistAddTracksViewController(
            candidates: candidateLoader.candidates,
            existingIDs: Set(viewModel.itemIDs),
            onSubmit: { [weak self] selectedIDs in
                guard let self else { return false }
                let result = await viewModel.addTracks(selectedIDs)
                render()
                return result
            }
        )
        controller.onDismiss = { [weak self] in
            guard let self else { return }
            isPresentingAddFlow = false
            Task { @MainActor [weak self] in
                await self?.applyPendingExternalReloadIfNeeded()
            }
        }
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = UIModalPresentationStyle.formSheet
        present(navigationController, animated: true)
    }

    private var canPresentAddFlow: Bool {
        !viewModel.isLoading
            && !viewModel.isMutating
            && (candidateLoader.loadState == .loaded || candidateLoader.loadState == .empty)
    }

    @objc private func editTriggered() {
        if viewModel.isEditing {
            mutationTask?.cancel()
            mutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await viewModel.saveReorder()
                mutationTask = nil
                render()
                await applyPendingExternalReloadIfNeeded()
                presentMutationFailureIfNeeded()
            }
        } else {
            viewModel.beginEditing()
            tableView.setEditing(true, animated: true)
            updateEditingAppearance()
            renderedEntryIDs.removeAll(keepingCapacity: true)
            tableView.reloadData()
        }
    }

    private func updateEditingAppearance() {
        guard let editButton = navigationItem.rightBarButtonItems?.first else { return }
        editButton.image = UIImage(systemName: viewModel.isEditing ? "checkmark" : "pencil")
        editButton.accessibilityLabel = L(viewModel.isEditing ? "完成编辑" : "编辑歌单")
        let addButton = navigationItem.rightBarButtonItems?.last
        addButton?.isEnabled = !viewModel.isEditing && !viewModel.isMutating
    }

    private func sendPlayback(_ intent: PlaylistPlaybackIntent) {
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await viewModel.sendPlayback(intent)
            mutationTask = nil
            render()
            await applyPendingExternalReloadIfNeeded()
            presentCommandFailureIfNeeded()
        }
    }

    private func sendPlayback(
        itemID: MediaItemID,
        intent: PlaylistPlaybackIntent
    ) {
        guard let command = PlaylistPlaybackCommand.make(
            playlistID: viewModel.playlist.id,
            itemIDs: [itemID],
            intent: intent
        ) else { return }
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await playback.send(command)
            } catch {
                let alert = UIAlertController(
                    title: L("播放失败"),
                    message: playlistFeatureMessage(for: error),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L("好"), style: .default))
                present(alert, animated: true)
            }
                mutationTask = nil
                await applyPendingExternalReloadIfNeeded()
            }
    }

    private func play(_ itemID: MediaItemID) {
        mutationTask?.cancel()
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await viewModel.play(itemID: itemID)
            mutationTask = nil
            await applyPendingExternalReloadIfNeeded()
            presentCommandFailureIfNeeded()
        }
    }

    private func makeTrackMenu(
        entry: PlaylistEntry,
        candidate: PlaylistTrackCandidate?
    ) -> UIMenu {
        let title = candidate?.title ?? entry.trackID.externalID
        let subtitle = candidate?.subtitle
        let shareText = [title, subtitle].compactMap { $0 }.joined(separator: " - ")
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            let controller = UIActivityViewController(
                activityItems: [shareText],
                applicationActivities: nil
            )
            if let popover = controller.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(
                    x: self.view.bounds.midX,
                    y: self.view.bounds.midY,
                    width: 1,
                    height: 1
                )
            }
            self.present(controller, animated: true)
        }
        let remove = UIAction(
            title: L("从歌单移除"),
            image: UIImage(systemName: "trash"),
            attributes: [.destructive]
        ) { [weak self] _ in
            self?.remove(trackIDs: [entry.trackID])
        }
        return UIMenu(children: [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [share]
            ),
            UIMenu(title: "", options: [.displayInline], children: [
                UIAction(
                    title: L("播放"),
                    image: UIImage(systemName: "play.fill")
                ) { [weak self] _ in self?.play(entry.trackID) },
                UIAction(
                    title: L("下一首播放"),
                    image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
                ) { [weak self] _ in
                    self?.sendPlayback(itemID: entry.trackID, intent: .playNext)
                },
                UIAction(
                    title: L("加入队列"),
                    image: UIImage(systemName: "text.append")
                ) { [weak self] _ in
                    self?.sendPlayback(itemID: entry.trackID, intent: .enqueue)
                },
            ]),
            UIMenu(title: "", options: [.displayInline], children: [remove]),
        ])
    }

    private func remove(trackIDs: Set<MediaItemID>) {
        guard !trackIDs.isEmpty else { return }
        let alert = UIAlertController(
            title: L("移除所选歌曲？"),
            message: L("歌曲会从当前歌单移除，资料库中的原曲不会被删除。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("移除"), style: .destructive) { [weak self] _ in
            self?.mutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await viewModel.remove(trackIDs: trackIDs)
                mutationTask = nil
                render()
                await applyPendingExternalReloadIfNeeded()
                presentMutationFailureIfNeeded()
            }
        })
        present(alert, animated: true)
    }

    private func presentMutationFailureIfNeeded() {
        guard case .failed(let message) = viewModel.mutationState else { return }
        let alert = UIAlertController(title: L("操作失败"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .default) { [weak self] _ in
            self?.viewModel.clearMutationState()
        })
        present(alert, animated: true)
    }

    private func presentCommandFailureIfNeeded() {
        guard case .failed(let message) = viewModel.commandState else { return }
        let alert = UIAlertController(title: L("播放失败"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .default) { [weak self] _ in
            self?.viewModel.clearCommandState()
        })
        present(alert, animated: true)
    }
}

extension PlaylistDetailViewController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.orderedEntries.count
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PlaylistEntryCell.reuseIdentifier,
            for: indexPath
        )
        guard let entryCell = cell as? PlaylistEntryCell,
              indexPath.row < viewModel.orderedEntries.count
        else { return cell }
        let entry = viewModel.orderedEntries[indexPath.row]
        let candidate = candidateLoader.candidates.first { $0.id == entry.trackID }
        entryCell.configure(
            position: indexPath.row,
            title: candidate?.title ?? entry.trackID.externalID,
            subtitle: candidate?.subtitle,
            isEditing: viewModel.isEditing,
            isSelected: viewModel.selectedTrackIDs.contains(entry.trackID),
            menu: makeTrackMenu(entry: entry, candidate: candidate)
        )
        entryCell.accessibilityIdentifier = "playlists.track.\(entry.trackID.externalID)"
        return entryCell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < viewModel.orderedEntries.count else { return }
        let entry = viewModel.orderedEntries[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        if viewModel.isEditing {
            viewModel.toggleSelection(for: entry.trackID)
            tableView.reloadRows(at: [indexPath], with: .none)
            return
        }
        play(entry.trackID)
    }

    public func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !viewModel.isEditing,
              indexPath.row < viewModel.orderedEntries.count
        else { return nil }
        let entry = viewModel.orderedEntries[indexPath.row]
        let candidate = candidateLoader.candidates.first { $0.id == entry.trackID }
        let configuration = UIContextMenuConfiguration(
            identifier: NSString(string: "\(viewModel.playlist.id.rawValue)-\(entry.trackID.externalID)"),
            previewProvider: nil
        ) { [weak self] _ in
            self?.makeTrackMenu(entry: entry, candidate: candidate)
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    public func tableView(
        _ tableView: UITableView,
        canMoveRowAt indexPath: IndexPath
    ) -> Bool {
        viewModel.isEditing && !viewModel.isMutating
    }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        viewModel.move(
            from: IndexSet(integer: sourceIndexPath.row),
            to: destinationIndexPath.row
        )
        tableView.reloadData()
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !viewModel.isEditing,
              indexPath.row < viewModel.orderedEntries.count
        else { return nil }
        let entry = viewModel.orderedEntries[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: L("移除")) { [weak self] _, _, completion in
            self?.remove(trackIDs: Set([entry.trackID]))
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [action])
    }
}

@MainActor
private final class PlaylistDetailHeaderView: UIView {
    var onPlayAll: (() -> Void)?
    var onShuffle: (() -> Void)?

    private let artworkView = MusicFreeUIKitArtworkView(
        accessibilityLabel: L("歌单封面"),
        placeholderSystemImage: "music.note.list",
        placeholderTitle: nil
    )
    private lazy var artworkBinding = PlaylistArtworkBinding(view: artworkView)
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let playButton = MusicFreeUIKitPillActionButton(
        title: L("播放全部"),
        systemImage: "play.fill"
    )
    private let shuffleButton = MusicFreeUIKitPillActionButton(
        title: L("随机播放"),
        systemImage: "shuffle"
    )
    private let stack = UIStackView()
    private let actions = UIStackView()
    private let accessibilityAnchor = UIView()

    init(playlist: Playlist) {
        super.init(frame: .zero)
        titleLabel.text = playlist.name
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        playlist: Playlist,
        entryCount: Int,
        isEnabled: Bool,
        artworkServing: (any ArtworkServing)?
    ) {
        titleLabel.text = playlist.name
        artworkView.placeholderTitle = playlist.name
        artworkBinding.configure(
            artworkID: playlist.artworkID,
            sourceID: MediaSourceID.local,
            maximumPixelDimension: 320,
            serving: artworkServing
        )
        // Match the SwiftUI surface's localized key so the English visual
        // review exposes “0 tracks” (and Chinese still resolves through the
        // same catalog entry) instead of an untranslated UIKit-only string.
        countLabel.text = L("%d tracks", entryCount)
        playButton.isEnabled = isEnabled
        shuffleButton.isEnabled = isEnabled
    }

    private func commonInit() {
        backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        // UITableView may stop exposing a tableHeaderView itself as an
        // accessibility container after reloadData(). Keep a tiny independent
        // anchor so the header remains queryable without hiding its labels and
        // playback buttons from assistive technologies.
        accessibilityAnchor.translatesAutoresizingMaskIntoConstraints = false
        accessibilityAnchor.accessibilityIdentifier = "playlists.detail.header"
        accessibilityAnchor.accessibilityLabel = L("歌单标题")
        accessibilityAnchor.accessibilityTraits = .header
        accessibilityAnchor.isAccessibilityElement = true
        addSubview(accessibilityAnchor)
        NSLayoutConstraint.activate([
            accessibilityAnchor.leadingAnchor.constraint(equalTo: leadingAnchor),
            accessibilityAnchor.topAnchor.constraint(equalTo: topAnchor),
            accessibilityAnchor.widthAnchor.constraint(equalToConstant: 1),
            accessibilityAnchor.heightAnchor.constraint(equalToConstant: 1)
        ])
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor).isActive = true
        artworkView.accessibilityIdentifier = "playlists.detail.artwork"

        titleLabel.font = MusicFreeUIFontTokens.screenTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        countLabel.font = MusicFreeUIFontTokens.secondary
        countLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        countLabel.textAlignment = .center

        playButton.onPrimaryAction = { [weak self] in self?.onPlayAll?() }
        shuffleButton.onPrimaryAction = { [weak self] in self?.onShuffle?() }

        actions.axis = .horizontal
        actions.spacing = MusicFreeSpacingTokens.small
        actions.distribution = .fillEqually
        actions.addArrangedSubview(playButton)
        actions.addArrangedSubview(shuffleButton)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.large,
            leading: MusicFreeSpacingTokens.contentInset,
            bottom: MusicFreeSpacingTokens.large,
            trailing: MusicFreeSpacingTokens.contentInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(actions)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * MusicFreeSpacingTokens.contentInset)
        ])
    }
}

@MainActor
private final class PlaylistEntryCell: UITableViewCell {
    static let reuseIdentifier = "PlaylistEntryCell"

    private let numberLabel = UILabel()
    private let rowView = MusicFreeUIKitMediaRowView(
        title: "",
        subtitle: nil,
        showsArtwork: false
    )
    private let selectionView = UIImageView()
    private let moreButton = UIButton(type: .system)
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        numberLabel.font = MusicFreeUIFontTokens.caption
        numberLabel.textColor = MusicFreeUIColorTokens.foregroundTertiary
        numberLabel.textAlignment = .center
        numberLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        selectionView.translatesAutoresizingMaskIntoConstraints = false
        selectionView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        selectionView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        selectionView.tintColor = MusicFreeUIColorTokens.accent

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        moreButton.accessibilityLabel = L("歌曲选项")
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // Keep the title and artist as independent StaticText descendants,
        // matching the SwiftUI playlist detail hierarchy used by visual and
        // accessibility regression tests.
        rowView.exposesTextAccessibility = true
        rowView.isUserInteractionEnabled = false

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(numberLabel)
        stack.addArrangedSubview(rowView)
        stack.addArrangedSubview(moreButton)
        stack.addArrangedSubview(selectionView)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        position: Int,
        title: String,
        subtitle: String?,
        isEditing: Bool,
        isSelected: Bool,
        menu: UIMenu
    ) {
        numberLabel.text = "\(position + 1)"
        rowView.titleText = title
        rowView.subtitleText = subtitle
        rowView.isUserInteractionEnabled = false
        moreButton.menu = menu
        moreButton.isHidden = isEditing
        selectionView.isHidden = !isEditing
        selectionView.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle"
        )
        accessibilityLabel = title
        accessibilityValue = isEditing
            ? (isSelected ? L("已选择") : L("未选择"))
            : L("第 %d 首歌曲", position + 1)
    }
}
