import Foundation
import AVFAudio
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

public enum OfflineDSPRenderSession {
    /// Bounded blocks and tail, with cancellation between blocks. Only this
    /// offline path allocates output memory; the chain processes borrowed PCM.
    public static func render(channels: [[Float]], sampleRate: Double, processors: [any PluginDSPProcessor],
                              blockFrames: Int = 1024, includeTail: Bool = true) throws -> [[Float]] {
        guard let frames = channels.first?.count, channels.allSatisfy({ $0.count == frames }) else { throw PluginError.invalidConfiguration }
        let format = try PluginPCMFormat(sampleRate: sampleRate, channelCount: channels.count, maximumFrames: blockFrames)
        // Serial effects can each extend the preceding effect's tail. Bound the
        // sum to ten seconds (and keep conversion safe for unusual sample rates).
        let tailLimit = Int(min(sampleRate, 768_000) * 10)
        let tail = includeTail ? processors.reduce(0) { total, processor in
            total + min(processor.behavior.tailFrames, tailLimit - total)
        } : 0
        let chain = try DSPProcessingChain(processors: processors, format: format, budgetFraction: 0.5, enforceBudget: false)
        defer { chain.reset(.stop) }
        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(blockFrames)),
              let planes = buffer.floatChannelData else { throw PluginError.invalidConfiguration }
        var output = Array(repeating: [Float](), count: channels.count)
        for start in stride(from: 0, to: frames + tail, by: blockFrames) {
            try Task.checkCancellation()
            let count = min(blockFrames, frames + tail - start)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in channels.indices {
                for frame in 0..<count { planes[channel][frame] = start + frame < frames ? channels[channel][start + frame] : 0 }
            }
            try chain.process(buffer)
            for channel in channels.indices { output[channel].append(contentsOf: UnsafeBufferPointer(start: planes[channel], count: count)) }
        }
        return output
    }
}
