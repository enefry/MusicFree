import Foundation
import SystemIntegrationAPI

/// The audio-session category exposed by the Apple adapter without leaking
/// AVFAudio types into the application boundary.
public enum AppleAudioSessionCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case playback
}

/// The audio-session mode exposed by the Apple adapter without leaking
/// AVFAudio types into the application boundary.
public enum AppleAudioSessionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case `default`
    case moviePlayback
    case spokenAudio
}

/// The small, stable subset of AVAudioSession category options needed by the
/// first long-form playback integration.
public struct AppleAudioSessionOptions: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let allowBluetooth = Self(rawValue: 1 << 0)
    public static let allowBluetoothA2DP = Self(rawValue: 1 << 1)
    public static let allowAirPlay = Self(rawValue: 1 << 2)
    public static let mixWithOthers = Self(rawValue: 1 << 3)
    public static let duckOthers = Self(rawValue: 1 << 4)

    // Output-only playback supports Bluetooth A2DP and AirPlay implicitly.
    // Passing their route overrides with AVAudioSession.Category.playback is
    // rejected by AVAudioSession as paramErr on physical devices.
    public static let longFormPlayback: Self = []

    public static let all: Self = [
        .allowBluetooth,
        .allowBluetoothA2DP,
        .allowAirPlay,
        .mixWithOthers,
        .duckOthers,
    ]

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt64.self))
    }
}

/// Configuration for the first Apple system-integration implementation.
/// Framework-specific values are selected only by the adapter's private
/// platform wrappers.
public struct AppleSystemConfiguration: Codable, Equatable, Hashable, Sendable {
    public let audioCategory: AppleAudioSessionCategory
    public let audioMode: AppleAudioSessionMode
    public let audioOptions: AppleAudioSessionOptions
    public let commandPolicy: Set<RemoteCommandKind>

    public init(
        audioCategory: AppleAudioSessionCategory = .playback,
        audioMode: AppleAudioSessionMode = .default,
        audioOptions: AppleAudioSessionOptions = .longFormPlayback,
        commandPolicy: Set<RemoteCommandKind> = Set(RemoteCommandKind.allCases)
    ) {
        self.audioCategory = audioCategory
        self.audioMode = audioMode
        self.audioOptions = audioOptions
        self.commandPolicy = commandPolicy
    }

    public static let standard = Self()

    /// Validates relationships that cannot be represented by the option set
    /// itself before a platform wrapper touches AVFAudio.
    public func validated() throws -> Self {
        let unsupportedPlaybackRouteOverrides: AppleAudioSessionOptions = [
            .allowBluetooth,
            .allowBluetoothA2DP,
            .allowAirPlay,
        ]
        guard audioOptions.intersection(unsupportedPlaybackRouteOverrides).isEmpty else {
            throw AppleSystemAdapterError.invalidConfiguration
        }
        guard audioOptions.contains(.duckOthers) == false
            || audioOptions.contains(.mixWithOthers)
        else {
            throw AppleSystemAdapterError.invalidConfiguration
        }
        return self
    }
}
