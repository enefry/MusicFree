import DesignSystem
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import Observation

/// The companion owns a draft; the host context owns persistence and runtime application.
@MainActor @Observable
final class StereoBalanceSettingsModel {
    private(set) var strengthPercent = 20.0
    private(set) var automatic = true
    private(set) var loading = true
    private(set) var saving = false
    private(set) var loadFailed = false
    private(set) var failure: String?
    private let context: PluginSettingsContext
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var savedRevision = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    var canEdit: Bool { !loading && !loadFailed }

    init(context: PluginSettingsContext) { self.context = context }
    deinit { worker?.cancel() }

    func load() async {
        loading = true; loadFailed = false; failure = nil
        do {
            let preference = try await context.readPreference()
            try Task.checkCancellation()
            try context.descriptor.configuration.validate(preference.configuration, credentialRecordID: preference.credentialRecordID)
            if case .number(let value) = preference.configuration["strengthPercent"] { strengthPercent = value }
            else { strengthPercent = 20 }
            if case .flag(let value) = preference.configuration["automatic"] { automatic = value }
            else { automatic = true }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true; failure = L("无法读取插件设置，请重试。")
        }
        loading = false
    }
    func setStrength(_ value: Double) {
        guard canEdit, value.isFinite, (0...100).contains(value) else { return }
        strengthPercent = value.rounded(); commit()
    }
    func setAutomatic(_ value: Bool) {
        guard canEdit else { return }
        automatic = value; commit()
    }
    func resetParameters() {
        guard canEdit else { return }
        automatic = true; strengthPercent = 20; commit()
    }
    func retrySave() { guard canEdit else { return }; commit() }

    private func commit() {
        revision += 1; failure = nil
        guard worker == nil else { return }
        saving = true
        worker = Task { [weak self] in await self?.saveDrafts() }
    }
    private func saveDrafts() async {
        defer { worker = nil; saving = false }
        while savedRevision < revision, !Task.isCancelled {
            let attemptedRevision = revision
            let values: [String: PluginConfigurationValue] = ["strengthPercent": .number(strengthPercent), "automatic": .flag(automatic)]
            do {
                let preference = try await context.readPreference()
                try Task.checkCancellation()
                try await context.saveConfiguration(values, preference.credentialRecordID)
                savedRevision = attemptedRevision
            } catch {
                guard !Task.isCancelled else { return }
                // A failure for an older draft must not discard a newer pending edit.
                if attemptedRevision == revision {
                    failure = L("参数尚未保存，请重试。")
                    return
                }
            }
        }
    }
}
