import Foundation
import MediaSourceAPI
import MusicTestSupport
import MusicDomain
import PlaybackAPI
import SettingsAPI
import Testing
@testable import AppServices

@MainActor
@Test("online source coordinator enforces application and source privacy gates")
func onlineSourceCoordinatorEnforcesPrivacyGates() async throws {
    let source = CoordinatorFixtureSource()
    let coordinator = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: source.descriptor.sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    )
    let basePreferences = try OnlineSourcePreferences().adding(configuration)

    coordinator.apply(
        ImportPreferences(
            privacyPreferences: .defaults,
            onlineSourcePreferences: basePreferences
        )
    )
    let initial = await coordinator.snapshot()
    #expect(initial.sources.count == 1)
    #expect(initial.sources[0].isRegistered)
    #expect(!initial.sources[0].isRuntimeEnabled)

    await #expect(throws: OnlineSourceServingError.applicationPrivacyRequired) {
        try await coordinator.browse(
            sourceID: source.descriptor.sourceID,
            request: SourceBrowseRequest()
        )
    }

    let appAccepted = ImportPreferences(
        privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
        onlineSourcePreferences: basePreferences
    )
    coordinator.apply(appAccepted)
    await #expect(throws: OnlineSourceServingError.sourcePrivacyRequired(source.descriptor.sourceID)) {
        try await coordinator.browse(
            sourceID: source.descriptor.sourceID,
            request: SourceBrowseRequest()
        )
    }

    let sourceAccepted = try configuration
        .acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
        .settingEnabled(true)
    coordinator.apply(
        ImportPreferences(
            privacyPreferences: appAccepted.privacyPreferences,
            onlineSourcePreferences: try basePreferences.updating(sourceAccepted)
        )
    )
    let ready = await coordinator.snapshot()
    #expect(ready.sources[0].isRuntimeEnabled)
    #expect(try await coordinator.browse(
        sourceID: source.descriptor.sourceID,
        request: SourceBrowseRequest()
    ).items.count == 1)
    try await coordinator.authenticate(
        sourceID: source.descriptor.sourceID,
        oneTimeCode: "123456"
    )
    await #expect(throws: OnlineSourceAuthenticationError.invalidOneTimeCode) {
        try await coordinator.authenticate(
            sourceID: source.descriptor.sourceID,
            oneTimeCode: "wrong"
        )
    }

    coordinator.apply(
        ImportPreferences(
            privacyPreferences: appAccepted.privacyPreferences,
            onlineSourcePreferences: try basePreferences
                .updating(sourceAccepted)
                .settingEnabled(false)
        )
    )
    #expect(!(await coordinator.snapshot()).sources[0].isRuntimeEnabled)
    await #expect(throws: OnlineSourceServingError.sourceDisabled(source.descriptor.sourceID)) {
        try await coordinator.browse(
            sourceID: source.descriptor.sourceID,
            request: SourceBrowseRequest()
        )
    }
}

@MainActor
@Test("online source coordinator builds newly configured instances through its factory")
func onlineSourceCoordinatorBuildsConfiguredInstances() async throws {
    let coordinator = try OnlineSourceCoordinator(
        sources: [],
        factory: CoordinatorFixtureFactory()
    )
    let sourceID = MediaSourceID("coordinator.factory.instance")
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: "Factory Instance",
        endpoint: URL(string: "https://nas.example.test"),
        isEnabled: true
    )
    let acceptedConfiguration = try configuration
        .acceptingPrivacyPolicy(version: "fixture-policy-1")

    coordinator.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences()
                .adding(acceptedConfiguration)
        )
    )

    let snapshot = await coordinator.snapshot()
    #expect(snapshot.sources.count == 1)
    #expect(snapshot.sources[0].isRegistered)
    #expect(snapshot.sources[0].isRuntimeEnabled)
    #expect(
        try await coordinator.browse(
            sourceID: sourceID,
            request: SourceBrowseRequest()
        ).items.count == 1
    )
}

@MainActor
@Test("online source coordinator rebuilds an instance when its configuration changes")
func onlineSourceCoordinatorRebuildsChangedConfiguration() async throws {
    let factory = RecordingCoordinatorFactory()
    let coordinator = try OnlineSourceCoordinator(sources: [], factory: factory)
    let sourceID = MediaSourceID("coordinator.factory.refresh")
    let appPrivacy = PrivacyPreferences.defaults.acceptingPrivacyPolicy()

    let first = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: "Home NAS",
        endpoint: URL(string: "https://home.example.test"),
        isEnabled: true
    ).acceptingPrivacyPolicy(version: "fixture-policy-1")
    let second = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: "Office NAS",
        endpoint: URL(string: "https://office.example.test"),
        credentialRecordID: "credential.office",
        isEnabled: true
    ).acceptingPrivacyPolicy(version: "fixture-policy-1")

    coordinator.apply(
        ImportPreferences(
            privacyPreferences: appPrivacy,
            onlineSourcePreferences: try OnlineSourcePreferences().adding(first)
        )
    )
    coordinator.apply(
        ImportPreferences(
            privacyPreferences: appPrivacy,
            onlineSourcePreferences: try OnlineSourcePreferences().adding(second)
        )
    )

    #expect(factory.configurations.count == 2)
    #expect(factory.configurations.last == second)
    let page = try await coordinator.browse(
        sourceID: sourceID,
        request: SourceBrowseRequest()
    )
    #expect(page.items.first?.displayName == "Office NAS")
}

@MainActor
@Test("online audition prepares a redacted remote resource without a queue")
func onlineAuditionPreparesTransientRemoteResource() async throws {
    let sourceID = MediaSourceID("coordinator.audition")
    let request = RemotePlaybackRequest(
        url: URL(string: "https://audio.example.test/temporary")!,
        headers: ["Authorization": "secret"],
        expiresAt: Date().addingTimeInterval(60)
    )
    let source = CoordinatorFixtureSource(
        sourceID: sourceID,
        displayName: "Audition Fixture",
        playbackAccess: .http(request: request, transcode: nil)
    )
    let onlineSources = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    ).acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
    onlineSources.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences().adding(configuration)
        )
    )

    let engine = FakePlaybackEngine()
    let coordinator = OnlineAuditionCoordinator(
        onlineSources: onlineSources,
        engine: engine
    )
    let item = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "track-1"),
        kind: .track,
        displayName: "Temporary Track",
        artist: "Fixture Artist",
        duration: .seconds(30),
        isPlayable: true
    )

    try await coordinator.audition(sourceID: sourceID, item: item)

    #expect(engine.prepareCalls.count == 1)
    #expect(engine.playCallCount == 1)
    #expect(coordinator.snapshot.phase == .playing)
    #expect(coordinator.snapshot.itemID == item.id)
    #expect(!(engine.prepareCalls[0].item.resource is any Encodable))
    #expect(String(describing: engine.prepareCalls[0].item.resource).contains("redacted"))

    await coordinator.stop()
    #expect(coordinator.snapshot.phase == .stopped)
    #expect(engine.stopCallCount > 0)
}

@MainActor
@Test("online audition rejects expired access before preparing the engine")
func onlineAuditionRejectsExpiredAccess() async throws {
    let sourceID = MediaSourceID("coordinator.audition.expired")
    let source = CoordinatorFixtureSource(
        sourceID: sourceID,
        playbackAccess: .http(
            request: RemotePlaybackRequest(
                url: URL(string: "https://audio.example.test/expired")!,
                expiresAt: Date().addingTimeInterval(-1)
            ),
            transcode: nil
        )
    )
    let onlineSources = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    ).acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
    onlineSources.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences().adding(configuration)
        )
    )
    let engine = FakePlaybackEngine()
    let coordinator = OnlineAuditionCoordinator(
        onlineSources: onlineSources,
        engine: engine
    )
    let item = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "expired-track"),
        kind: .track,
        displayName: "Expired Track",
        isPlayable: true
    )

    await #expect(throws: OnlineAuditionError.accessExpired) {
        try await coordinator.audition(sourceID: sourceID, item: item)
    }
    #expect(engine.prepareCalls.isEmpty)
}

@MainActor
@Test("formal playback resuming stops an active online audition")
func formalPlaybackResumingStopsOnlineAudition() async throws {
    let sourceID = MediaSourceID("coordinator.audition.interruption")
    let source = CoordinatorFixtureSource(
        sourceID: sourceID,
        playbackAccess: .http(
            request: RemotePlaybackRequest(
                url: URL(string: "https://audio.example.test/interruption")!,
                expiresAt: Date().addingTimeInterval(60)
            ),
            transcode: nil
        )
    )
    let onlineSources = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    ).acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
    onlineSources.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences().adding(configuration)
        )
    )
    let formalPlayback = AuditionFormalPlaybackFixture()
    let engine = FakePlaybackEngine()
    let coordinator = OnlineAuditionCoordinator(
        onlineSources: onlineSources,
        engine: engine,
        formalPlayback: formalPlayback
    )
    let item = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "interrupted-track"),
        kind: .track,
        displayName: "Interrupted Track",
        isPlayable: true
    )

    try await coordinator.audition(sourceID: sourceID, item: item)
    #expect(coordinator.snapshot.phase == .playing)

    formalPlayback.publish(phase: .playing)
    for _ in 0..<2_000 where coordinator.snapshot.phase != .stopped {
        await Task.yield()
    }

    #expect(coordinator.snapshot.phase == .stopped)
    #expect(engine.stopCallCount > 0)
}

@MainActor
@Test("closing online audition does not deactivate the shared audio session")
func closingOnlineAuditionLeavesSharedAudioSessionForFormalPlayback() async throws {
    let sourceID = MediaSourceID("coordinator.audition.shared-audio")
    let source = CoordinatorFixtureSource(
        sourceID: sourceID,
        playbackAccess: .http(
            request: RemotePlaybackRequest(
                url: URL(string: "https://audio.example.test/shared-audio")!,
                expiresAt: Date().addingTimeInterval(60)
            ),
            transcode: nil
        )
    )
    let onlineSources = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    ).acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
    onlineSources.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences().adding(configuration)
        )
    )

    let audioSession = FakeAudioSessionManager()
    let engine = FakePlaybackEngine()
    let coordinator = OnlineAuditionCoordinator(
        onlineSources: onlineSources,
        engine: engine,
        audioSession: audioSession
    )
    let item = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "shared-audio-track"),
        kind: .track,
        displayName: "Shared Audio Track",
        duration: .seconds(30),
        isPlayable: true
    )

    try await coordinator.audition(sourceID: sourceID, item: item)
    #expect(audioSession.activateCallCount == 1)

    await coordinator.close()

    #expect(audioSession.deactivateCallCount == 0)
    #expect(audioSession.isActive)
    #expect(coordinator.snapshot == .idle)
}

@MainActor
@Test("A superseded online audition cannot stop the newer audition")
func supersededOnlineAuditionCannotStopNewerOperation() async throws {
    let sourceID = MediaSourceID("coordinator.audition.superseded")
    let gate = AuditionAccessGate()
    let source = CoordinatorFixtureSource(
        sourceID: sourceID,
        playbackAccess: .http(
            request: RemotePlaybackRequest(
                url: URL(string: "https://audio.example.test/superseded")!,
                expiresAt: Date().addingTimeInterval(60)
            ),
            transcode: nil
        ),
        playbackAccessGate: gate
    )
    let onlineSources = try OnlineSourceCoordinator(sources: [source])
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: source.descriptor.displayName,
        isEnabled: true
    ).acceptingPrivacyPolicy(version: source.privacyPolicyVersion)
    onlineSources.apply(
        ImportPreferences(
            privacyPreferences: PrivacyPreferences.defaults.acceptingPrivacyPolicy(),
            onlineSourcePreferences: try OnlineSourcePreferences().adding(configuration)
        )
    )

    let engine = FakePlaybackEngine()
    let coordinator = OnlineAuditionCoordinator(
        onlineSources: onlineSources,
        engine: engine
    )
    let firstItem = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "first"),
        kind: .track,
        displayName: "First Audition",
        isPlayable: true
    )
    let secondItem = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "second"),
        kind: .track,
        displayName: "Second Audition",
        isPlayable: true
    )

    let firstTask = Task { @MainActor in
        try? await coordinator.audition(sourceID: sourceID, item: firstItem)
    }
    await gate.waitUntilFirstCallStarts()

    let secondTask = Task { @MainActor in
        try? await coordinator.audition(sourceID: sourceID, item: secondItem)
    }
    for _ in 0..<2_000 where
        coordinator.snapshot.itemID != secondItem.id ||
        coordinator.snapshot.phase != .playing
    {
        await Task.yield()
    }
    await secondTask.value

    #expect(coordinator.snapshot.itemID == secondItem.id)
    #expect(coordinator.snapshot.phase == .playing)
    #expect(engine.stopCallCount == 1)

    await gate.releaseFirstCall()
    await firstTask.value

    #expect(coordinator.snapshot.itemID == secondItem.id)
    #expect(coordinator.snapshot.phase == .playing)
    #expect(engine.stopCallCount == 1)

    await coordinator.stop()
}

private struct CoordinatorFixtureSource: PlaybackSource,
    OneTimeCodeAuthenticatingOnlineSource {
    let descriptor: MediaSourceDescriptor
    let capabilities: MediaSourceCapabilities = [.artwork, .metadataReading]
    let providerKind: OnlineProviderKind = .dsAudio
    let onlineCapabilities: OnlineSourceCapabilities = [
        .browsing,
        .downloading,
        .onlinePlayback,
    ]
    let privacyPolicyVersion = "fixture-policy-1"
    let playbackAccessResult: PlaybackAccess
    let playbackAccessGate: AuditionAccessGate?

    init(
        sourceID: MediaSourceID = MediaSourceID("coordinator.fixture"),
        displayName: String = "Coordinator Fixture",
        playbackAccess: PlaybackAccess = .downloadRequired,
        playbackAccessGate: AuditionAccessGate? = nil
    ) {
        descriptor = MediaSourceDescriptor(
            sourceID: sourceID,
            kind: .remote,
            displayName: displayName,
            isReadOnly: true
        )
        playbackAccessResult = playbackAccess
        self.playbackAccessGate = playbackAccessGate
    }

    func resolve(_: MediaItemID) async throws -> PlaybackResource {
        .local(URL(fileURLWithPath: "/private/temporary/fixture.m4a"))
    }

    func artwork(for _: ArtworkID) async throws -> ArtworkResource? { nil }

    func authenticate(oneTimeCode: String) async throws {
        guard oneTimeCode == "123456" else {
            throw OnlineSourceAuthenticationError.invalidOneTimeCode
        }
    }

    func browse(_: SourceBrowseRequest) async throws -> SourceCatalogPage {
        SourceCatalogPage(items: [
            SourceCatalogItem(
                id: SourceObjectID(sourceID: descriptor.sourceID, externalID: "track-1"),
                kind: .track,
                displayName: descriptor.displayName,
                isPlayable: true
            )
        ])
    }

    func download(
        _ itemID: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        DownloadReceipt(
            sourceID: descriptor.sourceID,
            itemID: itemID,
            fileURL: URL(fileURLWithPath: "/private/temporary/fixture.m4a")
        )
    }

    func playbackAccess(
        for _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        if let playbackAccessGate {
            let isFirstCall = await playbackAccessGate.registerCall()
            if isFirstCall {
                await playbackAccessGate.waitForFirstCallRelease()
            }
        }
        return playbackAccessResult
    }
}

private actor AuditionAccessGate {
    private var callCount = 0
    private var firstCallStarted = false
    private var firstCallReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func registerCall() -> Bool {
        callCount += 1
        guard callCount == 1 else { return false }
        firstCallStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return true
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForFirstCallRelease() async {
        guard !firstCallReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        guard !firstCallReleased else { return }
        firstCallReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct CoordinatorFixtureFactory: OnlineSourceFactory {
    func makeSource(
        for configuration: OnlineSourceConfiguration
    ) throws -> (any OnlineSource)? {
        CoordinatorFixtureSource(
            sourceID: configuration.sourceID,
            displayName: configuration.displayName
        )
    }
}

private final class RecordingCoordinatorFactory: OnlineSourceFactory, @unchecked Sendable {
    private(set) var configurations: [OnlineSourceConfiguration] = []

    func makeSource(
        for configuration: OnlineSourceConfiguration
    ) throws -> (any OnlineSource)? {
        configurations.append(configuration)
        return CoordinatorFixtureSource(
            sourceID: configuration.sourceID,
            displayName: configuration.displayName
        )
    }
}

@MainActor
private final class AuditionFormalPlaybackFixture: PlaybackServing {
    private(set) var snapshot = PlaybackSessionSnapshot()
    private var continuations: [UUID: AsyncStream<PlaybackSessionSnapshot>.Continuation] = [:]

    func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    func send(_ command: PlaybackSessionCommand) async {
        if command == .pause {
            publish(phase: .paused)
        }
    }

    func execute(_ command: PlaybackSessionCommand) async throws {
        await send(command)
    }

    func publish(phase: PlaybackPhase) {
        snapshot = PlaybackSessionSnapshot(
            state: PlaybackState(
                phase: phase,
                generation: snapshot.generation.advanced()
            )
        )
        continuations.values.forEach { $0.yield(snapshot) }
    }
}
