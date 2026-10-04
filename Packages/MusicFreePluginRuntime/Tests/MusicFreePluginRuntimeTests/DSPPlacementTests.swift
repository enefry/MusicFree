import Foundation
import Testing
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
@testable import MusicFreePluginRuntime

private struct PlacementProcessor: PluginDSPProcessor {
    let behavior: PluginDSPBehavior
    mutating func prepare(format: PluginPCMFormat) throws {}
    mutating func process(_ buffer: PluginPCMBufferView) throws {}
    mutating func reset(_ reason: PluginDSPResetReason) {}
}
private let placementID = PluginID(rawValue: "test.placement")
private func placementDescriptor(_ options: PluginDSPPlacementOptions? = .init(
    supported: [.perTrack, .postMix], defaultPlacement: .postMix)) -> PluginDescriptor {
    .init(id: placementID, name: "Placement", kinds: [.dsp], dspPlacements: options)
}
private func placementRuntime(fixedScope: PluginDSPScope? = nil) -> PluginRuntime {
    .init(registry: PluginRegistry([.init(descriptor: placementDescriptor(), dsp: { configuration in
        PlacementProcessor(behavior: .init(scope: fixedScope ?? (configuration.dspPlacement == .postMix ? .postMix : .perTrack)))
    })]))
}

@Test func placementSettingsDecodeLegacyAndPreserveFuturePositions() throws {
    let preference = PluginPreference(pluginID: placementID, dspPlacement: .perTrack)
    #expect(try JSONDecoder().decode(PluginPreference.self, from: JSONEncoder().encode(preference)) == preference)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preference)) as? [String: Any])
    legacy.removeValue(forKey: "dspPlacement")
    let decoded = try JSONDecoder().decode(PluginPreference.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.dspPlacement == nil)
    #expect(try placementDescriptor().resolvedDSPPlacement(decoded.dspPlacement) == .postMix)
    legacy["dspPlacement"] = "futurePosition"
    let future = try JSONDecoder().decode(PluginPreference.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(future.dspPlacement?.rawValue == "futurePosition")
    #expect(try JSONDecoder().decode(PluginPreference.self, from: JSONEncoder().encode(future)) == future)
    #expect(throws: PluginError.unsupportedCapability) { try placementDescriptor().resolvedDSPPlacement(future.dspPlacement) }
    var descriptor = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(placementDescriptor())) as? [String: Any])
    descriptor.removeValue(forKey: "dspPlacements")
    #expect(try JSONDecoder().decode(PluginDescriptor.self, from: JSONSerialization.data(withJSONObject: descriptor)).dspPlacements == nil)
    let instance = PluginInstanceConfiguration(dspPlacement: .perTrack)
    var oldInstance = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(instance)) as? [String: Any])
    oldInstance.removeValue(forKey: "dspPlacement")
    #expect(try JSONDecoder().decode(PluginInstanceConfiguration.self, from: JSONSerialization.data(withJSONObject: oldInstance)).dspPlacement == nil)
}

@Test(arguments: [
    PluginDSPPlacementOptions(supported: [], defaultPlacement: .perTrack),
    .init(supported: [.perTrack], defaultPlacement: .postMix),
    .init(supported: [.init(rawValue: "futurePosition")], defaultPlacement: .init(rawValue: "futurePosition"))
]) func invalidPlacementDeclarationsAreIsolated(_ options: PluginDSPPlacementOptions) {
    let descriptor = placementDescriptor(options)
    let registry = PluginRegistry([.init(descriptor: descriptor, dsp: { _ in PlacementProcessor(behavior: .init()) })])
    #expect(registry.unavailable[placementID] == .invalidRegistration)
    #expect(registry.registrations.isEmpty)
}

@Test func placementFactoriesReceiveSelectionAndRejectScopeMismatch() async throws {
    let runtime = placementRuntime()
    var preference = PluginPreference(pluginID: placementID, isEnabled: true, isLoadAllowed: true)
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await runtime.makeDSP(pluginID: placementID).behavior.scope == .postMix)
    preference.dspPlacement = .perTrack
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await runtime.dspConfiguration(pluginID: placementID).dspPlacement == .perTrack)
    #expect(try await runtime.makeDSP(pluginID: placementID).behavior.scope == .perTrack)
    await #expect(throws: PluginError.unsupportedCapability) {
        try await runtime.makeDSP(pluginID: placementID, configuration: .init(dspPlacement: .postMix))
    }
    let mismatched = placementRuntime(fixedScope: .perTrack)
    preference.dspPlacement = .postMix
    await mismatched.apply(preferences: [preference], applicationPrivacyAccepted: false)
    await #expect(throws: PluginError.unsupportedCapability) { try await mismatched.makeDSP(pluginID: placementID) }
    #expect(await mismatched.snapshots().first?.state == .failed)
    preference.dspPlacement = .perTrack
    await mismatched.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await mismatched.makeDSP(pluginID: placementID).behavior.scope == .perTrack)
    #expect(await mismatched.snapshots().first?.state == .registered)
}

@Test func unknownPlacementBlocksExecutionAndCanBeCorrected() async throws {
    let runtime = placementRuntime()
    var preference = PluginPreference(pluginID: placementID, isEnabled: true, isLoadAllowed: true,
        dspPlacement: .init(rawValue: "futurePosition"))
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(await runtime.snapshots().first?.state == .failed)
    await #expect(throws: PluginError.unsupportedCapability) { try await runtime.makeDSP(pluginID: placementID) }
    preference.dspPlacement = .postMix
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await runtime.makeDSP(pluginID: placementID).behavior.scope == .postMix)
}
