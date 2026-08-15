import Foundation

/// A validated playback speed retained as user intent.
public struct PlaybackRate: Codable, Equatable, Hashable, Sendable, Comparable {
    public static let minimumValue = 0.25
    public static let maximumValue = 4.0

    public let value: Double

    public init(value: Double) throws {
        guard value.isFinite else {
            throw SettingsError.invalidValue(field: "playback.rate", reason: .nonFinite)
        }
        guard (Self.minimumValue...Self.maximumValue).contains(value) else {
            throw SettingsError.invalidValue(field: "playback.rate", reason: .outOfRange)
        }
        self.value = value
    }

    private init(unchecked value: Double) {
        self.value = value
    }

    public static let normal = Self(unchecked: 1.0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(value: container.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A validated equalizer gain in decibels.
public struct EqualizerGain: Codable, Equatable, Hashable, Sendable, Comparable {
    public static let minimumDecibels = -12.0
    public static let maximumDecibels = 12.0

    public let decibels: Double

    public init(decibels: Double) throws {
        guard decibels.isFinite else {
            throw SettingsError.invalidValue(field: "playback.equalizer.gain", reason: .nonFinite)
        }
        guard (Self.minimumDecibels...Self.maximumDecibels).contains(decibels) else {
            throw SettingsError.invalidValue(field: "playback.equalizer.gain", reason: .outOfRange)
        }
        self.decibels = decibels
    }

    private init(unchecked decibels: Double) {
        self.decibels = decibels
    }

    public static let zero = Self(unchecked: 0.0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.decibels < rhs.decibels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(decibels: container.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decibels)
    }
}

/// A frequency and gain pair. The API does not prescribe a fixed band list.
public struct EqualizerBand: Codable, Equatable, Hashable, Sendable {
    public let frequencyHz: Int
    public let gain: EqualizerGain

    public init(frequencyHz: Int, gain: EqualizerGain) throws {
        guard frequencyHz > 0 else {
            throw SettingsError.invalidValue(field: "playback.equalizer.frequencyHz", reason: .outOfRange)
        }
        self.frequencyHz = frequencyHz
        self.gain = gain
    }
}

/// User-configured equalizer intent without assuming an engine-specific band layout.
public struct EqualizerPreferences: Codable, Equatable, Hashable, Sendable {
    public let isEnabled: Bool
    public let preamp: EqualizerGain
    public let bands: [EqualizerBand]

    public init(
        isEnabled: Bool = false,
        preamp: EqualizerGain = .zero,
        bands: [EqualizerBand] = []
    ) throws {
        var frequencies = Set<Int>()
        for band in bands {
            guard frequencies.insert(band.frequencyHz).inserted else {
                throw SettingsError.invalidValue(field: "playback.equalizer.bands", reason: .duplicate)
            }
        }

        self.init(
            uncheckedIsEnabled: isEnabled,
            uncheckedPreamp: preamp,
            uncheckedBands: bands.sorted { $0.frequencyHz < $1.frequencyHz }
        )
    }

    private init(
        uncheckedIsEnabled isEnabled: Bool,
        uncheckedPreamp preamp: EqualizerGain,
        uncheckedBands bands: [EqualizerBand]
    ) {
        self.isEnabled = isEnabled
        self.preamp = preamp
        self.bands = bands
    }

    public static let defaults = Self(
        uncheckedIsEnabled: false,
        uncheckedPreamp: .zero,
        uncheckedBands: []
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case preamp
        case bands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            preamp: try container.decodeIfPresent(EqualizerGain.self, forKey: .preamp) ?? .zero,
            bands: try container.decodeIfPresent([EqualizerBand].self, forKey: .bands) ?? []
        )
    }
}

/// ReplayGain intent. Runtime support is determined outside SettingsAPI.
public enum ReplayGainMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case off
    case track
    case album
}

/// User intent for gapless and crossfade transitions.
@available(macOS 13.0, iOS 16.0, *)
public struct TransitionPreferences: Codable, Equatable, Hashable, Sendable {
    public static let maximumCrossfadeDuration = Duration.seconds(30)

    public let gaplessPlaybackEnabled: Bool
    public let crossfadeDuration: Duration

    public init(
        gaplessPlaybackEnabled: Bool = true,
        crossfadeDuration: Duration = .zero
    ) throws {
        guard crossfadeDuration >= .zero,
              crossfadeDuration <= Self.maximumCrossfadeDuration
        else {
            throw SettingsError.invalidValue(
                field: "playback.transition.crossfadeDuration",
                reason: .outOfRange
            )
        }
        self.init(
            uncheckedGaplessPlaybackEnabled: gaplessPlaybackEnabled,
            uncheckedCrossfadeDuration: crossfadeDuration
        )
    }

    private init(
        uncheckedGaplessPlaybackEnabled gaplessPlaybackEnabled: Bool,
        uncheckedCrossfadeDuration crossfadeDuration: Duration
    ) {
        self.gaplessPlaybackEnabled = gaplessPlaybackEnabled
        self.crossfadeDuration = crossfadeDuration
    }

    public static let defaults = Self(
        uncheckedGaplessPlaybackEnabled: true,
        uncheckedCrossfadeDuration: .zero
    )

    public var isCrossfadeEnabled: Bool {
        crossfadeDuration > .zero
    }

    private enum CodingKeys: String, CodingKey {
        case gaplessPlaybackEnabled
        case crossfadeDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            gaplessPlaybackEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .gaplessPlaybackEnabled
            ) ?? true,
            crossfadeDuration: try container.decodeIfPresent(
                Duration.self,
                forKey: .crossfadeDuration
            ) ?? .zero
        )
    }
}

/// Playback preferences independent of a concrete playback engine.
@available(macOS 13.0, iOS 16.0, *)
public struct PlaybackPreferences: Codable, Equatable, Hashable, Sendable {
    public let rate: PlaybackRate
    public let equalizer: EqualizerPreferences
    public let replayGain: ReplayGainMode
    public let transition: TransitionPreferences
    public let sleepTimer: SleepTimerPreferences

    public init(
        rate: PlaybackRate = .normal,
        equalizer: EqualizerPreferences = .defaults,
        replayGain: ReplayGainMode = .off,
        transition: TransitionPreferences = .defaults,
        sleepTimer: SleepTimerPreferences = .defaults
    ) {
        self.rate = rate
        self.equalizer = equalizer
        self.replayGain = replayGain
        self.transition = transition
        self.sleepTimer = sleepTimer
    }

    public static let defaults = Self()

    /// Compatibility name for callers that describe this value as the default rate.
    public var defaultRate: PlaybackRate {
        rate
    }

    private enum CodingKeys: String, CodingKey {
        case rate
        case equalizer
        case replayGain
        case transition
        case sleepTimer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rate: try container.decodeIfPresent(PlaybackRate.self, forKey: .rate) ?? .normal,
            equalizer: try container.decodeIfPresent(EqualizerPreferences.self, forKey: .equalizer)
                ?? .defaults,
            replayGain: try container.decodeIfPresent(ReplayGainMode.self, forKey: .replayGain) ?? .off,
            transition: try container.decodeIfPresent(TransitionPreferences.self, forKey: .transition)
                ?? .defaults,
            sleepTimer: try container.decodeIfPresent(SleepTimerPreferences.self, forKey: .sleepTimer)
                ?? .defaults
        )
    }
}
