import Foundation
import MusicDomain
import SystemIntegrationAPI
import Testing

@Test("Audio session events preserve interruption and route semantics")
func audioSessionEventsPreserveStableSemantics() throws {
    let events: [AudioSessionEvent] = [
        .interruptionBegan,
        .interruptionEnded(shouldResume: true),
        .routeChanged(
            AudioRouteChange(
                reason: .oldDeviceUnavailable,
                isOutputAvailable: false
            )
        ),
        .mediaServicesReset,
    ]

    let data = try JSONEncoder().encode(events)
    let decoded = try JSONDecoder().decode([AudioSessionEvent].self, from: data)

    #expect(decoded == events)
    #expect(decoded[0].interruptionDetails?.isBeginning == true)
    #expect(decoded[1].interruptionDetails?.shouldResume == true)
    #expect(decoded[2].routeChangeDetails?.isOldDeviceUnavailable == true)
    #expect(decoded[2].routeChangeDetails?.hasOutput == false)
    #expect(decoded[3].isMediaServicesReset)
}

@Test("System integration capabilities form a platform-neutral boundary")
func systemIntegrationCapabilitiesRoundTrip() throws {
    let capabilities: SystemIntegrationCapabilities = [
        .audioSession,
        .audioSessionEvents,
        .nowPlaying,
        .remoteCommands,
    ]
    let snapshot = SystemIntegrationCapabilitySnapshot(
        platform: .macOS,
        capabilities: capabilities
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(
        SystemIntegrationCapabilitySnapshot.self,
        from: data
    )

    #expect(decoded == snapshot)
    #expect(decoded.platform == .mac)
    #expect(decoded.supports([.audioSession, .nowPlaying]))
    #expect(!decoded.supports(.backgroundAudio))
}

@Test("Now Playing snapshots normalize metadata and project elapsed time")
func nowPlayingSnapshotPreservesValueSemantics() {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let artwork = NowPlayingArtworkReference(id: ArtworkID("artwork-1"))
    let timestamp = Date(timeIntervalSince1970: 100)
    let snapshot = NowPlayingSnapshot(
        itemID: itemID,
        title: "  Song  ",
        artist: "  Artist  ",
        album: "  ",
        duration: .seconds(180),
        elapsed: .seconds(30),
        isPlaying: true,
        rate: 1.25,
        queuePosition: 1,
        queueCount: 3,
        artwork: artwork,
        updatedAt: timestamp
    )

    #expect(snapshot.title == "Song")
    #expect(snapshot.artist == "Artist")
    #expect(snapshot.album == nil)
    #expect(snapshot.playbackState == .playing)
    #expect(snapshot.playbackRate == 1.25)
    #expect(snapshot.projectedElapsed(at: Date(timeIntervalSince1970: 102)) == .seconds(32.5))
    #expect(snapshot.projectedElapsed(at: Date(timeIntervalSince1970: 1_000)) == .seconds(180))
    #expect(snapshot == snapshot)
}

@Test("Remote commands expose stable kinds and validation")
func remoteCommandsPreserveKindsAndValueSemantics() throws {
    let commands: [RemotePlaybackCommand] = [
        .play,
        .togglePlayPause,
        .seek(to: .seconds(12)),
        .changeRate(to: 1.5),
    ]
    let data = try JSONEncoder().encode(commands)
    let decoded = try JSONDecoder().decode([RemotePlaybackCommand].self, from: data)

    #expect(decoded == commands)
    #expect(decoded.map(\.kind) == [.play, .toggle, .seek, .rate])
    #expect(decoded[2].seekPosition == .seconds(12))
    #expect(decoded[3].requestedRate == 1.5)
    #expect(RemotePlaybackCommand.seek(.seconds(1)).isValid)
    #expect(!RemotePlaybackCommand.changeRate(0).isValid)

    let enabled: Set<RemoteCommandKind> = [.play, .pause, .rate]
    #expect(enabled.contains(.changeRate))
    #expect(RemoteCommandResult.handled == .success)
    #expect(RemoteCommandResult.noActionableNowPlayingItem == .noActionableItem)
}

@Test("System integration errors keep stable and redacted diagnostics")
func systemIntegrationErrorsExposeSafeSemantics() throws {
    let error = SystemIntegrationError.invalidSnapshot(
        field: "/private/var/mobile/Library/secret"
    )

    #expect(error.diagnosticCode == "invalid-now-playing-snapshot")
    #expect(error.failureReason == "The Now Playing snapshot field field is invalid.")
    #expect(!error.description.contains("/private/var"))
    #expect(!error.isRetryable)

    let encoded = try JSONEncoder().encode(
        SystemIntegrationError.commandRegistrationFailed(command: .next)
    )
    let decoded = try JSONDecoder().decode(SystemIntegrationError.self, from: encoded)
    #expect(decoded == .commandRegistrationFailed(command: .next))
}

@MainActor
private final class ProtocolConformance: AudioSessionManaging, NowPlayingPublishing,
    RemoteCommandReceiving
{
    func configureForPlayback() throws {}

    func activate() async throws {}

    func deactivate() async {}

    func makeEventStream() -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func publish(_ snapshot: NowPlayingSnapshot) {}

    func clear() {}

    func makeCommandStream() -> AsyncStream<RemotePlaybackCommand> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func setEnabledCommands(_ commands: Set<RemoteCommandKind>) {}
}

@Test("System integration ports remain main actor isolated")
@MainActor
func systemIntegrationPortsCompileAsMainActorProtocols() async throws {
    let subject = ProtocolConformance()
    try subject.configureForPlayback()
    try await subject.activate()
    subject.setEnabledCommands([.play])
    subject.clear()
    await subject.deactivate()
}
