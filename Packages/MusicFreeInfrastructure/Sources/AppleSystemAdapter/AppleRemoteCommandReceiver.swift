import Foundation
import PlaybackAPI
import SystemIntegrationAPI

#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
protocol AppleRemoteCommandCenterClient: AnyObject {
    var supportedCommands: Set<RemoteCommandKind> { get }

    func installTarget(
        for command: RemoteCommandKind,
        handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) -> Void
    ) -> AppleRemoteCommandTargetToken?

    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind)
}

@MainActor
private final class PlatformRemoteCommandCenterClient: AppleRemoteCommandCenterClient {
#if canImport(MediaPlayer)
    private let center = MPRemoteCommandCenter.shared()

    var supportedCommands: Set<RemoteCommandKind> {
        Set(RemoteCommandKind.allCases)
    }

    func installTarget(
        for command: RemoteCommandKind,
        handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) -> Void
    ) -> AppleRemoteCommandTargetToken? {
        guard let remoteCommand = remoteCommand(for: command) else {
            return nil
        }

        let target = remoteCommand.addTarget { event in
            guard let playbackCommand = Self.map(command: command, event: event) else {
                return .commandFailed
            }

            Task { @MainActor in
                handler(playbackCommand)
            }
            return .success
        }

        return AppleRemoteCommandTargetToken {
            remoteCommand.removeTarget(target)
        }
    }

    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind) {
        remoteCommand(for: command)?.isEnabled = enabled
    }

    private func remoteCommand(for command: RemoteCommandKind) -> MPRemoteCommand? {
        switch command {
        case .play:
            center.playCommand
        case .pause:
            center.pauseCommand
        case .togglePlayPause:
            center.togglePlayPauseCommand
        case .next:
            center.nextTrackCommand
        case .previous:
            center.previousTrackCommand
        case .seek:
            center.changePlaybackPositionCommand
        case .changeRate:
            center.changePlaybackRateCommand
        }
    }

    private static func map(
        command: RemoteCommandKind,
        event: MPRemoteCommandEvent
    ) -> RemotePlaybackCommand? {
        switch command {
        case .play:
            return .play
        case .pause:
            return .pause
        case .togglePlayPause:
            return .togglePlayPause
        case .next:
            return .next
        case .previous:
            return .previous
        case .seek:
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite,
                  event.positionTime >= 0
            else {
                return nil
            }
            return .seek(to: .seconds(event.positionTime))
        case .changeRate:
            guard let event = event as? MPChangePlaybackRateCommandEvent,
                  event.playbackRate.isFinite,
                  event.playbackRate > 0
            else {
                return nil
            }
            return .changeRate(to: event.playbackRate)
        }
    }
#else
    var supportedCommands: Set<RemoteCommandKind> { [] }

    func installTarget(
        for command: RemoteCommandKind,
        handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) -> Void
    ) -> AppleRemoteCommandTargetToken? {
        nil
    }

    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind) {}
#endif
}

@MainActor
public final class AppleRemoteCommandReceiver: RemoteCommandReceiving {
    public let configuration: AppleSystemConfiguration

    private let client: any AppleRemoteCommandCenterClient
    private let targetStore = RemoteCommandTargetStore()
    private var commandContinuation: AsyncStream<RemotePlaybackCommand>.Continuation?
    private var isDisposed = false

    public private(set) var enabledCommands: Set<RemoteCommandKind> = []
    public private(set) var lastError: AppleSystemAdapterError?

    public init(configuration: AppleSystemConfiguration = .standard) {
        self.configuration = configuration
        self.client = PlatformRemoteCommandCenterClient()
        setEnabledCommands(configuration.commandPolicy)
    }

    init(
        configuration: AppleSystemConfiguration = .standard,
        client: any AppleRemoteCommandCenterClient
    ) {
        self.configuration = configuration
        self.client = client
        setEnabledCommands(configuration.commandPolicy)
    }

    public func makeCommandStream() -> AsyncStream<RemotePlaybackCommand> {
        guard commandContinuation == nil, !isDisposed else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            self.commandContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishCommandStream()
                }
            }
        }
    }

    public func setEnabledCommands(_ commands: Set<RemoteCommandKind>) {
        guard !isDisposed else { return }

        let supported = client.supportedCommands
        let requested = commands.intersection(supported)
        let current = targetStore.registeredCommands

        for command in current.subtracting(requested) {
            _ = targetStore.remove(command)
            client.setEnabled(false, for: command)
        }

        for command in requested.subtracting(current) {
            let token = client.installTarget(for: command) { [weak self] playbackCommand in
                self?.emit(playbackCommand)
            }
            guard let token else {
                lastError = .commandRegistrationFailed(command)
                continue
            }
            targetStore.insert(token, for: command)
            client.setEnabled(true, for: command)
        }

        enabledCommands = targetStore.registeredCommands
        if !commands.subtracting(supported).isEmpty, lastError == nil {
            lastError = .unavailable(
                platform: AppleSystemCapabilityDetector.current.platform,
                capability: .remoteCommands
            )
        }
    }

    public var capabilities: SystemIntegrationCapabilitySnapshot {
        AppleSystemCapabilityDetector.current
    }

    public var registeredCommandCount: Int {
        targetStore.count
    }

    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        let commands = targetStore.registeredCommands
        targetStore.removeAll()
        for command in commands {
            client.setEnabled(false, for: command)
        }
        enabledCommands = []
        finishCommandStream()
    }

    private func emit(_ command: RemotePlaybackCommand) {
        guard !isDisposed else { return }
        guard command.isValid else { return }
        commandContinuation?.yield(command)
    }

    private func finishCommandStream() {
        guard let continuation = commandContinuation else { return }
        commandContinuation = nil
        continuation.finish()
    }

}
