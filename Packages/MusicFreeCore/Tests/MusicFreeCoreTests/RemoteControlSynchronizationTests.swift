import Foundation
@testable import AppServices
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import PlaybackAPI
import SystemIntegrationAPI
import Testing

@MainActor
struct RemoteControlSynchronizationTests {
    @Test func remotePauseAndPlayPublishMatchingStates() async throws {
        let setup = try await makeSetup()
        #expect(setup.publisher.currentSnapshot?.isPlaying == true)

        #expect(setup.remote.emit(.pause))
        try await waitUntil {
            setup.container.playback.snapshot.phase == .paused
                && setup.publisher.currentSnapshot?.playbackState == .paused
        }
        #expect(setup.publisher.currentSnapshot?.itemID == setup.itemID)

        #expect(setup.remote.emit(.play))
        try await waitUntil {
            setup.container.playback.snapshot.phase == .playing
                && setup.publisher.currentSnapshot?.isPlaying == true
        }
        await setup.container.stop()
    }

    @Test func sleepTimerPublishesPauseAndRemotePlayCanResume() async throws {
        let setup = try await makeSetup()
        setup.container.sleepTimer.startOneTime(durationMinutes: 1)
        for _ in 0..<200 {
            if await setup.clock.clock.pendingSleepCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await setup.clock.clock.pendingSleepCount() > 0)
        await setup.clock.clock.advance(by: .seconds(60))
        try await waitUntil {
            setup.container.playback.snapshot.phase == .paused
                && setup.publisher.currentSnapshot?.playbackState == .paused
                && !setup.container.sleepTimer.snapshot.isActive
        }
        #expect(setup.engine.pauseCallCount == 1)
        #expect(setup.remote.emit(.play))
        try await waitUntil { setup.publisher.currentSnapshot?.isPlaying == true }
        await setup.container.stop()
    }

    @Test(arguments: [PlaybackPhase.stopped, .failed])
    func terminalStatesDoNotRepublishClearedMetadata(phase: PlaybackPhase) async throws {
        let setup = try await makeSetup()
        if phase == .stopped {
            try await setup.container.playback.execute(.stop)
        } else {
            setup.engine.emit(.failed(
                generation: setup.engine.state.generation,
                itemID: setup.itemID,
                error: .engineFailure(code: "remote-control-test")
            ))
        }
        try await waitUntil {
            setup.container.playback.snapshot.phase == phase
                && setup.publisher.currentSnapshot == nil
        }
        let publicationCount = setup.publisher.publishCallCount
        setup.engine.emit(.positionChanged(
            generation: setup.engine.state.generation,
            itemID: setup.itemID,
            position: .seconds(1),
            duration: .seconds(120)
        ))
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.publisher.currentSnapshot == nil)
        #expect(setup.publisher.publishCallCount == publicationCount)
        #expect(setup.container.playback.snapshot.currentItemID == setup.itemID)
        await setup.container.stop()
    }

    private func makeSetup() async throws -> (
        container: AppServiceContainer,
        engine: FakePlaybackEngine,
        publisher: FakeNowPlayingPublisher,
        remote: FakeRemoteCommandReceiver,
        clock: RemoteControlTestClock,
        itemID: MediaItemID
    ) {
        let itemID = FixtureFactory.itemID()
        let entry = PlaybackQueueEntry(id: UUID(), itemID: itemID)
        let engine = FakePlaybackEngine()
        let publisher = FakeNowPlayingPublisher()
        let remote = FakeRemoteCommandReceiver()
        let clock = RemoteControlTestClock(clock: TestClock(startDate: Date()))
        let source = FakeMediaSource(resolveResults: [
            itemID: .resource(.local(URL(fileURLWithPath: "/fixture/remote-control.wav")))
        ])
        let container = try AppServiceContainer(dependencies: AppDependencies(
            mediaSources: [source],
            libraryRepository: InMemoryLibraryRepository(tracks: [
                Track(id: itemID, title: "Remote control", duration: .seconds(120))
            ]),
            playbackQueueRepository: InMemoryPlaybackQueueRepository(snapshot: PlaybackQueueSnapshot(
                entries: [entry], currentEntryID: entry.id
            )),
            playbackEngine: engine,
            nowPlaying: publisher,
            remoteCommands: remote,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(
                platform: .iOS, capabilities: [.nowPlaying, .remoteCommands]
            ),
            clock: clock
        ))
        _ = try await container.start()
        try await container.playback.execute(.resume)
        return (container, engine, publisher, remote, clock, itemID)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

private struct RemoteControlTestClock: AppClock {
    let clock: TestClock

    func now() async -> Date {
        await clock.now()
    }

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
