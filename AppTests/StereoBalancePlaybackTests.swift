import AVFAudio
import Foundation
import Testing
import MusicDomain
import PlaybackAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge
import MusicFreePluginAudio
@testable import FFmpegPlaybackAdapter
@testable import MusicFree

@Suite(.serialized) @MainActor
struct StereoBalancePlaybackTests {
    @Test func stereoBalanceProcessesActualFFmpegOutputOnce() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("StereoBalancePlaybackTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("right-channel.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            pcm.frameLength = 48000
            let channels = try #require(pcm.floatChannelData)
            for frame in 0..<48000 {
                channels[0][frame] = 0
                channels[1][frame] = Float(0.2 * sin(2 * .pi * 440 * Double(frame) / 48000))
            }
            try file.write(from: pcm)
        }
        let registration = PluginHostService.stereoBalanceRegistration
        func render(enabled: Bool, strength: Double, automatic: Bool = false) async throws -> [Float] {
            let engine = FFmpegPlaybackEngine(equalizerManagedExternally: true)
            defer { engine.dispose() }
            let runtime = PluginRuntime(registry: PluginRegistry([registration]))
            let controller = PluginPCMHostController(runtime: runtime) { specs in
                let factory: FFmpegPCMProcessorFactory = { try PluginFFmpegPCMAdapter(format: $0, specifications: specs) }
                try engine.setPCMProcessorFactory(specs.isEmpty ? nil : factory, preservesTiming: true)
            }
            defer { engine.hardStop(); controller.unload() }
            await runtime.apply(preferences: [.init(pluginID: registration.descriptor.id, isEnabled: enabled, isLoadAllowed: true,
                configuration: ["strengthPercent": .number(strength), "automatic": .flag(automatic)])], applicationPrivacyAccepted: false)
            await controller.apply()
            try await engine.prepare(.init(itemID: .init(sourceID: .local, externalID: "stereo-balance-tone"),
                resource: .localFile(url), displaySnapshot: .init(title: "Right channel tone")), startAt: nil)
            engine.audioEngine.stop()
            try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            try engine.play()
            let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var peaks: [Float] = [0, 0]
            for _ in 0..<60 {
                #expect(try engine.audioEngine.renderOffline(512, to: output) == .success)
                let channels = try #require(output.floatChannelData)
                for channel in 0..<2 {
                    for frame in 0..<Int(output.frameLength) { peaks[channel] = max(peaks[channel], abs(channels[channel][frame])) }
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(controller.failedPluginIDs.isEmpty)
            return peaks
        }
        let original = try await render(enabled: false, strength: 20)
        #expect(original[0] < 1e-6 && original[1] > 0.15)
        for strength in [20.0, 30, 50, 100] {
            let processed = try await render(enabled: true, strength: strength)
            #expect(abs(processed[0] / original[1] - Float(strength / 200)) < 0.002)
            #expect(abs(processed[1] / original[1] - Float(1 - strength / 200)) < 0.002)
        }
        let automatic = try await render(enabled: true, strength: 20, automatic: true)
        #expect(abs(automatic[0] / original[1] - 0.1) < 0.002)
        #expect(abs(automatic[1] / original[1] - 0.9) < 0.002)
    }
}
