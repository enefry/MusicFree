import Foundation

/// The two stable phases of a system audio interruption.
public enum AudioSessionInterruption: Codable, Equatable, Hashable, Sendable {
    case began
    case ended(shouldResume: Bool)

    public var shouldResume: Bool {
        switch self {
        case .began:
            return false
        case .ended(let shouldResume):
            return shouldResume
        }
    }

    public var isBeginning: Bool {
        if case .began = self {
            return true
        }
        return false
    }
}

/// Platform-neutral reasons for an audio output route change.
public enum AudioRouteChangeReason: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
}

/// A route change contains only facts useful to the playback coordinator.
/// Concrete route descriptions remain inside the system adapter.
public struct AudioRouteChange: Codable, Equatable, Hashable, Sendable {
    public let reason: AudioRouteChangeReason
    public let isOutputAvailable: Bool?
    public let isInputAvailable: Bool?

    public init(
        reason: AudioRouteChangeReason,
        isOutputAvailable: Bool? = nil,
        isInputAvailable: Bool? = nil
    ) {
        self.reason = reason
        self.isOutputAvailable = isOutputAvailable
        self.isInputAvailable = isInputAvailable
    }

    public var hasOutput: Bool? {
        isOutputAvailable
    }

    public var hasInput: Bool? {
        isInputAvailable
    }

    public var isOldDeviceUnavailable: Bool {
        reason == .oldDeviceUnavailable
    }
}

/// Events emitted by an audio-session adapter.
public enum AudioSessionEvent: Codable, Equatable, Hashable, Sendable {
    case interruption(AudioSessionInterruption)
    case routeChanged(AudioRouteChange)
    case mediaServicesReset

    public static var interruptionBegan: Self {
        .interruption(.began)
    }

    public static func interruptionEnded(shouldResume: Bool) -> Self {
        .interruption(.ended(shouldResume: shouldResume))
    }

    public static func routeChange(_ change: AudioRouteChange) -> Self {
        .routeChanged(change)
    }

    public static var mediaReset: Self {
        .mediaServicesReset
    }

    public var interruptionDetails: AudioSessionInterruption? {
        guard case .interruption(let interruption) = self else {
            return nil
        }
        return interruption
    }

    public var routeChangeDetails: AudioRouteChange? {
        guard case .routeChanged(let change) = self else {
            return nil
        }
        return change
    }

    public var isMediaServicesReset: Bool {
        if case .mediaServicesReset = self {
            return true
        }
        return false
    }
}
