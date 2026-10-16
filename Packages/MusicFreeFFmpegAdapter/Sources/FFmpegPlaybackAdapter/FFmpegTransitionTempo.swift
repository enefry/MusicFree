import AVFoundation
import CPlaybackTransition

/// Source frames per output frame. Each decoder owns its schedule and stretcher;
/// neither the mixed output nor the application's playback rate is changed.
struct FFmpegTransitionTempo: Sendable, Equatable {
    let rate: Double
    let hold: Double
    let recovery: Double

    func sourceFrame(_ outputFrame: Double, sampleRate: Double) -> Double {
        mft_tempo_source_frame(rate, hold * sampleRate, recovery * sampleRate, outputFrame)
    }

    func outputFrames(for sourceFrames: Int64, sampleRate: Double) -> Int64 {
        var low = 0.0, high = Double(sourceFrames) / min(rate, 1) + 1
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if sourceFrame(middle, sampleRate: sampleRate) < Double(sourceFrames) { low = middle }
            else { high = middle }
        }
        return Int64(high.rounded(.up))
    }
}

/// Bounded streaming WSOLA, used only on a producer's serial decoding queue.
/// Shared grain offsets preserve stereo phase. A 20 ms overlap and +/-5 ms
/// waveform search change duration without resampling or changing pitch.
final class FFmpegTransitionTimeStretcher {
    let tempo: FFmpegTransitionTempo
    private(set) var outputFrames: Int64
    private(set) var directOutputFrame: Int64?
    private(set) var directSourceCorrection: Int64 = 0
    private let sourceFrames: Int64
    private let format: AVAudioFormat
    private let hop: Int
    private let search: Int
    private let restoreFrame: Int64
    private var input: [[Float]]
    private var inputOrigin: Int64 = 0
    private var sourceEOF = false
    private var tail: [[Float]]
    private var outputPosition: Int64 = 0

    init(format: AVAudioFormat, sourceFrames: Int64, tempo: FFmpegTransitionTempo) {
        self.format = format; self.tempo = tempo
        self.sourceFrames = sourceFrames
        hop = max(1, Int((format.sampleRate * 0.02).rounded()))
        search = max(1, Int((format.sampleRate * 0.005).rounded()))
        restoreFrame = Int64(((tempo.hold + tempo.recovery) * format.sampleRate).rounded(.up))
        outputFrames = tempo.outputFrames(for: sourceFrames, sampleRate: format.sampleRate)
        input = Array(repeating: [], count: Int(format.channelCount))
        tail = Array(repeating: [], count: Int(format.channelCount))
    }

    func nextBuffer(read: () throws -> AVAudioPCMBuffer?) throws -> AVAudioPCMBuffer? {
        guard outputPosition < outputFrames else { return nil }
        let nominal = Int64(tempo.sourceFrame(Double(outputPosition), sampleRate: format.sampleRate).rounded()) + directSourceCorrection
        // Choose one final correlated grain at unity, then follow that exact
        // source offset. Forcing the nominal phase here creates a short dip.
        let searching = outputPosition > 0 && directOutputFrame == nil
        let first = max(inputOrigin, nominal - Int64(searching ? search : 0))
        let last = nominal + Int64(searching ? search : 0)
        let needed = last + Int64(2 * hop)
        while !sourceEOF && inputOrigin + Int64(input[0].count) < needed {
            guard let buffer = try read(), buffer.frameLength > 0, let data = buffer.floatChannelData else {
                sourceEOF = true; break
            }
            for channel in input.indices {
                input[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
        }
        let availableEnd = inputOrigin + Int64(input[0].count)
        guard nominal < availableEnd else { return nil }
        var selected = nominal
        if searching && !tail[0].isEmpty {
            let end = min(last, availableEnd - Int64(2 * hop))
            if first <= end {
                // Coarse search, then sample-accurate refinement. The small
                // distance penalty resolves periodic ties near the planned clock.
                func score(_ frame: Int64) -> Double {
                    let index = Int(frame - inputOrigin)
                    var dot = 0.0, energy = 0.0, reference = 0.0
                    for channel in input.indices {
                        for i in stride(from: 0, to: hop, by: 4) {
                            let a = Double(tail[channel][i]), b = Double(input[channel][index + i])
                            dot += a * b; energy += b * b; reference += a * a
                        }
                    }
                    return dot / max(1e-15, (energy * reference).squareRoot())
                        - 0.0001 * Double(abs(frame - nominal)) / Double(search)
                }
                var best = -Double.infinity
                for candidate in stride(from: first, through: end, by: 4) {
                    let value = score(candidate)
                    if value > best { best = value; selected = candidate }
                }
                let coarse = selected
                for candidate in max(first, coarse - 3)...min(end, coarse + 3) {
                    let value = score(candidate)
                    if value > best { best = value; selected = candidate }
                }
            }
        }
        if outputPosition >= restoreFrame && directOutputFrame == nil {
            directOutputFrame = outputPosition
            directSourceCorrection = selected - nominal
            outputFrames = outputPosition + sourceFrames - selected
        }
        let count = min(hop, Int(outputFrames - outputPosition), Int(availableEnd - selected))
        guard count > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)),
              let data = output.floatChannelData else { return nil }
        output.frameLength = UInt32(count)
        let start = Int(selected - inputOrigin)
        for channel in input.indices {
            for i in 0..<count {
                let sample = input[channel][start + i]
                if tail[channel].count == hop {
                    let mix = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(max(1, hop - 1))))
                    data[channel][i] = tail[channel][i] * (1 - mix) + sample * mix
                } else { data[channel][i] = sample }
            }
            let tailStart = start + hop
            if tailStart + hop <= input[channel].count {
                tail[channel] = Array(input[channel][tailStart..<(tailStart + hop)])
            } else { tail[channel] = [] }
        }
        outputPosition += Int64(count)
        // Keep a bounded window; compact after one consumed decoder block.
        let discard = max(0, Int(selected - inputOrigin) - search)
        if discard >= 8192 {
            for channel in input.indices { input[channel].removeFirst(discard) }
            inputOrigin += Int64(discard)
        }
        return output
    }
}
