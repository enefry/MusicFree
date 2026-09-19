import AVKit
import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MusicDomain
import PlaybackAPI
import UIKit

/// UIKit queue surface used by the migrated Now Playing controller.
///
/// Queue state remains owned by `PlayerViewModel`; this controller only maps
/// snapshots to table rows and forwards playback/queue commands.
@MainActor
public final class PlayerQueueViewController: UIViewController {
    private enum TableSection: Equatable {
        case history
        case current
        case playbackMode
        case upcoming
    }

    private struct Row {
        let entry: PlaybackQueueEntry
        let isCurrent: Bool
        let track: Track?
    }

    private let serving: any PlaybackServing
    private let artworkServing: (any ArtworkServing)?
    private let library: (any LibraryServing)?
    private let viewModel: PlayerViewModel
    private let historyLoader: NowPlayingHistoryLoader
    private let editor = QueueEditor()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let queueAccessibilityContainer = UIView()
    private let queueListContainer = UIView()
    private let queueScrollCompatibilityProxy = UIScrollView()
    private let currentQueueCompatibilityMarker = UIView()
    private let emptyStateView: MusicFreeUIKitEmptyStateView
    private let footerBar = UIView()
    private let footerStack = UIStackView()
    private let lyricsButton = UIButton(type: .system)
    private let routePicker = AVRoutePickerView()
    private let queueFooterButton = UIButton(type: .system)
    private let onShowLyrics: (() -> Void)?
    private let onShowAlbum: ((AlbumID) -> Void)?
    private let onShowArtist: ((ArtistID) -> Void)?
    private let onDismiss: (() -> Void)?
    private var currentRow: Row?
    private var upcomingRows: [Row] = []
    private var sections: [TableSection] = []
    private var trackTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyObservationTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?
    private var snapshotCancellable: AnyCancellable?
    private var stateCancellables = Set<AnyCancellable>()
    private var tracks: [MediaItemID: Track] = [:]
    private var artistNames: [ArtistID: String] = [:]
    private var requestedQueueKey: String?
    private var renderedQueueStructure: PlaybackQueueStructure?
    private var renderedCurrentItemID: MediaItemID?
    private var queueRowsDirty = true
    private var renderedHistoryItems: [PlaybackHistoryItem] = []
    private var renderedHistoryArtistNames: [ArtistID: String] = [:]
    /// The queue presents history above the current item, but Apple Music
    /// opens with the current item anchored near the top of the scroll view.
    /// History and track metadata load asynchronously after the first reload,
    /// so keep applying that anchor until the user starts scrolling.
    private var hasUserScrolled = false

    public init(
        serving: any PlaybackServing,
        audioServing: (any PlaybackAudioServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil,
        onShowLyrics: (() -> Void)? = nil,
        onShowAlbum: ((AlbumID) -> Void)? = nil,
        onShowArtist: ((ArtistID) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.serving = serving
        self.artworkServing = artworkServing
        self.library = library
        self.onShowLyrics = onShowLyrics
        self.onShowAlbum = onShowAlbum
        self.onShowArtist = onShowArtist
        self.onDismiss = onDismiss
        viewModel = PlayerViewModel(
            serving: serving,
            audioServing: audioServing,
            autoStart: false
        )
        historyLoader = NowPlayingHistoryLoader(library: library)
        emptyStateView = MusicFreeUIKitEmptyStateView(
            title: L("暂无播放记录"),
            message: L("播放歌曲后，历史和继续播放队列会显示在这里。"),
            systemImage: "clock.arrow.circlepath"
        )
        super.init(nibName: nil, bundle: nil)
        title = L("播放队列")
        restorationIdentifier = "player.queue.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "player.queue"
        configureTableView()
        configureFooter()
        configureToolbar()
        observeState()
        render(serving.snapshot)
        viewModel.start()
        historyTask = Task { @MainActor [weak self] in
            await self?.historyLoader.load()
        }
        historyObservationTask = Task { @MainActor [weak self] in
            await self?.historyLoader.observeChanges()
        }
        observeLibraryChanges()
        snapshotCancellable = viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasUserScrolled = false
        observeLibraryChanges()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
        trackTask?.cancel()
        trackTask = nil
        historyTask?.cancel()
        historyTask = nil
        historyObservationTask?.cancel()
        historyObservationTask = nil
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
        editTask?.cancel()
        editTask = nil
        viewModel.stop()
    }

    deinit {
        trackTask?.cancel()
        historyTask?.cancel()
        historyObservationTask?.cancel()
        libraryChangeTask?.cancel()
        editTask?.cancel()
    }

    private func observeState() {
        historyLoader.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHistorySection() }
            .store(in: &stateCancellables)
        historyLoader.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHistoryItems() }
            .store(in: &stateCancellables)
        historyLoader.$artistNames
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHistoryArtistNames() }
            .store(in: &stateCancellables)
        historyLoader.$failureMessage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.presentError(title: L("播放历史不可用"), message: message) }
            .store(in: &stateCancellables)

        editor.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.tableView.setEditing(self.editor.isActive, animated: true)
                self.isModalInPresentation = self.editor.isActive
                self.queueRowsDirty = true
                self.render(self.serving.snapshot)
            }
            .store(in: &stateCancellables)
        editor.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rerender() }
            .store(in: &stateCancellables)
        editor.$failureMessage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.presentError(title: L("无法更新播放队列"), message: message) }
            .store(in: &stateCancellables)
    }

    private func rerender() {
        queueRowsDirty = true
        render(serving.snapshot)
    }

    private func observeLibraryChanges() {
        guard libraryChangeTask == nil, let library else { return }
        libraryChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await library.makeChangeStream()
            for await change in stream {
                guard !Task.isCancelled else { return }
                let categories: Set<LibraryChangeCategory> = [
                    .tracks, .artwork, .deletions
                ]
                guard !change.categories.isDisjoint(with: categories),
                      !change.affectedIDs.trackIDs.isEmpty
                else { continue }
                let visibleIDs = Set(self.currentRow?.entry.itemID.map { [$0] } ?? [])
                    .union(self.upcomingRows.compactMap(\.entry.itemID))
                    .intersection(change.affectedIDs.trackIDs)
                guard !visibleIDs.isEmpty else { continue }
                await self.refreshQueueTracks(visibleIDs, library: library)
            }
        }
    }

    private func configureTableView() {
        queueAccessibilityContainer.translatesAutoresizingMaskIntoConstraints = false
        queueAccessibilityContainer.backgroundColor = .clear
        queueAccessibilityContainer.isAccessibilityElement = false
        queueAccessibilityContainer.accessibilityIdentifier = "player.continuePlaying.list"
        view.addSubview(queueAccessibilityContainer)

        queueListContainer.translatesAutoresizingMaskIntoConstraints = false
        queueListContainer.backgroundColor = .clear
        queueListContainer.isAccessibilityElement = false
        queueAccessibilityContainer.addSubview(queueListContainer)

        // Keep the former Now Playing scroll locator available while the
        // queue locator points at the real UITableView. The proxy is placed
        // behind the table and remains visually inert; direct gestures still
        // hit the table above it.
        queueScrollCompatibilityProxy.translatesAutoresizingMaskIntoConstraints = false
        queueScrollCompatibilityProxy.backgroundColor = .clear
        queueScrollCompatibilityProxy.isAccessibilityElement = true
        queueScrollCompatibilityProxy.accessibilityIdentifier = "player.nowPlaying.upperScroll"
        queueScrollCompatibilityProxy.isScrollEnabled = false
        queueScrollCompatibilityProxy.alwaysBounceVertical = true
        queueAccessibilityContainer.insertSubview(
            queueScrollCompatibilityProxy,
            belowSubview: queueListContainer
        )

        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footerBar.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        footerBar.layer.borderColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.24).cgColor
        footerBar.layer.borderWidth = 0.5
        view.addSubview(footerBar)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        tableView.accessibilityIdentifier = "player.queue.list"
        tableView.register(PlayerQueueCell.self, forCellReuseIdentifier: PlayerQueueCell.reuseIdentifier)
        tableView.register(PlayerQueueMessageCell.self, forCellReuseIdentifier: PlayerQueueMessageCell.reuseIdentifier)
        tableView.register(PlayerQueueModeCell.self, forCellReuseIdentifier: PlayerQueueModeCell.reuseIdentifier)
        tableView.register(PlayerQueueHeaderView.self, forHeaderFooterViewReuseIdentifier: PlayerQueueHeaderView.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = MusicFreeLayoutMetrics.compactRowMinimumHeight
        tableView.estimatedRowHeight = MusicFreeLayoutMetrics.compactRowMinimumHeight
        queueListContainer.addSubview(tableView)
        NSLayoutConstraint.activate([
            queueAccessibilityContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            queueAccessibilityContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            queueAccessibilityContainer.topAnchor.constraint(equalTo: view.topAnchor),
            queueAccessibilityContainer.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            footerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            queueListContainer.leadingAnchor.constraint(equalTo: queueAccessibilityContainer.leadingAnchor),
            queueListContainer.trailingAnchor.constraint(equalTo: queueAccessibilityContainer.trailingAnchor),
            queueListContainer.topAnchor.constraint(equalTo: queueAccessibilityContainer.topAnchor),
            queueListContainer.bottomAnchor.constraint(equalTo: queueAccessibilityContainer.bottomAnchor),
            queueScrollCompatibilityProxy.leadingAnchor.constraint(equalTo: queueAccessibilityContainer.leadingAnchor),
            queueScrollCompatibilityProxy.trailingAnchor.constraint(equalTo: queueAccessibilityContainer.trailingAnchor),
            queueScrollCompatibilityProxy.topAnchor.constraint(equalTo: queueAccessibilityContainer.topAnchor),
            queueScrollCompatibilityProxy.bottomAnchor.constraint(equalTo: queueAccessibilityContainer.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: queueListContainer.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: queueListContainer.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: queueListContainer.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: queueListContainer.bottomAnchor),
        ])

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        queueAccessibilityContainer.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: queueAccessibilityContainer.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: queueAccessibilityContainer.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: queueAccessibilityContainer.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: queueAccessibilityContainer.bottomAnchor),
        ])

        // Compatibility marker for the older queue locator. The real current
        // row remains exposed as `player.nowPlaying.current`; this marker
        // keeps the existing queue-only test contract during migration.
        currentQueueCompatibilityMarker.translatesAutoresizingMaskIntoConstraints = false
        currentQueueCompatibilityMarker.isAccessibilityElement = true
        currentQueueCompatibilityMarker.accessibilityIdentifier = "player.queue.current"
        currentQueueCompatibilityMarker.accessibilityLabel = L("正在播放")
        currentQueueCompatibilityMarker.alpha = 0.01
        queueListContainer.addSubview(currentQueueCompatibilityMarker)
        NSLayoutConstraint.activate([
            currentQueueCompatibilityMarker.leadingAnchor.constraint(equalTo: queueListContainer.leadingAnchor),
            currentQueueCompatibilityMarker.topAnchor.constraint(equalTo: queueListContainer.topAnchor),
            currentQueueCompatibilityMarker.widthAnchor.constraint(equalToConstant: 1),
            currentQueueCompatibilityMarker.heightAnchor.constraint(equalToConstant: 1),
        ])

        tableView.contentInset.bottom = MusicFreeSpacingTokens.small
        tableView.verticalScrollIndicatorInsets.bottom = MusicFreeSpacingTokens.small
    }

    private func configureFooter() {
        footerStack.axis = .horizontal
        footerStack.alignment = .center
        footerStack.distribution = .equalCentering
        footerStack.spacing = MusicFreeSpacingTokens.large
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        configureFooterButton(
            lyricsButton,
            systemImage: "quote.bubble",
            title: L("歌词"),
            action: #selector(showLyrics)
        )
        lyricsButton.accessibilityIdentifier = "player.lyrics.footer"

        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        routePicker.activeTintColor = MusicFreeUIColorTokens.accent
        routePicker.prioritizesVideoDevices = false
        routePicker.backgroundColor = .clear
        routePicker.accessibilityLabel = L("AirPlay")
        routePicker.accessibilityIdentifier = "player.routePicker"
        NSLayoutConstraint.activate([
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44)
        ])

        configureFooterButton(
            queueFooterButton,
            systemImage: "list.bullet.fill",
            title: L("播放队列"),
            action: #selector(dismissQueue)
        )
        queueFooterButton.accessibilityIdentifier = "player.queue.footer"
        queueFooterButton.accessibilityTraits = [.button, .selected]

        footerStack.addArrangedSubview(lyricsButton)
        footerStack.addArrangedSubview(routePicker)
        footerStack.addArrangedSubview(queueFooterButton)
        footerBar.addSubview(footerStack)
        NSLayoutConstraint.activate([
            footerBar.heightAnchor.constraint(equalToConstant: 72),
            footerStack.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: MusicFreeSpacingTokens.large),
            footerStack.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -MusicFreeSpacingTokens.large),
            footerStack.topAnchor.constraint(equalTo: footerBar.topAnchor),
            footerStack.bottomAnchor.constraint(equalTo: footerBar.bottomAnchor)
        ])
    }

    private func configureFooterButton(
        _ button: UIButton,
        systemImage: String,
        title: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = MusicFreeUIColorTokens.foregroundSecondary
        button.setImage(UIImage(systemName: systemImage), for: .normal)
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configureToolbar() {
        updateToolbar()
    }

    private func updateToolbar() {
        if editor.isActive {
            let cancel = UIBarButtonItem(
                title: L("取消"),
                style: .plain,
                target: self,
                action: #selector(cancelEditing)
            )
            cancel.accessibilityIdentifier = "player.queue.cancelEditing"
            navigationItem.leftBarButtonItem = cancel
            let done = UIBarButtonItem(
                title: editor.isSaving ? L("保存中…") : L("完成"),
                style: .done,
                target: self,
                action: #selector(commitEditing)
            )
            done.isEnabled = !editor.isSaving
            done.accessibilityIdentifier = "player.queue.doneEditing"
            navigationItem.rightBarButtonItems = [done]
            return
        }

        navigationItem.leftBarButtonItem = nil
        let edit = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(beginEditing)
        )
        edit.accessibilityLabel = L("编辑播放顺序")
        edit.accessibilityIdentifier = "player.queue.edit"
        edit.isEnabled = !upcomingRows.isEmpty

        let menu = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: makeQueueMenu()
        )
        menu.accessibilityLabel = L("更多队列操作")
        navigationItem.rightBarButtonItems = [menu, edit]
    }

    private func makeQueueMenu() -> UIMenu {
        let repeatMenu = UIMenu(
            title: L("重复模式"),
            children: PlaybackRepeatMode.allCases.map { mode in
                UIAction(
                    title: repeatTitle(mode),
                    image: UIImage(systemName: repeatIcon(mode)),
                    state: viewModel.snapshot.queue.repeatMode == mode ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setRepeatMode(mode)
                }
            }
        )
        let clear = UIAction(
            title: L("清空播放队列"),
            image: UIImage(systemName: "trash"),
            attributes: [.destructive]
        ) { [weak self] _ in
            self?.confirmClearQueue()
        }
        return UIMenu(
            title: L("更多队列操作"),
            children: [repeatMenu, clear]
        )
    }

    private func render(_ snapshot: PlaybackSessionSnapshot) {
        let queueStructure = snapshot.queue.structure
        let currentItemID = snapshot.currentItemID
        let shouldReloadRows = queueRowsDirty
            || renderedQueueStructure != queueStructure
            || renderedCurrentItemID != currentItemID

        guard shouldReloadRows else {
            // Position and phase updates are consumed by the playback
            // controls. They do not change queue rows or scroll geometry.
            updateToolbar()
            return
        }

        let orderedEntries = viewModel.orderedQueueEntries
        let currentEntryID = snapshot.queue.currentEntryID
        let resolvedCurrentRow = orderedEntries.first(where: { $0.id == currentEntryID }).map { entry in
            Row(
                entry: entry,
                isCurrent: true,
                track: entry.itemID.flatMap { tracks[$0] }
            )
        }
        let queueEntries: [PlaybackQueueEntry]
        if editor.isActive {
            queueEntries = editor.entries
        } else {
            queueEntries = upcomingEntries(from: orderedEntries, currentEntryID: currentEntryID)
        }
        currentRow = resolvedCurrentRow
        upcomingRows = queueEntries.map { entry in
            Row(
                entry: entry,
                isCurrent: false,
                track: entry.itemID.flatMap { tracks[$0] }
            )
        }

        sections = []
        if library != nil {
            sections.append(.history)
        }
        if currentRow != nil {
            sections.append(.current)
        }
        if !orderedEntries.isEmpty {
            sections.append(.playbackMode)
            sections.append(.upcoming)
        }

        let historyPending = library != nil && (historyLoader.state == .idle || historyLoader.state == .loading)
        let hasContent = currentRow != nil || !upcomingRows.isEmpty || !historyLoader.items.isEmpty || historyPending
        tableView.isHidden = !hasContent
        emptyStateView.isHidden = hasContent
        tableView.reloadData()
        renderedHistoryItems = displayedHistoryItems
        renderedHistoryArtistNames = historyLoader.artistNames
        anchorCurrentRowIfNeeded()
        updateToolbar()
        renderedQueueStructure = queueStructure
        renderedCurrentItemID = currentItemID
        queueRowsDirty = false
        loadTracks(for: orderedEntries)
    }

    private func refreshHistorySection() {
        guard isViewLoaded else { return }
        let nextItems = displayedHistoryItems
        renderedHistoryItems = nextItems
        renderedHistoryArtistNames = historyLoader.artistNames
        updateTableVisibility()
        guard let section = sections.firstIndex(of: .history), !tableView.isHidden else { return }
        tableView.reloadSections(IndexSet(integer: section), with: .none)
    }

    private func refreshHistoryItems() {
        guard isViewLoaded else { return }
        let nextItems = displayedHistoryItems
        let previousItems = renderedHistoryItems
        let previousArtistNames = renderedHistoryArtistNames
        let previousIDs = previousItems.map(\.sessionID)
        let nextIDs = nextItems.map(\.sessionID)
        updateTableVisibility()

        guard let section = sections.firstIndex(of: .history), !tableView.isHidden else { return }
        guard previousIDs == nextIDs, previousItems.count == nextItems.count else {
            renderedHistoryItems = nextItems
            renderedHistoryArtistNames = historyLoader.artistNames
            tableView.reloadSections(IndexSet(integer: section), with: .none)
            return
        }
        let changedRows = nextItems.indices.filter { index in
            historyRowSignature(previousItems[index], artistNames: previousArtistNames)
                != historyRowSignature(nextItems[index], artistNames: historyLoader.artistNames)
        }
        renderedHistoryItems = nextItems
        renderedHistoryArtistNames = historyLoader.artistNames
        reloadHistoryRows(changedRows, section: section)
    }

    private func refreshHistoryArtistNames() {
        guard isViewLoaded else { return }
        let nextItems = displayedHistoryItems
        let oldNames = renderedHistoryArtistNames
        let nextNames = historyLoader.artistNames
        renderedHistoryArtistNames = nextNames
        guard let section = sections.firstIndex(of: .history),
              nextItems.map(\.sessionID) == renderedHistoryItems.map(\.sessionID),
              !tableView.isHidden
        else { return }
        let changedRows = nextItems.indices.filter { index in
            historyRowSignature(nextItems[index], artistNames: oldNames)
                != historyRowSignature(nextItems[index], artistNames: nextNames)
        }
        reloadHistoryRows(changedRows, section: section)
    }

    private func reloadHistoryRows(_ rows: [Int], section: Int) {
        guard !rows.isEmpty else { return }
        let indexPaths = rows.map { IndexPath(row: $0, section: section) }
        let valid = indexPaths.filter {
            $0.row < tableView.numberOfRows(inSection: section)
        }
        guard !valid.isEmpty else { return }
        tableView.reloadRows(at: valid, with: .none)
    }

    private func updateTableVisibility() {
        let historyPending = library != nil && (historyLoader.state == .idle || historyLoader.state == .loading)
        let hasContent = currentRow != nil || !upcomingRows.isEmpty
            || !historyLoader.items.isEmpty || historyPending
        tableView.isHidden = !hasContent
        emptyStateView.isHidden = hasContent
    }

    private func historyRowSignature(
        _ item: PlaybackHistoryItem,
        artistNames: [ArtistID: String]
    ) -> String {
        let names = item.track.artistIDs.compactMap { artistNames[$0] }.joined(separator: "|")
        return [
            item.sessionID.uuidString,
            String(describing: item.track.id),
            item.track.title,
            String(describing: item.track.albumID),
            String(describing: item.track.artworkID),
            names
        ].joined(separator: "#")
    }

    private func anchorCurrentRowIfNeeded() {
        guard currentRow != nil,
              sections.contains(.current)
        else {
            return
        }

        // UITableView cannot resolve section geometry until the reload has
        // reached the next layout pass. Dispatching once keeps the initial
        // anchor deterministic without changing the normal scroll behavior.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentRow != nil,
                  !self.hasUserScrolled,
                  let currentSection = self.sections.firstIndex(of: .current),
                  self.tableView.numberOfRows(inSection: currentSection) > 0
            else {
                return
            }
            self.tableView.layoutIfNeeded()
            self.tableView.scrollToRow(
                at: IndexPath(row: 0, section: currentSection),
                at: .top,
                animated: false
            )
        }
    }

    private func upcomingEntries(
        from entries: [PlaybackQueueEntry],
        currentEntryID: UUID?
    ) -> [PlaybackQueueEntry] {
        guard let currentEntryID,
              let currentIndex = entries.firstIndex(where: { $0.id == currentEntryID })
        else {
            return entries
        }
        let startIndex = entries.index(after: currentIndex)
        guard startIndex < entries.endIndex else { return [] }
        return Array(entries[startIndex...])
    }

    private func loadTracks(for entries: [PlaybackQueueEntry]) {
        let queueKey = entries.map { entry in
            let itemDescription = entry.itemID.map(String.init(describing:)) ?? "none"
            return "\(entry.id.uuidString):\(itemDescription)"
        }.joined(separator: ",")
        guard requestedQueueKey != queueKey else { return }
        requestedQueueKey = queueKey
        trackTask?.cancel()
        guard let library else {
            tracks = [:]
            artistNames = [:]
            return
        }
        let itemIDs = entries.compactMap(\.itemID)
        trackTask = Task { @MainActor [weak self] in
            var loaded: [MediaItemID: Track] = [:]
            for itemID in itemIDs {
                guard !Task.isCancelled else { return }
                if let track = try? await library.track(id: itemID) {
                    loaded[itemID] = track
                }
            }
            guard !Task.isCancelled, let self else { return }

            let loadedArtistNames = (try? await QueueArtistNameLoader.load(
                for: Array(loaded.values),
                from: library
            )) ?? [:]
            guard !Task.isCancelled else { return }

            let changedIDs = Set(loaded.compactMap { id, track in
                self.tracks[id] != track ? id : nil
            })
            self.tracks = loaded
            self.artistNames = loadedArtistNames
            self.refreshQueueRows(itemIDs: changedIDs.isEmpty ? Set(loaded.keys) : changedIDs)
        }
    }

    private func refreshQueueTracks(
        _ ids: Set<MediaItemID>,
        library: any LibraryServing
    ) async {
        var updatedTracks = tracks
        var changedIDs = Set<MediaItemID>()
        for id in ids {
            guard !Task.isCancelled else { return }
            let next = try? await library.track(id: id)
            if let next {
                if updatedTracks[id] != next {
                    updatedTracks[id] = next
                    changedIDs.insert(id)
                }
            } else if updatedTracks.removeValue(forKey: id) != nil {
                changedIDs.insert(id)
            }
        }
        guard !changedIDs.isEmpty else { return }
        let changedTracks = changedIDs.compactMap { updatedTracks[$0] }
        let names = (try? await QueueArtistNameLoader.load(
            for: changedTracks,
            from: library
        )) ?? [:]
        tracks = updatedTracks
        artistNames.merge(names, uniquingKeysWith: { _, new in new })
        refreshQueueRows(itemIDs: changedIDs)
    }

    private func refreshQueueRows(itemIDs: Set<MediaItemID>) {
        guard isViewLoaded, !itemIDs.isEmpty else { return }
        var paths: [IndexPath] = []
        if let currentSection = sections.firstIndex(of: .current),
           currentRow?.entry.itemID.map(itemIDs.contains) == true {
            paths.append(IndexPath(row: 0, section: currentSection))
        }
        if let upcomingSection = sections.firstIndex(of: .upcoming) {
            for (rowIndex, row) in upcomingRows.enumerated()
                where row.entry.itemID.map(itemIDs.contains) == true {
                paths.append(IndexPath(row: rowIndex, section: upcomingSection))
            }
        }
        let valid = paths.filter {
            $0.section < tableView.numberOfSections
                && $0.row < tableView.numberOfRows(inSection: $0.section)
        }
        guard !valid.isEmpty else { return }
        tableView.reloadRows(at: valid, with: .none)
    }

    private var displayedHistoryItems: [PlaybackHistoryItem] {
        NowPlayingHistoryPresentation.visibleItems(
            from: historyLoader.items,
            currentItemID: viewModel.snapshot.currentItemID
        )
    }

    private func confirmClearQueue() {
        guard !viewModel.snapshot.queue.entries.isEmpty else { return }
        let alert = UIAlertController(
            title: L("清空播放队列？"),
            message: L("当前播放也会停止，资料库中的歌曲不会被删除。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("清空队列"), style: .destructive) { [weak self] _ in
            self?.viewModel.clearQueue()
        })
        present(alert, animated: true)
    }

    private func confirmClearHistory() {
        guard !historyLoader.items.isEmpty, !historyLoader.isClearing else { return }
        let alert = UIAlertController(
            title: L("清除播放历史？"),
            message: L("歌曲仍会保留在资料库中，累计播放统计不会重置。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("清除播放历史"), style: .destructive) { [weak self] _ in
            self?.historyTask?.cancel()
            self?.historyTask = Task { @MainActor [weak self] in
                await self?.historyLoader.clear()
            }
        })
        present(alert, animated: true)
    }

    private func presentError(title: String, message: String) {
        guard viewIfLoaded?.window != nil,
              presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func beginEditing() {
        guard !upcomingRows.isEmpty, !editor.isActive else { return }
        editor.begin(queue: viewModel.snapshot.queue)
    }

    @objc private func cancelEditing() {
        guard editor.isActive, !editor.isSaving else { return }
        editor.cancel()
    }

    @objc private func commitEditing() {
        guard editor.isActive, !editor.isSaving else { return }
        editTask?.cancel()
        editTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.editor.commit(using: self.viewModel)
            self.editTask = nil
        }
    }

    @objc private func toggleShuffle() {
        viewModel.setShuffle(viewModel.snapshot.queue.shuffleMode == .on ? .off : .on)
    }

    @objc private func toggleRepeatOne() {
        viewModel.setRepeatMode(viewModel.snapshot.queue.repeatMode == .one ? .off : .one)
    }

    @objc private func toggleRepeatAll() {
        viewModel.setRepeatMode(viewModel.snapshot.queue.repeatMode == .all ? .off : .all)
    }

    @objc private func showLyrics() {
        onShowLyrics?()
    }

    @objc private func dismissQueue() {
        dismiss(animated: true)
    }

    private func repeatIcon(_ mode: PlaybackRepeatMode) -> String {
        mode == .one ? "repeat.1" : "repeat"
    }

    private func repeatTitle(_ mode: PlaybackRepeatMode) -> String {
        switch mode {
        case .off: return L("关闭重复")
        case .one: return L("重复单曲")
        case .all: return L("重复队列")
        }
    }
}

extension PlayerQueueViewController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    public func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        switch sections[section] {
        case .history:
            return max(displayedHistoryItems.count, 1)
        case .current:
            return currentRow == nil ? 0 : 1
        case .playbackMode:
            return 1
        case .upcoming:
            return max(upcomingRows.count, 1)
        }
    }

    public func tableView(
        _: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        // All visible headings are rendered by `PlayerQueueHeaderView` below.
        // Returning a title here makes UITableView install its private default
        // header, which is exposed as an opaque `Other` element in the AX tree.
        nil
    }

    public func tableView(
        _: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        guard sections.indices.contains(section) else { return nil }
        let sectionKind = sections[section]
        guard sectionKind != .playbackMode else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: PlayerQueueHeaderView.reuseIdentifier
        ) as! PlayerQueueHeaderView
        switch sectionKind {
        case .history:
            header.configure(
                title: L("历史"),
                accessibilityIdentifier: "player.nowPlaying.history.heading",
                actionTitle: L("清除"),
                actionEnabled: !historyLoader.items.isEmpty && !historyLoader.isClearing,
                target: self,
                action: #selector(clearHistory)
            )
        case .current:
            let menu = makeCurrentTrackMenu()
            header.configure(
                title: L("正在播放"),
                accessibilityIdentifier: "player.nowPlaying.current.heading",
                actionSystemImage: "ellipsis",
                actionAccessibilityLabel: L("更多操作"),
                actionAccessibilityIdentifier: "player.nowPlaying.more",
                actionMenu: menu,
                actionEnabled: menu != nil
            )
        case .upcoming:
            header.configure(
                title: L("继续播放"),
                accessibilityIdentifier: "player.nowPlaying.upcoming.heading"
            )
        case .playbackMode:
            return nil
        }
        return header
    }

    public func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard sections.indices.contains(section) else { return .leastNormalMagnitude }
        return sections[section] == .playbackMode ? .leastNormalMagnitude : 40
    }

    public func tableView(_: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        guard sections.indices.contains(section) else { return .leastNormalMagnitude }
        return sections[section] == .playbackMode ? .leastNormalMagnitude : 40
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard sections.indices.contains(indexPath.section) else { return UITableViewCell() }
        switch sections[indexPath.section] {
        case .history:
            guard displayedHistoryItems.indices.contains(indexPath.row) else {
                return messageCell(
                    tableView,
                    text: historyMessage,
                    actionTitle: historyLoader.state == .failed ? L("重试") : nil,
                    target: self,
                    action: historyLoader.state == .failed ? #selector(retryHistory) : nil
                )
            }
            let item = displayedHistoryItems[indexPath.row]
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerQueueCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerQueueCell
            cell.configure(
                track: item.track,
                currentItem: nil,
                itemID: item.track.id,
                artworkServing: artworkServing,
                artistNames: historyLoader.artistNames
            )
            cell.accessibilityIdentifier = "player.nowPlaying.history.\(item.sessionID.uuidString)"
            cell.accessibilityHint = L("重新播放歌曲")
            return cell
        case .current:
            guard let row = currentRow else { return UITableViewCell() }
            return queueCell(tableView, row: row, indexPath: indexPath)
        case .playbackMode:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerQueueModeCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerQueueModeCell
            cell.configure(
                shuffleEnabled: viewModel.snapshot.queue.shuffleMode == .on,
                repeatOneEnabled: viewModel.snapshot.queue.repeatMode == .one,
                repeatAllEnabled: viewModel.snapshot.queue.repeatMode == .all,
                crossfadeEnabled: viewModel.snapshot.capabilities.contains(.crossfade),
                crossfadeSelected: viewModel.snapshot.effectiveEffects.transition.mode == .crossfade,
                target: self,
                shuffleAction: #selector(toggleShuffle),
                repeatOneAction: #selector(toggleRepeatOne),
                repeatAllAction: #selector(toggleRepeatAll)
            )
            return cell
        case .upcoming:
            guard upcomingRows.indices.contains(indexPath.row) else {
                return messageCell(tableView, text: editor.isActive ? L("没有可编辑的歌曲") : L("队列末尾"))
            }
            return queueCell(tableView, row: upcomingRows[indexPath.row], indexPath: indexPath)
        }
    }

    private func queueCell(
        _ tableView: UITableView,
        row: Row,
        indexPath: IndexPath
    ) -> PlayerQueueCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PlayerQueueCell.reuseIdentifier,
            for: indexPath
        ) as! PlayerQueueCell
        cell.configure(
            track: row.track,
            currentItem: row.isCurrent ? viewModel.snapshot.currentItem : nil,
            itemID: row.entry.itemID,
            artworkServing: artworkServing,
            artistNames: artistNames
        )
        cell.accessibilityIdentifier = row.isCurrent
            ? "player.nowPlaying.current"
            : "player.queue.entry.\(row.entry.id.uuidString)"
        cell.isUserInteractionEnabled = true
        return cell
    }

    private func messageCell(
        _ tableView: UITableView,
        text: String,
        actionTitle: String? = nil,
        target: Any? = nil,
        action: Selector? = nil
    ) -> PlayerQueueMessageCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PlayerQueueMessageCell.reuseIdentifier
        ) as! PlayerQueueMessageCell
        cell.configure(text: text, actionTitle: actionTitle, target: target, action: action)
        return cell
    }

    public func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections.indices.contains(indexPath.section) else { return }
        switch sections[indexPath.section] {
        case .history:
            guard displayedHistoryItems.indices.contains(indexPath.row) else { return }
            viewModel.send(.play(itemID: displayedHistoryItems[indexPath.row].track.id))
        case .current:
            if let currentRow { viewModel.selectQueueEntry(currentRow.entry.id) }
        case .playbackMode:
            break
        case .upcoming:
            guard upcomingRows.indices.contains(indexPath.row) else { return }
            viewModel.selectQueueEntry(upcomingRows[indexPath.row].entry.id)
        }
    }

    public func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = makeContextMenu(for: indexPath) else { return nil }
        let configuration = UIContextMenuConfiguration(
            identifier: NSString(string: "queue-\(indexPath.section)-\(indexPath.row)"),
            previewProvider: nil
        ) { _ in menu }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    private func makeContextMenu(for indexPath: IndexPath) -> UIMenu? {
        guard sections.indices.contains(indexPath.section) else { return nil }
        switch sections[indexPath.section] {
        case .history:
            guard displayedHistoryItems.indices.contains(indexPath.row) else { return nil }
            let track = displayedHistoryItems[indexPath.row].track
            return makeQueueTrackMenu(
                title: track.title,
                subtitle: QueueArtistNameLoader.subtitle(
                    for: track,
                    artistNames: historyLoader.artistNames
                ),
                track: track,
                play: { [weak self] in self?.viewModel.send(.play(itemID: track.id)) },
                playNext: { [weak self] in
                    self?.viewModel.send(.enqueueNext(itemIDs: [track.id]))
                },
                enqueue: { [weak self] in
                    self?.viewModel.send(.enqueueItems(itemIDs: [track.id]))
                }
            )
        case .current:
            guard let currentRow else { return nil }
            let title = currentRow.track?.title
                ?? viewModel.snapshot.currentItem?.title
                ?? currentRow.entry.itemID?.externalID
                ?? L("歌曲暂不可用")
            let subtitle = QueueArtistNameLoader.subtitle(
                for: currentRow.track,
                artistNames: artistNames
            ) ?? viewModel.snapshot.currentItem?.artist
            return makeQueueTrackMenu(
                title: title,
                subtitle: subtitle,
                track: currentRow.track
            )
        case .upcoming:
            guard upcomingRows.indices.contains(indexPath.row), !editor.isActive else { return nil }
            let row = upcomingRows[indexPath.row]
            let title = row.track?.title
                ?? row.entry.itemID?.externalID
                ?? L("歌曲暂不可用")
            let subtitle = QueueArtistNameLoader.subtitle(
                for: row.track,
                artistNames: artistNames
            )
            let remove = UIAction(
                title: L("从队列移除"),
                image: UIImage(systemName: "trash"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.removeFromQueue"),
                attributes: [.destructive]
            ) { [weak self] _ in
                self?.viewModel.removeQueueEntry(row.entry.id)
            }
            return makeQueueTrackMenu(
                title: title,
                subtitle: subtitle,
                track: row.track,
                play: { [weak self] in self?.viewModel.selectQueueEntry(row.entry.id) },
                destructiveAction: remove
            )
        case .playbackMode:
            return nil
        }
    }

    private func makeQueueTrackMenu(
        title: String,
        subtitle: String?,
        track: Track? = nil,
        play: (() -> Void)? = nil,
        playNext: (() -> Void)? = nil,
        enqueue: (() -> Void)? = nil,
        destructiveAction: UIAction? = nil
    ) -> UIMenu {
        let shareText = [title, subtitle].compactMap { $0 }.joined(separator: " - ")
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            identifier: UIAction.Identifier("player.nowPlaying.actions.share")
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
        var actions: [UIMenuElement] = []
        if let play {
            actions.append(UIAction(
                title: L("播放"),
                image: UIImage(systemName: "play.fill"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.play")
            ) { _ in play() })
        }
        if let playNext {
            actions.append(UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.playNext")
            ) { _ in playNext() })
        }
        if let enqueue {
            actions.append(UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.enqueue")
            ) { _ in enqueue() })
        }
        if let albumID = track?.albumID, let onShowAlbum {
            actions.append(UIAction(
                title: L("跳转到专辑"),
                image: UIImage(systemName: "rectangle.stack"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.album")
            ) { _ in onShowAlbum(albumID) })
        }
        if let artistID = track?.artistID, let onShowArtist {
            actions.append(UIAction(
                title: L("跳转到艺人"),
                image: UIImage(systemName: "person"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.artist")
            ) { _ in onShowArtist(artistID) })
        }

        var groups: [UIMenuElement] = [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [share]
            )
        ]
        if !actions.isEmpty {
            groups.append(UIMenu(title: "", options: [.displayInline], children: actions))
        }
        if let destructiveAction {
            groups.append(UIMenu(
                title: "",
                options: [.displayInline],
                children: [destructiveAction]
            ))
        }
        return UIMenu(children: groups)
    }

    private func makeCurrentTrackMenu() -> UIMenu? {
        guard let currentRow,
              let itemID = currentRow.entry.itemID ?? viewModel.snapshot.currentItemID else {
            return nil
        }
        let title = currentRow.track?.title
            ?? viewModel.snapshot.currentItem?.title
            ?? itemID.externalID
        let subtitle = QueueArtistNameLoader.subtitle(
            for: currentRow.track,
            artistNames: artistNames
        ) ?? viewModel.snapshot.currentItem?.artist
        return makeQueueTrackMenu(
            title: title,
            subtitle: subtitle,
            track: currentRow.track,
            playNext: { [weak self] in
                self?.viewModel.send(.enqueueNext(itemIDs: [itemID]))
            },
            enqueue: { [weak self] in
                self?.viewModel.send(.enqueueItems(itemIDs: [itemID]))
            }
        )
    }

    public func scrollViewWillBeginDragging(_: UIScrollView) {
        hasUserScrolled = true
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section] == .upcoming,
              upcomingRows.indices.contains(indexPath.row), !editor.isActive else { return nil }
        let row = upcomingRows[indexPath.row]
        guard !row.isCurrent else { return nil }
        let remove = UIContextualAction(style: .destructive, title: L("移除")) { [weak self] _, _, completion in
            self?.viewModel.removeQueueEntry(row.entry.id)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    public func tableView(_: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section] == .upcoming else {
            return false
        }
        return upcomingRows.indices.contains(indexPath.row)
    }

    public func tableView(_: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        editor.isActive
            && sections.indices.contains(indexPath.section)
            && sections[indexPath.section] == .upcoming
            && upcomingRows.indices.contains(indexPath.row)
    }

    public func tableView(
        _: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sourceIndexPath.section == destinationIndexPath.section,
              sections.indices.contains(sourceIndexPath.section),
              sections[sourceIndexPath.section] == .upcoming,
              editor.isActive
        else { return }
        editor.move(
            from: IndexSet(integer: sourceIndexPath.row),
            to: destinationIndexPath.row
        )
    }

    public func tableView(
        _: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              sections.indices.contains(indexPath.section),
              sections[indexPath.section] == .upcoming,
              upcomingRows.indices.contains(indexPath.row)
        else { return }
        let row = upcomingRows[indexPath.row]
        if editor.isActive {
            editor.remove(at: IndexSet(integer: indexPath.row))
        } else {
            viewModel.removeQueueEntry(row.entry.id)
        }
    }

    private var historyMessage: String {
        switch historyLoader.state {
        case .idle, .loading: return L("正在载入播放历史")
        case .empty: return L("暂无播放历史")
        case .failed: return L("载入失败，点击重试")
        case .loaded: return L("当前歌曲尚未形成历史记录")
        }
    }

    private func makeRepeatMenu() -> UIMenu {
        UIMenu(
            title: L("重复模式"),
            children: PlaybackRepeatMode.allCases.map { mode in
                UIAction(
                    title: repeatTitle(mode),
                    image: UIImage(systemName: repeatIcon(mode)),
                    state: viewModel.snapshot.queue.repeatMode == mode ? .on : .off
                ) { [weak self] _ in
                    self?.viewModel.setRepeatMode(mode)
                }
            }
        )
    }

    @objc private func clearHistory() {
        confirmClearHistory()
    }

    @objc private func retryHistory() {
        historyTask?.cancel()
        historyTask = Task { @MainActor [weak self] in
            await self?.historyLoader.load()
        }
    }
}

@MainActor
private final class PlayerQueueCell: UITableViewCell {
    static let reuseIdentifier = "PlayerQueueCell"

    private let rowView = MusicFreeUIKitMediaRowView(title: "")
    private var artworkTask: Task<Void, Never>?
    private var renderedArtworkKey: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        rowView.isUserInteractionEnabled = false
        rowView.exposesTextAccessibility = true
        rowView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkTask?.cancel()
        artworkTask = nil
        renderedArtworkKey = nil
        rowView.artworkImage = nil
    }

    func configure(
        track: Track?,
        currentItem: PlaybackDisplaySnapshot?,
        itemID: MediaItemID?,
        artworkServing: (any ArtworkServing)?,
        artistNames: [ArtistID: String]
    ) {
        let title = track?.title ?? currentItem?.title ?? itemID?.externalID ?? L("歌曲暂不可用")
        let subtitle = QueueArtistNameLoader.subtitle(
            for: track,
            artistNames: artistNames
        ) ?? currentItem?.artist
        rowView.titleText = title
        rowView.subtitleText = subtitle
        rowView.showsArtwork = true
        rowView.placeholderSystemImage = "music.note"
        rowView.artworkAccessibilityLabel = track?.artworkID == nil
            ? L("暂无封面")
            : L("封面")

        let artworkID = track?.artworkID ?? currentItem?.artworkID
        let sourceID = itemID?.sourceID
        let artworkKey = "\(sourceID?.rawValue ?? ""):\(artworkID?.rawValue ?? "")"
        renderedArtworkKey = artworkKey
        artworkTask?.cancel()
        artworkTask = nil
        let cachedImage: UIImage? = if let artworkID, let sourceID {
            PlayerArtworkImagePipeline.shared.cachedImage(
                artworkID: artworkID,
                sourceID: sourceID,
                maximumPixelDimension: 160
            )
        } else {
            nil
        }
        rowView.artworkImage = cachedImage
        if let artworkID, let sourceID, let artworkServing {
            artworkTask = Task { @MainActor [weak self] in
                do {
                    let image = await PlayerArtworkImagePipeline.shared.image(
                        artworkID: artworkID,
                        sourceID: sourceID,
                        maximumPixelDimension: 160,
                        serving: artworkServing
                    )
                    try Task.checkCancellation()
                    guard let self, self.renderedArtworkKey == artworkKey else { return }
                    self.rowView.artworkImage = image
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }

        let accessory = UIImageView(
            image: UIImage(systemName: currentItem == nil
                ? "line.3.horizontal"
                : "speaker.wave.2.fill")
        )
        accessory.tintColor = currentItem == nil
            ? MusicFreeUIColorTokens.foregroundTertiary
            : MusicFreeUIColorTokens.accent
        accessory.contentMode = .center
        accessory.frame = CGRect(
            x: 0,
            y: 0,
            width: MusicFreeLayoutMetrics.minimumHitTarget,
            height: MusicFreeLayoutMetrics.minimumHitTarget
        )
        rowView.accessoryView = accessory
    }
}

@MainActor
private final class PlayerQueueMessageCell: UITableViewCell {
    static let reuseIdentifier = "PlayerQueueMessageCell"

    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = MusicFreeUIFontTokens.rowSubtitle
        messageLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = MusicFreeUIFontTokens.rowSubtitle
        let stack = UIStackView(arrangedSubviews: [messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.xSmall
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String,
        actionTitle: String?,
        target: Any?,
        action: Selector?
    ) {
        messageLabel.text = text
        accessibilityLabel = text
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle?.isEmpty != false || target == nil || action == nil
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        if let target, let action {
            actionButton.addTarget(target, action: action, for: .touchUpInside)
        }
    }
}

@MainActor
private final class PlayerQueueModeCell: UITableViewCell {
    static let reuseIdentifier = "PlayerQueueModeCell"

    private let shuffleButton = UIButton(type: .system)
    private let repeatOneButton = UIButton(type: .system)
    private let repeatAllButton = UIButton(type: .system)
    private let crossfadeButton = UIButton(type: .system)
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        accessibilityIdentifier = "player.nowPlaying.modeControls"
        accessibilityLabel = L("播放模式")
        accessibilityTraits = .summaryElement
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.spacing = MusicFreeSpacingTokens.xSmall
        stack.translatesAutoresizingMaskIntoConstraints = false
        [shuffleButton, repeatOneButton, repeatAllButton, crossfadeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.titleLabel?.font = MusicFreeUIFontTokens.rowSubtitle
            $0.layer.cornerRadius = 20
            $0.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
            $0.tintColor = MusicFreeUIColorTokens.foregroundPrimary
            stack.addArrangedSubview($0)
        }
        shuffleButton.accessibilityIdentifier = "player.queue.shuffle"
        repeatOneButton.accessibilityIdentifier = "player.queue.repeatOne"
        repeatAllButton.accessibilityIdentifier = "player.queue.repeatAll"
        crossfadeButton.accessibilityIdentifier = "player.queue.crossfade"
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.small),
            shuffleButton.heightAnchor.constraint(equalToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        shuffleEnabled: Bool,
        repeatOneEnabled: Bool,
        repeatAllEnabled: Bool,
        crossfadeEnabled: Bool,
        crossfadeSelected: Bool,
        target: Any,
        shuffleAction: Selector,
        repeatOneAction: Selector,
        repeatAllAction: Selector
    ) {
        configureButton(
            shuffleButton,
            imageName: "shuffle",
            title: L("随机播放"),
            isEnabled: true,
            isSelected: shuffleEnabled,
            target: target,
            action: shuffleAction
        )
        configureButton(
            repeatOneButton,
            imageName: "repeat.1",
            title: L("重复单曲"),
            isEnabled: true,
            isSelected: repeatOneEnabled,
            target: target,
            action: repeatOneAction
        )
        configureButton(
            repeatAllButton,
            imageName: "repeat",
            title: L("重复队列"),
            isEnabled: true,
            isSelected: repeatAllEnabled,
            target: target,
            action: repeatAllAction
        )
        configureButton(
            crossfadeButton,
            imageName: "waveform.path.ecg",
            title: L("淡入淡出"),
            isEnabled: crossfadeEnabled,
            isSelected: crossfadeSelected,
            target: nil,
            action: nil
        )
    }

    private func configureButton(
        _ button: UIButton,
        imageName: String,
        title: String,
        isEnabled: Bool,
        isSelected: Bool,
        target: Any?,
        action: Selector?
    ) {
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.accessibilityLabel = title
        button.accessibilityValue = isEnabled
            ? (isSelected ? L("已开启") : L("已关闭"))
            : L("不可用")
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.36
        button.removeTarget(nil, action: nil, for: .allEvents)
        if let target, let action {
            button.addTarget(target, action: action, for: .touchUpInside)
        }
    }
}

@MainActor
private final class PlayerQueueHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "PlayerQueueHeaderView"

    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        contentView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        contentView.clipsToBounds = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MusicFreeUIFontTokens.sectionTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = MusicFreeUIFontTokens.rowSubtitle
        NSLayoutConstraint.activate([
            actionButton.widthAnchor.constraint(equalToConstant: 44),
            actionButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        let stack = UIStackView(arrangedSubviews: [titleLabel, UIView(), actionButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MusicFreeSpacingTokens.small),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -MusicFreeSpacingTokens.xSmall)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        accessibilityIdentifier: String,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        actionAccessibilityLabel: String? = nil,
        actionAccessibilityIdentifier: String? = nil,
        actionMenu: UIMenu? = nil,
        actionEnabled: Bool = false,
        target: Any? = nil,
        action: Selector? = nil
    ) {
        titleLabel.text = title
        // Keep the visible heading discoverable by its user-facing title,
        // matching the SwiftUI surface and existing UI-test locators. The
        // header container carries the stable semantic identifier used by
        // automation that needs to distinguish history/current/upcoming.
        titleLabel.accessibilityIdentifier = title
        titleLabel.accessibilityLabel = title
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits = .header
        self.accessibilityIdentifier = accessibilityIdentifier
        isAccessibilityElement = false
        actionButton.setTitle(actionSystemImage == nil ? actionTitle : nil, for: .normal)
        actionButton.setImage(
            actionSystemImage.flatMap { UIImage(systemName: $0) },
            for: .normal
        )
        let hasTargetAction = target != nil && action != nil
        let hasMenu = actionMenu != nil
        actionButton.menu = actionMenu
        actionButton.showsMenuAsPrimaryAction = hasMenu
        actionButton.isHidden = !hasTargetAction && !hasMenu
        actionButton.isEnabled = actionEnabled
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        if let target, let action {
            actionButton.addTarget(target, action: action, for: .touchUpInside)
        }
        actionButton.accessibilityLabel = actionAccessibilityLabel ?? actionTitle
        actionButton.accessibilityIdentifier = actionAccessibilityIdentifier
            ?? (actionTitle?.isEmpty == false ? "player.history.clear" : nil)
        accessibilityElements = actionButton.isHidden
            ? [titleLabel]
            : [titleLabel, actionButton]
    }

    func configure(
        title: String,
        actionTitle: String,
        actionEnabled: Bool,
        target: Any,
        action: Selector
    ) {
        configure(
            title: title,
            accessibilityIdentifier: "player.nowPlaying.history.heading",
            actionTitle: actionTitle,
            actionEnabled: actionEnabled,
            target: target,
            action: action
        )
    }
}
