import AppServices
import DesignSystem
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import SettingsAPI
import UIKit
import Observation

/// Host owns lifecycle/consent controls and navigation; companions own their pages.
@MainActor
public final class PluginSettingsViewController: UITableViewController {
    public static let showHiddenStorageKey = "musicfree.plugins.showHidden"

    private let plugins: any PluginServing
    private let settings: any SettingsServing
    private let model: PluginSettingsModel
    private let pageHost: PluginSettingsPageHost?
    private var snapshots: [PluginSnapshot] { model.snapshots.filter { $0.state != .compiledOut } }
    private var observationGeneration = 0
    private var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showHiddenStorageKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showHiddenStorageKey) }
    }
    private var selectedPluginID: PluginID?
    private var analysisTask: Task<Void, Never>?
    private var lastAnalysisUpdate = Date.distantPast
    private var analysis: PluginPCMAnalysisSnapshot?
    private var rows: [String: SettingsNativeRow] = [:]
    private var sections: [(String, String)] = []
    private var dataSource: SettingsNativeDataSource!

    public init(plugins: any PluginServing, settings: any SettingsServing, pageHost: PluginSettingsPageHost? = nil, pluginID: PluginID? = nil) {
        self.plugins = plugins; self.settings = settings
        self.pageHost = pageHost
        self.model = pageHost?.model ?? PluginSettingsModel(plugins: plugins, settings: settings)
        self.selectedPluginID = pluginID
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private init(plugins: any PluginServing, settings: any SettingsServing, model: PluginSettingsModel, pageHost: PluginSettingsPageHost?) {
        self.plugins = plugins; self.settings = settings; self.model = model; self.pageHost = pageHost
        super.init(style: .insetGrouped)
    }
    deinit { analysisTask?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L("插件")
        tableView.accessibilityIdentifier = selectedPluginID.map { "settings.plugins.detail.\($0.rawValue)" } ?? "settings.plugins"
        tableView.register(SettingsNativeCell.self, forCellReuseIdentifier: "plugin")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        dataSource = SettingsNativeDataSource(tableView: tableView) { [weak self] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "plugin", for: path) as! SettingsNativeCell
            if let row = self?.rows[id] { cell.configure(row) }
            return cell
        }
        dataSource.sectionText = { [weak self] index, footer in
            guard !footer, let self, self.sections.indices.contains(index) else { return nil }
            return self.sections[index].1
        }
        model.start()
        render()
    }
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refresh()
        if let selectedPluginID, snapshots.first(where: { $0.id == selectedPluginID })?.descriptor.kinds.contains(.dsp) == true {
            let plugins = plugins
            analysisTask?.cancel()
            analysisTask = Task { [weak self] in
                for await value in await plugins.audioAnalysis() {
                    guard !Task.isCancelled, let self else { return }
                    guard Date().timeIntervalSince(self.lastAnalysisUpdate) >= 0.25 else { continue }
                    self.lastAnalysisUpdate = Date()
                    self.analysis = value
                    self.updateAnalysisRows()
                }
            }
        }
    }
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        analysisTask?.cancel()
        analysisTask = nil
    }
    public override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? { tableView }
    private func updateAnalysisRows() {
        guard let id = selectedPluginID, let analysis else { return }
        for (suffix, title, value) in [("peak", "音频峰值", analysis.peak), ("rms", "音频 RMS", analysis.rms)] {
            let rowID = "plugins.\(id.rawValue).\(suffix)"
            let row = SettingsNativeRow(id: rowID, title: L(title), detail: String(format: "%.3f", value))
            rows[rowID] = row
            if let path = dataSource.indexPath(for: rowID), let cell = tableView.cellForRow(at: path) as? SettingsNativeCell { cell.configure(row) }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            _ = model.snapshots
            _ = model.failure
            _ = model.isLoading
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.render()
            }
        }
        var next: [(String, String, [SettingsNativeRow])] = []
        for snapshot in snapshots where snapshot.id == selectedPluginID {
            title = snapshot.descriptor.name
            let id = "plugins.\(snapshot.id.rawValue)"
            let unavailable = [.compiledOut, .incompatible, .invalidRegistration].contains(snapshot.state)
            var controls = [SettingsNativeRow(id: id + ".status", title: status(snapshot.state), detail: snapshot.diagnostic ?? "")]
            for (suffix, title, key) in [("visible", "显示入口", \PluginPreference.isVisible), ("enabled", "启用能力", \PluginPreference.isEnabled), ("loadAllowed", "允许加载", \PluginPreference.isLoadAllowed)] {
                controls.append(.init(id: id + "." + suffix, title: L(title), control: .toggle(snapshot.preference[keyPath: key], { [weak self] value in self?.model.mutate(snapshot.id) { $0[keyPath: key] = value } })))
            }
            let entries = pageHost?.registry.entries(pluginID: snapshot.id) ?? []
            // Native account pages own per-account disclosure; a second service
            // consent here would duplicate it and obscure the account scope.
            let hasNativeAccounts = entries.contains { $0.role == .accounts }
                && snapshot.descriptor.sourceConfiguration.fields.contains { $0.id == "nativeSource" }
            if !hasNativeAccounts && (!snapshot.descriptor.permissions.isEmpty || snapshot.descriptor.kinds.contains(.lyrics) || snapshot.descriptor.kinds.contains(.metadata)) {
                controls.append(action(id + ".policy", L("服务许可")) { [weak self] in self?.requestConsent(snapshot) })
                var revoke = action(id + ".revoke", L("撤销许可")) { [weak self] in self?.saveConsent(snapshot, granting: false) }
                revoke.destructive = true; controls.append(revoke)
            }
            if hasNativeAccounts {
                controls.append(.init(id: id + ".privacyNote", title: L("联网许可由每个账户单独管理；应用级同意和全局撤回位于隐私与联网服务。")))
            }
            var configuration = action(id + ".configuration", L("配置"), disclosure: true) { [weak self] in
                guard let self else { return }
                let editor = PluginConfigurationViewController(descriptor: snapshot.descriptor, initial: snapshot.preference.configuration, credentialRecordID: snapshot.preference.credentialRecordID) { [weak self] values in
                    guard let self else { return false }
                    return await self.model.saveConfiguration(snapshot.descriptor, values: values)
                }
                self.navigationController?.pushViewController(editor, animated: true)
            }
            configuration.enabled = !unavailable
            if !entries.contains(where: { $0.role == .configuration }),
               snapshot.descriptor.configuration.fields.contains(where: { $0.kind != .secret }) { controls.append(configuration) }
            for entry in entries {
                var row = action("plugins.pages." + entry.id, L(entry.title), disclosure: true) { [weak self] in
                    guard let self, let page = self.pageHost?.makePage(entryID: entry.id) else { return }
                    self.navigationController?.pushViewController(page, animated: true)
                }
                row.enabled = !unavailable
                row.image = UIImage(systemName: entry.systemImage)
                controls.append(row)
            }
            if snapshot.descriptor.kinds.contains(.onlineSource) && !entries.contains(where: { $0.role == .accounts })
                && !snapshot.descriptor.sourceConfiguration.fields.contains(where: { $0.id == "nativeSource" }) {
                controls.append(action(id + ".sources", L("账户与来源"), disclosure: true) { [weak self] in
                    guard let self else { return }
                    self.navigationController?.pushViewController(PluginSourcesViewController(descriptor: snapshot.descriptor, settings: self.settings, plugins: self.plugins), animated: true)
                })
            }
            if snapshot.descriptor.kinds.contains(.dsp) {
                if let placements = snapshot.descriptor.dspPlacements {
                    let selected = snapshot.preference.dspPlacement ?? placements.defaultPlacement
                    let actions = PluginDSPPlacement.known.filter { placements.supported.contains($0) }.map { placement in
                        UIAction(title: placement == .perTrack ? L("每轨混音前") : L("总线混音后"), state: placement == selected ? .on : .off) { [weak self] _ in self?.model.mutate(snapshot.id) { $0.dspPlacement = placement } }
                    }
                    let title = placements.supported.contains(selected) ? (selected == .perTrack ? L("每轨混音前") : L("总线混音后")) : "\(L("不支持的位置"))：\(selected.rawValue)"
                    controls.append(.init(id: id + ".placement", title: L("处理位置"), enabled: !unavailable, control: .menu(title, UIMenu(children: actions))))
                }
                var priority = action(id + ".priority", L("处理优先级（高级）")) { [weak self] in
                    self?.editDSPPriority(snapshot)
                }
                priority.detail = "\(snapshot.effectiveDSPPriority)" + (snapshot.preference.dspPriority == nil ? " · " + L("默认") : "")
                priority.enabled = !unavailable
                controls.append(priority)
                controls.append(.init(id: id + ".placementNote", title: L("每轨分别处理后混音；总线处理混音后的声音。更改位置在暂停或停止后生效，每个播放会话使用独立实例。")))
                controls.append(.init(id: id + ".peak", title: L("音频峰值"), detail: analysis.map { String(format: "%.3f", $0.peak) } ?? "—"))
                controls.append(.init(id: id + ".rms", title: L("音频 RMS"), detail: analysis.map { String(format: "%.3f", $0.rms) } ?? "—"))
            }
            next.append((id, snapshot.descriptor.name, controls))
        }
        if selectedPluginID == nil {
            title = L("插件")
            next = [("management", "", [SettingsNativeRow(id: "plugins.showHidden", title: L("管理隐藏插件"), control: .toggle(showHidden, { [weak self] in self?.showHidden = $0; self?.render() }))])]
            let groups: [(PluginKind, String)] = [(.dsp, "音效"), (.lyrics, "歌词"), (.metadata, "元数据"), (.onlineSource, "在线源")]
            var included = Set<PluginID>()
            for (kind, title) in groups {
                let values = snapshots.filter { $0.descriptor.kinds.contains(kind) && !included.contains($0.id) && (showHidden || $0.preference.isVisible) }
                included.formUnion(values.map(\.id))
                if !values.isEmpty { next.append(("kind.\(kind.rawValue)", L(title), values.map(summaryRow))) }
            }
            let other = snapshots.filter { !included.contains($0.id) && (showHidden || $0.preference.isVisible) }
            if !other.isEmpty { next.append(("other", L("其他"), other.map(summaryRow))) }
            next.append(("note", "", [.init(id: "plugins.note", title: L("插件管理启用、加载和配置；隐私与联网服务集中管理联网同意和撤回。启用插件不会自动同意联网，隐藏入口不会停止已启用的能力。"))]))
        }
        if model.isLoading && snapshots.isEmpty {
            next.append(("loading", "", [.init(id: "plugins.loading", title: L("加载设置"))]))
        }
        if let selectedPluginID, !model.isLoading, !snapshots.contains(where: { $0.id == selectedPluginID }) {
            next.append(("unavailable", "", [.init(id: "plugins.unavailable", title: L("不可用"))]))
        }
        if let failure = model.failure { next.append(("failure", L("状态"), [.init(id: "plugins.failure", title: failure), action("plugins.retry", L("重试")) { [weak self] in self?.model.refresh() }])) }
        sections = next.map { ($0.0, $0.1) }
        // Keep controls and their appearance intact while persistence runs.
        rows = Dictionary(uniqueKeysWithValues: next.flatMap { $0.2 }.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in next { snapshot.appendSections([section.0]); snapshot.appendItems(section.2.map(\.id), toSection: section.0) }
        if dataSource.snapshot().itemIdentifiers != snapshot.itemIdentifiers || dataSource.snapshot().sectionIdentifiers != snapshot.sectionIdentifiers { dataSource.apply(snapshot, animatingDifferences: false) }
        for case let cell as SettingsNativeCell in tableView.visibleCells { if let id = cell.rowID, let row = rows[id] { cell.configure(row) } }
    }
    private func summaryRow(_ snapshot: PluginSnapshot) -> SettingsNativeRow {
        var row = action("plugins.\(snapshot.id.rawValue).entry", snapshot.descriptor.name, disclosure: true) { [weak self] in
            guard let self else { return }
            let detail = PluginSettingsViewController(plugins: self.plugins, settings: self.settings, model: self.model, pageHost: self.pageHost)
            detail.selectedPluginID = snapshot.id
            self.navigationController?.pushViewController(detail, animated: true)
        }
        row.detail = status(snapshot.state)
        row.trailingValue = snapshot.preference.isEnabled ? L("已开启") : L("已关闭")
        if !snapshot.preference.isVisible { row.detail += " · " + L("已隐藏") }
        return row
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id], row.enabled else { return }
        row.action?()
    }
    private func action(_ id: String, _ title: String, disclosure: Bool = false, perform: @escaping () -> Void) -> SettingsNativeRow {
        .init(id: id, title: title, disclosure: disclosure, action: perform)
    }
    private func editDSPPriority(_ snapshot: PluginSnapshot) {
        let alert = UIAlertController(title: L("处理优先级"),
            message: L("同一处理位置内，数值越小越先执行；相同时按插件 ID 排序。修改在暂停或停止后生效。请输入 0–1000 的整数。"), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.text = String(snapshot.effectiveDSPPriority)
            field.accessibilityIdentifier = "plugins.dspPriority.value"
        }
        let save = UIAlertAction(title: L("保存"), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text,
                  let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...1000).contains(value) else { return }
            self?.model.mutate(snapshot.id) { $0.dspPriority = value }
        }
        alert.textFields?.first?.addAction(UIAction { [weak alert, weak save] _ in
            let text = alert?.textFields?.first?.text ?? ""
            save?.isEnabled = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map { (0...1000).contains($0) } ?? false
        }, for: .editingChanged)
        alert.addAction(save)
        alert.addAction(.init(title: L("恢复默认"), style: .default) { [weak self] _ in
            self?.model.mutate(snapshot.id) { $0.dspPriority = nil }
        })
        alert.addAction(.init(title: L("取消"), style: .cancel))
        present(alert, animated: true)
    }

    private func requestConsent(_ snapshot: PluginSnapshot) {
        let alert = UIAlertController(title: L("服务许可"), message: snapshot.descriptor.permissions.contains(.network) ? L("此服务可发送歌曲查询和来源访问请求；凭据由系统 Keychain 保存。已经发送的请求无法撤回。") : L("此参考服务使用离线数据。宿主的歌词和歌曲信息同意记录将保留用于服务运行。"), preferredStyle: .alert)
        alert.addAction(.init(title: L("同意并授权"), style: .default) { [weak self] _ in self?.saveConsent(snapshot, granting: true) })
        alert.addAction(.init(title: L("取消"), style: .cancel)); present(alert, animated: true)
    }
    private func saveConsent(_ snapshot: PluginSnapshot, granting: Bool) {
        model.setConsent(snapshot.descriptor, granting: granting)
    }
    private func status(_ state: PluginLifecycleState) -> String {
        let title: String = switch state {
        case .disabled: "已停用"
        case .loadBlocked: "尚未允许加载"
        case .permissionRequired: "需要许可"
        case .registered: "已注册，按需加载"
        case .loading: "加载中"
        case .ready: "可用"
        case .running: "运行中"
        case .compiledOut: "当前构建未包含"
        case .incompatible: "版本不兼容，配置已保留"
        case .invalidRegistration: "注册不可用"
        case .failed: "加载失败"
        case .unloaded: "已卸载"
        }
        return L(title)
    }
}

@MainActor
final class PluginConfigurationViewController: UITableViewController {
    private let descriptor: PluginDescriptor
    private let credentialRecordID: String?
    private let onSave: ([String: PluginConfigurationValue]) async -> Bool
    private var values: [String: PluginConfigurationValue]
    private var textFields: [String: UITextField] = [:]
    private var switches: [String: UISwitch] = [:]
    private var failure: String?
    private var task: Task<Void, Never>?
    private var fields: [PluginConfigurationField] { descriptor.configuration.fields.filter { $0.kind != .secret } }
    init(descriptor: PluginDescriptor, initial: [String: PluginConfigurationValue], credentialRecordID: String?, onSave: @escaping ([String: PluginConfigurationValue]) async -> Bool) {
        self.descriptor = descriptor; values = initial; self.credentialRecordID = credentialRecordID; self.onSave = onSave
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { task?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("配置")
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "plugins.configuration.form"
        navigationItem.rightBarButtonItem = .init(title: L("保存配置"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "plugins.configuration.save"
        for field in fields {
            if field.kind == .flag {
                let toggle = UISwitch()
                if case .flag(let value) = values[field.id] { toggle.isOn = value }
                toggle.accessibilityLabel = field.title
                toggle.accessibilityIdentifier = "plugins.configuration.\(field.id)"
                switches[field.id] = toggle
            } else {
                let input = UITextField()
                input.placeholder = field.title
                input.accessibilityLabel = field.title
                input.autocorrectionType = .no; input.autocapitalizationType = .none
                input.keyboardType = field.kind == .number ? .numbersAndPunctuation : .default
                if case .text(let value) = values[field.id] { input.text = value }
                if case .number(let value) = values[field.id] { input.text = String(value) }
                input.accessibilityIdentifier = "plugins.configuration.\(field.id)"
                textFields[field.id] = input
            }
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fields.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { failure }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fields[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = field.title
        if let toggle = switches[field.id] { cell.accessoryView = toggle }
        else if let input = textFields[field.id] {
            cell.textLabel?.text = nil
            let label = UILabel()
            label.text = field.title
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(label)
            input.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(input)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                label.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                input.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8)
            ])
            input.font = .preferredFont(forTextStyle: .body)
            input.adjustsFontForContentSizeCategory = true
            NSLayoutConstraint.activate([input.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor), input.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor), input.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)])
        }
        return cell
    }
    @objc private func save() {
        guard task == nil else { return }
        view.endEditing(true)
        do {
            for field in fields {
                switch field.kind {
                case .flag: values[field.id] = .flag(switches[field.id]?.isOn ?? false)
                case .text:
                    let text = textFields[field.id]?.text ?? ""
                    values[field.id] = text.isEmpty && !field.required ? nil : .text(text)
                case .number:
                    let text = textFields[field.id]?.text ?? ""
                    if text.isEmpty && !field.required { values[field.id] = nil }
                    else { guard let number = Double(text), number.isFinite else { throw PluginError.invalidConfiguration }; values[field.id] = .number(number) }
                case .secret: break
                }
            }
            try descriptor.configuration.validate(values, credentialRecordID: credentialRecordID)
        } catch { failure = L("配置无效，请检查必填项及数值范围。"); tableView.beginUpdates(); tableView.endUpdates(); return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.isUserInteractionEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            let saved = await onSave(values)
            task = nil
            navigationItem.rightBarButtonItem?.isEnabled = true; tableView.isUserInteractionEnabled = true
            if saved { navigationController?.popViewController(animated: true) }
            else { failure = L("插件设置保存失败。请检查配置后重试。"); tableView.beginUpdates(); tableView.endUpdates() }
        }
    }
}

@MainActor
final class PluginSourcesViewController: UITableViewController {
    private let descriptor: PluginDescriptor
    private let settings: any SettingsServing
    private let plugins: any PluginServing
    private var configurations: [OnlineSourceConfiguration] = []
    private var failure: String?
    private var task: Task<Void, Never>?
    init(descriptor: PluginDescriptor, settings: any SettingsServing, plugins: any PluginServing) {
        self.descriptor = descriptor; self.settings = settings; self.plugins = plugins
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { task?.cancel() }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = L("账户与来源")
        let settings = settings
        let providerID = descriptor.onlineProviderID
        task?.cancel()
        task = Task { [weak self] in
            do {
                let current = try await settings.load()
                guard !Task.isCancelled else { return }
                self?.configurations = current.importPreferences.onlineSourcePreferences.sources.filter { $0.providerKind.rawValue == providerID }
                self?.failure = nil
            } catch { self?.failure = L("无法读取来源配置，请返回后重试。") }
            self?.tableView.reloadData()
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { configurations.count + 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { failure }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = indexPath.row == configurations.count ? L("添加来源") : configurations[indexPath.row].displayName
        cell.accessoryType = .disclosureIndicator
        if indexPath.row == configurations.count { cell.accessibilityIdentifier = "plugins.source.add" }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let configuration = indexPath.row == configurations.count ? nil : configurations[indexPath.row]
        let editor = PluginSourceEditorViewController(descriptor: descriptor, configuration: configuration, settings: settings, plugins: plugins) { [weak self] in
            guard let self else { return }; self.navigationController?.popToViewController(self, animated: true)
        }
        navigationController?.pushViewController(editor, animated: true)
    }
}
