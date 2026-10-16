import DesignSystem
import LibraryAPI
import MusicDomain
import SettingsAPI

@MainActor
public struct MetadataProviderSettingsContext {
    private let model: SettingsSceneModel
    private let provider: MetadataProviderID
    public init(model: SettingsSceneModel, providerID: String) {
        self.model = model; provider = MetadataProviderID(rawValue: providerID)
    }
    public func load() async { await model.loadIfNeeded() }
    public var isRegistered: Bool { model.viewModel.metadataEnrichmentSnapshot.status(for: provider)?.isRegistered == true }
    public var statusText: String {
        guard let status = model.viewModel.metadataEnrichmentSnapshot.status(for: provider), status.isRegistered else { return L("尚未接入") }
        switch status.authorization {
        case .notDetermined: return L("未授权")
        case .authorized: return L("可用")
        case .denied: return L("权限已拒绝")
        case .restricted: return L("设备受限")
        case .unavailable: return L("不可用")
        }
    }
    public func requestAuthorization() async {
        model.viewModel.requestMetadataAuthorization(for: provider)
        await model.viewModel.waitForMetadataAuthorization()
    }
}
