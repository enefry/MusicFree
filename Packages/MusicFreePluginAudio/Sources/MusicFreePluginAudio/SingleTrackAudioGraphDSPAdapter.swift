import AVFAudio
import MusicFreePluginAppleAudioAPI
import MusicFreePluginDSPAPI
import MusicFreePluginAPI

@MainActor public final class SingleTrackAudioGraphDSPAdapter: AudioGraphDSPAdapter {
    private let engine: AVAudioEngine
    private let upstream: AVAudioNode
    private let downstream: AVAudioNode
    private var effect: (any PluginAppleAudioEffect)?
    private var generation: UInt64 = 0
    public init(engine: AVAudioEngine, upstream: AVAudioNode, downstream: AVAudioNode) {
        self.engine = engine; self.upstream = upstream; self.downstream = downstream
    }
    public func attach(_ effect: any PluginAppleAudioEffect, format: AVAudioFormat, graphGeneration: UInt64) throws {
        guard graphGeneration >= generation, !engine.isRunning else { throw PluginError.staleOperation }
        detach(graphGeneration: graphGeneration)
        try effect.configure(format: format)
        engine.attach(effect.node)
        engine.disconnectNodeOutput(upstream)
        engine.connect(upstream, to: effect.node, format: format)
        engine.connect(effect.node, to: downstream, format: format)
        self.effect = effect; generation = graphGeneration
    }
    public func detach(graphGeneration: UInt64) {
        guard graphGeneration >= generation, !engine.isRunning else { return }
        if let effect {
            effect.reset(.stop)
            engine.disconnectNodeOutput(upstream); engine.disconnectNodeOutput(effect.node)
            engine.detach(effect.node)
            engine.connect(upstream, to: downstream, format: nil)
        }
        effect = nil; generation = graphGeneration
    }
    public func rebuild(format: AVAudioFormat, graphGeneration: UInt64) throws {
        guard graphGeneration >= generation, !engine.isRunning else { throw PluginError.staleOperation }
        if let effect { try attach(effect, format: format, graphGeneration: graphGeneration) }
        generation = graphGeneration
    }
}

@MainActor public final class ReferenceAppleGainEffect: PluginAppleAudioEffect {
    private let equalizer = AVAudioUnitEQ(numberOfBands: 0)
    public var node: AVAudioNode { equalizer }
    public let behavior = PluginDSPBehavior(scope: .postMix)
    public init(gainDecibels: Float = 0) { equalizer.globalGain = min(24, max(-96, gainDecibels.isFinite ? gainDecibels : 0)) }
    public func configure(format: AVAudioFormat) throws {
        guard format.channelCount > 0, format.sampleRate > 0 else { throw PluginError.invalidConfiguration }
    }
    public func reset(_ reason: PluginDSPResetReason) { equalizer.reset() }
    public func setBypassed(_ bypassed: Bool) { equalizer.bypass = bypassed }
}
