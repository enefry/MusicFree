import Foundation
import MusicDomain
import SystemIntegrationAPI
import Testing

#if os(iOS) && canImport(MediaPlayer)
import Dispatch
@preconcurrency import MediaPlayer
import UIKit
#endif

@testable import AppleSystemAdapter

@Test("Standard playback configuration uses implicit output routes")
func standardPlaybackConfigurationUsesImplicitRoutes() throws {
    let configuration = try AppleSystemConfiguration.standard.validated()

    #expect(configuration.audioCategory == .playback)
    #expect(configuration.audioOptions.isEmpty)
}

@Test("Playback configuration rejects input-category route overrides")
func playbackConfigurationRejectsRouteOverrides() {
    #expect(throws: AppleSystemAdapterError.self) {
        try AppleSystemConfiguration(audioOptions: [.allowBluetooth]).validated()
    }
    #expect(throws: AppleSystemAdapterError.self) {
        try AppleSystemConfiguration(audioOptions: [.allowBluetoothA2DP]).validated()
    }
    #expect(throws: AppleSystemAdapterError.self) {
        try AppleSystemConfiguration(audioOptions: [.allowAirPlay]).validated()
    }
}

@Test("Apple audio notification values map to stable API events")
@MainActor
func appleAudioSessionEventMapping() {
    #expect(
        AppleAudioSessionEventMapper.interruption(
            typeRawValue: AppleAudioSessionEventMapper.interruptionBeganRawValue,
            optionsRawValue: 0
        ) == .interruption(.began)
    )
    #expect(
        AppleAudioSessionEventMapper.interruption(
            typeRawValue: AppleAudioSessionEventMapper.interruptionEndedRawValue,
            optionsRawValue: AppleAudioSessionEventMapper.interruptionShouldResumeMask
        ) == .interruption(.ended(shouldResume: true))
    )
    #expect(
        AppleAudioSessionEventMapper.routeReason(
            rawValue: AppleAudioSessionEventMapper.routeOldDeviceUnavailableRawValue
        ) == .oldDeviceUnavailable
    )
    #expect(
        AppleAudioSessionEventMapper.routeReason(rawValue: 999) == .unknown
    )
    #expect(
        AppleAudioSessionEventMapper.routeChange(
            reasonRawValue: AppleAudioSessionEventMapper.routeNewDeviceAvailableRawValue,
            outputAvailable: true,
            inputAvailable: false
        ) == .routeChanged(
            AudioRouteChange(
                reason: .newDeviceAvailable,
                isOutputAvailable: true,
                isInputAvailable: false
            )
        )
    )
}

@Test("Apple capability detection stays platform explicit")
@MainActor
func appleCapabilityDetection() {
    let iPadSnapshot = AppleSystemCapabilityDetector.snapshot(
        platform: .iPadOS,
        inputs: AppleSystemCapabilityInputs(
            audioSession: true,
            interruptionEvents: true,
            routeChangeEvents: true,
            mediaServicesResetEvents: true,
            nowPlaying: true,
            remoteCommands: true,
            backgroundAudio: true,
            lockScreenControls: true
        )
    )
    #expect(iPadSnapshot.platform == .iPadOS)
    #expect(iPadSnapshot.supports(.audioSessionEvents))
    #expect(iPadSnapshot.supports([.nowPlaying, .remoteCommands]))

    let macSnapshot = AppleSystemCapabilityDetector.snapshot(
        platform: .macOS,
        inputs: AppleSystemCapabilityInputs(
            nowPlaying: true,
            remoteCommands: true
        )
    )
    #expect(macSnapshot.platform == .macOS)
    #expect(macSnapshot.supports([.nowPlaying, .remoteCommands]))
    #expect(!macSnapshot.capabilities.contains(.audioSession))
    #expect(!macSnapshot.capabilities.contains(.backgroundAudio))
}

@Test("Injected audio session lifecycle is idempotent and finishes its stream")
@MainActor
func injectedAudioSessionLifecycle() async throws {
    let client = RecordingAudioSessionClient()
    let manager = try AppleAudioSessionManager(
        configuration: .standard,
        client: client,
        notificationCenter: NotificationCenter()
    )
    let stream = manager.makeEventStream()

    try manager.configureForPlayback()
    try await manager.activate()
    try await manager.activate()
    #expect(client.configureCount == 1)
    #expect(client.activationStates == [true])

    await manager.deactivate()
    await manager.deactivate()
    #expect(client.activationStates == [true, false])

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

@Test("Media services reset invalidates audio session state before reactivation")
@MainActor
func mediaServicesResetForcesAudioSessionReconfiguration() async throws {
    let client = RecordingAudioSessionClient()
    let manager = try AppleAudioSessionManager(
        configuration: .standard,
        client: client,
        notificationCenter: NotificationCenter()
    )
    let stream = manager.makeEventStream()

    try await manager.activate()
    manager.handleMediaServicesReset()
    try await manager.activate()

    #expect(client.configureCount == 2)
    #expect(client.activationStates == [true, true])
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .mediaServicesReset)

    await manager.deactivate()
    #expect(client.activationStates == [true, true, false])
}

@Test("Injected remote command targets are registered once and fully removed")
@MainActor
func injectedRemoteCommandRegistrationLifecycle() async {
    let client = RecordingRemoteCommandClient()
    let receiver = AppleRemoteCommandReceiver(
        configuration: AppleSystemConfiguration(commandPolicy: [.play, .pause]),
        client: client
    )
    let stream = receiver.makeCommandStream()

    #expect(client.installCount == 2)
    receiver.setEnabledCommands([.play, .pause])
    #expect(client.installCount == 2)

    client.send(.play)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .play)

    receiver.setEnabledCommands([.play])
    #expect(receiver.registeredCommandCount == 1)
    #expect(client.removeCount == 1)
    receiver.setEnabledCommands([.play])
    #expect(client.installCount == 2)

    receiver.dispose()
    #expect(receiver.registeredCommandCount == 0)
    #expect(client.removeCount == 2)
}

@Test("Injected Now Playing client receives publish and clear without Apple framework types")
@MainActor
func injectedNowPlayingBoundary() {
    let client = RecordingNowPlayingClient()
    let publisher = AppleNowPlayingPublisher(client: client)
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let snapshot = NowPlayingSnapshot(
        itemID: itemID,
        title: "Track",
        artist: "Artist",
        duration: .seconds(120),
        elapsed: .seconds(12),
        isPlaying: true,
        rate: 1,
        queuePosition: 0,
        queueCount: 1,
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    publisher.publish(snapshot)
    #expect(client.published.count == 1)
    #expect(client.published.first?.itemID == itemID)
    #expect(client.published.first?.title == "Track")
    #expect(client.published.first?.queuePosition == 0)

    publisher.clear()
    #expect(client.clearCount == 1)
    #expect(publisher.currentSnapshot == nil)
}

#if os(iOS) && canImport(MediaPlayer)
@Test("Now Playing artwork request handler supports a background queue")
@MainActor
func nowPlayingArtworkRequestHandlerSupportsBackgroundQueue() async throws {
    let sourceSize = CGSize(width: 40, height: 20)
    let data = UIGraphicsImageRenderer(size: sourceSize).pngData { context in
        context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: sourceSize))
    }
    let artwork = try #require(PlatformNowPlayingArtworkFactory.make(from: data))
    let requestedSize = CGSize(width: 18, height: 11)

    let renderedSize = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            continuation.resume(returning: artwork.image(at: requestedSize)?.size)
        }
    }

    let size = try #require(renderedSize)
    #expect(size == CGSize(width: 18, height: 9))
}
#endif

@MainActor
private final class RecordingAudioSessionClient: AppleAudioSessionClient {
    var configureCount = 0
    var activationStates: [Bool] = []
    var routeAvailability: (output: Bool?, input: Bool?) = (true, false)

    func configure(using configuration: AppleSystemConfiguration) throws {
        configureCount += 1
    }

    func setActive(_ active: Bool) throws {
        activationStates.append(active)
    }
}

@MainActor
private final class RecordingRemoteCommandClient: AppleRemoteCommandCenterClient {
    let supportedCommands = Set(RemoteCommandKind.allCases)
    var installCount = 0
    var removeCount = 0
    private var handlers: [RemoteCommandKind: @MainActor @Sendable (RemotePlaybackCommand) -> Void] = [:]

    func installTarget(
        for command: RemoteCommandKind,
        handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) -> Void
    ) -> AppleRemoteCommandTargetToken? {
        installCount += 1
        handlers[command] = handler
        return AppleRemoteCommandTargetToken { [weak self] in
            self?.removeCount += 1
            self?.handlers.removeValue(forKey: command)
        }
    }

    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind) {}

    func send(_ command: RemotePlaybackCommand) {
        handlers[command.kind]?(command)
    }
}

@MainActor
private final class RecordingNowPlayingClient: AppleNowPlayingInfoClient {
    var published: [AppleNowPlayingInfo] = []
    var clearCount = 0

    func publish(_ info: AppleNowPlayingInfo) throws {
        published.append(info)
    }

    func clear() throws {
        clearCount += 1
    }
}
