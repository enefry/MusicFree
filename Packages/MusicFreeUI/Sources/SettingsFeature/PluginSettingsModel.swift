import AppServices
import DesignSystem
import MusicFreePluginAPI
import Observation
import SettingsAPI

/// Shared by the plugin overview and its details. Pending edits are projected
/// over runtime snapshots so earlier commits cannot undo newer user choices.
@MainActor
@Observable
final class PluginSettingsModel {
    private(set) var snapshots: [PluginSnapshot] = []
    private(set) var isLoading = false
    private(set) var failure: String?
    @ObservationIgnored private let plugins: any PluginServing
    @ObservationIgnored private let settings: any SettingsServing
    @ObservationIgnored private var committed: [PluginSnapshot] = []
    @ObservationIgnored private var pending: [Mutation] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var loadingFailed = false

    private struct Mutation {
        let edit: (AppSettings) throws -> AppSettings
        let failureMessage: String
        var completion: CheckedContinuation<Bool, Never>?
    }

    init(plugins: any PluginServing, settings: any SettingsServing) {
        self.plugins = plugins
        self.settings = settings
    }

    deinit {
        worker?.cancel()
        refreshTask?.cancel()
        observationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        let settings = settings
        observationTask = Task { [weak self] in
            for await _ in await settings.makeChangeStream() {
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let plugins = plugins, settings = settings
        isLoading = committed.isEmpty
        refreshTask = Task { [weak self] in
            do {
                _ = try await settings.load()
                let values = await plugins.snapshots()
                guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
                if self.loadingFailed { self.failure = nil; self.loadingFailed = false }
                self.committed = values
                self.isLoading = false
                self.projectPendingEdits()
            } catch {
                guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
                self.isLoading = false
                self.loadingFailed = true
                self.failure = L("无法读取插件设置，请重试。")
            }
        }
    }

    func mutate(_ id: PluginID, edit: @escaping (inout PluginPreference) -> Void) {
        enqueue(preferenceMutation(id, edit: edit))
    }

    func saveConfiguration(_ descriptor: PluginDescriptor, values: [String: PluginConfigurationValue]) async -> Bool {
        await saveConfiguration(descriptor, values: values, credentialRecordID: nil, replaceCredential: false)
    }

    func saveConfiguration(_ descriptor: PluginDescriptor, values: [String: PluginConfigurationValue],
                           credentialRecordID: String?, replaceCredential: Bool = true) async -> Bool {
        var mutation = preferenceMutation(descriptor.id) {
            $0.configuration = values
            $0.schemaVersion = descriptor.configuration.version
            if replaceCredential { $0.credentialRecordID = credentialRecordID }
        }
        let edit = mutation.edit
        mutation = Mutation(edit: { current in
            let updated = try edit(current)
            let preference = updated.pluginPreferences.first { $0.pluginID == descriptor.id }!
            try descriptor.configuration.validate(preference.configuration, credentialRecordID: preference.credentialRecordID)
            return updated
        }, failureMessage: mutation.failureMessage)
        return await withCheckedContinuation { continuation in
            mutation.completion = continuation
            enqueue(mutation)
        }
    }

    func setConsent(_ descriptor: PluginDescriptor, granting: Bool) {
        enqueue(.init(edit: { current in
            granting ? PluginConsentSettings.grant(descriptor: descriptor, current: current)
                : PluginConsentSettings.revoke(descriptor: descriptor, current: current)
        }, failureMessage: L(granting ? "服务许可保存失败。" : "服务许可撤销失败。")))
    }

    func saveConsent(_ descriptor: PluginDescriptor, granting: Bool) async -> Bool {
        await withCheckedContinuation { completion in
            enqueue(.init(edit: { current in
                granting ? PluginConsentSettings.grant(descriptor: descriptor, current: current)
                    : PluginConsentSettings.revoke(descriptor: descriptor, current: current)
            }, failureMessage: L("服务许可保存失败。"), completion: completion))
        }
    }

    /// Used by scoped account adapters; participates in the same queue as
    /// switches/configuration so rapid account edits cannot overwrite them.
    func saveSourceEdit(_ edit: @escaping (AppSettings) throws -> AppSettings) async -> Bool {
        await withCheckedContinuation { completion in
            enqueue(.init(edit: edit, failureMessage: L("保存失败，请检查名称、配置范围和凭据。"), completion: completion))
        }
    }

    private func preferenceMutation(_ id: PluginID, edit: @escaping (inout PluginPreference) -> Void) -> Mutation {
        .init(edit: { current in
            var preferences = current.pluginPreferences
            let index = preferences.firstIndex { $0.pluginID == id }
            var preference = index.map { preferences[$0] } ?? PluginPreference(pluginID: id)
            edit(&preference)
            if let index { preferences[index] = preference } else { preferences.append(preference) }
            return current.settingPluginPreferences(preferences)
        }, failureMessage: L("插件设置保存失败。请检查配置后重试。"))
    }

    private func enqueue(_ mutation: Mutation) {
        pending.append(mutation)
        failure = nil
        projectPendingEdits()
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func projectPendingEdits() {
        var projected = AppSettings.defaults.settingPluginPreferences(committed.map(\.preference))
        for mutation in pending {
            if let next = try? mutation.edit(projected) { projected = next }
        }
        snapshots = committed.map { value in
            PluginSnapshot(descriptor: value.descriptor,
                preference: projected.pluginPreferences.first { $0.pluginID == value.id } ?? value.preference,
                state: value.state, diagnostic: value.diagnostic)
        }
    }

    private func drain() async {
        while let mutation = pending.first {
            var saved = false
            do {
                // Read at execution time, preserving other pages' preferences
                // and any normalization performed by SettingsCoordinator.
                let current = try await settings.load()
                let updated = try mutation.edit(current)
                try await settings.update(updated)
                let persisted = try await settings.load()
                await plugins.apply(persisted)
                failure = nil
                saved = true
            } catch {
                failure = mutation.failureMessage
            }
            refreshTask?.cancel()
            refreshGeneration += 1
            committed = await plugins.snapshots()
            isLoading = false
            pending.removeFirst()
            projectPendingEdits()
            mutation.completion?.resume(returning: saved)
        }
        worker = nil
    }

    func waitForPendingWork() async {
        await worker?.value
        await refreshTask?.value
    }
}
