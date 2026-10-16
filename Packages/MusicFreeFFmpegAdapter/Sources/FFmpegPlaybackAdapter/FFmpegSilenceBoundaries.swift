import AVFoundation
import FFmpegAudioKit
import Foundation

/// Cancellation can interrupt an edge scan even while its decode queue is busy.
final class FFmpegBoundaryScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Runs only on the decoder's queue, before DSP or sample-rate conversion.
/// Never treats a quiet passage reached by a user seek as a new song boundary.
struct FFmpegSilenceBoundaries {
    var startFrame: Int64 = 0
    var endFrame: Int64?
    var decodedEndFrame: Int64?

    // A conservative -80 dB peak across EVERY channel. Keep 20 ms at each
    // edge, and require at least 250 ms of continuous silence before trimming.
    static let threshold: Float = 0.0001
    static let scanSeconds = 30.0

    static func analyze(_ decoder: FFmpegAudioDecoder, isCancelled: () -> Bool = { false }) throws -> Self {
        let rate = decoder.format.sampleRate
        let minimum = Int64(0.25 * rate), padding = Int64(0.02 * rate)
        let scanFrames = Int64(scanSeconds * rate)
        var result = Self()
        try decoder.seek(to: .zero)
        var headFrames: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            guard let buffer = try decoder.nextBuffer() else {
                // Entirely silent files remain playable, including as
                // a prepared successor; never turn a valid resource into EOF.
                result.decodedEndFrame = headFrames
                return result
            }
            if let first = audibleRange(buffer)?.lowerBound {
                let leading = headFrames + Int64(first)
                if leading >= minimum { result.startFrame = max(0, leading - padding) }
                break
            }
            headFrames += Int64(buffer.frameLength)
        }

        guard let duration = decoder.duration else { return result }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds.isFinite, seconds > 0 else { return result }
        var tailStart = Int64(max(0, seconds - scanSeconds) * rate)
        try decoder.seek(to: .seconds(Double(tailStart) / rate))
        var tailFrames: Int64 = 0, lastAudible: Int64?
        // Metadata is only a seek hint. A cutoff is accepted exclusively
        // after real decoded EOF, with a bounded scan if metadata is wrong.
        while tailFrames <= scanFrames + Int64(rate) {
            if isCancelled() { throw CancellationError() }
            guard let buffer = try decoder.nextBuffer() else {
                guard tailFrames > 0 else { return result }
                let decodedEnd = tailStart + tailFrames
                result.decodedEndFrame = decodedEnd
                // Work backwards in bounded windows for long silent outros,
                // without retaining PCM or repeatedly decoding the suffix.
                while lastAudible == nil, tailStart > 0 {
                    if isCancelled() { throw CancellationError() }
                    let previousStart = max(0, tailStart - scanFrames)
                    let windowLength = tailStart - previousStart
                    tailStart = previousStart
                    try decoder.seek(to: .seconds(Double(tailStart) / rate))
                    tailFrames = 0
                    while tailFrames < windowLength {
                        if isCancelled() { throw CancellationError() }
                        guard let preceding = try decoder.nextBuffer(frameCapacity: UInt32(min(8192, windowLength - tailFrames))) else {
                            return result // Inconsistent seek/metadata: retain the original tail.
                        }
                        if let last = audibleRange(preceding)?.upperBound { lastAudible = tailFrames + Int64(last) }
                        tailFrames += Int64(preceding.frameLength)
                    }
                }
                if let lastAudible, decodedEnd - tailStart - lastAudible - 1 >= minimum {
                    let end = tailStart + lastAudible + 1 + padding
                    if end > result.startFrame { result.endFrame = end }
                }
                return result
            }
            if let last = audibleRange(buffer)?.upperBound { lastAudible = tailFrames + Int64(last) }
            tailFrames += Int64(buffer.frameLength)
        }
        return result
    }

    static func audibleRange(_ buffer: AVAudioPCMBuffer) -> ClosedRange<Int>? {
        guard let data = buffer.floatChannelData else { return nil }
        var first: Int?, last: Int?
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(buffer.format.channelCount) {
                let sample = data[channel][frame]
                if !sample.isFinite || abs(sample) > threshold {
                    if first == nil { first = frame }
                    last = frame
                    break
                }
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }
}
