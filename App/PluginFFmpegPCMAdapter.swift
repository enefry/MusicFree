import AVFAudio
import FFmpegPlaybackAdapter
import MusicFreePluginDSPAPI
import MusicFreePluginAudio

/// Constructed and owned only by one decoder slot's serial queue.
final class PluginFFmpegPCMAdapter: FFmpegPCMProcessing {
    private let chain: DSPProcessingChain
    init(format: AVAudioFormat, specifications: [PluginDSPFactorySpec]) throws {
        let pcm = try PluginPCMFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount), maximumFrames: 8192)
        var processors: [any PluginDSPProcessor] = []
        var accepted: [PluginDSPFactorySpec] = []
        for specification in specifications {
            do {
                let processor = try specification.makeProcessor()
                guard processor.behavior.scope == .perTrack, processor.behavior.latencyFrames == 0,
                      processor.behavior.tailFrames == 0 else { specification.gate.markFailed(); continue }
                processors.append(processor); accepted.append(specification)
            } catch { specification.gate.markFailed() }
        }
        let gates = accepted.map(\.gate)
        chain = try DSPProcessingChain(processors: processors, format: pcm, bypassesPreparationFailures: true,
            onBypass: { gates[$0].markFailed() })
    }
    func process(_ buffer: AVAudioPCMBuffer) throws { try chain.process(buffer) }
    func reset() { chain.reset(.stop) }
}
