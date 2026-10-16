import AVFAudio
import Foundation
import Testing
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import MusicFreePluginAudio
import MusicFreePluginRuntime
@testable import MusicFreePluginHostBridge

@Test func dspPriorityDefaultsOverridesTiesAndPersistence() throws {
    func snapshot(_ id: String, defaultPriority: Int? = nil, override: Int? = nil) -> PluginSnapshot {
        .init(descriptor: .init(id: .init(rawValue: id), name: id, kinds: [.dsp], defaultDSPPriority: defaultPriority),
              preference: .init(pluginID: .init(rawValue: id), dspPriority: override), state: .registered)
    }
    let values = [snapshot("z", defaultPriority: 100), snapshot("a", defaultPriority: 300),
                  snapshot("c"), snapshot("b", defaultPriority: 900, override: 100)]
    #expect(values.sorted(by: PluginSnapshot.dspProcessingOrder).map(\.id.rawValue) == ["b", "z", "a", "c"])
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let preference = values[3].preference
    #expect(try decoder.decode(PluginPreference.self, from: encoder.encode(preference)) == preference)
    var reset = preference; reset.dspPriority = nil
    #expect(try decoder.decode(PluginPreference.self, from: encoder.encode(reset)).dspPriority == nil)
    // Simulate persisted preferences and descriptor manifests written before this field existed.
    var old = try #require(JSONSerialization.jsonObject(with: encoder.encode(preference)) as? [String: Any])
    old.removeValue(forKey: "dspPriority")
    #expect(try decoder.decode(PluginPreference.self, from: JSONSerialization.data(withJSONObject: old)).dspPriority == nil)
    var descriptor = try #require(JSONSerialization.jsonObject(with: encoder.encode(values[0].descriptor)) as? [String: Any])
    descriptor.removeValue(forKey: "defaultDSPPriority")
    #expect(try decoder.decode(PluginDescriptor.self, from: JSONSerialization.data(withJSONObject: descriptor)).defaultDSPPriority == nil)
}

@Test @MainActor func dspHostsUsePriorityAndDeferReorderingWhileRunning() async throws {
    let a = PluginID(rawValue: "test.a"), z = PluginID(rawValue: "test.z")
    let registrations: [BuiltInPluginRegistration] = [(a, 300), (z, 100)].map { id, priority in
        .init(descriptor: .init(id: id, name: id.rawValue, kinds: [.dsp],
            dspPlacements: .init(supported: [.perTrack, .postMix], defaultPlacement: .perTrack), defaultDSPPriority: priority),
            dsp: { configuration in
                try ReferenceGainProcessor(scope: configuration.dspPlacement == .postMix ? .postMix : .perTrack)
            })
    }
    let runtime = PluginRuntime(registry: PluginRegistry(registrations))
    var running = false
    var specs: [PluginDSPFactorySpec] = []
    var nodes: [AVAudioNode] = []
    let pcm = PluginPCMHostController(runtime: runtime) {
        if running { throw PluginError.unavailable }; specs = $0
    }
    let audio = PluginAudioHostController(runtime: runtime, factories: [
        a: { _ in ReferenceAppleGainEffect(gainDecibels: -1) },
        z: { _ in ReferenceAppleGainEffect(gainDecibels: -2) }
    ], installChain: {
        if running { throw PluginError.unavailable }; nodes = $0
    })
    defer { running = false; pcm.unload(); audio.unload() }
    var preferences = [a, z].map { PluginPreference(pluginID: $0, isEnabled: true, isLoadAllowed: true, dspPlacement: .perTrack) }
    await runtime.apply(preferences: preferences, applicationPrivacyAccepted: false)
    await pcm.apply()
    #expect(specs.map(\.pluginID) == [z, a])
    running = true
    preferences[0].dspPriority = 0
    await runtime.apply(preferences: preferences, applicationPrivacyAccepted: false)
    await pcm.apply()
    #expect(specs.map(\.pluginID) == [z, a])
    running = false; await pcm.apply()
    #expect(specs.map(\.pluginID) == [a, z])
    for index in preferences.indices { preferences[index].dspPlacement = .postMix; preferences[index].dspPriority = nil }
    await runtime.apply(preferences: preferences, applicationPrivacyAccepted: false)
    await pcm.apply(); await audio.apply()
    #expect(specs.isEmpty)
    #expect(nodes.compactMap { ($0 as? AVAudioUnitEQ)?.globalGain } == [-2, -1])
    running = true; preferences[0].dspPriority = 0
    await runtime.apply(preferences: preferences, applicationPrivacyAccepted: false)
    await audio.apply()
    #expect(nodes.compactMap { ($0 as? AVAudioUnitEQ)?.globalGain } == [-2, -1])
    running = false; await audio.apply()
    #expect(nodes.compactMap { ($0 as? AVAudioUnitEQ)?.globalGain } == [-1, -2])
}
