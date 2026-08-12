import Foundation
import SystemIntegrationAPI

#if os(iOS)
import AVFAudio
#endif

/// A framework-free injection boundary for audio-session behavior.
@MainActor
protocol AppleAudioSessionClient: AnyObject {
    func configure(using configuration: AppleSystemConfiguration) throws
    func setActive(_ active: Bool) throws
    var routeAvailability: (output: Bool?, input: Bool?) { get }
}

@MainActor
private final class PlatformAudioSessionClient: AppleAudioSessionClient {
#if os(iOS)
    private let session = AVAudioSession.sharedInstance()

    func configure(using configuration: AppleSystemConfiguration) throws {
        try session.setCategory(
            configuration.audioCategory.avCategory,
            mode: configuration.audioMode.avMode,
            options: configuration.audioOptions.avOptions
        )
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active)
    }

    var routeAvailability: (output: Bool?, input: Bool?) {
        let route = session.currentRoute
        return (
            output: !route.outputs.isEmpty,
            input: !route.inputs.isEmpty
        )
    }
#else
    func configure(using configuration: AppleSystemConfiguration) throws {}

    func setActive(_ active: Bool) throws {}

    var routeAvailability: (output: Bool?, input: Bool?) {
        (output: nil, input: nil)
    }
#endif
}

@MainActor
public final class AppleAudioSessionManager: AudioSessionManaging {
    public let configuration: AppleSystemConfiguration

    private let client: any AppleAudioSessionClient
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []
    private var eventContinuation: AsyncStream<AudioSessionEvent>.Continuation?
    private var isConfigured = false
    private var isActive = false

    public private(set) var lastError: AppleSystemAdapterError?

    public init(configuration: AppleSystemConfiguration = .standard) throws {
        self.configuration = try configuration.validated()
        self.client = PlatformAudioSessionClient()
        self.notificationCenter = .default
    }

    init(
        configuration: AppleSystemConfiguration = .standard,
        client: any AppleAudioSessionClient,
        notificationCenter: NotificationCenter = .default
    ) throws {
        self.configuration = try configuration.validated()
        self.client = client
        self.notificationCenter = notificationCenter
    }

    public func configureForPlayback() throws {
        do {
            try client.configure(using: configuration)
            isConfigured = true
            lastError = nil
        } catch let error as AppleSystemAdapterError {
            lastError = error
            throw error
        } catch {
            lastError = .audioSessionConfigurationFailed
            throw AppleSystemAdapterError.audioSessionConfigurationFailed
        }
    }

    public func activate() async throws {
        guard !isActive else { return }

        if !isConfigured {
            try configureForPlayback()
        }

        do {
            try client.setActive(true)
        } catch let error as AppleSystemAdapterError {
            lastError = error
            throw error
        } catch {
            lastError = .audioSessionActivationFailed
            throw AppleSystemAdapterError.audioSessionActivationFailed
        }

        isActive = true
        registerObserversIfNeeded()
    }

    public func deactivate() async {
        let hadLifecycle = isActive || !observerTokens.isEmpty
        removeObservers()

        if hadLifecycle {
            do {
                try client.setActive(false)
            } catch let error as AppleSystemAdapterError {
                lastError = error
            } catch {
                lastError = .audioSessionDeactivationFailed
            }
        }

        isActive = false
        finishEventStream()
    }

    public func makeEventStream() -> AsyncStream<AudioSessionEvent> {
        guard eventContinuation == nil else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            self.eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishEventStream()
                }
            }
        }
    }

    public var capabilities: SystemIntegrationCapabilitySnapshot {
        AppleSystemCapabilityDetector.current
    }

    public func dispose() async {
        await deactivate()
    }

    private func finishEventStream() {
        guard let continuation = eventContinuation else { return }
        eventContinuation = nil
        continuation.finish()
    }

    private func emit(_ event: AudioSessionEvent) {
        guard isActive else { return }
        eventContinuation?.yield(event)
    }

    private func registerObserversIfNeeded() {
#if os(iOS)
        guard observerTokens.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()
        observerTokens = [
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let userInfo = notification.userInfo
                let typeRawValue = AppleAudioSessionEventMapper.unsignedValue(
                    userInfo?[AVAudioSessionInterruptionTypeKey]
                )
                let optionsRawValue = AppleAudioSessionEventMapper.unsignedValue(
                    userInfo?[AVAudioSessionInterruptionOptionKey]
                ) ?? 0
                Task { @MainActor [weak self] in
                    guard let typeRawValue else { return }
                    self?.handleInterruption(
                        typeRawValue: typeRawValue,
                        optionsRawValue: optionsRawValue
                    )
                }
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let reasonRawValue = AppleAudioSessionEventMapper.unsignedValue(
                    notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                )
                Task { @MainActor [weak self] in
                    guard let reasonRawValue else { return }
                    self?.handleRouteChange(reasonRawValue: reasonRawValue)
                }
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            },
        ]
#endif
    }

    private func removeObservers() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll(keepingCapacity: false)
    }

    func handleMediaServicesReset() {
        guard isActive else { return }
        isConfigured = false
        isActive = false
        eventContinuation?.yield(.mediaServicesReset)
    }

#if os(iOS)
    private func handleInterruption(
        typeRawValue: UInt,
        optionsRawValue: UInt
    ) {
        if let event = AppleAudioSessionEventMapper.interruption(
            typeRawValue: typeRawValue,
            optionsRawValue: optionsRawValue
        ) {
            emit(event)
        }
    }

    private func handleRouteChange(reasonRawValue: UInt) {
        let availability = client.routeAvailability
        emit(
            AppleAudioSessionEventMapper.routeChange(
                reasonRawValue: reasonRawValue,
                outputAvailable: availability.output,
                inputAvailable: availability.input
            )
        )
    }
#endif

}

#if os(iOS)
private extension AppleAudioSessionCategory {
    var avCategory: AVAudioSession.Category {
        switch self {
        case .playback:
            .playback
        }
    }
}

private extension AppleAudioSessionMode {
    var avMode: AVAudioSession.Mode {
        switch self {
        case .default:
            .default
        case .moviePlayback:
            .moviePlayback
        case .spokenAudio:
            .spokenAudio
        }
    }
}

private extension AppleAudioSessionOptions {
    var avOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = []
        if contains(.allowBluetooth) {
            options.insert(.allowBluetoothHFP)
        }
        if contains(.allowBluetoothA2DP) {
            options.insert(.allowBluetoothA2DP)
        }
        if contains(.allowAirPlay) {
            options.insert(.allowAirPlay)
        }
        if contains(.mixWithOthers) {
            options.insert(.mixWithOthers)
        }
        if contains(.duckOthers) {
            options.insert(.duckOthers)
        }
        return options
    }
}
#endif
