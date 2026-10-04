import AVFAudio
import Foundation
import Testing
import SettingsAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio
import MusicFreePluginHostBridge

@MainActor private final class PlacementMountState {
    var running = false
    var node: AVAudioNode?
    var specs: [PluginDSPFactorySpec] = []
}

@Test @MainActor func placementMovesOnlyAfterPauseAndNeverEnablesBothRoutes() async throws {
    let id = ReferencePluginRegistrationProvider.dspID
    let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
    let state = PlacementMountState()
    let audio = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) {
        if state.running { throw PluginError.unavailable }; state.node = $0
    }
    let pcm = PluginPCMHostController(runtime: runtime, excluding: Set(PluginAudioHostController.referenceFactories.keys)) {
        if state.running { throw PluginError.unavailable }; state.specs = $0
    }
    defer { state.running = false; audio.unload(); pcm.unload() }
    let service = PluginHostService(runtime: runtime, audio: [audio], pcm: [pcm])
    let (stream, continuation) = AsyncStream<Bool>.makeStream()
    let (pcmStream, pcmContinuation) = AsyncStream<Bool>.makeStream()
    audio.observe(stream); pcm.observe(pcmStream)
    defer { continuation.finish(); pcmContinuation.finish() }
    func settings(_ placement: PluginDSPPlacement?) -> AppSettings {
        .init(pluginPreferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
            configuration: ["gain": .number(0.5)], dspPlacement: placement)])
    }
    await service.apply(settings(nil))
    let oldNode = try #require(state.node as? AVAudioUnitEQ)
    #expect(!oldNode.bypass); #expect(state.specs.isEmpty)
    state.running = true
    await service.apply(settings(.perTrack))
    #expect(oldNode.bypass); #expect(state.node === oldNode); #expect(state.specs.isEmpty)
    state.running = false; continuation.yield(false); pcmContinuation.yield(false)
    for _ in 0..<100 where state.node != nil || state.specs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(state.node == nil)
    let oldSpec = try #require(state.specs.first)
    #expect(oldSpec.configuration.dspPlacement == .perTrack); #expect(oldSpec.gate.isAllowed)
    state.running = true
    await service.apply(settings(.postMix))
    #expect(!oldSpec.gate.isAllowed); #expect(state.node == nil)
    state.running = false; continuation.yield(false); pcmContinuation.yield(false)
    for _ in 0..<100 where state.node == nil || !state.specs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(state.node != nil); #expect(state.specs.isEmpty)
    #expect(!(try #require(state.node as? AVAudioUnitEQ)).bypass)
}

@Test @MainActor func formalAndAuditionHaveIndependentPlacementInstances() async throws {
    let id = ReferencePluginRegistrationProvider.dspID
    let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
    var formalNode: AVAudioNode?, auditionNode: AVAudioNode?
    var formalSpecs: [PluginDSPFactorySpec] = [], auditionSpecs: [PluginDSPFactorySpec] = []
    let formalAudio = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) { formalNode = $0 }
    let auditionAudio = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) { auditionNode = $0 }
    let formalPCM = PluginPCMHostController(runtime: runtime) { formalSpecs = $0 }
    let auditionPCM = PluginPCMHostController(runtime: runtime) { auditionSpecs = $0 }
    defer { formalAudio.unload(); auditionAudio.unload(); formalPCM.unload(); auditionPCM.unload() }
    let service = PluginHostService(runtime: runtime, audio: [formalAudio, auditionAudio], pcm: [formalPCM, auditionPCM])
    var preference = PluginPreference(pluginID: id, isEnabled: true, isLoadAllowed: true, dspPlacement: .postMix)
    await service.apply(.init(pluginPreferences: [preference]))
    #expect(try #require(formalNode) !== #require(auditionNode))
    #expect(formalSpecs.isEmpty); #expect(auditionSpecs.isEmpty)
    preference.dspPlacement = .perTrack
    await service.apply(.init(pluginPreferences: [preference]))
    #expect(formalNode == nil); #expect(auditionNode == nil)
    let formal = try #require(formalSpecs.first), audition = try #require(auditionSpecs.first)
    #expect(formal.gate !== audition.gate)
    formal.gate.setAllowed(false)
    #expect(audition.gate.isAllowed)
}

@Test @MainActor func unsupportedGraphBackendReportsFailure() async throws {
    let id = ReferencePluginRegistrationProvider.dspID
    let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
    var node: AVAudioNode?
    let controller = PluginAudioHostController(runtime: runtime, factories: [:]) { node = $0 }
    defer { controller.unload() }
    let service = PluginHostService(runtime: runtime, audio: [controller])
    await service.apply(.init(pluginPreferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true, dspPlacement: .postMix)]))
    #expect(node == nil)
    #expect(await service.snapshots().first { $0.id == id }?.state == .failed)
}

@Test @MainActor func stalePreferenceRevocationCannotLeaveCurrentPCMLaneBypassed() async throws {
    let id = ReferencePluginRegistrationProvider.dspID
    let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
    var specs: [PluginDSPFactorySpec] = []
    let pcm = PluginPCMHostController(runtime: runtime) { specs = $0 }
    defer { pcm.unload() }
    let preference = PluginPreference(pluginID: id, isEnabled: true, isLoadAllowed: true, dspPlacement: .perTrack)
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    await pcm.apply()
    let current = try #require(specs.first)
    pcm.revokeChangedPreferences([])
    #expect(!current.gate.isAllowed)
    await pcm.apply()
    #expect(specs.first?.gate === current.gate)
    #expect(current.gate.isAllowed)
}
