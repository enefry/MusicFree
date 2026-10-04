import AVFAudio
import Foundation
import Testing
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
@testable import MusicFreePluginAudio

private struct Broken: PluginDSPProcessor {
    let behavior = PluginDSPBehavior()
    mutating func prepare(format: PluginPCMFormat) throws {}
    mutating func reset(_ reason: PluginDSPResetReason) {}
    mutating func process(_ buffer: PluginPCMBufferView) throws { buffer.channels[0][0] = .nan }
}
private struct CannotPrepare: PluginDSPProcessor {
    let behavior = PluginDSPBehavior()
    mutating func prepare(format: PluginPCMFormat) throws { throw PluginError.invalidConfiguration }
    mutating func reset(_ reason: PluginDSPResetReason) {}
    mutating func process(_ buffer: PluginPCMBufferView) throws { buffer.channels[0][0] = 99 }
}
private struct OneFrameDelay: PluginDSPProcessor {
    let behavior = PluginDSPBehavior(latencyFrames: 1, tailFrames: 1)
    var previous: Float = 0
    mutating func prepare(format: PluginPCMFormat) throws { previous = 0 }
    mutating func reset(_ reason: PluginDSPResetReason) { previous = 0 }
    mutating func process(_ buffer: PluginPCMBufferView) throws {
        for frame in 0..<buffer.frameCount {
            let input = buffer.channels[0][frame]
            buffer.channels[0][frame] = previous
            previous = input
        }
    }
}
@Test func serialOfflineEffectsFlushTheirCombinedTailAtEOF() throws {
    let output = try OfflineDSPRenderSession.render(channels: [[1, 2]], sampleRate: 48000,
        processors: [OneFrameDelay(), OneFrameDelay()], blockFrames: 1)
    #expect(output == [[0, 0, 1, 2]])
    let truncated = try OfflineDSPRenderSession.render(channels: [[1, 2]], sampleRate: 48000,
        processors: [OneFrameDelay(), OneFrameDelay()], blockFrames: 1, includeTail: false)
    #expect(truncated == [[0, 0]])
}
@Test func permissionGateAndPreparationFailureKeepOtherProcessorsRunning() throws {
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: 1, maximumFrames: 64)
    let gate = PluginDSPPermissionGate()
    let spec = PluginDSPFactorySpec(pluginID: .init(rawValue: "test.gain"), factory: { _ in try ReferenceGainProcessor(gain: 0.5) },
        configuration: .init(), gate: gate)
    let chain = try DSPProcessingChain(processors: [CannotPrepare(), spec.makeProcessor()], format: format,
        enforceBudget: false, bypassesPreparationFailures: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 64)!
    buffer.frameLength = 64
    func process() throws -> Float {
        for frame in 0..<64 { buffer.floatChannelData![0][frame] = 1 }
        try chain.process(buffer)
        return buffer.floatChannelData![0][0]
    }
    #expect(try process() == 1)
    gate.setAllowed(true)
    #expect(try process() == 0.5)
    gate.setAllowed(false)
    #expect(try process() == 1)
    #expect(chain.bypassed == [0])
}
@Test func offlineGainChainAndEOF() throws {
    let output = try OfflineDSPRenderSession.render(channels: [[1, -1, 0.5], [0.4, 0.8, 0]], sampleRate: 48000,
        processors: [ReferenceGainProcessor(gain: 0.5), ReferenceGainProcessor(gain: 0.5)], blockFrames: 2)
    #expect(output == [[0.25, -0.25, 0.125], [0.1, 0.2, 0]])
    #expect(try OfflineDSPRenderSession.render(channels: [[]], sampleRate: 48000, processors: []) == [[]])
}
@Test func invalidSamplesAndProcessorFailureRestoreInput() throws {
    let output = try OfflineDSPRenderSession.render(channels: [[1, .infinity, .nan, -1]], sampleRate: 48000,
        processors: [Broken(), ReferenceGainProcessor(gain: 0.5)], blockFrames: 2)
    #expect(output == [[0.5, 0, 0, -0.5]])
}
@Test func rejectsInvalidFormat() throws {
    #expect(throws: PluginError.invalidConfiguration) { try PluginPCMFormat(sampleRate: .nan, channelCount: 2, maximumFrames: 1024) }
    #expect(throws: PluginError.invalidConfiguration) { try OfflineDSPRenderSession.render(channels: [[1], [1, 2]], sampleRate: 48000, processors: []) }
}
@Test @MainActor func analysisHasActualProducerBoundedQueueAndGenerationGate() throws {
    let analysis = PluginAnalysisQueue()
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: 1, maximumFrames: 64)
    let chain = try DSPProcessingChain(processors: [], format: format, analysis: analysis, generation: 7)
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 64)!
    buffer.frameLength = 64
    for frame in 0..<64 { buffer.floatChannelData![0][frame] = 0.5 }
    for _ in 0..<100 { try chain.process(buffer) }
    let latest = try #require(analysis.latest(generation: 7))
    #expect(latest.peak == 0.5); #expect(latest.rms == 0.5)
    #expect(analysis.latest(generation: 7) == nil)
    try chain.process(buffer)
    #expect(analysis.latest(generation: 8) == nil)
    chain.reset(.seek)
    try chain.reconfigure(format: format)
}
@Test func cancellationStopsOfflineRender() async {
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try OfflineDSPRenderSession.render(channels: [[1]], sampleRate: 48000, processors: [])
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

private final class ScriptedCPUClock: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    let samples: [UInt64]
    init(_ samples: [UInt64]) { self.samples = samples }
    func read() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let value = samples[index % samples.count]; index += 1; return value
    }
}
private struct ThrowAfterMutation: PluginDSPProcessor {
    let behavior = PluginDSPBehavior()
    mutating func prepare(format: PluginPCMFormat) throws {}
    mutating func reset(_ reason: PluginDSPResetReason) {}
    mutating func process(_ buffer: PluginPCMBufferView) throws { buffer.channels[0][0] = 99; throw PluginError.invalidResponse }
}
@Test func throwingEffectRestoresInputAndContinuesDownstream() throws {
    #expect(try OfflineDSPRenderSession.render(channels: [[1, 2]], sampleRate: 48000,
        processors: [ThrowAfterMutation(), ReferenceGainProcessor(gain: 0.5)]) == [[0.5, 1]])
}
@Test func isolatedCPUOverrunDoesNotPermanentlyBypass() throws {
    let clock = ScriptedCPUClock([0, 0, 400_000, 400_000, 401_000, 401_000, 0, 0, 0, 0, 0, 0])
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: 1, maximumFrames: 48)
    let chain = try DSPProcessingChain(processors: [ReferenceGainProcessor(gain: 0.5), ReferenceGainProcessor(gain: 0.5)],
        format: format, processingClock: { clock.read() })
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 48))
    buffer.frameLength = 48
    for _ in 0..<8 { try chain.process(buffer) }
    #expect(chain.bypassed.isEmpty)
}
@Test func sustainedChainBudgetCompletesHealthyDownstreamEffects() throws {
    let clock = ScriptedCPUClock([0, 0, 240_000, 240_000, 480_000, 480_000, 720_000, 720_000])
    let format = try PluginPCMFormat(sampleRate: 48000, channelCount: 1, maximumFrames: 48)
    let chain = try DSPProcessingChain(processors: [ReferenceGainProcessor(gain: 0.5), ReferenceGainProcessor(gain: 0.5), ReferenceGainProcessor(gain: 0.5)],
        format: format, processingClock: { clock.read() })
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 48))
    buffer.frameLength = 48
    for _ in 0..<3 {
        for frame in 0..<48 { buffer.floatChannelData![0][frame] = 1 }
        try chain.process(buffer)
        #expect(buffer.floatChannelData![0][0] == 0.125)
    }
    #expect(chain.bypassed == [0])
    for frame in 0..<48 { buffer.floatChannelData![0][frame] = 1 }
    try chain.process(buffer)
    #expect(buffer.floatChannelData![0][0] == 0.25)
}
