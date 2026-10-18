import DesignSystem
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import SettingsFeature
import UIKit

@MainActor
public final class MusicCatalogCookieSettingsViewController: PluginSettingsFormViewController {
    private let context: PluginSettingsContext
    private var credentialID: String?
    private var loading = true
    private var task: Task<Void, Never>?

    public init(context: PluginSettingsContext) {
        self.context = context
        super.init()
        title = L(context.descriptor.name)
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { task?.cancel() }
    public override var canEdit: Bool { !loading }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "plugins.\(context.descriptor.id.rawValue).cookie"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                credentialID = try await context.readPreference().credentialRecordID
                loading = false
                render()
            } catch { showFailure() }
        }
    }

    public override func makeSections() -> [Section] {
        let id = "plugins.\(context.descriptor.id.rawValue)"
        var edit = action(id + ".cookie.edit", L("设置 Cookie"), disclosure: true) { [weak self] in self?.editCookie() }
        edit.enabled = canEdit
        var remove = action(id + ".cookie.remove", L("清除 Cookie"), destructive: true) { [weak self] in self?.saveCookie(nil) }
        remove.enabled = canEdit && credentialID != nil
        return [.init(id: "cookie", title: L("Cookie 配置"),
            footer: L("可先匿名查询。服务要求登录时，可填写自己的 Cookie；凭据仅存于系统钥匙串。歌词和元数据插件分别配置。"),
            rows: [text(id + ".cookie.status", L("状态"), detail: loading ? L("加载中") : credentialID == nil ? L("匿名查询") : L("已配置 Cookie")), edit, remove])]
    }

    private func editCookie() {
        let alert = UIAlertController(title: L("设置 Cookie"), message: L("请输入该音乐服务的登录 Cookie。"), preferredStyle: .alert)
        alert.addTextField { input in
            input.isSecureTextEntry = true
            input.autocorrectionType = .no
            input.autocapitalizationType = .none
            input.accessibilityIdentifier = "plugins.cookie.input"
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("保存"), style: .default) { [weak self, weak alert] _ in
            let cookie = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.saveCookie(cookie.isEmpty ? nil : cookie)
        })
        present(alert, animated: true)
    }

    private func saveCookie(_ cookie: String?) {
        guard !loading else { return }
        if let cookie, cookie.utf8.count > 8_192 || cookie.unicodeScalars.contains(where: CharacterSet.newlines.contains) {
            showFailure(); return
        }
        loading = true
        render()
        task = Task { [weak self] in
            guard let self else { return }
            var newID: String?
            do {
                let preference = try await context.readPreference()
                if let cookie { newID = try await context.saveCredential(Data(cookie.utf8)) }
                try await context.saveConfiguration(preference.configuration, newID)
                credentialID = newID
                if let oldID = preference.credentialRecordID { try? await context.deleteCredential(oldID) }
                loading = false
                render()
            } catch {
                if let newID { try? await context.deleteCredential(newID) }
                loading = false
                render()
                showFailure()
            }
        }
    }

    private func showFailure() {
        guard !Task.isCancelled else { return }
        let alert = UIAlertController(title: L("无法保存配置"), message: L("请检查 Cookie，并确认已允许插件访问凭据。"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("确定"), style: .default))
        present(alert, animated: true)
    }
}
