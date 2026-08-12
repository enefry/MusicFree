import Foundation
import MusicDomain
import PlaybackAPI
import SystemIntegrationAPI

public struct FakeAudioSessionScript: Sendable {
    public var configurationError: SystemIntegrationError?
    public var activationError: SystemIntegrationError?
    public var deactivationError: SystemIntegrationError?

    public init(
        configurationError: SystemIntegrationError? = nil,
        activationError: SystemIntegrationError? = nil,
        deactivationError: SystemIntegrationError? = nil
    ) {
        self.configurationError = configurationError
        self.activationError = activationError
        self.deactivationError = deactivationError
    }
}

/// Main-actor audio-session fake with one event subscription and explicit
/// lifecycle state.
@MainActor
public final class FakeAudioSessionManager: AudioSessionManaging {
    public var script: FakeAudioSessionScript
    public private(set) var isConfigured = false
    public private(set) var isActive = false
    public private(set) var configureCallCount = 0
    public private(set) var activateCallCount = 0
    public private(set) var deactivateCallCount = 0
    public private(set) var lastError: SystemIntegrationError?
    public private(set) var subscriptionError: TestSupportError?

    private var eventContinuation: AsyncStream<AudioSessionEvent>.Continuation?
    private var eventSubscriptionID: UUID?

    public init(script: FakeAudioSessionScript = .init()) {
        self.script = script
    }

    public func configureForPlayback() throws {
        configureCallCount += 1
        if let error = script.configurationError {
            lastError = error
            throw error
        }
        isConfigured = true
    }

    public func activate() async throws {
        activateCallCount += 1
        guard isConfigured else {
            lastError = .audioSessionConfigurationFailed
            throw SystemIntegrationError.audioSessionConfigurationFailed
        }
        if let error = script.activationError {
            lastError = error
            throw error
        }
        isActive = true
    }

    public func deactivate() async {
        deactivateCallCount += 1
        if let error = script.deactivationError {
            lastError = error
        }
        isActive = false
    }

    public func makeEventStream() -> AsyncStream<AudioSessionEvent> {
        guard eventContinuation == nil else {
            subscriptionError = .duplicateActiveSubscription
            return AsyncStream { $0.finish() }
        }
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            self.eventSubscriptionID = subscriptionID
            self.eventContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard self?.eventSubscriptionID == subscriptionID else { return }
                    self?.eventContinuation = nil
                    self?.eventSubscriptionID = nil
                }
            }
        }
    }

    public func emit(_ event: AudioSessionEvent) {
        eventContinuation?.yield(event)
    }

    public func finishEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventSubscriptionID = nil
    }

    public func activeEventSubscription() -> Bool {
        eventContinuation != nil
    }
}

/// Records normalized Now Playing values without importing MediaPlayer.
@MainActor
public final class FakeNowPlayingPublisher: NowPlayingPublishing {
    public var publicationError: SystemIntegrationError?
    public var clearError: SystemIntegrationError?
    public private(set) var currentSnapshot: NowPlayingSnapshot?
    public private(set) var publishedSnapshots: [NowPlayingSnapshot] = []
    public private(set) var publishCallCount = 0
    public private(set) var clearCallCount = 0
    public private(set) var lastError: SystemIntegrationError?

    public init(
        publicationError: SystemIntegrationError? = nil,
        clearError: SystemIntegrationError? = nil
    ) {
        self.publicationError = publicationError
        self.clearError = clearError
    }

    public func publish(_ snapshot: NowPlayingSnapshot) {
        publishCallCount += 1
        guard publicationError == nil else {
            lastError = publicationError
            return
        }
        currentSnapshot = snapshot
        publishedSnapshots.append(snapshot)
    }

    public func clear() {
        clearCallCount += 1
        guard clearError == nil else {
            lastError = clearError
            return
        }
        currentSnapshot = nil
    }

    public func resetCallHistory() {
        publishedSnapshots.removeAll()
        publishCallCount = 0
        clearCallCount = 0
        lastError = nil
    }
}

/// A main-actor remote command receiver. Commands are emitted only when they
/// are valid and enabled, matching the adapter boundary instead of allowing a
/// fake to bypass command registration.
@MainActor
public final class FakeRemoteCommandReceiver: RemoteCommandReceiving {
    public private(set) var enabledCommands: Set<RemoteCommandKind> = []
    public private(set) var enabledCommandHistory: [Set<RemoteCommandKind>] = []
    public private(set) var emittedCommands: [RemotePlaybackCommand] = []
    public private(set) var droppedCommands: [RemotePlaybackCommand] = []
    public private(set) var subscriptionError: TestSupportError?

    private var commandContinuation: AsyncStream<RemotePlaybackCommand>.Continuation?
    private var commandSubscriptionID: UUID?

    public init(enabledCommands: Set<RemoteCommandKind> = []) {
        self.enabledCommands = enabledCommands
    }

    public func makeCommandStream() -> AsyncStream<RemotePlaybackCommand> {
        guard commandContinuation == nil else {
            subscriptionError = .duplicateActiveSubscription
            return AsyncStream { $0.finish() }
        }
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            self.commandSubscriptionID = subscriptionID
            self.commandContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard self?.commandSubscriptionID == subscriptionID else { return }
                    self?.commandContinuation = nil
                    self?.commandSubscriptionID = nil
                }
            }
        }
    }

    public func setEnabledCommands(_ commands: Set<RemoteCommandKind>) {
        enabledCommands = commands
        enabledCommandHistory.append(commands)
    }

    @discardableResult
    public func emit(_ command: RemotePlaybackCommand, ignoringEnabled: Bool = false) -> Bool {
        guard command.isValid,
              ignoringEnabled || enabledCommands.contains(command.kind)
        else {
            droppedCommands.append(command)
            return false
        }
        emittedCommands.append(command)
        commandContinuation?.yield(command)
        return true
    }

    public func finishCommands() {
        commandContinuation?.finish()
        commandContinuation = nil
        commandSubscriptionID = nil
    }

    public func activeCommandSubscription() -> Bool {
        commandContinuation != nil
    }

    public func resetCallHistory() {
        enabledCommandHistory.removeAll()
        emittedCommands.removeAll()
        droppedCommands.removeAll()
    }
}
