import Foundation

/// A runtime platform label supplied by the system adapter.
public enum SystemIntegrationPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case iOS
    case iPadOS
    case macOS
    case unknown

    public static let ios = Self.iOS
    public static let ipadOS = Self.iPadOS
    public static let mac = Self.macOS
}

/// Capabilities exposed by a concrete system integration adapter.
public struct SystemIntegrationCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let audioSession = Self(rawValue: 1 << 0)
    public static let interruptionEvents = Self(rawValue: 1 << 1)
    public static let routeChangeEvents = Self(rawValue: 1 << 2)
    public static let mediaServicesResetEvents = Self(rawValue: 1 << 3)
    public static let nowPlaying = Self(rawValue: 1 << 4)
    public static let remoteCommands = Self(rawValue: 1 << 5)
    public static let backgroundAudio = Self(rawValue: 1 << 6)
    public static let lockScreenControls = Self(rawValue: 1 << 7)

    public static let audioSessionEvents: Self = [
        .interruptionEvents,
        .routeChangeEvents,
        .mediaServicesResetEvents,
    ]

    public static let all: Self = [
        .audioSession,
        .audioSessionEvents,
        .nowPlaying,
        .remoteCommands,
        .backgroundAudio,
        .lockScreenControls,
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

/// A capability boundary that can be passed to AppServices without importing
/// UIKit, AVFAudio, or MediaPlayer.
public struct SystemIntegrationCapabilitySnapshot: Codable, Equatable, Hashable, Sendable {
    public let platform: SystemIntegrationPlatform
    public let capabilities: SystemIntegrationCapabilities

    public init(
        platform: SystemIntegrationPlatform = .unknown,
        capabilities: SystemIntegrationCapabilities = []
    ) {
        self.platform = platform
        self.capabilities = capabilities
    }

    public func supports(_ required: SystemIntegrationCapabilities) -> Bool {
        capabilities.isSuperset(of: required)
    }
}
