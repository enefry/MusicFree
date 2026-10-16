import Foundation
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

public enum DeclickDSPPlugin {
    public static let id = PluginID(rawValue: "builtin.dsp.declick")
    public static var descriptor: PluginDescriptor {
        .init(id: id, name: "爆音抑制", kinds: [.dsp], configuration: .init(fields: [
            .init(id: "sensitivity", title: "检测灵敏度 (0–100，默认 35)", kind: .number, minimumNumber: 0, maximumNumber: 100),
            .init(id: "strengthPercent", title: "抑制强度 (0–100%，默认 100%)", kind: .number, minimumNumber: 0, maximumNumber: 100)
        ]), dspPlacements: .init(supported: [.perTrack], defaultPlacement: .perTrack), defaultDSPPriority: 100)
    }
    public static func makeProcessor(_ configuration: PluginInstanceConfiguration) throws -> any PluginDSPProcessor {
        try DeclickPCMProcessor(configuration: configuration)
    }
}

/// A causal short-impulse suppressor, not a declipper or an offline restoration
/// filter. No lookahead, leading silence, delayed tail, or frame-count change.
/// Each channel and each decoder lane keeps independent prediction state.
public struct DeclickPCMProcessor: PluginDSPProcessor {
    public let behavior = PluginDSPBehavior(scope: .perTrack)
    private let sensitivity: Double
    private let wet: Double
    private let thresholdFactor: Double
    private var format: PluginPCMFormat?
    private var states: [Channel] = []
    private var detectorStep = 0.0
    private var peakDecay = 0.0
    private var warmupFrames = 1
    private var burstFrames = 1
    private var protectionFrames = 1

    private struct Channel: Sendable {
        var last = 0.0
        var slope = 0.0
        var residual = 0.002
        var age = 0
        var burst = 0
        var protection = 0
        var peak = 0.0
    }

    public init(configuration: PluginInstanceConfiguration) throws {
        try DeclickDSPPlugin.descriptor.configuration.validate(configuration.values, credentialRecordID: nil)
        _ = try DeclickDSPPlugin.descriptor.resolvedDSPPlacement(configuration.dspPlacement)
        if case .number(let value) = configuration.values["sensitivity"] { sensitivity = value }
        else { sensitivity = 35 }
        if case .number(let value) = configuration.values["strengthPercent"] { wet = value / 100 }
        else { wet = 1 }
        thresholdFactor = 12 - 0.09 * sensitivity
    }

    public mutating func prepare(format: PluginPCMFormat) throws {
        self.format = format
        states = Array(repeating: Channel(), count: format.channelCount)
        detectorStep = -expm1(-1 / (format.sampleRate * 0.01))
        peakDecay = exp(-1 / (format.sampleRate * 0.02))
        warmupFrames = max(2, Int((format.sampleRate * 0.001).rounded()))
        burstFrames = max(1, Int((format.sampleRate * 0.0003).rounded()))
        protectionFrames = max(1, Int((format.sampleRate * 0.004).rounded()))
    }

    public mutating func reset(_ reason: PluginDSPResetReason) {
        for index in states.indices { states[index] = Channel() }
    }

    public mutating func process(_ buffer: PluginPCMBufferView) throws {
        guard buffer.format == format else { throw PluginError.invalidConfiguration }
        // Reject the whole block before changing samples or predictor state.
        for channel in buffer.channels {
            for frame in 0..<buffer.frameCount {
                guard channel[frame].isFinite else { throw PluginError.invalidResponse }
            }
        }
        guard sensitivity > 0, wet > 0 else { return }
        for channel in states.indices {
            let samples = buffer.channels[channel]
            for frame in 0..<buffer.frameCount {
                let input = Double(samples[frame])
                let bound = max(0.002, states[channel].peak)
                let prediction = max(-bound, min(bound, states[channel].last + states[channel].slope))
                let error = abs(input - prediction)
                let threshold = max(0.002, states[channel].residual) * thresholdFactor
                let detects = states[channel].age >= warmupFrames && states[channel].protection == 0 && error > threshold
                if detects && states[channel].burst < burstFrames {
                    // Continue the local slope briefly; damping bounds prediction
                    // during multi-sample corruption. Do not learn from the spike.
                    samples[frame] = Float((1 - wet) * input + wet * prediction)
                    states[channel].last = prediction
                    states[channel].slope *= 0.75
                    states[channel].burst += 1
                } else {
                    if detects {
                        // A sustained change is a new onset, not a short click.
                        // Admit it and relearn instead of flattening a drum/tone.
                        states[channel].protection = protectionFrames
                        states[channel].residual = max(states[channel].residual, error)
                        states[channel].slope = 0
                    } else {
                        states[channel].slope = input - states[channel].last
                        if states[channel].protection > 0 { states[channel].protection -= 1 }
                    }
                    states[channel].last = input
                    states[channel].peak = max(abs(input), states[channel].peak * peakDecay)
                    states[channel].burst = 0
                    states[channel].residual += detectorStep * (error - states[channel].residual)
                }
                if states[channel].age < warmupFrames { states[channel].age += 1 }
            }
        }
    }
}
