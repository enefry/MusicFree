import Foundation
import AVFAudio
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import PluginAnalysisRing
import Darwin

/// Exactly one processing producer and one UI consumer. Storage is allocated
/// before rendering; a full queue drops new samples without blocking.
public final class PluginAnalysisQueue: @unchecked Sendable {
    private let ring: OpaquePointer?
    public init() { ring = mf_analysis_create() }
    deinit { if let ring { mf_analysis_destroy(ring) } }
    fileprivate func push(peak: Float, rms: Float, frames: Int, generation: UInt64) {
        guard let ring else { return }
        _ = mf_analysis_push(ring, MFAnalysisSample(peak: peak, rms: rms, frames: UInt32(frames), generation: generation))
    }
    /// AVAudioEngine tap producer. Ignores unsupported/interleaved buffers;
    /// publishes one scalar sample with no allocation or blocking.
    public func ingest(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved,
              buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength > 0 else { return }
        var peak: Float = 0; var sum: Double = 0
        let channelCount = Int(buffer.format.channelCount); let frames = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            for frame in 0..<frames {
                let value = channels[channel][frame]
                if value.isFinite { peak = max(peak, abs(value)); sum += Double(value) * Double(value) }
            }
        }
        push(peak: peak, rms: Float(sqrt(sum / Double(frames * channelCount))), frames: frames, generation: generation)
    }
    @MainActor public func latest(generation: UInt64) -> PluginAudioAnalysis? {
        guard let ring else { return nil }
        var sample = MFAnalysisSample(); var latest: PluginAudioAnalysis?
        while mf_analysis_pop(ring, &sample) {
            if sample.generation == generation {
                latest = PluginAudioAnalysis(peak: sample.peak, rms: sample.rms, frames: Int(sample.frames))
            }
        }
        return latest
    }
    /// UI subscribes at 10 Hz, with one consumer per queue.
    @MainActor public func updates(generation: UInt64) -> AsyncStream<PluginAudioAnalysis> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    if let value = self.latest(generation: generation) { continuation.yield(value) }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
public struct PluginAudioAnalysis: Sendable { public let peak: Float; public let rms: Float; public let frames: Int }

/// Owned by one serial decode/render queue. Do not share this mutable chain
/// across formal playback, audition, or transition lanes.
public final class DSPProcessingChain {
    public private(set) var format: PluginPCMFormat
    public var bypassed: Set<Int> { Set(bypassFlags.indices.filter { bypassFlags[$0] }) }
    private var bypassFlags: [Bool]
    private var processors: [any PluginDSPProcessor]
    private let analysis: PluginAnalysisQueue?
    private let generation: UInt64
    private let budgetFraction: Double
    private let enforceBudget: Bool
    private let bypassesPreparationFailures: Bool
    private let onBypass: (@Sendable (Int) -> Void)?
    private let processingClock: @Sendable () -> UInt64
    private var overruns: [Int]
    private var chainOverruns = 0
    private var elapsedByProcessor: [UInt64]
    private var backup: [[Float]]
    public init(processors: [any PluginDSPProcessor], format: PluginPCMFormat,
                analysis: PluginAnalysisQueue? = nil, generation: UInt64 = 0, budgetFraction: Double = 0.25,
                enforceBudget: Bool = true, bypassesPreparationFailures: Bool = false,
                processingClock: @escaping @Sendable () -> UInt64 = DSPProcessingChain.threadCPUTime,
                onBypass: (@Sendable (Int) -> Void)? = nil) throws {
        guard budgetFraction.isFinite, budgetFraction > 0, budgetFraction <= 0.5 else { throw PluginError.invalidConfiguration }
        self.processors = processors; self.format = format; self.analysis = analysis
        self.generation = generation; self.budgetFraction = budgetFraction
        self.enforceBudget = enforceBudget
        self.bypassesPreparationFailures = bypassesPreparationFailures
        self.processingClock = processingClock; self.onBypass = onBypass
        overruns = Array(repeating: 0, count: processors.count)
        elapsedByProcessor = Array(repeating: 0, count: processors.count)
        bypassFlags = Array(repeating: false, count: processors.count)
        backup = (0..<format.channelCount).map { _ in Array(repeating: 0, count: format.maximumFrames) }
        for index in self.processors.indices {
            do { try self.processors[index].prepare(format: format) }
            catch {
                guard bypassesPreparationFailures else { throw error }
                bypassFlags[index] = true; onBypass?(index)
            }
        }
    }
    public static func threadCPUTime() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 else { return 0 }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
    public func reset(_ reason: PluginDSPResetReason) {
        for index in processors.indices { processors[index].reset(reason) }
    }
    public func reconfigure(format: PluginPCMFormat) throws {
        reset(.reconfigure)
        self.format = format
        backup = (0..<format.channelCount).map { _ in Array(repeating: 0, count: format.maximumFrames) }
        for index in processors.indices {
            do { try processors[index].prepare(format: format); bypassFlags[index] = false }
            catch { guard bypassesPreparationFailures else { throw error }; bypassFlags[index] = true; onBypass?(index) }
        }
        for index in overruns.indices { overruns[index] = 0 }
        chainOverruns = 0
    }
    public func process(_ buffer: PluginPCMBufferView) throws {
        guard buffer.format == format else { throw PluginError.invalidConfiguration }
        // Reject invalid input before any processor sees it.
        for channel in buffer.channels {
            for frame in 0..<buffer.frameCount where !channel[frame].isFinite { channel[frame] = 0 }
        }
        let chainStart = processingClock()
        let period = Double(buffer.frameCount) / format.sampleRate
        for index in processors.indices where !bypassFlags[index] {
            for channel in 0..<format.channelCount {
                backup[channel].withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.update(from: buffer.channels[channel], count: buffer.frameCount)
                }
            }
            let start = processingClock()
            var failed = false
            do { try processors[index].process(buffer) } catch { failed = true }
            for channel in buffer.channels {
                for frame in 0..<buffer.frameCount where !channel[frame].isFinite { failed = true }
            }
            let end = processingClock()
            let elapsedNanoseconds = end >= start ? end - start : 0
            elapsedByProcessor[index] = elapsedNanoseconds
            let elapsed = Double(elapsedNanoseconds) / 1_000_000_000
            if failed {
                for channel in 0..<format.channelCount {
                    backup[channel].withUnsafeBufferPointer { source in
                        buffer.channels[channel].update(from: source.baseAddress!, count: buffer.frameCount)
                    }
                }
            }
            // Detection happens only after return; it cannot preempt native code.
            overruns[index] = enforceBudget && period > 0 && elapsed > period * budgetFraction ? overruns[index] + 1 : 0
            if failed || overruns[index] >= 3 { bypassFlags[index] = true; onBypass?(index) }
        }
        let chainEnd = processingClock()
        let chainElapsed = Double(chainEnd >= chainStart ? chainEnd - chainStart : 0) / 1_000_000_000
        chainOverruns = enforceBudget && period > 0 && chainElapsed > period * 0.5 ? chainOverruns + 1 : 0
        if chainOverruns >= 3 {
            // Complete this block's chain; bypass the largest CPU consumer on
            // subsequent blocks instead of skipping healthy effects this frame.
            var largest: Int?
            for index in processors.indices where !bypassFlags[index] {
                if largest.map({ elapsedByProcessor[index] > elapsedByProcessor[$0] }) ?? true { largest = index }
            }
            if let largest { bypassFlags[largest] = true; onBypass?(largest) }
            chainOverruns = 0
        }
        if let analysis, buffer.frameCount > 0 {
            var peak: Float = 0; var sum: Double = 0
            for channel in buffer.channels {
                for frame in 0..<buffer.frameCount { let value = channel[frame]; peak = max(peak, abs(value)); sum += Double(value) * Double(value) }
            }
            analysis.push(peak: peak, rms: Float(sqrt(sum / Double(buffer.frameCount * format.channelCount))), frames: buffer.frameCount, generation: generation)
        }
    }
    /// Actual AVAudioPCMBuffer entry for the FFmpeg decode feeder. Memory never escapes.
    public func process(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
              buffer.format.sampleRate == format.sampleRate, Int(buffer.format.channelCount) == format.channelCount,
              let channels = buffer.floatChannelData else { throw PluginError.invalidConfiguration }
        let view = try PluginPCMBufferView(channels: UnsafeBufferPointer(start: channels, count: format.channelCount),
            frameCount: Int(buffer.frameLength), format: format)
        try process(view)
    }
}

public struct ReferenceGainProcessor: PluginDSPProcessor {
    public let behavior: PluginDSPBehavior
    private let gain: Float
    public init(gain: Float = 1, scope: PluginDSPScope = .perTrack) throws {
        guard gain.isFinite, (0...4).contains(gain) else { throw PluginError.invalidConfiguration }
        self.gain = gain
        self.behavior = PluginDSPBehavior(scope: scope)
    }
    public mutating func prepare(format: PluginPCMFormat) throws {}
    public mutating func process(_ buffer: PluginPCMBufferView) throws {
        for channel in buffer.channels { for frame in 0..<buffer.frameCount { channel[frame] *= gain } }
    }
    public mutating func reset(_ reason: PluginDSPResetReason) {}
}
