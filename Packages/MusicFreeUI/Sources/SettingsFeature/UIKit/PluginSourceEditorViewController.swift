import AppServices
import DesignSystem
import Foundation
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import SettingsAPI
import UIKit

/// Host-owned descriptor form shared by Settings and the Online Sources route.
@MainActor public final class PluginSourceEditorViewController: UITableViewController {
    private let descriptor: PluginDescriptor
    private let configuration: OnlineSourceConfiguration?
    private let settings: any SettingsServing
    private let plugins: any PluginServing
    private let onSaved: () -> Void
    private let name = UITextField()
    private var fields: [String: UITextField] = [:]
    private var flags: [String: UISwitch] = [:]
    private let enabled = UISwitch()
    private let consent = UISwitch()
    private var values: [String: PluginConfigurationValue] = [:]
    private var busy = true
    private var failure: String?
    private var task: Task<Void, Never>?

    public init(descriptor: PluginDescriptor, configuration: OnlineSourceConfiguration?, settings: any SettingsServing,
                plugins: any PluginServing, onSaved: @escaping () -> Void) {
        self.descriptor = descriptor; self.configuration = configuration
        self.settings = settings; self.plugins = plugins; self.onSaved = onSaved
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { task?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L(configuration == nil ? "添加来源" : "编辑来源")
        tableView.keyboardDismissMode = .onDrag
        view.accessibilityIdentifier = "plugins.source.form"
        name.placeholder = L("名称"); name.accessibilityLabel = L("名称"); name.text = configuration?.displayName ?? descriptor.name
        name.accessibilityIdentifier = "plugins.source.name"
        enabled.accessibilityIdentifier = "plugins.source.enabled"
        consent.accessibilityIdentifier = "plugins.source.consent"
        enabled.accessibilityLabel = L("启用此来源")
        consent.accessibilityLabel = L("同意此来源的服务许可")
        enabled.isOn = configuration?.isEnabled ?? false
        consent.isOn = configuration?.privacyPolicyVersion == descriptor.policyVersion
        for field in descriptor.sourceConfiguration.fields {
            if field.kind == .flag {
                let flag = UISwitch()
                flag.accessibilityIdentifier = "plugins.source.field.\(field.id)"
                flag.accessibilityLabel = field.title
                flags[field.id] = flag
            }
            else {
                let control = UITextField()
                control.accessibilityLabel = field.title
                control.placeholder = field.title; control.isSecureTextEntry = field.kind == .secret
                control.autocapitalizationType = .none; control.autocorrectionType = .no
                if field.kind == .number { control.keyboardType = .numbersAndPunctuation }
                control.accessibilityIdentifier = "plugins.source.field.\(field.id)"
                fields[field.id] = control
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await settings.load()
                guard !Task.isCancelled else { return }
                if let configuration {
                    values = current.pluginPreferences.first { $0.pluginID == descriptor.id }?.instances.first {
                        $0.instanceID == configuration.sourceID.rawValue
                    }?.values ?? [:]
                }
                for field in descriptor.sourceConfiguration.fields {
                    switch values[field.id] {
                    case .text(let value): fields[field.id]?.text = value
                    case .number(let value): fields[field.id]?.text = String(value)
                    case .flag(let value): flags[field.id]?.isOn = value
                    default: break
                    }
                }
                busy = false; tableView.reloadData()
            } catch { failure = L("无法读取来源配置，请返回后重试。"); tableView.reloadData() }
        }
    }
    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? descriptor.sourceConfiguration.fields.count + 3 : (configuration == nil ? 1 : 2)
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? failure : L(descriptor.permissions.contains(.network)
            ? "此来源可以访问声明的媒体服务。密码和令牌只保存在系统 Keychain；应用联网许可需单独开启。更新凭据时请重新填写全部必填凭据。"
            : "此来源提供离线参考内容，不发送网络请求。")
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.isUserInteractionEnabled = !busy
        if indexPath.section == 1 {
            cell.textLabel?.text = L(indexPath.row == 0 ? "保存来源" : "删除来源")
            cell.textLabel?.textColor = indexPath.row == 0 ? .systemBlue : .systemRed
            cell.accessibilityIdentifier = indexPath.row == 0 ? "plugins.source.save" : "plugins.source.delete"
            return cell
        }
        let fieldCount = descriptor.sourceConfiguration.fields.count
        if indexPath.row == 0 { embed(name, in: cell) }
        else if indexPath.row <= fieldCount {
            let field = descriptor.sourceConfiguration.fields[indexPath.row - 1]
            cell.textLabel?.text = field.title
            if let flag = flags[field.id] { cell.accessoryView = flag }
            else if let control = fields[field.id] { embed(control, in: cell); cell.textLabel?.text = nil }
        } else {
            cell.textLabel?.text = L(indexPath.row == fieldCount + 1 ? "启用此来源" : "同意此来源的服务许可")
            cell.accessoryView = indexPath.row == fieldCount + 1 ? enabled : consent
        }
        return cell
    }
    private func embed(_ field: UITextField, in cell: UITableViewCell) {
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
        ])
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy, indexPath.section == 1 else { return }
        if indexPath.row == 0 { task = Task { await save() } }
        else {
            let alert = UIAlertController(title: L("删除来源及其凭据？"), message: L("已导入媒体会保留。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
                self?.task = Task { await self?.remove() }
            })
            present(alert, animated: true)
        }
    }
    private func save() async {
        guard !busy else { return }
        view.endEditing(true); busy = true; failure = nil; tableView.reloadData()
        defer { busy = false; for field in descriptor.sourceConfiguration.fields where field.kind == .secret { fields[field.id]?.text = "" }; tableView.reloadData() }
        let sourceID = configuration?.sourceID ?? MediaSourceID(rawValue: UUID().uuidString)
        var newRecord: String?
        var committed = false
        do {
            var secrets: [String: String] = [:]
            for field in descriptor.sourceConfiguration.fields {
                let text = fields[field.id]?.text ?? ""
                switch field.kind {
                case .flag: values[field.id] = .flag(flags[field.id]?.isOn ?? false)
                case .text: if !text.isEmpty || field.required { values[field.id] = .text(text) } else { values[field.id] = nil }
                case .number:
                    if text.isEmpty && !field.required { values[field.id] = nil }
                    else { guard let number = Double(text), number.isFinite else { throw PluginError.invalidConfiguration }; values[field.id] = .number(number) }
                case .secret: if !text.isEmpty { secrets[field.id] = text }
                }
            }
            let current = try await settings.load()
            if !secrets.isEmpty {
                // A replacement record must contain the complete declared credential set.
                // Never replace a multi-field record with only one edited password/token.
                for field in descriptor.sourceConfiguration.fields where field.kind == .secret && field.required {
                    guard secrets[field.id]?.isEmpty == false else { throw PluginError.invalidConfiguration }
                }
            }
            if !secrets.isEmpty { newRecord = try await plugins.saveCredential(try JSONEncoder().encode(secrets), pluginID: descriptor.id, instanceID: sourceID.rawValue) }
            let record = newRecord ?? configuration?.credentialRecordID
            try descriptor.sourceConfiguration.validate(values, credentialRecordID: record)
            let source = try OnlineSourceConfiguration(sourceID: sourceID,
                providerKind: .init(rawValue: descriptor.onlineProviderID ?? descriptor.id.rawValue), displayName: name.text ?? "",
                endpoint: configuration?.endpoint, rootObjectID: configuration?.rootObjectID,
                credentialRecordID: record, privacyPolicyVersion: consent.isOn ? descriptor.policyVersion : nil, isEnabled: enabled.isOn)
            let instance = PluginInstanceConfiguration(instanceID: sourceID.rawValue, values: values, credentialRecordID: record,
                acceptedPolicyVersion: consent.isOn ? descriptor.policyVersion : nil, schemaVersion: descriptor.sourceConfiguration.version)
            let updated = try PluginConsentSettings.save(source: source, instance: instance, descriptor: descriptor, isNew: configuration == nil, current: current)
            try await settings.update(updated); committed = true; await plugins.apply(updated)
            if let old = configuration?.credentialRecordID, let newRecord, old != newRecord {
                try? await plugins.deleteCredential(recordID: old, pluginID: descriptor.id, instanceID: sourceID.rawValue)
            }
            onSaved()
        } catch {
            if !committed, let newRecord { try? await plugins.deleteCredential(recordID: newRecord, pluginID: descriptor.id, instanceID: sourceID.rawValue) }
            failure = L("保存失败，请检查名称、配置范围和凭据。")
        }
    }
    private func remove() async {
        guard !busy, let configuration else { return }
        busy = true; defer { busy = false; tableView.reloadData() }
        do {
            let current = try await settings.load()
            var preferences = current.pluginPreferences
            if let index = preferences.firstIndex(where: { $0.pluginID == descriptor.id }) {
                preferences[index].instances.removeAll { $0.instanceID == configuration.sourceID.rawValue }
            }
            let updated = AppSettings(importPreferences: current.importPreferences.settingOnlineSourcePreferences(
                current.importPreferences.onlineSourcePreferences.removing(configuration.sourceID)),
                playbackPreferences: current.playbackPreferences, storagePreferences: current.storagePreferences,
                loggingPreferences: current.loggingPreferences, pluginPreferences: preferences)
            try await settings.update(updated); await plugins.apply(updated)
            if let record = configuration.credentialRecordID { try? await plugins.deleteCredential(recordID: record, pluginID: descriptor.id, instanceID: configuration.sourceID.rawValue) }
            onSaved()
        } catch { failure = L("删除失败，请重试。") }
    }
}
