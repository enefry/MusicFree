import Foundation
import Testing
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
@testable import StereoBalanceDSPPlugin

private func make(_ strength: Double = 20, automatic: Bool = false) throws -> StereoBalancePCMProcessor {
    try .init(configuration: .init(values: ["strengthPercent": .number(strength), "automatic": .flag(automatic)]))
}

private func render(_ processor: inout StereoBalancePCMProcessor, left: [Float], right: [Float],
                    rate: Double = 48000, chunk: Int = 4096, prepare: Bool = true) throws -> [[Float]] {
    let format = try PluginPCMFormat(sampleRate: rate, channelCount: 2, maximumFrames: 8192)
    if prepare { try processor.prepare(format: format) }
    var l = left, r = right
    let frames = l.count
    try l.withUnsafeMutableBufferPointer { lb in
        try r.withUnsafeMutableBufferPointer { rb in
            for start in stride(from: 0, to: frames, by: chunk) {
                let count = min(chunk, frames - start)
                let pointers = [lb.baseAddress!.advanced(by: start), rb.baseAddress!.advanced(by: start)]
                try pointers.withUnsafeBufferPointer {
                    try processor.process(.init(channels: $0, frameCount: count, format: format))
                }
            }
        }
    }
    return [l, r]
}

@Test(arguments: [0.0, 20, 30, 50, 100])
func displayMappingAndFixedMix(strength: Double) throws {
    let parameters = try StereoBalanceParameters(configuration: .init(values: ["strengthPercent": .number(strength)]))
    #expect(parameters.maximumMixRatio == strength / 200)
    var processor = try make(strength)
    let out = try render(&processor, left: [0.5, -0.25, 0.125], right: [0, 0.5, 0.125])
    let p = strength / 200
    #expect(abs(Double(out[0][0]) - 0.5 * (1 - p)) < 1e-7)
    #expect(abs(Double(out[1][0]) - 0.5 * p) < 1e-7)
    #expect(abs(Double(out[1][1]) - (0.5 * (1 - p) - 0.25 * p)) < 1e-7)
    #expect(out[0][2] == 0.125 && out[1][2] == 0.125)
    if strength == 100 { #expect(out[0] == out[1]) }
}

@Test func defaultsAndInvalidConfigurations() throws {
    let defaults = try StereoBalanceParameters(configuration: .init())
    #expect(defaults.strengthPercent == 20 && defaults.automatic)
    #expect(!PluginPreference(pluginID: StereoBalanceDSPPlugin.id).isEnabled)
    #expect(StereoBalanceDSPPlugin.descriptor.permissions.isEmpty)
    for value in [-1.0, 100.01, .nan, .infinity] {
        #expect(throws: PluginError.invalidConfiguration) { try make(value) }
    }
    #expect(throws: PluginError.invalidConfiguration) {
        try StereoBalanceDSPPlugin.makeProcessor(.init(values: ["automatic": .number(1)]))
    }
    #expect(throws: PluginError.invalidConfiguration) {
        try StereoBalanceDSPPlugin.makeProcessor(.init(values: ["unknown": .flag(true)]))
    }
    #expect(throws: PluginError.unsupportedCapability) {
        try StereoBalanceDSPPlugin.makeProcessor(.init(dspPlacement: .postMix))
    }
}

@Test(arguments: [44100.0, 48000, 96000])
func automaticRespectsLimitAndBufferBoundaries(rate: Double) throws {
    let count = Int(rate * 2)
    let l = (0..<count).map { Float(0.4 * sin(2 * .pi * 440 * Double($0) / rate)) }
    let r = (0..<count).map { frame -> Float in frame < count / 2 ? 0 : l[frame] * 0.9 }
    var reference = try make(20, automatic: true)
    let expected = try render(&reference, left: l, right: r, rate: rate)
    for chunk in [1, 31, 441, 8192] {
        var processor = try make(20, automatic: true)
        let actual = try render(&processor, left: l, right: r, rate: rate, chunk: chunk)
        #expect(actual == expected)
    }
    for frame in 0..<count / 2 {
        #expect(abs(expected[1][frame]) <= abs(l[frame]) * 0.100001 + 1e-8)
        #expect(max(abs(expected[0][frame]), abs(expected[1][frame])) <= abs(l[frame]) + 1e-7)
    }
    #expect(expected[1].prefix(count / 2).contains { abs($0) > 0.03 })
}

@Test func automaticRestoresBalancedStereoAndProtectsAntiPhase() throws {
    let count = 48000 * 8
    let l = (0..<count).map { Float(0.4 * sin(2 * .pi * 440 * Double($0) / 48000)) }
    let r = (0..<count).map { frame -> Float in
        frame < 48000 ? 0 : Float(0.4 * cos(2 * .pi * 440 * Double(frame) / 48000))
    }
    var processor = try make(100, automatic: true)
    let out = try render(&processor, left: l, right: r)
    let error = zip(out[0].suffix(4800), l.suffix(4800)).map { abs($0 - $1) }.max()!
    #expect(error < 0.004)
    var phase = try make(100, automatic: true)
    let opposite = l.map { -$0 }
    let preserved = try render(&phase, left: l, right: opposite)
    #expect(preserved[0] == l && preserved[1] == opposite)
    var fixed = try make(100)
    let mono = try render(&fixed, left: l, right: opposite)
    #expect(mono[0].allSatisfy { $0 == 0 } && mono[1] == mono[0])
}

@Test func resetIsolationSilenceAndInvalidSamples() throws {
    let l = [Float](repeating: 0.4, count: 4800), r = [Float](repeating: 0, count: 4800)
    var changed = try make(50, automatic: true)
    _ = try render(&changed, left: l, right: r)
    changed.reset(.seek)
    var fresh = try make(50, automatic: true)
    let actual = try render(&changed, left: r, right: l, prepare: false)
    #expect(try render(&fresh, left: r, right: l) == actual)
    var silence = try make(100, automatic: true)
    let quiet = try render(&silence, left: r, right: r)
    #expect(quiet[0] == r && quiet[1] == r)
    var invalid = try make()
    #expect(throws: PluginError.invalidResponse) { try render(&invalid, left: [0.4, .nan], right: [0, 0]) }
    let recovered = try render(&invalid, left: [0.4], right: [0], prepare: false)
    #expect(abs(recovered[1][0] - 0.04) < 1e-7)
}

@Test(arguments: [1, 6])
func unsupportedLayoutsPassThrough(channelCount: Int) throws {
    var processor = try make(100)
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: channelCount, maximumFrames: 16)
    try processor.prepare(format: format)
    // Independent channel storage, matching the SDK planar pointer contract.
    let storage = (0..<channelCount).map { channel -> UnsafeMutablePointer<Float> in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        pointer.initialize(repeating: Float(channel + 1) / 10, count: 16)
        return pointer
    }
    defer { for pointer in storage { pointer.deinitialize(count: 16); pointer.deallocate() } }
    try storage.withUnsafeBufferPointer { try processor.process(.init(channels: $0, frameCount: 16, format: format)) }
    for (channel, pointer) in storage.enumerated() { #expect(pointer[0] == Float(channel + 1) / 10) }
}
