import Foundation
import SystemIntegrationAPI

/// Stable adapter errors. Apple framework error values never cross this
/// boundary and are intentionally reduced to actionable categories.
public enum AppleSystemAdapterError: Error, Codable, Equatable, Hashable, Sendable,
    LocalizedError, CustomStringConvertible
{
    case invalidConfiguration
    case unavailable(platform: SystemIntegrationPlatform, capability: SystemIntegrationCapabilities)
    case audioSessionConfigurationFailed
    case audioSessionActivationFailed
    case audioSessionDeactivationFailed
    case commandRegistrationFailed(RemoteCommandKind)
    case nowPlayingPublicationFailed
    case nowPlayingClearFailed
    case invalidArtwork

    public var diagnosticCode: String {
        switch self {
        case .invalidConfiguration:
            "invalid-configuration"
        case .unavailable:
            "unavailable-on-platform"
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
        case .invalidArtwork:
            "invalid-artwork"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .invalidConfiguration, .unavailable, .invalidArtwork:
            false
        case .audioSessionConfigurationFailed,
             .audioSessionActivationFailed,
             .audioSessionDeactivationFailed,
             .commandRegistrationFailed,
             .nowPlayingPublicationFailed,
             .nowPlayingClearFailed:
            true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Apple system integration configuration is invalid."
        case .unavailable:
            "The requested Apple system integration capability is unavailable."
        case .audioSessionConfigurationFailed:
            "The Apple audio session could not be configured."
        case .audioSessionActivationFailed:
            "The Apple audio session could not be activated."
        case .audioSessionDeactivationFailed:
            "The Apple audio session could not be deactivated."
        case .commandRegistrationFailed(let command):
            "The Apple remote command \(command.rawValue) could not be registered."
        case .nowPlayingPublicationFailed:
            "Now Playing information could not be published."
        case .nowPlayingClearFailed:
            "Now Playing information could not be cleared."
        case .invalidArtwork:
            "The Now Playing artwork could not be decoded."
        }
    }

    public var description: String {
        "AppleSystemAdapterError(\(diagnosticCode))"
    }

    public var systemIntegrationError: SystemIntegrationError {
        switch self {
        case .invalidConfiguration:
            .unknown(code: diagnosticCode)
        case .unavailable(_, let capability):
            .unsupportedCapability(capability)
        case .audioSessionConfigurationFailed:
            .audioSessionConfigurationFailed
        case .audioSessionActivationFailed:
            .audioSessionActivationFailed
        case .audioSessionDeactivationFailed:
            .audioSessionDeactivationFailed
        case .commandRegistrationFailed(let command):
            .commandRegistrationFailed(command: command)
        case .nowPlayingPublicationFailed:
            .nowPlayingPublicationFailed
        case .nowPlayingClearFailed:
            .nowPlayingClearFailed
        case .invalidArtwork:
            .nowPlayingPublicationFailed
        }
    }
}
