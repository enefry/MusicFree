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
        let track = FixtureFactory.track(0)
        let repository = InMemoryLibraryRepository(
            albums: [FixtureFactory.album(0)],
            artists: [FixtureFactory.artist(0)],
            genres: [FixtureFactory.genre(0)]
        )
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
    func inMemoryArtworkReferencesIncludeLocalGraphOwners() async throws {
        let artworkID = ArtworkID("graph-owner-artwork")
        let releaseID = AlbumReleaseID("graph-owner-release")
        let discID = DiscID(releaseID: releaseID, number: 1)
        let logicalID = LogicalTrackID("graph-owner-logical")
        let collectionID = LibraryCollectionID("graph-owner-collection")
        let artwork = ArtworkReference(id: artworkID)
        let repository = InMemoryLibraryRepository()

        try await repository.apply(try LibraryTransaction(
            idempotencyKey: "graph-owner-artwork",
            mutations: [
                .upsert(.artwork(artwork)),
                .upsert(.albumRelease(AlbumRelease(
                    id: releaseID,
                    title: "Release",
                    artwork: artwork
                ))),
                .upsert(.disc(Disc(id: discID, releaseID: releaseID, number: 1))),
                .upsert(.logicalTrack(LogicalTrack(
                    id: logicalID,
                    releaseID: releaseID,
                    discID: discID,
                    title: "Track",
                    discNumber: 1,
                    artwork: artwork
                ))),
                .upsert(.collection(LibraryCollection(
                    id: collectionID,
                    kind: .boxSet,
                    title: "Collection",
                    artwork: artwork
                )))
            ]
        ))

        #expect(try await repository.isArtworkReferenced(artworkID))
    }

    @Test
    func inMemoryLocalGraphValidationRejectsMissingArtistAndGenreReferences() async throws {
        let artistID = ArtistID("missing-graph-artist")
        let genreID = GenreID("missing-graph-genre")
        let assetID = MediaAssetID(sourceID: .local, externalID: "missing-graph-asset")

        let artistRepository = InMemoryLibraryRepository()
        await #expect(throws: LibraryError.constraint(.danglingReference)) {
            try await artistRepository.apply(try LibraryTransaction(
                idempotencyKey: "missing-graph-artist",
                mutations: [
                    .upsert(.logicalTrack(LogicalTrack(
                        id: LogicalTrackID("missing-artist-logical"),
                        title: "Missing Artist",
                        artistIDs: [artistID]
                    ))),
                    .upsert(.mediaAsset(MediaAsset(id: assetID))),
                    .upsert(.trackVariant(TrackVariant(
                        id: MediaItemID(sourceID: .local, externalID: "missing-artist-variant"),
                        logicalTrackID: LogicalTrackID("missing-artist-logical"),
                        assetID: assetID
                    )))
                ]
            ))
        }
        #expect(try await artistRepository.logicalTrack(id: LogicalTrackID("missing-artist-logical")) == nil)

        let genreRepository = InMemoryLibraryRepository()
        await #expect(throws: LibraryError.constraint(.danglingReference)) {
            try await genreRepository.apply(try LibraryTransaction(
                idempotencyKey: "missing-graph-genre",
                mutations: [
                    .upsert(.logicalTrack(LogicalTrack(
                        id: LogicalTrackID("missing-genre-logical"),
                        title: "Missing Genre",
                        genreIDs: [genreID]
                    ))),
                    .upsert(.mediaAsset(MediaAsset(
                        id: MediaAssetID(sourceID: .local, externalID: "missing-genre-asset")
                    ))),
                    .upsert(.trackVariant(TrackVariant(
                        id: MediaItemID(sourceID: .local, externalID: "missing-genre-variant"),
                        logicalTrackID: LogicalTrackID("missing-genre-logical"),
                        assetID: MediaAssetID(sourceID: .local, externalID: "missing-genre-asset")
                    )))
                ]
            ))
        }
        #expect(try await genreRepository.logicalTrack(id: LogicalTrackID("missing-genre-logical")) == nil)
    }

    @Test("in-memory graph replacement prunes old release members and groups")
    func inMemoryGraphReplacementPrunesOldCollectionReferences() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "in-memory-graph-replacement")
        let oldAssetID = MediaAssetID(sourceID: .local, externalID: "in-memory-old-asset")
        let newAssetID = MediaAssetID(sourceID: .local, externalID: "in-memory-new-asset")
        let oldLogicalID = LogicalTrackID("in-memory-old-logical")
        let newLogicalID = LogicalTrackID("in-memory-new-logical")
        let oldReleaseID = AlbumReleaseID("in-memory-old-release")
        let newReleaseID = AlbumReleaseID("in-memory-new-release")
        let oldDiscID = DiscID(releaseID: oldReleaseID, number: 1)
        let newDiscID = DiscID(releaseID: newReleaseID, number: 1)
        let oldGroupID = AlbumGroupID("in-memory-old-group")
        let collectionID = LibraryCollectionID("in-memory-box-set")
        let repository = InMemoryLibraryRepository()

        try await repository.apply(try LibraryTransaction(
            idempotencyKey: "in-memory-graph-replacement-initial",
            mutations: [
                .upsert(.albumGroup(AlbumGroup(id: oldGroupID, title: "Old Group"))),
                .upsert(.albumRelease(AlbumRelease(
                    id: oldReleaseID,
                    groupID: oldGroupID,
                    title: "Old Release"
                ))),
                .upsert(.disc(Disc(id: oldDiscID, releaseID: oldReleaseID, number: 1))),
                .upsert(.collection(LibraryCollection(
                    id: collectionID,
                    kind: .boxSet,
                    title: "Old Box Set"
                ))),
                .upsert(.collectionMember(LibraryCollectionMember(
                    collectionID: collectionID,
                    releaseID: oldReleaseID,
                    position: 0
                ))),
                .upsert(.logicalTrack(LogicalTrack(
                    id: oldLogicalID,
                    releaseID: oldReleaseID,
                    discID: oldDiscID,
                    title: "Old Track"
                ))),
                .upsert(.mediaAsset(MediaAsset(id: oldAssetID))),
                .upsert(.trackVariant(TrackVariant(
                    id: itemID,
                    logicalTrackID: oldLogicalID,
                    assetID: oldAssetID
                )))
            ]
        ))

        try await repository.apply(try LibraryTransaction(
            idempotencyKey: "in-memory-graph-replacement-update",
            mutations: [
                .upsert(.albumRelease(AlbumRelease(id: newReleaseID, title: "New Release"))),
                .upsert(.disc(Disc(id: newDiscID, releaseID: newReleaseID, number: 1))),
                .upsert(.logicalTrack(LogicalTrack(
                    id: newLogicalID,
                    releaseID: newReleaseID,
                    discID: newDiscID,
                    title: "New Track"
                ))),
                .upsert(.mediaAsset(MediaAsset(id: newAssetID))),
                .upsert(.trackVariant(TrackVariant(
                    id: itemID,
                    logicalTrackID: newLogicalID,
                    assetID: newAssetID
                )))
            ]
        ))

        #expect(try await repository.logicalTrack(id: oldLogicalID) == nil)
        #expect(try await repository.mediaAsset(id: oldAssetID) == nil)
        #expect(try await repository.release(id: oldReleaseID) == nil)
        #expect(try await repository.discs(for: oldReleaseID).isEmpty)
        #expect(try await repository.members(in: collectionID).isEmpty)
        #expect(try await repository.collections().isEmpty)
        #expect(try await repository.release(id: newReleaseID) != nil)
        #expect(try await repository.logicalTrack(id: newLogicalID) != nil)
        #expect(try await repository.mediaAsset(id: newAssetID) != nil)
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
