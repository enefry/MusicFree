import AVFoundation
import FFmpegAudioKit
import Foundation

/// Bounded, queue-owned analysis of unprocessed PCM. No PCM is retained.
struct FFmpegTransitionEdge: Sendable {
    static let hopSeconds = 0.01
    let origin: Double
    let rms: [Double]
    let mean: Double
    let onsets: [Double]
    let beatPeriod: Double?
    let beatOnsets: [Double]

    init(origin: Double, rms: [Double]) {
        self.origin = origin; self.rms = rms
        mean = rms.isEmpty ? 0 : sqrt(rms.reduce(0) { $0 + $1 * $1 } / Double(rms.count))
        let onsets = Self.extractOnsets(rms: rms, origin: origin)
        self.onsets = onsets
        let period = Self.estimateBeatPeriod(onsets)
        beatPeriod = period
        // An audible intro attack (or the first partial tail window) may be
        // off the later pulse grid. Never use that isolated attack as a beat.
        if let period {
            beatOnsets = onsets.map { anchor in
                onsets.filter { onset in
                    let distance = onset - anchor
                    return abs(distance - (distance / period).rounded() * period) <= 0.04
                }
            }.max(by: { $0.count < $1.count }) ?? []
        } else { beatOnsets = [] }
    }

    private static func extractOnsets(rms: [Double], origin: Double) -> [Double] {
        guard rms.count >= 3 else { return [] }
        let novelty = rms.indices.map { max(0, rms[$0] - ($0 == 0 ? 0 : rms[$0 - 1])) }
        let peak = novelty.max() ?? 0
        guard peak > 0.0001 else { return [] }
        let threshold = max(peak * 0.2, novelty.reduce(0, +) / Double(novelty.count) * 3)
        var result: [Double] = []
        for i in novelty.indices where novelty[i] >= threshold {
            guard (i == 0 || novelty[i] >= novelty[i - 1]),
                  (i + 1 == novelty.count || novelty[i] > novelty[i + 1]) else { continue }
            let time = origin + Double(i) * Self.hopSeconds
            if let last = result.last, time - last < 0.18 { continue }
            result.append(time)
        }
        return result
    }

    private static func estimateBeatPeriod(_ beats: [Double]) -> Double? {
        guard beats.count >= 6 else { return nil }
        let intervals = zip(beats.dropFirst(), beats).map { $0.0 - $0.1 }.sorted()
        let period = intervals[intervals.count / 2]
        // Conservative 60–180 BPM onset grid. Irregular, sparse, or ambiguous
        // music uses the energy path instead of pretending to have a beat.
        guard (1.0 / 3...1).contains(period) else { return nil }
        let regular = intervals.filter { abs($0 - period) <= 0.04 }.count
        guard Double(regular) / Double(intervals.count) >= 0.8 else { return nil }
        return period
    }

    func level(at sourceTime: Double, window: Double = 0.25) -> Double {
        let first = max(0, Int(((sourceTime - origin) / Self.hopSeconds).rounded(.down)))
        let last = min(rms.count, first + max(1, Int(window / Self.hopSeconds)))
        guard first < last else { return mean }
        return sqrt(rms[first..<last].reduce(0) { $0 + $1 * $1 } / Double(last - first))
    }
}

struct FFmpegSmartTransitionProfile: Sendable {
    let start: Double
    let end: Double
    let head: FFmpegTransitionEdge
    let tail: FFmpegTransitionEdge
    var duration: Double { end - start }

    static func analyze(_ decoder: FFmpegAudioDecoder, firstFrame: Int64, endFrame: Int64?,
                        isCancelled: () -> Bool) throws -> Self? {
        guard let endFrame, endFrame > firstFrame else { return nil }
        let rate = decoder.format.sampleRate
        let start = Double(firstFrame) / rate, end = Double(endFrame) / rate
        let head = try edge(decoder, start: start, end: min(end, start + 12), isCancelled: isCancelled)
        let tail = try edge(decoder, start: max(start, end - 12), end: end, isCancelled: isCancelled)
        guard head.mean > 0.0001, tail.mean > 0.0001 else { return nil }
        return Self(start: start, end: end, head: head, tail: tail)
    }

    private static func edge(_ decoder: FFmpegAudioDecoder, start: Double, end: Double,
                             isCancelled: () -> Bool) throws -> FFmpegTransitionEdge {
        try decoder.seek(to: .seconds(start))
        let rate = decoder.format.sampleRate
        let hop = max(1, Int((rate * FFmpegTransitionEdge.hopSeconds).rounded()))
        var remaining = Int64(((end - start) * rate).rounded())
        var energy = 0.0, count = 0
        var values: [Double] = []
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            guard let buffer = try decoder.nextBuffer(frameCapacity: UInt32(min(8192, remaining))),
                  buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels {
                    let sample = Double(data[channel][frame])
                    guard sample.isFinite else { throw FFmpegAudioDecoder.DecoderError.unsupportedFormat }
                    energy += sample * sample
                }
                count += 1
                if count == hop {
                    values.append(sqrt(energy / Double(count * channels)))
                    energy = 0; count = 0
                }
            }
            remaining -= Int64(buffer.frameLength)
        }
        guard remaining == 0 else { throw FFmpegAudioDecoder.DecoderError.unsupportedFormat }
        if count > 0 { values.append(sqrt(energy / Double(count * Int(decoder.format.channelCount)))) }
        return FFmpegTransitionEdge(origin: start, rms: values)
    }
}

struct FFmpegSmartTransitionPlan: Sendable {
    enum Basis: String, Sendable { case beats, energy, fixed }
    let overlap: Double
    let outgoingStart: Double?
    let incomingStart: Double?
    let basis: Basis
    let incomingTempo: FFmpegTransitionTempo?

    init(overlap: Double, outgoingStart: Double?, incomingStart: Double?, basis: Basis,
         incomingTempo: FFmpegTransitionTempo? = nil) {
        self.overlap = overlap; self.outgoingStart = outgoingStart
        self.incomingStart = incomingStart; self.basis = basis; self.incomingTempo = incomingTempo
    }

    static func choose(outgoing: FFmpegSmartTransitionProfile?, incoming: FFmpegSmartTransitionProfile?,
                       maximum: Double, currentPosition: Double) -> Self {
        let maximum = min(12, max(0, maximum))
        guard let outgoing, let incoming else {
            return Self(overlap: maximum, outgoingStart: nil, incomingStart: incoming?.start, basis: .fixed)
        }
        let limit = min(maximum, outgoing.duration / 2, incoming.duration / 2,
                        max(0, outgoing.end - currentPosition - 0.05))
        guard limit >= 0.25 else {
            return Self(overlap: limit, outgoingStart: outgoing.end - limit, incomingStart: incoming.start, basis: .energy)
        }
        let intro = max(0.0001, incoming.head.level(at: incoming.start, window: 0.5))
        let outro = max(0.0001, outgoing.tail.level(at: outgoing.end - 0.5, window: 0.5))
        let differenceDB = abs(20 * log10(intro / outro))
        // Similar levels tolerate a longer blend; a loud intro or a large
        // level mismatch calls for a short one. Never amplify either source.
        let target = min(limit, differenceDB > 12 ? 1.5 : intro > 0.25 ? 2 : 4)
        if let a = outgoing.tail.beatPeriod, let b = incoming.head.beatPeriod,
           abs(a - b) / a <= 0.06, let firstBeat = incoming.head.beatOnsets.first {
            let ratio = b / a
            // Keep A's tempo stable. B has its own pitch-preserving stage,
            // holding the matched tempo through the overlap, then recovering.
            // Finish recovery before B's midpoint so a later transition sees
            // its original beat grid. Short/late/loud blends keep the energy path.
            let canStretch = abs(ratio - 1) >= 0.002 && differenceDB <= 12 && limit >= 2 &&
                incoming.duration / 2 > target * ratio + 1
            let rate = canStretch ? ratio : 1
            let beatLimit = canStretch ? min(limit, (incoming.duration / 2 - 1) / max(1, rate)) : limit
            let offset = (firstBeat - incoming.start) / rate
            let preferred = min(limit, max(target, 4 * a))
            let choices = outgoing.tail.beatOnsets.compactMap { beat -> Double? in
                let duration = outgoing.end - beat + offset
                return duration >= (canStretch ? 2 : 0.25) && duration <= beatLimit &&
                    (canStretch || duration / a * abs(a - b) <= 0.09) ? duration : nil
            }
            if let overlap = choices.min(by: { abs($0 - preferred) < abs($1 - preferred) }) {
                let recovery = min(3, (incoming.duration / 2 - overlap * rate) / max(1, rate))
                return Self(overlap: overlap, outgoingStart: outgoing.end - overlap,
                            incomingStart: incoming.start, basis: .beats,
                            incomingTempo: canStretch ? .init(rate: rate, hold: overlap, recovery: recovery) : nil)
            }
        }
        // Evaluate quiet entry points using the actual tail envelope. A mild
        // duration penalty keeps a silent dip from causing a needlessly long mix.
        let candidates = stride(from: 0.25, through: limit, by: 0.05).map { $0 } + [limit]
        func score(_ duration: Double) -> Double {
            let level = max(0.0001, outgoing.tail.level(at: outgoing.end - duration))
            return abs(20 * log10(level / intro)) / 12 + abs(duration - target) / 2
        }
        let overlap = candidates.min(by: { score($0) < score($1) }) ?? limit
        return Self(overlap: overlap, outgoingStart: outgoing.end - overlap, incomingStart: incoming.start, basis: .energy)
    }
}
