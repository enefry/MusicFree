import Testing
import SettingsAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio
import MusicFreePluginHostBridge

@Test @MainActor func declickRegistrationMountsPerTrackAndRevokesOnDisable() async throws {
    let registration = PluginHostService.declickRegistration
    let id = registration.descriptor.id
    let runtime = PluginRuntime(registry: PluginRegistry([registration]))
    var installed: [PluginDSPFactorySpec] = []
    let controller = PluginPCMHostController(runtime: runtime) { installed = $0 }
    defer { controller.unload() }
    let service = PluginHostService(runtime: runtime, pcm: [controller])
    await service.apply(.init())
    #expect(installed.isEmpty)
    await service.apply(.init(pluginPreferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["sensitivity": .number(50), "strengthPercent": .number(100)])]))
    let specification = try #require(installed.first)
    #expect(specification.pluginID == id && specification.gate.isAllowed)
    let processor = try specification.makeProcessor()
    #expect(processor.behavior.latencyFrames == 0 && processor.behavior.tailFrames == 0)
    await service.apply(.init())
    #expect(!specification.gate.isAllowed && installed.isEmpty)
}
