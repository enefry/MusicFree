import Foundation
import Testing
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
@testable import DeclickDSPPlugin

private func make(sensitivity: Double = 35, strength: Double = 100) throws -> DeclickPCMProcessor {
    try .init(configuration: .init(values: ["sensitivity": .number(sensitivity), "strengthPercent": .number(strength)]))
}

private func render(_ processor: inout DeclickPCMProcessor, _ input: [[Float]],
                    rate: Double = 44100, chunk: Int = 4096, prepare: Bool = true) throws -> [[Float]] {
    let format = try PluginPCMFormat(sampleRate: rate, channelCount: input.count, maximumFrames: 8192)
    if prepare { try processor.prepare(format: format) }
    let frames = input[0].count
    let storage = input.map { channel -> UnsafeMutablePointer<Float> in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames))
        pointer.initialize(from: channel, count: frames)
        return pointer
    }
    defer { for pointer in storage { pointer.deinitialize(count: frames); pointer.deallocate() } }
    for start in stride(from: 0, to: frames, by: chunk) {
        let pointers = storage.map { $0.advanced(by: start) }
        try pointers.withUnsafeBufferPointer {
            try processor.process(.init(channels: $0, frameCount: min(chunk, frames-start), format: format))
        }
    }
    return storage.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
}

@Test func declickContractAndConfiguration() throws {
    let p = try DeclickDSPPlugin.makeProcessor(.init())
    #expect(p.behavior.scope == .perTrack && p.behavior.latencyFrames == 0 && p.behavior.tailFrames == 0)
    #expect(DeclickDSPPlugin.descriptor.permissions.isEmpty)
    #expect(!PluginPreference(pluginID: DeclickDSPPlugin.id).isEnabled)
    for value in [-1.0, 100.1, .nan, .infinity] {
        #expect(throws: PluginError.invalidConfiguration) { try make(sensitivity: value) }
        #expect(throws: PluginError.invalidConfiguration) { try make(strength: value) }
    }
    #expect(throws: PluginError.invalidConfiguration) {
        try DeclickDSPPlugin.makeProcessor(.init(values: ["sensitivity": .flag(true)]))
    }
    #expect(throws: PluginError.unsupportedCapability) {
        try DeclickDSPPlugin.makeProcessor(.init(dspPlacement: .postMix))
    }
}

@Test(arguments: [44100.0, 48000, 96000])
func isolatedImpulsesOnSilenceAndTone(rate: Double) throws {
    let count = Int(rate / 4)
    let clean = (0..<count).map { Float(0.15 * sin(2 * .pi * 440 * Double($0) / rate)) }
    for polarity: Float in [-1, 1] {
        var damaged = clean
        let at = count/2
        damaged[at] += polarity * 0.7
        var p = try make()
        let output = try render(&p, [damaged, clean], rate: rate)
        #expect(abs(output[0][at] - clean[at]) < 0.01)
        #expect(output[1] == clean)
        #expect(output[0].count == count)
        #expect(output[0].allSatisfy { $0.isFinite })
        var silence = [Float](repeating: 0, count: count)
        silence[at] = polarity * 0.7
        var q = try make()
        #expect(try render(&q, [silence], rate: rate)[0].allSatisfy { $0 == 0 })
    }
}

@Test func boundariesBypassChannelsResetAndInvalidInput() throws {
    let count = 12000
    let clean = (0..<count).map { Float(0.12 * sin(2 * .pi * 330 * Double($0) / 44100)) }
    var damaged = clean
    for i in [4095, 4096, 4097, 8191, 8192] { damaged[i] += 0.7 }
    var baseline = try make()
    let reference = try render(&baseline, [damaged, clean])
    for chunk in [1, 7, 31, 8192] {
        var p = try make()
        #expect(try render(&p, [damaged, clean], chunk: chunk) == reference)
    }
    for p in [try make(sensitivity: 0), try make(strength: 0)] {
        var bypass = p
        #expect(try render(&bypass, [damaged, clean]) == [damaged, clean])
    }
    baseline.reset(.seek)
    var fresh = try make()
    #expect(try render(&baseline, [clean, damaged], prepare: false) == render(&fresh, [clean, damaged]))
    var invalid = try make()
    #expect(throws: PluginError.invalidResponse) { try render(&invalid, [[0, .nan]]) }
    let resumed = try render(&invalid, [[0, 0]], prepare: false)
    #expect(resumed == [[0, 0]])
}

@Test func sustainedAttackDoesNotFlattenAndOutputRemainsBounded() throws {
    var step = [Float](repeating: 0, count: 2000)
    for i in 1000..<2000 { step[i] = 0.6 }
    var p = try make(sensitivity: 100)
    let output = try render(&p, [step])[0]
    #expect(output.suffix(900).allSatisfy { $0 == 0.6 })
    #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.6 })
    let tone = (0..<44100).map { i -> Float in
        let ramp = min(1, Double(i)/4410)
        return Float(ramp * (0.1*sin(2 * .pi * 6000 * Double(i)/44100)))
    }
    var q = try make()
    let preserved = try render(&q, [tone])[0]
    #expect(preserved == tone)
}

/// Opt-in external sample decoded to interleaved 44.1 kHz stereo Float32.
/// The repository does not include or rewrite the source audio.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICFREE_DECLICK_SAMPLE_PCM"] != nil))
func declickExternalSampleValidation() throws {
    let path = try #require(ProcessInfo.processInfo.environment["MUSICFREE_DECLICK_SAMPLE_PCM"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.count % 8 == 0)
    let interleaved = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let count = interleaved.count/2
    let input = (0..<2).map { channel in stride(from: channel, to: interleaved.count, by: 2).map { interleaved[$0] } }
    let start = Date()
    var p = try make()
    let output = try render(&p, input)
    let elapsed = Date().timeIntervalSince(start)
    let originalPeak = input.flatMap { [$0.min() ?? 0, $0.max() ?? 0] }.map { abs($0) }.max() ?? 0
    var regions: [[String: Any]] = []
    for second in [19, 23, 24, 28, 48] {
        let a = max(0, Int((Double(second)-0.5)*44100)), b = min(count, Int((Double(second)+1.5)*44100))
        guard a < b else { continue }
        let channels = (0..<2).map { channel -> [String: Any] in
            var changed = 0, maximum: Float = 0
            for i in a..<b {
                let difference = abs(output[channel][i]-input[channel][i])
                if difference > 0.001 { changed += 1 }
                maximum = max(maximum, difference)
            }
            return ["channel": channel == 0 ? "left" : "right", "changed_samples_above_0_001": changed,
                    "maximum_change": Double(maximum)]
        }
        regions.append(["reported_second": second, "window_seconds": [Double(a)/44100, Double(b)/44100], "channels": channels])
    }
    var changed = 0
    for channel in 0..<2 {
        #expect(output[channel].count == count)
        #expect(output[channel].allSatisfy { $0.isFinite && abs($0) <= originalPeak })
        for i in 0..<count where abs(output[channel][i]-input[channel][i]) > 0.001 { changed += 1 }
    }
    if let report = ProcessInfo.processInfo.environment["MUSICFREE_DECLICK_SAMPLE_REPORT"] {
        let json: [String: Any] = ["frames": count, "duration_seconds": Double(count)/44100,
            "elapsed_seconds_including_render_allocation": elapsed, "changed_channel_samples_above_0_001": changed,
            "changed_channel_samples_percent": Double(changed)/Double(count*2)*100, "regions": regions,
            "note": "Plugin numerical check. Changes do not establish perceptual improvement or defect labels."]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
    }
}
