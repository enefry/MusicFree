import Foundation
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

public enum StereoBalanceDSPPlugin {
    public static let id = PluginID(rawValue: "builtin.dsp.stereoBalance")
    public static var descriptor: PluginDescriptor {
        .init(id: id, name: "声道均衡", kinds: [.dsp], configuration: .init(fields: [
            .init(id: "strengthPercent", title: "均衡强度 (%)", kind: .number, minimumNumber: 0, maximumNumber: 100),
            .init(id: "automatic", title: "自动调整", kind: .flag)
        ]), dspPlacements: .init(supported: [.perTrack], defaultPlacement: .perTrack), defaultDSPPriority: 200)
    }
    public static func makeProcessor(_ configuration: PluginInstanceConfiguration) throws -> any PluginDSPProcessor {
        try StereoBalancePCMProcessor(configuration: configuration)
    }
}

/// Persist the displayed percentage; convert to a cross-mix coefficient once.
public struct StereoBalanceParameters: Sendable, Equatable {
    public let strengthPercent: Double
    public let automatic: Bool
    public var maximumMixRatio: Double { strengthPercent / 200 }

    public init(configuration: PluginInstanceConfiguration) throws {
        try StereoBalanceDSPPlugin.descriptor.configuration.validate(configuration.values, credentialRecordID: nil)
        _ = try StereoBalanceDSPPlugin.descriptor.resolvedDSPPlacement(configuration.dspPlacement)
        if case .number(let value) = configuration.values["strengthPercent"] { strengthPercent = value }
        else { strengthPercent = 20 }
        if case .flag(let value) = configuration.values["automatic"] { automatic = value }
        else { automatic = true }
    }
}

/// Value state owned by one serial decoder lane. No allocation, locks or I/O in process.
public struct StereoBalancePCMProcessor: PluginDSPProcessor {
    public let behavior = PluginDSPBehavior(scope: .perTrack)
    private let parameters: StereoBalanceParameters
    private var format: PluginPCMFormat?
    private var detectorStep = 0.0
    private var attackStep = 0.0
    private var releaseStep = 0.0
    private var controlFrames = 1
    private var untilControl = 0
    private var leftPower = 0.0
    private var rightPower = 0.0
    private var crossPower = 0.0
    private var targetMix = 0.0
    private var mix = 0.0
    private var hasSignal = false
    private static let targetRatio = pow(10.0, 6.0 / 10)
    private static let energyFloor = pow(10.0, -3.0 / 10)

    public init(configuration: PluginInstanceConfiguration) throws {
        parameters = try StereoBalanceParameters(configuration: configuration)
    }
    public mutating func prepare(format: PluginPCMFormat) throws {
        self.format = format
        detectorStep = -expm1(-1 / (format.sampleRate * 0.1))
        attackStep = detectorStep
        releaseStep = -expm1(-1 / (format.sampleRate * 1.5))
        controlFrames = max(1, Int((format.sampleRate * 0.01).rounded()))
        reset(.reconfigure)
    }
    public mutating func reset(_ reason: PluginDSPResetReason) {
        leftPower = 0; rightPower = 0; crossPower = 0
        mix = 0; targetMix = 0; untilControl = 0; hasSignal = false
    }
    public mutating func process(_ buffer: PluginPCMBufferView) throws {
        guard buffer.format == format else { throw PluginError.invalidConfiguration }
        guard buffer.format.channelCount == 2, parameters.maximumMixRatio > 0 else { return }
        let left = buffer.channels[0], right = buffer.channels[1]
        // Validate the whole block before mutating either samples or detector state.
        for frame in 0..<buffer.frameCount {
            guard left[frame].isFinite, right[frame].isFinite else { throw PluginError.invalidResponse }
        }
        for frame in 0..<buffer.frameCount {
            let l = Double(left[frame]), r = Double(right[frame])
            let p: Double
            if parameters.automatic {
                leftPower += detectorStep * (l * l - leftPower)
                rightPower += detectorStep * (r * r - rightPower)
                crossPower += detectorStep * (l * r - crossPower)
                if (leftPower + rightPower) * 0.5 > 1e-5 {
                    if !hasSignal {
                        // Protect a one-sided opening without mixing a balanced/anti-phase opening.
                        targetMix = desiredMix()
                        mix = targetMix; hasSignal = true; untilControl = controlFrames
                    } else if untilControl <= 0 {
                        targetMix = desiredMix(); untilControl = controlFrames
                    }
                    mix += (targetMix > mix ? attackStep : releaseStep) * (targetMix - mix)
                }
                untilControl -= 1
                p = min(parameters.maximumMixRatio, max(0, mix))
            } else { p = parameters.maximumMixRatio }
            if p > 0, l != r {
                left[frame] = Float((1 - p) * l + p * r)
                right[frame] = Float((1 - p) * r + p * l)
            }
        }
    }

    private func desiredMix() -> Double {
        let total = leftPower + rightPower
        guard total > 0 else { return 0 }
        let high = max(leftPower, rightPower) / total
        let low = min(leftPower, rightPower) / total
        let cross = min(sqrt(high * low), max(-sqrt(high * low), crossPower / total))
        let ratio = Self.targetRatio
        guard high > ratio * low else { return 0 }
        // Solve P_high(p) - ratio * P_low(p) = 0. The positive root is
        // stable even when the weak channel is silent; no monotonicity assumption.
        let differencePower = max(0, 1 - 2 * cross)
        let a = (1 - ratio) * differencePower
        let b = -2 * high + 2 * cross - ratio * (-2 * low + 2 * cross)
        let c = high - ratio * low
        let denominator = sqrt(max(0, b * b - 4 * a * c)) - b
        guard denominator > 0 else { return 0 }
        let goal = 2 * c / denominator
        // Total output power / input power = 1 - 2p(1-p)(1-2C).
        let allowedProduct = (1 - Self.energyFloor) / (2 * max(differencePower, 1e-20))
        let phaseLimit = allowedProduct >= 0.25 ? 0.5 : (1 - sqrt(max(0, 1 - 4 * allowedProduct))) / 2
        let p = min(parameters.maximumMixRatio, min(goal, phaseLimit))
        let own = 1 - p
        let highOut = own * own * high + p * p * low + 2 * own * p * cross
        let lowOut = own * own * low + p * p * high + 2 * own * p * cross
        // Some anti-phase mixtures initially worsen the imbalance. Leave them alone.
        guard lowOut > 0, highOut * low < high * lowOut else { return 0 }
        return max(0, p)
    }
}
