import AppServices
import DesignSystem
import MediaSourceAPI
import MusicDomain
import UIKit

@MainActor
final class OnlineSourceDownloadQueueViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Mode { case overview, completed, detail(SourceObjectID) }
    private enum Row: Hashable { case task(SourceObjectID), file(SourceObjectID), directory(SourceObjectID), completed, more }
    private struct Section { let title: String; let rows: [Row] }
    private enum Filter: CaseIterable { case all, active, failed, completed }
    private let model: OnlineSourcesSceneModel
    private let mode: Mode
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var sections: [Section] = []
    private var snapshot = OnlineDownloadQueueSnapshot()
    private var tasksByID: [SourceObjectID: OnlineDownloadTaskSummary] = [:]
    private var filesByID: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:]
    private var observationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var filter = Filter.all
    private var visibleLimit = 100
    private let resumeButton = UIButton(type: .system)
    private let resumeArea = UIView()
    private var resumeHeight: NSLayoutConstraint!
    private let emptyLabel = UILabel()

    convenience init(model: OnlineSourcesSceneModel) { self.init(model: model, mode: .overview) }
    private init(model: OnlineSourcesSceneModel, mode: Mode) {
        self.model = model
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "onlineSources.downloadQueue.view"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonTitle = L("下载任务")
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(DownloadQueueCell.self, forCellReuseIdentifier: "DownloadQueueCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 44
        tableView.sectionFooterHeight = 16
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 16)
        tableView.accessibilityIdentifier = "onlineSources.downloadQueue.list"
        for v in [tableView, resumeArea] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.configuration = .filled()
        resumeButton.configuration?.title = L("恢复任务")
        resumeButton.configuration?.image = UIImage(systemName: "arrow.counterclockwise")
        resumeButton.configuration?.imagePadding = 8
        resumeButton.configuration?.baseBackgroundColor = MusicFreeUIColorTokens.accent
        resumeButton.configuration?.baseForegroundColor = MusicFreeUIColorTokens.onAccent
        resumeButton.accessibilityIdentifier = "onlineSources.downloadQueue.resume"
        resumeButton.addAction(UIAction { [weak self] _ in self?.resumeCurrentTask() }, for: .touchUpInside)
        resumeArea.addSubview(resumeButton)
        resumeHeight = resumeArea.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor), tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: resumeArea.topAnchor),
            resumeArea.leadingAnchor.constraint(equalTo: view.leadingAnchor), resumeArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resumeArea.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), resumeHeight,
            resumeButton.leadingAnchor.constraint(equalTo: resumeArea.leadingAnchor, constant: 16),
            resumeButton.trailingAnchor.constraint(equalTo: resumeArea.trailingAnchor, constant: -16),
            resumeButton.centerYAnchor.constraint(equalTo: resumeArea.centerYAnchor), resumeButton.heightAnchor.constraint(equalToConstant: 48)
        ])
        emptyLabel.font = MusicFreeUIFontTokens.sectionTitle
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        emptyLabel.accessibilityIdentifier = "onlineSources.downloadQueue.empty"
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observe()
        render()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observationTask?.cancel(); observationTask = nil
        progressTask?.cancel(); progressTask = nil
        sourceTask?.cancel(); sourceTask = nil
        renderTask?.cancel(); renderTask = nil
    }
    deinit { observationTask?.cancel(); progressTask?.cancel(); sourceTask?.cancel(); renderTask?.cancel() }

    private func observe() {
        guard observationTask == nil else { return }
        let stream = model.downloadQueue.makeSnapshotStream()
        observationTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.render(debounced: true)
            }
        }
        let progress = model.downloadQueue.makeProgressStream()
        progressTask = Task { @MainActor [weak self] in
            for await itemID in progress {
                guard !Task.isCancelled else { return }
                self?.refreshProgress(itemID)
            }
        }
        let serving = model.serving
        sourceTask = Task { @MainActor [weak self] in
            let stream = await serving.makeSnapshotStream()
            for await _ in stream { guard !Task.isCancelled else { return }; self?.render(debounced: true) }
        }
    }

    private func render(debounced: Bool = false) {
        guard isViewLoaded else { return }
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let nextSnapshot = self.model.downloadQueue.snapshot
            let detailID: SourceObjectID?
            if case .detail(let id) = self.mode { detailID = id } else { detailID = nil }
            let computation = Task.detached(priority: .utility) {
                let tasks = nextSnapshot.tasks
                let files = detailID.map { nextSnapshot.files(for: $0) } ?? []
                return (tasks, files)
            }
            let (tasks, files) = await withTaskCancellationHandler {
                await computation.value
            } onCancel: { computation.cancel() }
            guard !Task.isCancelled else { return }
            self.applyRender(nextSnapshot, tasks: tasks, detailFiles: files)
        }
    }

    private func applyRender(_ nextSnapshot: OnlineDownloadQueueSnapshot, tasks: [OnlineDownloadTaskSummary], detailFiles: [OnlineSourceDownloadSnapshot]) {
        snapshot = nextSnapshot
        filesByID = snapshot.downloads
        tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let completed = tasks.filter { $0.phase == .completed }
        var next: [Section] = []
        var pageTitle = L("下载任务")
        var subtitle = L("%d 个任务进行中 · %d 个文件正在下载", tasks.filter { $0.phase.isActive }.count, snapshot.downloads.values.filter { $0.phase == .downloading }.count)
        var detailTask: OnlineDownloadTaskSummary?
        switch mode {
        case .overview:
            let active = tasks.filter { $0.phase.isActive }.map { Row.task($0.id) }
            if !active.isEmpty { next.append(Section(title: L("任务 · %d", active.count), rows: active)) }
            let files = snapshot.downloads.values.filter(\.isActive).sorted { $0.itemID < $1.itemID }
            if !files.isEmpty { next.append(Section(title: L("文件下载 · %d", files.count), rows: files.prefix(100).map { .file($0.itemID) })) }
            let recoverable = tasks.filter { !$0.phase.isActive && $0.phase != .completed }.map { Row.task($0.id) }
            if !recoverable.isEmpty { next.append(Section(title: L("待恢复 · %d", recoverable.count), rows: recoverable)) }
            if !completed.isEmpty { next.append(Section(title: L("已完成 · %d", completed.count), rows: completed.prefix(1).map { .task($0.id) } + [.completed])) }
        case .completed:
            pageTitle = L("已完成")
            subtitle = L("%d 个已完成任务", completed.count)
            let groups = Dictionary(grouping: completed) { task in task.createdAt.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast }
            for date in groups.keys.sorted(by: >) {
                let title = date == .distantPast ? L("较早") : Calendar.current.isDateInToday(date) ? L("今天") : Calendar.current.isDateInYesterday(date) ? L("昨天") : date.formatted(date: .abbreviated, time: .omitted)
                next.append(Section(title: title, rows: groups[date]!.map { .task($0.id) }))
            }
        case .detail(let id):
            detailTask = tasksByID[id]
            pageTitle = detailTask?.displayName ?? L("下载任务")
            subtitle = sourceName(id.sourceID)
            if let task = detailTask {
                let directories = snapshot.imports[id]?.directories ?? []
                if task.phase == .discovering, !directories.isEmpty { next.append(Section(title: L("目录展开 · %d/%d", directories.filter(\.isExpanded).count, directories.count), rows: directories.prefix(100).map { .directory($0.itemID) })) }
                let allFiles = detailFiles
                filesByID = Dictionary(allFiles.map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
                let filtered = allFiles.filter { file in
                    switch filter {
                    case .all: true
                    case .active: file.isActive || file.phase == .waiting
                    case .failed: file.phase == .failed || file.phase == .cancelled
                    case .completed: file.isSuccessful
                    }
                }
                let audio = filtered.filter { $0.isSupportingFile != true }
                let supporting = filtered.filter { $0.isSupportingFile == true }
                next.append(Section(title: L("文件下载 · %d", audio.count), rows: audio.prefix(visibleLimit).map { .file($0.itemID) } + (audio.count > visibleLimit ? [.more] : [])))
                if !supporting.isEmpty { next.append(Section(title: L("附属文件 · %d", supporting.count), rows: supporting.prefix(visibleLimit).map { .file($0.itemID) } + (supporting.count > visibleLimit ? [.more] : []))) }
                subtitle = sourceName(id.sourceID) + " · " + taskPhaseTitle(task.phase)
            }
        }
        let previousRows = sections.map(\.rows)
        sections = next
        if previousRows != next.map(\.rows) { tableView.reloadData() }
        else {
            for index in tableView.indexPathsForVisibleRows ?? [] {
                if let cell = tableView.cellForRow(at: index) as? DownloadQueueCell { configure(cell, row: sections[index.section].rows[index.row]) }
            }
            for index in sections.indices {
                if let header = tableView.headerView(forSection: index) {
                    var content = header.defaultContentConfiguration()
                    content.text = sections[index].title
                    content.textProperties.font = MusicFreeUIFontTokens.sectionTitle
                    content.textProperties.color = MusicFreeUIColorTokens.foregroundPrimary
                    if case .detail = mode, sections[index].title.hasPrefix(L("文件下载")) { content.directionalLayoutMargins.trailing = 112 }
                    header.contentConfiguration = content
                }
            }
        }
        tableView.backgroundView = next.allSatisfy { $0.rows.isEmpty } ? emptyLabel : nil
        emptyLabel.text = modeIsCompleted ? L("没有已完成任务") : L("没有下载任务")
        updateHeader(title: pageTitle, subtitle: subtitle, task: detailTask, files: detailFiles)
        let resumable = detailTask.map { !$0.phase.isActive && $0.phase != .completed && model.downloadQueue.canResumeTask($0.id) } ?? false
        resumeArea.isHidden = !resumable
        resumeHeight.constant = resumable ? 72 : 0
        configureNavigation(completedCount: completed.count, task: detailTask)
    }

    private var modeIsCompleted: Bool { if case .completed = mode { true } else { false } }
    private func sourceName(_ id: MediaSourceID) -> String { model.snapshot.sources.first { $0.sourceID == id }?.displayName ?? id.rawValue }

    private func updateHeader(title: String, subtitle: String, task: OnlineDownloadTaskSummary?, files: [OnlineSourceDownloadSnapshot]) {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        let heading = queueLabel(title, font: MusicFreeUIFontTokens.screenTitle)
        let sub = queueLabel(subtitle, font: MusicFreeUIFontTokens.caption, color: MusicFreeUIColorTokens.foregroundSecondary)
        stack.addArrangedSubview(heading); stack.addArrangedSubview(sub)
        if let task {
            let phase = queueLabel(taskPhaseTitle(task.phase), font: MusicFreeUIFontTokens.sectionTitle, color: taskColor(task.phase))
            stack.addArrangedSubview(phase)
            let counts = UIStackView()
            counts.distribution = .fillEqually
            let isDiscovering = task.phase == .discovering
            let directories = snapshot.imports[task.id]?.directories ?? []
            let values: [(String, String)]
            if isDiscovering {
                let expanded = directories.filter(\.isExpanded).count
                values = [(String(files.count), L("已发现文件")), (String(expanded), L("已展开目录")), (String(directories.count - expanded), L("待扫描目录")), ("—", L("总进度"))]
            } else {
                let active = files.filter(\.isActive).count
                let failed = files.filter { $0.phase == .failed }.count
                let waiting = files.filter { $0.phase == .waiting || $0.phase == .cancelled }.count
                values = [(String(task.completedFiles), L("已完成")), (String(active), L("进行中")), (String(failed), L("失败")), (String(waiting), L("待处理"))]
            }
            let counterKeys = isDiscovering ? ["discovered", "expanded", "directoriesWaiting", "progress"] : ["completed", "active", "failed", "waiting"]
            for (index, (value, label)) in values.enumerated() {
                let column = UIStackView(arrangedSubviews: [queueLabel(value, font: MusicFreeUIFontTokens.sectionTitle), queueLabel(label, font: MusicFreeUIFontTokens.caption, color: MusicFreeUIColorTokens.foregroundSecondary)])
                column.axis = .vertical; column.spacing = 4
                column.arrangedSubviews.first?.accessibilityIdentifier = "onlineSources.downloadQueue.counter.\(counterKeys[index])"
                for label in column.arrangedSubviews.compactMap({ $0 as? UILabel }) { label.textAlignment = .center }
                counts.addArrangedSubview(column)
            }
            stack.addArrangedSubview(counts)
            if let failure = task.failureReason { stack.addArrangedSubview(queueLabel(failureMessage(failure), font: MusicFreeUIFontTokens.caption, color: MusicFreeUIColorTokens.destructive)) }
        }
        let width = max(1, view.bounds.width)
        stack.frame = CGRect(x: 0, y: 0, width: width, height: stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        tableView.tableHeaderView = stack
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width else { return }
        header.frame.size.width = tableView.bounds.width
        header.frame.size.height = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        tableView.tableHeaderView = header
    }

    private func configureNavigation(completedCount: Int, task: OnlineDownloadTaskSummary?) {
        if let task {
            let action = UIBarButtonItem(image: UIImage(systemName: task.phase.isActive ? "xmark.circle" : "ellipsis"), primaryAction: task.phase.isActive ? UIAction { [weak self] _ in self?.cancelTask(task) } : nil)
            if !task.phase.isActive { action.menu = UIMenu(children: [UIAction(title: L("恢复任务"), image: UIImage(systemName: "arrow.counterclockwise"), attributes: model.downloadQueue.canResumeTask(task.id) && task.phase != .completed ? [] : .disabled) { [weak self] _ in self?.model.downloadQueue.resumeTask(task.id) }]) }
            action.accessibilityIdentifier = "onlineSources.downloadQueue.taskAction"
            action.accessibilityLabel = task.phase.isActive ? L("取消任务") : L("任务操作")
            navigationItem.rightBarButtonItem = action
        } else if modeIsCompleted {
            let clear = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.confirmClear() })
            clear.isEnabled = completedCount > 0
            clear.accessibilityIdentifier = "onlineSources.downloadQueue.clear"
            clear.accessibilityLabel = L("清理已完成任务")
            navigationItem.rightBarButtonItem = clear
        } else {
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
                UIAction(title: L("已完成"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.showCompleted() },
                UIAction(title: L("清理已完成任务"), image: UIImage(systemName: "trash"), attributes: completedCount > 0 ? [] : .disabled) { [weak self] _ in self?.confirmClear() },
                UIAction(title: L("取消全部"), image: UIImage(systemName: "xmark.circle"), attributes: snapshot.activeTaskCount > 0 ? .destructive : .disabled) { [weak self] _ in self?.confirmCancelAll() }
            ]))
            more.accessibilityLabel = L("下载任务操作")
            navigationItem.rightBarButtonItem = more
        }
    }

    private func refreshProgress(_ id: SourceObjectID) {
        guard let file = model.downloadQueue.fileSnapshot(for: id) else { return }
        if case .detail(let taskID) = mode, file.taskID != taskID && file.itemID != taskID { return }
        filesByID[id] = file
        for index in tableView.indexPathsForVisibleRows ?? [] where sections[index.section].rows[index.row] == .file(id) {
            if let cell = tableView.cellForRow(at: index) as? DownloadQueueCell { configureFile(cell, file: file) }
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadQueueCell", for: indexPath) as! DownloadQueueCell
        configure(cell, row: sections[indexPath.section].rows[indexPath.row])
        return cell
    }
    private func configure(_ cell: DownloadQueueCell, row: Row) {
        cell.reset()
        switch row {
        case .task(let id):
            guard let task = tasksByID[id] else { return }
            cell.titleLabel.text = task.displayName
            cell.statusLabel.text = task.phase == .discovering ? L("展开中 · 已发现 %d 个文件", task.totalFiles) : L("%@ · %d/%d 已完成", taskPhaseTitle(task.phase), task.completedFiles, task.totalFiles)
            cell.statusLabel.textColor = taskColor(task.phase)
            cell.pathLabel.text = sourceName(id.sourceID)
            cell.iconView.image = UIImage(systemName: task.isRecursive ? "folder" : "tray.and.arrow.down")
            cell.iconView.tintColor = taskColor(task.phase)
            cell.setAction(symbol: task.phase.isActive ? "xmark.circle" : task.phase == .completed ? "chevron.right" : "arrow.counterclockwise", label: task.phase.isActive ? L("取消任务") : L("恢复任务"), enabled: task.phase.isActive || task.phase == .completed || model.downloadQueue.canResumeTask(id)) { [weak self] in
                if task.phase.isActive { self?.cancelTask(task) }
                else if task.phase == .completed { self?.showDetail(id) }
                else { self?.model.downloadQueue.resumeTask(id) }
            }
            cell.accessibilityIdentifier = "onlineSources.downloadQueue.task.\(id.externalID)"
        case .file(let id): if let file = filesByID[id] { configureFile(cell, file: file) }
        case .directory(let id):
            guard case .detail(let taskID) = mode, let folder = snapshot.imports[taskID]?.directories?.first(where: { $0.itemID == id }) else { return }
            cell.titleLabel.text = folder.path
            cell.statusLabel.text = folder.isExpanded ? L("已展开") : L("等待展开")
            cell.statusLabel.textColor = folder.isExpanded ? MusicFreeUIColorTokens.positive : MusicFreeUIColorTokens.accent
            cell.iconView.image = UIImage(systemName: "folder")
        case .completed:
            cell.titleLabel.text = L("已完成任务")
            cell.pathLabel.text = L("%d 个任务", tasksByID.values.filter { $0.phase == .completed }.count)
            cell.iconView.image = UIImage(systemName: "checkmark.circle")
            cell.setAction(symbol: "chevron.right", label: L("查看已完成任务")) { [weak self] in self?.showCompleted() }
            cell.accessibilityIdentifier = "onlineSources.downloadQueue.completed"
        case .more:
            cell.titleLabel.text = L("加载更多")
            cell.iconView.image = UIImage(systemName: "chevron.down")
        }
    }

    private func configureFile(_ cell: DownloadQueueCell, file: OnlineSourceDownloadSnapshot) {
        cell.reset()
        cell.titleLabel.text = file.displayName
        cell.pathLabel.text = file.relativePath ?? sourceName(file.itemID.sourceID)
        cell.iconView.image = UIImage(systemName: file.isSupportingFile == true ? "doc" : "music.note")
        cell.progressView.isHidden = false
        cell.progressView.progress = Float(file.progress ?? 0)
        cell.progressView.progressTintColor = file.isSuccessful ? MusicFreeUIColorTokens.positive : file.phase == .failed ? MusicFreeUIColorTokens.destructive : MusicFreeUIColorTokens.accent
        cell.metadataRow.isHidden = false
        let bytes = file.receivedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        let total = file.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let byteText = total.map { "\(bytes.isEmpty ? "0 B" : bytes) / \($0)" } ?? bytes
        cell.percentLabel.text = file.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        cell.bytesLabel.text = file.phase == .downloading ? byteText + (file.bytesPerSecond.map { " · \(ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file))/s" } ?? "") : filePhaseTitle(file.phase) + (byteText.isEmpty ? "" : " · " + byteText)
        if let reason = file.failureReason { cell.bytesLabel.text = failureMessage(reason) + (byteText.isEmpty ? "" : " · " + byteText) }
        cell.bytesLabel.textColor = file.phase == .failed ? MusicFreeUIColorTokens.destructive : MusicFreeUIColorTokens.foregroundSecondary
        cell.percentLabel.textColor = cell.progressView.progressTintColor
        let actionable = file.isSupportingFile != true && (file.isActive || file.phase == .waiting || file.phase == .cancelled || file.phase == .failed)
        if actionable {
            let canCancel = file.isActive || file.phase == .waiting
            cell.setAction(symbol: canCancel ? "xmark.circle" : "arrow.counterclockwise", label: canCancel ? L("取消文件") : L("恢复任务"), enabled: canCancel || model.downloadQueue.canResumeTask(file.taskID ?? file.itemID)) { [weak self] in
                guard let self else { return }
                if canCancel { Task { await self.model.downloadQueue.cancelDownload(file.itemID, taskID: file.taskID) } }
                else { self.model.downloadQueue.resumeTask(file.taskID ?? file.itemID) }
            }
        } else {
            cell.setIndicator(symbol: file.isSuccessful ? "checkmark.circle" : file.phase == .importing ? "arrow.triangle.2.circlepath" : "ellipsis", color: file.isSuccessful ? MusicFreeUIColorTokens.positive : MusicFreeUIColorTokens.foregroundTertiary)
        }
        cell.accessibilityIdentifier = "onlineSources.downloadQueue.file.\(file.itemID.externalID)"
        cell.accessibilityValue = [filePhaseTitle(file.phase), cell.percentLabel.text ?? "", cell.bytesLabel.text ?? ""].joined(separator: ", ")
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .task(let id): showDetail(id)
        case .completed: showCompleted()
        case .more: visibleLimit += 100; render()
        default: break
        }
    }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UITableViewHeaderFooterView()
        var content = header.defaultContentConfiguration()
        content.text = sections[section].title
        content.textProperties.font = MusicFreeUIFontTokens.sectionTitle
        content.textProperties.color = MusicFreeUIColorTokens.foregroundPrimary
        header.contentConfiguration = content
        if case .detail = mode, sections[section].title.hasPrefix(L("文件下载")) {
            content.directionalLayoutMargins.trailing = 112
            header.contentConfiguration = content
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = filterTitle(filter)
            configuration.image = UIImage(systemName: "line.3.horizontal.decrease")
            configuration.imagePadding = 4
            button.configuration = configuration
            button.menu = UIMenu(children: Filter.allCases.map { value in UIAction(title: filterTitle(value), state: filter == value ? .on : .off) { [weak self] _ in self?.filter = value; self?.visibleLimit = 100; self?.render() } })
            button.showsMenuAsPrimaryAction = true
            button.translatesAutoresizingMaskIntoConstraints = false
            header.contentView.addSubview(button)
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: header.contentView.trailingAnchor, constant: -16), button.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor), button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
            button.accessibilityIdentifier = "onlineSources.downloadQueue.filter"
        }
        return header
    }
    private func filterTitle(_ filter: Filter) -> String { switch filter { case .all: L("全部"); case .active: L("进行中"); case .failed: L("未完成"); case .completed: L("已完成") } }
    private func showDetail(_ id: SourceObjectID) { navigationController?.pushViewController(Self(model: model, mode: .detail(id)), animated: true) }
    private func showCompleted() { navigationController?.pushViewController(Self(model: model, mode: .completed), animated: true) }
    private func resumeCurrentTask() { if case .detail(let id) = mode { model.downloadQueue.resumeTask(id) } }
    private func cancelTask(_ task: OnlineDownloadTaskSummary) {
        Task { await model.cancelDownloadTask(task.id) }
    }
    private func confirmClear() {
        let count = model.downloadQueue.snapshot.tasks.filter { $0.phase == .completed }.count
        guard count > 0 else { return }
        let alert = UIAlertController(title: L("清理 %d 个已完成任务？", count), message: L("仅移除任务和文件下载记录。\n已入库的音乐不会删除。"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("清理"), style: .destructive) { [weak self] _ in self?.model.downloadQueue.clearCompletedTasks(); self?.render() })
        present(alert, animated: true)
    }
    private func confirmCancelAll() {
        let alert = UIAlertController(title: L("取消全部下载任务？"), message: L("已入库的音乐会保留，未完成任务可恢复。"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("继续下载"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("取消全部"), style: .destructive) { [weak self] _ in Task { await self?.model.cancelAllDownloads() } })
        present(alert, animated: true)
    }
}

@MainActor
private final class DownloadQueueCell: UITableViewCell {
    let iconView = UIImageView()
    let titleLabel = queueLabel("", font: MusicFreeUIFontTokens.rowTitle)
    let statusLabel = queueLabel("", font: MusicFreeUIFontTokens.rowSubtitle)
    let pathLabel = queueLabel("", font: MusicFreeUIFontTokens.caption, color: MusicFreeUIColorTokens.foregroundSecondary)
    let bytesLabel = queueLabel("", font: MusicFreeUIFontTokens.caption, color: MusicFreeUIColorTokens.foregroundSecondary)
    let percentLabel = queueLabel("", font: MusicFreeUIFontTokens.caption)
    let progressView = UIProgressView(progressViewStyle: .default)
    let actionButton = UIButton(type: .system)
    let metadataRow = UIStackView()
    private var action: (() -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
        actionButton.tintColor = MusicFreeUIColorTokens.accent
        actionButton.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        metadataRow.axis = .horizontal; metadataRow.spacing = 8
        metadataRow.addArrangedSubview(bytesLabel); metadataRow.addArrangedSubview(percentLabel)
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bytesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [titleLabel, statusLabel, pathLabel, progressView, metadataRow])
        text.axis = .vertical; text.spacing = 4
        let row = UIStackView(arrangedSubviews: [iconView, text, actionButton])
        row.axis = .horizontal; row.spacing = 12; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 94), iconView.widthAnchor.constraint(equalToConstant: 24), iconView.heightAnchor.constraint(equalToConstant: 24),
            actionButton.widthAnchor.constraint(equalToConstant: 44), actionButton.heightAnchor.constraint(equalToConstant: 44), progressView.heightAnchor.constraint(equalToConstant: 4)
        ])
        progressView.trackTintColor = MusicFreeUIColorTokens.playerControl
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reset() {
        for label in [titleLabel, statusLabel, pathLabel, bytesLabel, percentLabel] { label.text = nil }
        statusLabel.isHidden = false
        progressView.isHidden = true; metadataRow.isHidden = true
        actionButton.isHidden = true; actionButton.isEnabled = true
        actionButton.tintColor = MusicFreeUIColorTokens.accent
        action = nil
        accessibilityValue = nil
    }
    func setAction(symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) {
        actionButton.isHidden = false
        actionButton.isEnabled = enabled
        actionButton.setImage(UIImage(systemName: symbol), for: .normal)
        actionButton.accessibilityLabel = label
        self.action = action
    }
    func setIndicator(symbol: String, color: UIColor) {
        actionButton.isHidden = false; actionButton.isEnabled = false
        actionButton.setImage(UIImage(systemName: symbol), for: .normal); actionButton.tintColor = color
    }
}

@MainActor
private func queueLabel(_ text: String, font: UIFont, color: UIColor = MusicFreeUIColorTokens.foregroundPrimary) -> UILabel {
    let label = UILabel(); label.text = text; label.font = font; label.textColor = color
    label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true
    return label
}
private func taskPhaseTitle(_ phase: OnlineDownloadTaskPhase) -> String {
    switch phase { case .waiting: L("排队中"); case .discovering: L("展开中"); case .downloading: L("下载中"); case .importing: L("正在入库"); case .completed: L("已完成"); case .cancelled: L("已取消"); case .partialFailure: L("部分失败"); case .failed: L("失败") }
}
private func filePhaseTitle(_ phase: OnlineSourceDownloadPhase) -> String {
    switch phase { case .waiting: L("等待下载"); case .downloading: L("下载中"); case .importing: L("下载完成 · 正在入库"); case .completed: L("已入库"); case .alreadyImported: L("媒体已存在"); case .skipped: L("已跳过"); case .cancelled: L("已取消"); case .failed: L("下载失败") }
}
@MainActor
private func taskColor(_ phase: OnlineDownloadTaskPhase) -> UIColor {
    switch phase { case .completed: MusicFreeUIColorTokens.positive; case .failed, .partialFailure: MusicFreeUIColorTokens.destructive; case .cancelled: MusicFreeUIColorTokens.foregroundSecondary; default: MusicFreeUIColorTokens.accent }
}
private func failureMessage(_ code: String) -> String {
    switch code { case "source_unavailable": L("来源不可用，请先启用来源"); case "empty_catalog": L("没有可下载的音频文件"); case "optional_file_unavailable": L("附属文件不可用，已跳过"); case "remote_item_missing": L("源文件已不存在，已跳过"); case "batch_import_failed", "item_import_failed", "import_failed": L("部分文件未完成，请重试"); case "interrupted": L("下载已中断，可恢复"); default: L("下载或入库失败，请重试") }
}
