import Foundation
import Testing
import AVFAudio
import EqualizerDSPPlugin
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

private func process(_ processor: inout any PluginDSPProcessor, _ samples: inout [Float], format: PluginPCMFormat) throws {
    try samples.withUnsafeMutableBufferPointer { samples in
        var channels = [samples.baseAddress!]
        try channels.withUnsafeMutableBufferPointer { table in
            try processor.process(.init(channels: UnsafeBufferPointer(table), frameCount: samples.count, format: format))
        }
    }
}
@Test(arguments: [48000.0, 44100.0, 32001.0, 22050.0])
func equalizerNumericalResponseAndNyquistSafety(sampleRate: Double) throws {
    let format = try PluginPCMFormat(sampleRate: sampleRate, channelCount: 1, maximumFrames: 8192)
    var processor = try EqualizerDSPPlugin.makeProcessor(.init(values: ["1000": .number(6), "16000": .number(12)], dspPlacement: .perTrack))
    try processor.prepare(format: format)
    var samples = (0..<8192).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / sampleRate)) }
    let original = samples
    try process(&processor, &samples, format: format)
    #expect(samples.allSatisfy { $0.isFinite })
    let power = samples.suffix(4096).reduce(0.0) { $0 + Double($1 * $1) }
    let originalPower = original.suffix(4096).reduce(0.0) { $0 + Double($1 * $1) }
    let gain = 10 * log10(power / originalPower)
    #expect(abs(gain - 6) < 0.25)
}
@Test func equalizerPreampAndResetDoNotLeakFilterHistory() throws {
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: 1, maximumFrames: 1024)
    var processor = try EqualizerDSPPlugin.makeProcessor(.init(values: ["preamp": .number(-6)], dspPlacement: .perTrack))
    try processor.prepare(format: format)
    var samples = [Float](repeating: 0.25, count: 1024)
    try process(&processor, &samples, format: format)
    #expect(abs(samples[512] - 0.25 * Float(pow(10, -6.0 / 20))) < 0.00001)
    processor = try EqualizerDSPPlugin.makeProcessor(.init(values: ["125": .number(12)], dspPlacement: .perTrack))
    try processor.prepare(format: format)
    samples = [Float](repeating: 0, count: 1024); samples[0] = 1
    try process(&processor, &samples, format: format)
    #expect(samples.dropFirst().contains { abs($0) > 0.000001 })
    processor.reset(.seek)
    samples = [Float](repeating: 0, count: 1024)
    try process(&processor, &samples, format: format)
    #expect(samples.allSatisfy { $0 == 0 })
}
@Test @MainActor func equalizerAppleParametersUpdateWithoutNodeReplacement() throws {
    let effect = try EqualizerDSPPlugin.makeAppleEffect(.init(values: ["500": .number(6)], dspPlacement: .postMix))
    let node = try #require(effect.node as? AVAudioUnitEQ)
    #expect(node.bands[4].gain == 6)
    #expect(try effect.update(configuration: .init(values: ["500": .number(-6), "preamp": .number(-3)], dspPlacement: .postMix)))
    #expect(effect.node === node)
    #expect(node.bands[4].gain == -6); #expect(node.globalGain == -3)
    #expect(throws: PluginError.invalidConfiguration) { try EqualizerDSPPlugin.makeProcessor(.init(values: ["1000": .number(13)])) }
}
