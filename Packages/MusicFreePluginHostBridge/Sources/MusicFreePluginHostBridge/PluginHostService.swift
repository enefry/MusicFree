import Foundation
import AppServices
import SettingsAPI
import MusicDomain
import LibraryAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import EqualizerDSPPlugin
import MusicFreePluginAppleAudioAPI

public struct PluginHostService: PluginServing {
    public let runtime: PluginRuntime
    private let audio: [PluginAudioHostController]
    private let pcm: [PluginPCMHostController]
    private let durationProvider: (@Sendable (MediaItemID) async -> TimeInterval?)?
    public init(runtime: PluginRuntime, audio: [PluginAudioHostController] = [], pcm: [PluginPCMHostController] = [],
                durationProvider: (@Sendable (MediaItemID) async -> TimeInterval?)? = nil) {
        self.runtime = runtime; self.audio = audio; self.pcm = pcm; self.durationProvider = durationProvider
    }
    public func adaptingSettings(_ settings: AppSettings, previous: AppSettings?) async throws -> AppSettings {
        try BuiltinPluginSettingsAdapter.adapt(settings, previous: previous, descriptors: Array(runtime.registry.descriptors.values))
    }
    public static var equalizerRegistration: BuiltInPluginRegistration {
        .init(descriptor: EqualizerDSPPlugin.descriptor, dsp: EqualizerDSPPlugin.makeProcessor)
    }
    @MainActor public static var audioFactories: [PluginID: AppleAudioDSPPluginFactory] {
        PluginAudioHostController.referenceFactories.merging([EqualizerDSPPlugin.id: EqualizerDSPPlugin.makeAppleEffect]) { _, builtin in builtin }
    }
    public func apply(_ settings: AppSettings) async {
        // Source gates are per account, in addition to plugin-level policy.
        let sources = settings.importPreferences.onlineSourcePreferences.runtimeSources(
            applicationPrivacyAccepted: settings.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
        var allowed: [PluginID: Set<String>] = [:]
        for registration in runtime.registry.registrations.values where registration.onlineSource != nil {
            allowed[registration.descriptor.id] = Set(sources.filter {
                $0.providerKind.rawValue == registration.descriptor.onlineProviderID
                    && $0.privacyPolicyVersion == registration.descriptor.policyVersion
            }.map { $0.sourceID.rawValue })
        }
        await runtime.apply(preferences: settings.pluginPreferences,
            applicationPrivacyAccepted: settings.importPreferences.privacyPreferences.isPrivacyPolicyAccepted,
            allowedSourceInstances: allowed)
        await applyDSP(settings.pluginPreferences)
    }
    @MainActor private func applyDSP(_ preferences: [PluginPreference]) async {
        for controller in audio { controller.revokeChangedPreferences(preferences) }
        for controller in pcm { controller.revokeChangedPreferences(preferences) }
        for controller in audio { await controller.apply() }
        for controller in pcm { await controller.apply() }
    }
    public func snapshots() async -> [PluginSnapshot] {
        var failed = Set<PluginID>()
        for controller in audio { failed.formUnion(await controller.failedPluginIDs) }
        for controller in pcm { failed.formUnion(await controller.failedPluginIDs) }
        return await runtime.snapshots().map { snapshot in
            guard failed.contains(snapshot.id),
                  [.registered, .ready, .running].contains(snapshot.state) else { return snapshot }
            return PluginSnapshot(descriptor: snapshot.descriptor, preference: snapshot.preference,
                state: .failed, diagnostic: "音频效果已旁路：处理位置不可用、总线位置已占用，或处理器不符合要求。")
        }
    }
    public func audioAnalysis() async -> AsyncStream<PluginPCMAnalysisSnapshot> {
        guard let controller = audio.first else { return AsyncStream { $0.finish() } }
        return await controller.analysisUpdates()
    }
    public func saveCredential(_ data: Data, pluginID: PluginID, instanceID: String) async throws -> String {
        try KeychainPluginCredentialStore().save(data, pluginID: pluginID, instanceID: instanceID)
    }
    public func deleteCredential(recordID: String, pluginID: PluginID, instanceID: String) async throws {
        try KeychainPluginCredentialStore().delete(recordID: recordID, pluginID: pluginID, instanceID: instanceID)
    }
    public func stop() async {
        for controller in audio { await controller.unload() }
        for controller in pcm { await controller.unload() }
        await runtime.shutdown()
    }
    public var lyricsProviders: [any LyricsProviding] {
        runtime.registry.registrations.values.filter { $0.lyrics != nil }.sorted { $0.descriptor.id < $1.descriptor.id }
            .map { PluginLyricsProviderAdapter(pluginID: $0.descriptor.id, runtime: runtime) }
    }
    public var metadataProviders: [any MetadataEnrichmentProviding] {
        runtime.registry.registrations.values.filter { $0.metadata != nil }.sorted { $0.descriptor.id < $1.descriptor.id }
            .map { PluginMetadataProviderAdapter(pluginID: $0.descriptor.id, runtime: runtime,
                durationProvider: $0.descriptor.dataProviderID == "metadataServer" ? durationProvider : nil) }
    }
}
