import Foundation
import MusicDomain

/// Errors that can be reported by a concrete system integration adapter.
/// Underlying framework errors stay inside the adapter and are represented by
/// one of these stable categories at the API boundary.
public enum SystemIntegrationError: Error, Codable, Equatable, Hashable, Sendable,
    LocalizedError, CustomStringConvertible, CustomReflectable
{
    case audioSessionConfigurationFailed
    case audioSessionActivationFailed
    case audioSessionDeactivationFailed
    case commandRegistrationFailed(command: RemoteCommandKind)
    case nowPlayingPublicationFailed
    case nowPlayingClearFailed
    case unsupportedCapability(SystemIntegrationCapabilities)
    case invalidSnapshot(field: String)
    case unknown(code: String)

    public var isRetryable: Bool {
        switch self {
        case .audioSessionConfigurationFailed,
             .audioSessionActivationFailed,
             .audioSessionDeactivationFailed,
             .commandRegistrationFailed,
             .nowPlayingPublicationFailed,
             .nowPlayingClearFailed,
             .unknown:
            return true
        case .unsupportedCapability, .invalidSnapshot:
            return false
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .audioSessionConfigurationFailed:
            "audio-session-configuration-failed"
        case .audioSessionActivationFailed:
            "audio-session-activation-failed"
        case .audioSessionDeactivationFailed:
            "audio-session-deactivation-failed"
        case .commandRegistrationFailed:
            "remote-command-registration-failed"
        case .nowPlayingPublicationFailed:
            "now-playing-publication-failed"
        case .nowPlayingClearFailed:
            "now-playing-clear-failed"
        case .unsupportedCapability:
            "unsupported-system-integration-capability"
        case .invalidSnapshot:
            "invalid-now-playing-snapshot"
        case .unknown:
            "unknown-system-integration-error"
        }
    }

    public var failureReason: String {
        switch self {
        case .audioSessionConfigurationFailed:
            "The audio session could not be configured."
        case .audioSessionActivationFailed:
            "The audio session could not be activated."
        case .audioSessionDeactivationFailed:
            "The audio session could not be deactivated."
        case .commandRegistrationFailed(let command):
            "The remote command \(command.rawValue) could not be registered."
        case .nowPlayingPublicationFailed:
            "Now Playing information could not be published."
        case .nowPlayingClearFailed:
            "Now Playing information could not be cleared."
        case .unsupportedCapability:
            "The requested system integration capability is unavailable."
        case .invalidSnapshot(let field):
            "The Now Playing snapshot field \(Self.redacted(field)) is invalid."
        case .unknown:
            "The system integration operation could not be completed."
        }
    }

    public var errorDescription: String? {
        failureReason
    }

    public var description: String {
        "SystemIntegrationError(\(diagnosticCode))"
    }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .audioSessionConfigurationFailed:
            try container.encode("audioSessionConfigurationFailed", forKey: .kind)
        case .audioSessionActivationFailed:
            try container.encode("audioSessionActivationFailed", forKey: .kind)
        case .audioSessionDeactivationFailed:
            try container.encode("audioSessionDeactivationFailed", forKey: .kind)
        case .commandRegistrationFailed(let command):
            try container.encode("commandRegistrationFailed", forKey: .kind)
            try container.encode(command, forKey: .command)
        case .nowPlayingPublicationFailed:
            try container.encode("nowPlayingPublicationFailed", forKey: .kind)
        case .nowPlayingClearFailed:
            try container.encode("nowPlayingClearFailed", forKey: .kind)
        case .unsupportedCapability(let capabilities):
            try container.encode("unsupportedCapability", forKey: .kind)
            try container.encode(capabilities.rawValue, forKey: .capabilityRawValue)
        case .invalidSnapshot(let field):
            try container.encode("invalidSnapshot", forKey: .kind)
            try container.encode(Self.redacted(field), forKey: .field)
        case .unknown(let code):
            try container.encode("unknown", forKey: .kind)
            try container.encode(Self.redacted(code), forKey: .code)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "audioSessionConfigurationFailed":
            self = .audioSessionConfigurationFailed
        case "audioSessionActivationFailed":
            self = .audioSessionActivationFailed
        case "audioSessionDeactivationFailed":
            self = .audioSessionDeactivationFailed
        case "commandRegistrationFailed":
            self = .commandRegistrationFailed(
                command: try container.decode(RemoteCommandKind.self, forKey: .command)
            )
        case "nowPlayingPublicationFailed":
            self = .nowPlayingPublicationFailed
        case "nowPlayingClearFailed":
            self = .nowPlayingClearFailed
        case "unsupportedCapability":
            self = .unsupportedCapability(
                SystemIntegrationCapabilities(
                    rawValue: try container.decode(UInt64.self, forKey: .capabilityRawValue)
                )
            )
        case "invalidSnapshot":
            self = .invalidSnapshot(
                field: Self.redacted(try container.decode(String.self, forKey: .field))
            )
        case "unknown":
            self = .unknown(
                code: Self.redacted(try container.decode(String.self, forKey: .code))
            )
        default:
            self = .unknown(code: Self.redacted(kind))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case capabilityRawValue
        case field
        case code
    }

    private static func redacted(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "field"
        }
        if normalized.contains("/") || normalized.contains("\\") || normalized.count > 64 {
            return "field"
        }
        return normalized
    }
}
