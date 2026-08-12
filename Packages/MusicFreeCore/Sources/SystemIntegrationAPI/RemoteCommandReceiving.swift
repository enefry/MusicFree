import Foundation

/// Commands that may be enabled by a system integration adapter.
public enum RemoteCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case seek
    case changeRate

    public static let toggle = Self.togglePlayPause
    public static let changePosition = Self.seek
    public static let rate = Self.changeRate
}

/// A user intent emitted by a remote command receiver.
public enum RemotePlaybackCommand: Codable, Equatable, Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case seek(to: Duration)
    case changeRate(to: Float)

    public static func seek(_ position: Duration) -> Self {
        .seek(to: position)
    }

    public static func changeRate(_ rate: Float) -> Self {
        .changeRate(to: rate)
    }

    public static func rate(_ rate: Float) -> Self {
        .changeRate(to: rate)
    }

    public var kind: RemoteCommandKind {
        switch self {
        case .play:
            .play
        case .pause:
            .pause
        case .togglePlayPause:
            .togglePlayPause
        case .next:
            .next
        case .previous:
            .previous
        case .seek:
            .seek
        case .changeRate:
            .changeRate
        }
    }

    public var seekPosition: Duration? {
        guard case .seek(let position) = self else {
            return nil
        }
        return position
    }

    public var requestedRate: Float? {
        guard case .changeRate(let rate) = self else {
            return nil
        }
        return rate
    }

    public var isValid: Bool {
        switch self {
        case .seek(let position):
            return position >= .zero
        case .changeRate(let rate):
            return rate.isFinite && rate > 0
        case .play, .pause, .togglePlayPause, .next, .previous:
            return true
        }
    }
}

/// The adapter-neutral result vocabulary corresponding to a remote command.
public enum RemoteCommandResult: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case noActionableItem
    case commandFailed
    case unsupported

    public static let handled = Self.success
    public static let noActionableNowPlayingItem = Self.noActionableItem
    public static let failed = Self.commandFailed
}

public typealias RemoteCommandHandlingResult = RemoteCommandResult

/// Receives system remote-control intents without exposing command tokens or
/// framework event objects.
@MainActor
public protocol RemoteCommandReceiving: AnyObject {
    func makeCommandStream() -> AsyncStream<RemotePlaybackCommand>
    func setEnabledCommands(_ commands: Set<RemoteCommandKind>)
}
