import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing
import MusicTestSupport

struct MusicTestSupportInitialTests {
    @Test
    func fixturesAndRandomValuesAreDeterministic() throws {
        let first = FixtureFactory.track(2)
        let second = FixtureFactory.track(2)
        #expect(first == second)
        #expect(FixtureFactory.stableUUID(4) == FixtureFactory.stableUUID(4))

        var left = DeterministicRandomSource(seed: 42)
        var right = DeterministicRandomSource(seed: 42)
        #expect(left.sequence(count: 4) == right.sequence(count: 4))
        #expect(left.shuffled([0, 1, 2, 3, 4]) == right.shuffled([0, 1, 2, 3, 4]))

        var generator = SequentialIDGenerator(start: 3)
        #expect(generator.nextUUID() == FixtureFactory.stableUUID(3))
        #expect(generator.nextID(prefix: "test") == "test-4")
    }

    @Test
    func mediaSourceScriptsAndCallsAreObservable() async throws {
        let itemID = FixtureFactory.itemID(1)
        let source = FakeMediaSource(
            resolveResults: [itemID: .resource(.local(FixtureFactory.fixtureURL(1)))],
            artworkResults: [
                FixtureFactory.artworkID(1): .resource(.inMemory(Data("art".utf8)))
            ]
        )

        _ = try await source.resolve(itemID)
        _ = try await source.artwork(for: FixtureFactory.artworkID(1))
        #expect(source.resolveCalls == [itemID])
        #expect(source.artworkCalls == [FixtureFactory.artworkID(1)])

        await #expect(throws: MediaSourceError.self) {
            _ = try await source.resolve(FixtureFactory.itemID(99))
        }
    }

    @Test
    func importerCancellationEmitsOneTerminalEvent() async throws {
        let importID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let request = MediaImportRequest(importID: importID, urls: [FixtureFactory.fixtureURL(0)])
        let script = FakeImportScript(
            events: [.discovered(importID: importID, url: request.urls[0])],
            autoFinish: false
        )
        let importer = FakeMediaImporter(script: script)
        var iterator = importer.importMedia(request).makeAsyncIterator()

        let discoveredValue = try await iterator.next()
        let discovered = try #require(discoveredValue)
        await importer.cancelImport(importID)
        let cancelledValue = try await iterator.next()
        let cancelled = try #require(cancelledValue)
        let end = try await iterator.next()

        let events = [discovered, cancelled]
        #expect(events.count == 2)
        #expect(events.last?.isTerminal == true)
        #expect(end == nil)
        #expect(importer.cancelledImportIDs == [importID])
    }

    @Test
    func libraryTransactionsAreAtomicAndPublishOnlyOnCommit() async throws {
        let repository = InMemoryLibraryRepository()
        let track = FixtureFactory.track(0)
        let transaction = try LibraryTransaction(
            idempotencyKey: "insert-track",
            mutations: [.upsert(.track(track))]
        )
        let changes = repository.changes()
        let recorder = AsyncStreamRecorder<LibraryChange>()
        let task = Task { await recorder.record(changes) }

        try await repository.apply(transaction)
        let persistedTrack = try await repository.track(id: track.id)
        #expect(persistedTrack == track)

        let invalid = try LibraryTransaction(
            idempotencyKey: "invalid-relation",
            mutations: [
                .relation(.setArtists(trackID: track.id, artistIDs: [ArtistID("missing")]))
            ]
        )
        await #expect(throws: LibraryError.self) {
            try await repository.apply(invalid)
        }
        #expect(await repository.emittedChanges.count == 1)
        await recorder.waitForCount(1)
        #expect(await recorder.snapshot().count == 1)

        await repository.close()
        _ = await task.value
    }

    @Test
    func playbackHistoryClearPublishesOneTargetedChange() async throws {
        let track = FixtureFactory.track(0)
        let repository = InMemoryLibraryRepository(tracks: [track])
        let sessionID = FixtureFactory.stableUUID(500)
        try await repository.recordPlaybackStarted(PlaybackStart(
            sessionID: sessionID,
            itemID: track.id,
            startedAt: Date(timeIntervalSince1970: 100)
        ))

        try await repository.clearHistory()

        let page = try await repository.recentHistory(
            page: try LibraryPageRequest(limit: 10)
        )
        #expect(page.elements.isEmpty)
        let changes = await repository.emittedChanges
        #expect(changes.count == 1)
        #expect(changes[0].categories == [.playbackHistory])
        #expect(changes[0].affectedIDs.trackIDs == [track.id])

        try await repository.clearHistory()
        #expect(await repository.emittedChanges.count == 1)
    }

    @Test
    func settingsChangesHaveNoInitialOrEqualEmission() async throws {
        let repository = InMemorySettingsRepository()
        let stream = repository.changes()
        let recorder = AsyncStreamRecorder<AppSettings>()
        let task = Task { await recorder.record(stream) }

        try await repository.save(.defaults)
        #expect(await recorder.snapshot().isEmpty)
        let changed = AppSettings(
            playbackPreferences: PlaybackPreferences(rate: try PlaybackRate(value: 1.25))
        )
        try await repository.save(changed)
        try await repository.save(changed)

        await repository.close()
        let events = await task.value
        #expect(events == [changed])
    }

    @Test
    @MainActor
    func playbackEngineRejectsUnsupportedCommandsAndKeepsGeneration() async throws {
        let engine = FakePlaybackEngine(capabilities: [])
        let stream = engine.makeEventStream()
        let recorder = AsyncStreamRecorder<PlaybackEvent>()
        let task = Task { await recorder.record(stream) }

        try await engine.prepare(FixtureFactory.playbackItem(0), startAt: .zero)
        let generation = engine.state.generation
        await #expect(throws: PlaybackError.self) {
            try await engine.seek(to: .seconds(1))
        }
        #expect(engine.state.generation == generation)
        engine.emit(.phaseChanged(generation: generation, itemID: engine.state.itemID, phase: .paused))

        engine.finishEvents()
        let events = await task.value
        #expect(events.count >= 2)
    }

    @Test
    @MainActor
    func systemPortStreamsRecordCallsAndFinish() async throws {
        let audio = FakeAudioSessionManager()
        try audio.configureForPlayback()
        try await audio.activate()
        #expect(audio.isActive)

        let stream = audio.makeEventStream()
        let recorder = AsyncStreamRecorder<AudioSessionEvent>()
        let task = Task { await recorder.record(stream) }
        audio.emit(.mediaServicesReset)
        audio.finishEvents()
        _ = await task.value
        #expect(await recorder.snapshot() == [.mediaServicesReset])

        let remote = FakeRemoteCommandReceiver(enabledCommands: [.play])
        let commandStream = remote.makeCommandStream()
        let commandRecorder = AsyncStreamRecorder<RemotePlaybackCommand>()
        let commandTask = Task { await commandRecorder.record(commandStream) }
        #expect(remote.emit(.pause) == false)
        #expect(remote.emit(.play))
        remote.finishCommands()
        _ = await commandTask.value
        #expect(await commandRecorder.snapshot() == [.play])
    }

    @Test
    func testClockAdvancesSleepingTasksWithoutWallClock() async throws {
        let clock = TestClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await clock.pendingSleepCount() == 1)
        await clock.advance(by: .seconds(10))
        let didWake = try await sleeper.value
        #expect(didWake)
        #expect(await clock.pendingSleepCount() == 0)
    }
}
