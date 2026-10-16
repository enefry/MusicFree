import DesignSystem
import MusicFreePluginSettingsUIKitAPI
import Observation
import SettingsFeature
import UIKit

@MainActor
@Observable
private final class AuthorizationPageState {
    var requesting = false
}

@MainActor
public final class MetadataPluginSettingsViewController: PluginSettingsFormViewController {
    private let context: PluginSettingsContext
    private let authorization: MetadataProviderSettingsContext
    private let requestsSystemAuthorization: Bool
    private let state = AuthorizationPageState()
    private var task: Task<Void, Never>?

    public init(context: PluginSettingsContext, authorization: MetadataProviderSettingsContext,
                requestsSystemAuthorization: Bool) {
        self.context = context; self.authorization = authorization
        self.requestsSystemAuthorization = requestsSystemAuthorization
        super.init()
        title = context.descriptor.name
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { task?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "plugins.\(context.descriptor.id.rawValue).service"
        task = Task { [weak self] in await self?.authorization.load() }
    }
    public override func makeSections() -> [Section] {
        let id = "plugins.\(context.descriptor.id.rawValue)"
        var rows = [text(id + ".authorization.status", L("状态"), detail: authorization.statusText)]
        if requestsSystemAuthorization {
            var request = action(id + ".authorization", L("重新请求权限")) { [weak self] in
                guard let self, !state.requesting else { return }
                state.requesting = true
                task = Task { [weak self] in
                    guard let self else { return }
                    await authorization.requestAuthorization()
                    state.requesting = false
                }
            }
            request.enabled = authorization.isRegistered && !state.requesting
            rows.append(request)
        }
        return [.init(id: "service", title: L("服务与授权"), rows: rows)]
    }
}
