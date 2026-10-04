import Foundation
import AVFAudio
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import MusicFreePluginAppleAudioAPI

public enum EqualizerDSPPlugin {
    public static let id = PluginID(rawValue: "builtin.dsp.equalizer")
    public static let frequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var descriptor: PluginDescriptor {
        .init(id: id, name: "Equalizer", kinds: [.dsp], configuration: .init(fields:
            [.init(id: "preamp", title: "Preamp (dB)", kind: .number, minimumNumber: -12, maximumNumber: 12)]
                + frequencies.map { .init(id: String($0), title: "\($0) Hz (dB)", kind: .number, minimumNumber: -12, maximumNumber: 12) }),
            dspPlacements: .init(supported: [.perTrack, .postMix], defaultPlacement: .postMix))
    }
    public static func makeProcessor(_ configuration: PluginInstanceConfiguration) throws -> any PluginDSPProcessor {
        try EqualizerPCMProcessor(configuration: configuration)
    }
    @MainActor public static func makeAppleEffect(_ configuration: PluginInstanceConfiguration) throws -> any PluginAppleAudioEffect {
        try EqualizerAppleEffect(configuration: configuration)
    }
    static func gains(_ configuration: PluginInstanceConfiguration) throws -> (preamp: Double, bands: [Double]) {
        try descriptor.configuration.validate(configuration.values, credentialRecordID: nil)
        func number(_ key: String) -> Double {
            if case .number(let value) = configuration.values[key] { return value }
            return 0
        }
        return (number("preamp"), frequencies.map { number(String($0)) })
    }
}

/// Cascaded one-octave peaking filters. Storage is allocated in prepare, owned
/// by one decoder lane, and never shared with audition or the incoming track.
public struct EqualizerPCMProcessor: PluginDSPProcessor {
    public let behavior: PluginDSPBehavior
    private let gains: [Double]
    private let preamp: Double
    private struct Biquad: Sendable {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        mutating func sample(_ input: Double) -> Double {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }
    }
    private var filters: [Biquad] = []
    private var format: PluginPCMFormat?
    public init(configuration: PluginInstanceConfiguration) throws {
        let settings = try EqualizerDSPPlugin.gains(configuration)
        gains = settings.bands; preamp = pow(10, settings.preamp / 20)
        let placement = try EqualizerDSPPlugin.descriptor.resolvedDSPPlacement(configuration.dspPlacement)
        behavior = .init(scope: placement == .postMix ? .postMix : .perTrack)
    }
    public mutating func prepare(format: PluginPCMFormat) throws {
        self.format = format
        let coefficients = zip(EqualizerDSPPlugin.frequencies, gains).map { frequency, gain -> Biquad in
            guard gain != 0, Double(frequency) < format.sampleRate * 0.49 else { return Biquad() }
            let omega = 2 * Double.pi * Double(frequency) / format.sampleRate
            let sine = sin(omega), cosine = cos(omega), amplitude = pow(10, gain / 40)
            // Keep a margin below Nyquist, where the octave formula becomes singular.
            let alpha = sine * sinh(log(2) / 2 * omega / sine)
            let a0 = 1 + alpha / amplitude
            return Biquad(b0: (1 + alpha * amplitude) / a0, b1: -2 * cosine / a0,
                b2: (1 - alpha * amplitude) / a0, a1: -2 * cosine / a0, a2: (1 - alpha / amplitude) / a0)
        }
        filters = (0..<format.channelCount).flatMap { _ in coefficients }
    }
    public mutating func process(_ buffer: PluginPCMBufferView) throws {
        guard buffer.format == format else { throw PluginError.invalidConfiguration }
        for channel in 0..<buffer.format.channelCount {
            let samples = buffer.channels[channel]
            for frame in 0..<buffer.frameCount {
                var value = Double(samples[frame]) * preamp
                for band in gains.indices { value = filters[channel * gains.count + band].sample(value) }
                samples[frame] = Float(value)
            }
        }
    }
    public mutating func reset(_ reason: PluginDSPResetReason) {
        for index in filters.indices { filters[index].z1 = 0; filters[index].z2 = 0 }
    }
}

@MainActor public final class EqualizerAppleEffect: PluginAppleAudioEffect {
    public let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    public var node: AVAudioNode { equalizer }
    public let behavior = PluginDSPBehavior(scope: .postMix)
    public init(configuration: PluginInstanceConfiguration) throws {
        for (band, frequency) in zip(equalizer.bands, EqualizerDSPPlugin.frequencies) {
            band.filterType = .parametric; band.frequency = Float(frequency)
            band.bandwidth = 1; band.bypass = false
        }
        _ = try update(configuration: configuration)
    }
    public func configure(format: AVAudioFormat) throws {}
    public func reset(_ reason: PluginDSPResetReason) { equalizer.reset() }
    public func setBypassed(_ bypassed: Bool) { equalizer.bypass = bypassed }
    public func update(configuration: PluginInstanceConfiguration) throws -> Bool {
        guard try EqualizerDSPPlugin.descriptor.resolvedDSPPlacement(configuration.dspPlacement) == .postMix else { return false }
        let settings = try EqualizerDSPPlugin.gains(configuration)
        equalizer.globalGain = Float(settings.preamp)
        for (band, gain) in zip(equalizer.bands, settings.bands) { band.gain = Float(gain) }
        return true
    }
}
