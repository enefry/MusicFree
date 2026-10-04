import AVFAudio
import Testing
import MusicFreePluginAPI
import MusicFreePluginAppleAudioAPI
import MusicFreePluginAudio

@Test @MainActor func appleEffectActuallyProcessesOfflineGraphAndDetaches() throws {
    let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
    engine.attach(player)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let adapter = SingleTrackAudioGraphDSPAdapter(engine: engine, upstream: player, downstream: engine.mainMixerNode)
    let effect = ReferenceAppleGainEffect(gainDecibels: -6.0206)
    try adapter.attach(effect, format: format, graphGeneration: 1)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    input.frameLength = 1024
    for frame in 0..<1024 { input.floatChannelData![0][frame] = 0.5 }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    player.scheduleBuffer(input)
    try engine.start(); player.play()
    #expect(try engine.renderOffline(1024, to: output) == .success)
    #expect(abs(output.floatChannelData![0][512] - 0.25) < 0.001)
    engine.stop(); player.stop()
    adapter.detach(graphGeneration: 0)
    #expect(engine.attachedNodes.contains(effect.node))
    adapter.detach(graphGeneration: 2)
    #expect(!engine.attachedNodes.contains(effect.node))
}
