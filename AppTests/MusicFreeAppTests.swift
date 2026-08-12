@testable import MusicFree
import Testing

@MainActor
@Test("Production composition exposes verified playback and system capabilities")
func productionCompositionExposesCapabilities() async throws {
    let container = AppContainer()
    #expect(container.serviceContainer == nil)
    let composed = await container.retryComposition()
    #expect(composed)
    let services = try #require(container.serviceContainer)
    let effective = try await services.settingsServing.effective()

    #expect(effective.playbackCapabilities.contains(.seeking))
    #expect(effective.playbackCapabilities.contains(.variableRate))
    #expect(effective.playbackCapabilities.contains(.equalizer))
    #expect(effective.equalizerDescriptor?.bands.isEmpty == false)
    #expect(effective.equalizerDescriptor?.presets.isEmpty == false)
    #expect(!effective.playbackCapabilities.contains(.replayGain))
    #expect(!effective.playbackCapabilities.contains(.gapless))
    #expect(effective.systemCapabilities.supports(.audioSession))
    #expect(effective.systemCapabilities.supports(.backgroundAudio))
    #expect(effective.systemCapabilities.supports(.nowPlaying))
    #expect(effective.systemCapabilities.supports(.remoteCommands))
}
