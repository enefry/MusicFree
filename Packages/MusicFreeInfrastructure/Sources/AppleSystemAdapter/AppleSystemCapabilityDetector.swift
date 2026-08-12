import Foundation
import SystemIntegrationAPI

#if os(iOS)
import UIKit
#endif

/// Explicit inputs make capability calculation testable without loading an
/// Apple framework or relying on a simulator's hardware state.
public struct AppleSystemCapabilityInputs: Codable, Equatable, Hashable, Sendable {
    public let audioSession: Bool
    public let interruptionEvents: Bool
    public let routeChangeEvents: Bool
    public let mediaServicesResetEvents: Bool
    public let nowPlaying: Bool
    public let remoteCommands: Bool
    public let backgroundAudio: Bool
    public let lockScreenControls: Bool

    public init(
        audioSession: Bool = false,
        interruptionEvents: Bool = false,
        routeChangeEvents: Bool = false,
        mediaServicesResetEvents: Bool = false,
        nowPlaying: Bool = false,
        remoteCommands: Bool = false,
        backgroundAudio: Bool = false,
        lockScreenControls: Bool = false
    ) {
        self.audioSession = audioSession
        self.interruptionEvents = interruptionEvents
        self.routeChangeEvents = routeChangeEvents
        self.mediaServicesResetEvents = mediaServicesResetEvents
        self.nowPlaying = nowPlaying
        self.remoteCommands = remoteCommands
        self.backgroundAudio = backgroundAudio
        self.lockScreenControls = lockScreenControls
    }
}

/// Detects only the first-version capabilities owned by this adapter.
@MainActor
public enum AppleSystemCapabilityDetector {
    public static var current: SystemIntegrationCapabilitySnapshot {
        snapshot(platform: currentPlatform, inputs: currentInputs)
    }

    public static func snapshot(
        platform: SystemIntegrationPlatform,
        inputs: AppleSystemCapabilityInputs
    ) -> SystemIntegrationCapabilitySnapshot {
        var capabilities: SystemIntegrationCapabilities = []
        if inputs.audioSession {
            capabilities.insert(.audioSession)
        }
        if inputs.interruptionEvents {
            capabilities.insert(.interruptionEvents)
        }
        if inputs.routeChangeEvents {
            capabilities.insert(.routeChangeEvents)
        }
        if inputs.mediaServicesResetEvents {
            capabilities.insert(.mediaServicesResetEvents)
        }
        if inputs.nowPlaying {
            capabilities.insert(.nowPlaying)
        }
        if inputs.remoteCommands {
            capabilities.insert(.remoteCommands)
        }
        if inputs.backgroundAudio {
            capabilities.insert(.backgroundAudio)
        }
        if inputs.lockScreenControls {
            capabilities.insert(.lockScreenControls)
        }

        return SystemIntegrationCapabilitySnapshot(
            platform: platform,
            capabilities: capabilities
        )
    }

    private static var currentPlatform: SystemIntegrationPlatform {
#if os(iOS)
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
#else
        .iOS
#endif
#elseif os(macOS)
        .macOS
#else
        .unknown
#endif
    }

    private static var currentInputs: AppleSystemCapabilityInputs {
#if os(iOS)
        AppleSystemCapabilityInputs(
            audioSession: true,
            interruptionEvents: true,
            routeChangeEvents: true,
            mediaServicesResetEvents: true,
            nowPlaying: canImportMediaPlayer,
            remoteCommands: canImportMediaPlayer,
            backgroundAudio: true,
            lockScreenControls: canImportMediaPlayer
        )
#elseif os(macOS)
        AppleSystemCapabilityInputs(
            nowPlaying: canImportMediaPlayer,
            remoteCommands: canImportMediaPlayer
        )
#else
        AppleSystemCapabilityInputs()
#endif
    }

    private static var canImportMediaPlayer: Bool {
#if canImport(MediaPlayer)
        true
#else
        false
#endif
    }
}
