import Foundation
import AppServices
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing

@Test("AppServiceError descriptions include the stable diagnostic code")
func appServiceErrorDescriptionIncludesDiagnosticCode() {
    let error = AppServiceError.missingDependency("settingsRepository")

    #expect(error.description == "AppServiceError(app.missing_dependency)")
    #expect(error.description.contains(error.diagnosticCode))
}

@MainActor
@Test("Concurrent AppService starts share recovery, settings, and playback subscriptions")
func concurrentAppServiceStartsShareOneLifecycle() async throws {
    let recovery = ControlledStartupRecovery()
    let settings = TestSettingsRepository()
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: recovery,
            libraryRepository: TestLibraryRepository(tracks: []),
            settingsRepository: settings,
            playbackEngine: engine
        )
    )

    let first = Task { @MainActor in
        try await container.start()
    }
    await recovery.waitUntilPendingRemovalsStarts()

    let secondState = AsyncTestOperationState()
    let second = Task { @MainActor in
        secondState.markStarted()
        let report = try await container.start()
        secondState.markFinished()
        return report
    }
    await secondState.waitUntilStarted()
    await Task.yield()

    #expect(!secondState.finished)
    #expect(await recovery.pendingRemovalsCallCount == 1)
    await recovery.releasePendingRemovals()

    let firstReport = try await first.value
    let secondReport = try await second.value
    let repeatedReport = try await container.start()
    #expect(firstReport == secondReport)
    #expect(repeatedReport == firstReport)
    #expect(await recovery.pendingRemovalsCallCount == 1)
    #expect(settings.loadCount == 1)
    #expect(engine.eventStreamCount == 1)

    await container.stop()
}

@MainActor
@Test("A failed AppService start allows a fresh shared lifecycle attempt")
func failedAppServiceStartAllowsRetry() async throws {
    let queue = FailingFirstLoadQueueRepository()
    let settings = TestSettingsRepository()
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            playbackQueueRepository: queue,
            settingsRepository: settings,
            playbackEngine: engine
        )
    )

    do {
        _ = try await container.start()
        Issue.record("The first queue restore should fail startup")
    } catch let error as AppServiceError {
        #expect(error == .library(.capacity(.storageUnavailable)))
    }

    let report = try await container.start()
    let repeatedReport = try await container.start()
    #expect(repeatedReport == report)
    #expect(await queue.loadCount == 2)
    #expect(settings.loadCount == 1)
    #expect(engine.eventStreamCount == 1)

    await container.stop()
}

@MainActor
@Test("AppService startup enforces automatic storage pruning before playback starts")
func appServiceStartupWaitsForAutomaticStoragePruning() async throws {
    let maintenance = ControlledStorageMaintenance()
    let engine = TestPlaybackEngine(capabilities: [])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            settingsRepository: TestSettingsRepository(),
            storageMaintenance: maintenance,
            playbackEngine: engine
        )
    )

    let start = Task { @MainActor in try await container.start() }
    await maintenance.waitUntilPruningStarts()

    #expect(engine.eventStreamCount == 0)
    #expect(await maintenance.pruneCallCount == 1)
    #expect(await maintenance.lastLimit == .fiveGiB)
    #expect(await maintenance.lastRetention == .seconds(7 * 24 * 60 * 60))

    await maintenance.releasePruning()
    _ = try await start.value
    #expect(engine.eventStreamCount == 1)
    await container.stop()
}

@MainActor
@Test("Disabled automatic storage pruning never invokes the adapter")
func appServiceStartupSkipsDisabledAutomaticStoragePruning() async throws {
    let preferences = try StoragePreferences(
        cacheLimit: .fiveGiB,
        automaticallyPruneCache: false,
        stagingRetention: .zero
    )
    let maintenance = ControlledStorageMaintenance(startsBlocked: false)
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            settingsRepository: TestSettingsRepository(
                value: AppSettings(storagePreferences: preferences)
            ),
            storageMaintenance: maintenance
        )
    )

    _ = try await container.start()

    #expect(await maintenance.pruneCallCount == 0)
    await container.stop()
}

@MainActor
@Test("Automatic storage pruning failure is reported without failing startup")
func appServiceStartupReportsAutomaticStoragePruningFailure() async throws {
    let maintenance = ControlledStorageMaintenance(
        startsBlocked: false,
        failsPruning: true
    )
    let engine = TestPlaybackEngine(capabilities: [])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            settingsRepository: TestSettingsRepository(),
            storageMaintenance: maintenance,
            playbackEngine: engine
        )
    )

    let report = try await container.start()

    #expect(report.fallbacks == [.storagePruningFailed])
    #expect(engine.eventStreamCount == 1)
    await container.stop()
}

@MainActor
@Test("AppService stop fences an in-flight start and terminally disposes playback")
func appServiceStopFencesInflightStart() async throws {
    let recovery = ControlledStartupRecovery()
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: recovery,
            libraryRepository: TestLibraryRepository(tracks: []),
            playbackEngine: engine
        )
    )
    let start = Task { @MainActor in
        try await container.start()
    }
    await recovery.waitUntilPendingRemovalsStarts()

    let stopState = AsyncTestOperationState()
    let stop = Task { @MainActor in
        stopState.markStarted()
        await container.stop()
        stopState.markFinished()
    }
    await stopState.waitUntilStarted()
    await Task.yield()

    #expect(!stopState.finished)
    await recovery.releasePendingRemovals()
    await stop.value

    switch await start.result {
    case .success:
        Issue.record("A fenced startup should not report success")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    #expect(stopState.finished)
    #expect(engine.eventStreamCount == 0)
    #expect(engine.disposeCount == 1)

    do {
        _ = try await container.start()
        Issue.record("A stopped service graph must not restart a disposed engine")
    } catch let error as AppServiceError {
        #expect(error == .invalidRequest(operation: "services.startAfterStop"))
    }
}

@MainActor
@Test("Favorite state can be toggled repeatedly without reusing a transaction key")
func appServicesFavoriteCanToggleRepeatedly() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "favorite-repeat")
    let repository = InMemoryLibraryRepository(
        tracks: [Track(id: itemID, title: "Repeat Favorite")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let favorite = try await container.library.setFavorite(true, for: itemID)
    let unfavorite = try await container.library.setFavorite(false, for: itemID)
    let favoriteAgain = try await container.library.setFavorite(true, for: itemID)

    #expect(favorite.isFavorite)
    #expect(!unfavorite.isFavorite)
    #expect(favoriteAgain.isFavorite)
    #expect(try await repository.track(id: itemID)?.isFavorite == true)
    let transactions = await repository.appliedTransactions
    #expect(transactions.count == 3)
    #expect(Set(transactions.map(\.idempotencyKey)).count == 3)
}

@MainActor
@Test("Playback history keeps repeated track sessions and clears through AppServices")
func appServicesPlaybackHistoryKeepsSessionsAndClears() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "history-track")
    let track = Track(id: itemID, title: "History Track")
    let repository = InMemoryLibraryRepository(tracks: [track])
    let olderSession = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    let newerSession = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!

    try await repository.recordPlaybackStarted(PlaybackStart(
        sessionID: olderSession,
        itemID: itemID,
        startedAt: Date(timeIntervalSince1970: 100)
    ))
    try await repository.recordCompleted(PlaybackCompletion(
        sessionID: olderSession,
        itemID: itemID,
        occurredAt: Date(timeIntervalSince1970: 130),
        reason: .ended
    ))
    try await repository.recordPlaybackStarted(PlaybackStart(
        sessionID: newerSession,
        itemID: itemID,
        startedAt: Date(timeIntervalSince1970: 200)
    ))

    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        playbackHistoryRepository: repository
    ))
    let page = try await container.library.recentHistory(
        page: try LibraryPageRequest(limit: 10)
    )

    #expect(page.elements.map(\.sessionID) == [newerSession, olderSession])
    #expect(page.elements.map(\.track.id) == [itemID, itemID])
    #expect(page.elements[0].lastCompletionReason == nil)
    #expect(page.elements[1].lastCompletionReason == .ended)

    try await container.library.clearPlaybackHistory()
    let cleared = try await container.library.recentHistory(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(cleared.elements.isEmpty)
}

@MainActor
@Test("AppServices preserves import success, item failure, and cancellation")
func appServicesImportPaths() async throws {
    let successID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let failureID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let cancelID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let successItem = MediaItemID(sourceID: .local, externalID: "success")
    let url = URL(fileURLWithPath: "/private/import/song.m4a")
    let importer = TestImporter(scripts: [
        successID: TestImportScript(
            events: [
                .discovered(importID: successID, url: url),
                .persisting(importID: successID, itemID: successItem),
                .completed(
                    importID: successID,
                    result: MediaImportResult(
                        importID: successID,
                        imported: 1,
                        duplicate: 0,
                        skipped: 0,
                        failed: 0,
                        cancelled: 0
                    )
                ),
            ]
        ),
        failureID: TestImportScript(
            events: [
                .itemFailed(
                    importID: failureID,
                    url: url,
                    error: .unsupportedFormat
                ),
                .completed(
                    importID: failureID,
                    result: MediaImportResult(
                        importID: failureID,
                        imported: 0,
                        duplicate: 0,
                        skipped: 0,
                        failed: 1,
                        cancelled: 0
                    )
                ),
            ]
        ),
        cancelID: TestImportScript(events: [], autoFinish: false),
    ])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(mediaImporter: importer)
    )

    let successEvents = try await collect(
        try await container.importer.start(
            MediaImportRequest(importID: successID, urls: [url])
        )
    )
    #expect(successEvents.count == 3)
    #expect((successEvents.last?.isTerminal) == true)
    #expect((await container.importer.state(for: successID)?.result?.imported) == 1)

    let failureEvents = try await collect(
        try await container.importer.start(
            MediaImportRequest(importID: failureID, urls: [url])
        )
    )
    #expect(failureEvents.count == 2)
    #expect((await container.importer.state(for: failureID)?.result?.failed) == 1)

    let cancelStream = try await container.importer.start(
        MediaImportRequest(importID: cancelID, urls: [url])
    )
    let cancelTask = Task { try await collect(cancelStream) }
    await Task.yield()
    await container.importer.cancel(cancelID)
    let cancelEvents = try await cancelTask.value
    #expect(cancelEvents.count == 1)
    if case .cancelled(_, let result) = cancelEvents[0] {
        #expect(result.isCancelled)
        #expect(result.cancelled == 1)
    } else {
        Issue.record("Expected one cancelled terminal import event")
    }
}

@MainActor
@Test("Import consumer cancellation closes the session immediately")
func appServicesImportConsumerCancellationClosesSession() async throws {
    let importID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let importer = TestImporter(scripts: [
        importID: TestImportScript(events: [], autoFinish: false)
    ])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(mediaImporter: importer)
    )
    let stream = try await container.importer.start(
        MediaImportRequest(
            importID: importID,
            urls: [URL(fileURLWithPath: "/private/import/cancelled.m4a")]
        )
    )

    let consumer = Task {
        for try await _ in stream {}
    }
    await Task.yield()
    consumer.cancel()
    _ = await consumer.result
    for _ in 0..<10 {
        if await container.importer.state(for: importID)?.isActive == false {
            break
        }
        await Task.yield()
    }

    #expect(await container.importer.state(for: importID)?.isActive == false)

    // The ID can be reused after the consumer disappears, even if the
    // underlying importer has not produced a terminal event yet.
    let retry = try await container.importer.start(
        MediaImportRequest(
            importID: importID,
            urls: [URL(fileURLWithPath: "/private/import/cancelled.m4a")]
        )
    )
    await container.importer.cancel(importID)
    let retryEvents = try await collect(retry)
    #expect(retryEvents.count == 1)
    #expect(retryEvents.first?.isTerminal == true)
}

@MainActor
@Test("Late events from a cancelled import cannot mutate a retried session")
func appServicesImportSessionTokensRejectLateEvents() async throws {
    let importID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
    let importer = LateEventImporter()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(mediaImporter: importer)
    )
    let request = MediaImportRequest(
        importID: importID,
        urls: [URL(fileURLWithPath: "/private/import/race.m4a")]
    )

    let firstStream = try await container.importer.start(request)
    let firstConsumer = Task {
        for try await _ in firstStream {}
    }
    await Task.yield()
    firstConsumer.cancel()
    _ = await firstConsumer.result
    for _ in 0..<10 {
        if await container.importer.state(for: importID)?.isActive == false {
            break
        }
        await Task.yield()
    }

    let secondStream = try await container.importer.start(request)
    importer.emit(
        attempt: 1,
        event: .itemFailed(
            importID: importID,
            url: request.urls[0],
            error: .unsupportedFormat
        )
    )
    await Task.yield()
    #expect(await container.importer.state(for: importID)?.processedCount == 0)

    importer.emit(
        attempt: 2,
        event: .completed(
            importID: importID,
            result: MediaImportResult(
                importID: importID,
                imported: 1,
                duplicate: 0,
                skipped: 0,
                failed: 0,
                cancelled: 0
            )
        )
    )
    importer.finish(attempt: 2)
    let secondEvents = try await collect(secondStream)
    #expect(secondEvents.count == 1)
    #expect(await container.importer.state(for: importID)?.result?.imported == 1)
}

@MainActor
@Test("Library deletion rolls back before library removal and finalizes after pending removal")
func appServicesDeletionSaga() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "delete-me")
    let track = Track(id: itemID, title: "Delete Me")

    let rollbackLibrary = TestLibraryRepository(tracks: [track])
    rollbackLibrary.removeError = .capacity(.storageUnavailable)
    let rollbackRemover = TestRemoval()
    let rollbackContainer = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: rollbackRemover,
            libraryRepository: rollbackLibrary
        )
    )
    do {
        _ = try await rollbackContainer.library.delete([itemID])
        Issue.record("A library removal failure should be thrown")
    } catch let error as AppServiceError {
        #expect(error == .library(.capacity(.storageUnavailable)))
    }
    let rollbackTrack = try await rollbackLibrary.track(id: itemID)
    #expect(rollbackTrack != nil)
    #expect(rollbackRemover.rollbackCount == 1)
    #expect(rollbackRemover.commitCount == 0)

    let pendingLibrary = TestLibraryRepository(tracks: [track])
    let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let pendingQueue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [PlaybackQueueEntry(id: entryID, itemID: itemID)],
            currentEntryID: entryID
        )
    )
    pendingQueue.failSave = true
    let pendingRemover = TestRemoval()
    let pendingContainer = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: pendingRemover,
            libraryRepository: pendingLibrary,
            playbackQueueRepository: pendingQueue
        )
    )

    do {
        _ = try await pendingContainer.library.delete([itemID])
        Issue.record("A queue save failure should leave a pending removal")
    } catch let error as AppServiceError {
        if case .pendingRemoval = error {
            let pendingTrack = try await pendingLibrary.track(id: itemID)
            #expect(pendingTrack == nil)
        } else {
            Issue.record("Expected a pending removal error")
        }
    }
    #expect(pendingRemover.pendingCount == 1)

    pendingQueue.failSave = false
    let recovery = try await pendingContainer.library.recoverPendingRemovals()
    #expect(recovery.finalizedTransactionIDs.count == 1)
    #expect(recovery.pendingTransactionIDs.isEmpty)
    #expect(pendingRemover.commitCount == 1)
}

@MainActor
@Test("Library browse/search, queue restore, and playback use stable IDs")
func appServicesLibraryAndPlaybackPath() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "play-me")
    let artistID = ArtistID("play-artist")
    let albumID = AlbumID("play-album")
    let track = Track(
        id: itemID,
        title: "Play Me",
        albumID: albumID,
        artistIDs: [artistID],
        duration: .seconds(42)
    )
    let library = TestLibraryRepository(
        tracks: [track],
        albums: [Album(id: albumID, title: "Play Album", artistIDs: [artistID])],
        artists: [Artist(id: artistID, name: "Play Artist")]
    )
    let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [PlaybackQueueEntry(id: entryID, itemID: itemID)],
            currentEntryID: entryID
        )
    )
    let engine = TestPlaybackEngine(capabilities: [.seeking, .variableRate])
    let source = TestSource()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [source],
            libraryRepository: library,
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    let snapshotStream = container.playback.makeSnapshotStream()
    var snapshotIterator = snapshotStream.makeAsyncIterator()
    let restoredSnapshot = await snapshotIterator.next()
    #expect(restoredSnapshot?.currentItemID == itemID)

    let page = try await container.library.browseTracks(
        matching: TrackQuery(),
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(page.items == [track])
    let search = try await container.library.searchTracks(
        text: "play",
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(search.items == [track])
    #expect(engine.preparedItems.isEmpty)

    await container.playback.send(.resume)
    #expect(engine.preparedItems.count == 1)
    #expect(container.playback.snapshot.currentItemID == itemID)
    #expect(container.playback.snapshot.phase == .playing)
    var enrichedSnapshot = container.playback.snapshot
    while enrichedSnapshot.currentItem?.artist != "Play Artist"
        || enrichedSnapshot.currentItem?.album != "Play Album" {
        enrichedSnapshot = try #require(await snapshotIterator.next())
    }
    #expect(enrichedSnapshot.currentItem?.artist == "Play Artist")
    #expect(enrichedSnapshot.currentItem?.album == "Play Album")

    await container.playback.send(.play(itemID: itemID))
    #expect(engine.preparedItems.count == 2)
}

@MainActor
@Test("Playback queue restores as a paused session after service recreation")
func playbackQueueRestoresAfterServiceRecreation() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "cold-start-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "cold-start-second")
    let tracks = [
        Track(id: firstID, title: "Cold Start First", duration: .seconds(30)),
        Track(id: secondID, title: "Cold Start Second", duration: .seconds(45))
    ]
    let library = TestLibraryRepository(tracks: tracks)
    let queue = TestQueueRepository()
    let firstEngine = TestPlaybackEngine(capabilities: [.seeking])
    let firstContainer = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: library,
            playbackQueueRepository: queue,
            playbackEngine: firstEngine
        )
    )
    _ = try await firstContainer.start()
    await firstContainer.playback.send(
        .playItems(itemIDs: [firstID, secondID], shuffle: false)
    )

    let persistedQueue = firstContainer.playback.snapshot.queue.snapshot
    #expect(persistedQueue.itemIDs == [firstID, secondID])
    #expect(firstContainer.playback.snapshot.phase == .playing)
    await firstContainer.stop()

    let restoredEngine = TestPlaybackEngine(capabilities: [.seeking])
    let restoredContainer = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: library,
            playbackQueueRepository: queue,
            playbackEngine: restoredEngine
        )
    )
    _ = try await restoredContainer.start()

    let restored = restoredContainer.playback.snapshot
    #expect(restored.queue.snapshot == persistedQueue)
    #expect(restored.currentItemID == firstID)
    #expect(restored.currentItem?.title == "Cold Start First")
    #expect(restored.phase == .paused)
    #expect(restored.position == .zero)
    #expect(restoredEngine.preparedItems.isEmpty)
    await restoredContainer.stop()
}

@MainActor
@Test("Playback starts before optional relationship metadata finishes")
func appServicesPlaybackDoesNotWaitForRelationshipMetadata() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-latency")
    let artistID = ArtistID("metadata-artist")
    let albumID = AlbumID("metadata-album")
    let track = Track(
        id: itemID,
        title: "Immediate Audio",
        albumID: albumID,
        artistIDs: [artistID],
        duration: .seconds(30)
    )
    let metadataGate = ResolutionGate()
    let library = TestLibraryRepository(
        tracks: [track],
        albums: [Album(id: albumID, title: "Deferred Album")],
        artists: [Artist(id: artistID, name: "Deferred Artist")],
        metadataLookupGate: metadataGate
    )
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: library,
            playbackQueueRepository: TestQueueRepository(),
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    let enrichedSnapshotTask = Task<PlaybackSessionSnapshot?, Never> { @MainActor in
        for await snapshot in container.playback.makeSnapshotStream() {
            if snapshot.currentItem?.artist == "Deferred Artist",
               snapshot.currentItem?.album == "Deferred Album" {
                return snapshot
            }
        }
        return nil
    }
    let playbackTask = Task { @MainActor in
        await container.playback.send(.play(itemID: itemID))
    }

    await metadataGate.waitUntilStarted()
    await engine.waitUntilPreparedItemCount(1)
    #expect(engine.state.phase == .playing)
    #expect(container.playback.snapshot.currentItem?.artist == nil)
    #expect(container.playback.snapshot.currentItem?.album == nil)

    await metadataGate.release()
    await playbackTask.value
    let enrichedSnapshot = await enrichedSnapshotTask.value
    #expect(enrichedSnapshot?.currentItem?.artist == "Deferred Artist")
    #expect(enrichedSnapshot?.currentItem?.album == "Deferred Album")
}

@MainActor
@Test("Shuffle requests generate and persist an order anchored at the current entry")
func appServicesGeneratesShuffleOrder() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "shuffle-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "shuffle-second")
    let thirdID = MediaItemID(sourceID: .local, externalID: "shuffle-third")
    let firstEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [
                PlaybackQueueEntry(id: firstEntryID, itemID: firstID),
                PlaybackQueueEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                    itemID: secondID
                ),
                PlaybackQueueEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
                    itemID: thirdID
                )
            ],
            currentEntryID: firstEntryID
        )
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "Shuffle First"),
                Track(id: secondID, title: "Shuffle Second"),
                Track(id: thirdID, title: "Shuffle Third")
            ]),
            playbackQueueRepository: queue,
            randomSource: FixedRandomSource(value: 42)
        )
    )
    _ = try await container.start()

    await container.playback.send(
        .editQueue(.setShuffle(mode: .on, seed: nil, order: []))
    )

    let snapshot = container.playback.snapshot
    #expect(snapshot.queue.shuffleMode == .on)
    #expect(snapshot.queue.shuffleOrder.count == 3)
    #expect(snapshot.queue.shuffleOrder.first == firstEntryID)
    #expect(snapshot.queue.shuffleSeed == 42)
    let persistedQueue = try await queue.load()
    #expect(persistedQueue == snapshot.queue.snapshot)
}

@MainActor
@Test("Deleting the current track clears the live playback snapshot")
func appServicesDeletionClearsPlaybackSnapshot() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "delete-playing")
    let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000405")!
    let library = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Delete Playing", duration: .seconds(30))]
    )
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [PlaybackQueueEntry(id: entryID, itemID: itemID)],
            currentEntryID: entryID
        )
    )
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            managedMediaRemover: TestRemoval(),
            libraryRepository: library,
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    await container.playback.send(.resume)
    #expect(container.playback.snapshot.phase == .playing)

    _ = try await container.library.delete([itemID])

    #expect(container.playback.snapshot.currentItemID == nil)
    #expect(container.playback.snapshot.currentItem == nil)
    #expect(container.playback.snapshot.queue.entries.isEmpty)
    #expect(container.playback.snapshot.phase == .stopped)
}

@MainActor
@Test("Library deletion cannot be overwritten by an in-flight queue edit")
func appServicesSerializesDeletionWithQueueEdits() async throws {
    let deletedID = MediaItemID(sourceID: .local, externalID: "delete-concurrent")
    let retainedID = MediaItemID(sourceID: .local, externalID: "retain-concurrent")
    let entries = [deletedID, retainedID].enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                920 + index
            ))!,
            itemID: itemID
        )
    }
    let queue = BlockingFirstSaveQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: entries[0].id
        )
    )
    let library = TestLibraryRepository(tracks: [
        Track(id: deletedID, title: "Delete Concurrent"),
        Track(id: retainedID, title: "Retain Concurrent"),
    ])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: TestRemoval(),
            libraryRepository: library,
            playbackQueueRepository: queue
        )
    )
    _ = try await container.start()

    let editCommand = Task { @MainActor in
        try await container.playback.execute(.editQueue(.setRepeatMode(.all)))
    }
    await queue.waitUntilFirstSaveStarts()

    let deletion = Task { @MainActor in
        try await container.library.delete([deletedID])
    }
    while try await library.track(id: deletedID) != nil {
        await Task.yield()
    }
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(await queue.saveCount == 1)
    await queue.releaseFirstSave()

    try await editCommand.value
    _ = try await deletion.value

    let persisted = try await queue.load()
    #expect(persisted.itemIDs == [retainedID])
    #expect(persisted.repeatMode == .all)
    #expect(await queue.saveCount == 2)
    #expect(container.playback.snapshot.queue.snapshot == persisted)
}

@MainActor
@Test("A failed resource resolve is attached to the selected item and can retry")
func appServicesPlaybackResolveFailureUsesSelectedItem() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "resolve-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "resolve-second")
    let library = TestLibraryRepository(tracks: [
        Track(id: firstID, title: "Resolve First", duration: .seconds(30)),
        Track(id: secondID, title: "Resolve Second", duration: .seconds(30)),
    ])
    let source = TestSource(failingItemIDs: [secondID])
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [source],
            libraryRepository: library,
            playbackQueueRepository: TestQueueRepository(),
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    await container.playback.send(.play(itemID: firstID))
    #expect(container.playback.snapshot.phase == .playing)

    await container.playback.send(.play(itemID: secondID))
    #expect(container.playback.snapshot.currentItemID == secondID)
    #expect(container.playback.snapshot.phase == .failed)
    #expect(container.playback.snapshot.error != nil)

    source.failingItemIDs = []
    await container.playback.send(.play(itemID: secondID))
    #expect(container.playback.snapshot.currentItemID == secondID)
    #expect(container.playback.snapshot.phase == .playing)
}

@MainActor
@Test("A superseded resource resolve cannot replace the newer playback intent")
func appServicesPlaybackDropsSupersededResolution() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "slow-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "fast-second")
    let source = SuspendedResolutionTestSource(blockedItemID: firstID)
    let engine = TestPlaybackEngine(capabilities: [.seeking])
    let queue = TestQueueRepository()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [source],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "Slow First"),
                Track(id: secondID, title: "Fast Second"),
            ]),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    let firstCommand = Task { @MainActor in
        try? await container.playback.execute(.play(itemID: firstID))
    }
    await source.waitUntilBlockedResolutionStarts()

    try await container.playback.execute(.play(itemID: secondID))
    await source.releaseBlockedResolution()
    await firstCommand.value

    #expect(engine.preparedItems.map(\.itemID) == [secondID])
    #expect(container.playback.snapshot.currentItemID == secondID)
    #expect(container.playback.snapshot.queue.currentItemID == secondID)
    #expect(container.playback.snapshot.phase == .playing)
    #expect(try await queue.load().currentItemID == secondID)
}

@MainActor
@Test("Batch playback replaces and persists the queue as one user intent")
func appServicesBatchPlaybackIsAtomic() async throws {
    let itemIDs = ["batch-first", "batch-second", "batch-third"].map {
        MediaItemID(sourceID: .local, externalID: $0)
    }
    let queue = TestQueueRepository()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(
                tracks: itemIDs.map { Track(id: $0, title: $0.externalID) }
            ),
            playbackQueueRepository: queue,
            playbackEngine: TestPlaybackEngine(capabilities: []),
            randomSource: FixedRandomSource(value: 42)
        )
    )
    _ = try await container.start()

    try await container.playback.execute(
        .playItems(itemIDs: itemIDs, shuffle: true)
    )

    let persisted = try await queue.load()
    #expect(persisted.itemIDs == itemIDs)
    #expect(persisted.currentItemID == itemIDs.first)
    #expect(persisted.shuffleMode == .on)
    #expect(persisted.shuffleOrder.first == persisted.currentEntryID)
    #expect(queue.saveCount == 1)
}

@MainActor
@Test("Enqueue next inserts after the current entry in normal and shuffle order")
func appServicesEnqueueNextUsesCurrentPosition() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "queue-first")
    let currentID = MediaItemID(sourceID: .local, externalID: "queue-current")
    let lastID = MediaItemID(sourceID: .local, externalID: "queue-last")
    let nextIDs = [
        MediaItemID(sourceID: .local, externalID: "queue-next-1"),
        MediaItemID(sourceID: .local, externalID: "queue-next-2"),
    ]
    let entries = [firstID, currentID, lastID].enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                800 + index
            ))!,
            itemID: itemID
        )
    }
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: entries[1].id,
            shuffleMode: .on,
            shuffleSeed: 9,
            shuffleOrder: [entries[2].id, entries[1].id, entries[0].id]
        )
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "First"),
                Track(id: currentID, title: "Current"),
                Track(id: lastID, title: "Last"),
            ]),
            playbackQueueRepository: queue
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.enqueueNext(itemIDs: nextIDs))

    let persisted = try await queue.load()
    #expect(persisted.itemIDs == [firstID, currentID] + nextIDs + [lastID])
    let orderedItemIDs = persisted.shuffleOrder.compactMap { entryID in
        persisted.entries.first { $0.id == entryID }?.itemID
    }
    #expect(orderedItemIDs == [lastID, currentID] + nextIDs + [firstID])
}

@MainActor
@Test("Enqueue next and append preserve the current entry and their distinct positions")
func appServicesEnqueueNextAndAppendPreserveCurrentEntry() async throws {
    let currentID = MediaItemID(sourceID: .local, externalID: "queue-current")
    let tailID = MediaItemID(sourceID: .local, externalID: "queue-tail")
    let nextID = MediaItemID(sourceID: .local, externalID: "queue-next")
    let appendedID = MediaItemID(sourceID: .local, externalID: "queue-appended")
    let currentEntry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000840")!,
        itemID: currentID
    )
    let tailEntry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000841")!,
        itemID: tailID
    )
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [currentEntry, tailEntry],
            currentEntryID: currentEntry.id
        )
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: currentID, title: "Current"),
                Track(id: tailID, title: "Tail"),
                Track(id: nextID, title: "Next"),
                Track(id: appendedID, title: "Appended"),
            ]),
            playbackQueueRepository: queue
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.enqueueNext(itemIDs: [nextID]))
    try await container.playback.execute(.enqueueItems(itemIDs: [appendedID]))

    let persisted = try await queue.load()
    #expect(persisted.itemIDs == [currentID, nextID, tailID, appendedID])
    #expect(persisted.currentItemID == currentID)
    #expect(container.playback.snapshot.queue.itemIDs == persisted.itemIDs)
    #expect(container.playback.snapshot.currentItemID == persisted.currentItemID)
}

@MainActor
@Test("Concurrent queue edits derive from the latest persisted snapshot")
func appServicesSerializesConcurrentQueueEdits() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "concurrent-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "concurrent-second")
    let entries = [firstID, secondID].enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                900 + index
            ))!,
            itemID: itemID
        )
    }
    let queue = BlockingFirstSaveQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: entries[0].id
        )
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "Concurrent First"),
                Track(id: secondID, title: "Concurrent Second"),
            ]),
            playbackQueueRepository: queue,
            randomSource: FixedRandomSource(value: 11)
        )
    )
    _ = try await container.start()

    let repeatCommand = Task { @MainActor in
        try await container.playback.execute(.editQueue(.setRepeatMode(.all)))
    }
    await queue.waitUntilFirstSaveStarts()

    let shuffleCommand = Task { @MainActor in
        try await container.playback.execute(
            .editQueue(
                .setShuffle(
                    mode: .on,
                    seed: 11,
                    order: entries.map(\.id)
                )
            )
        )
    }
    for _ in 0..<10 {
        await Task.yield()
    }
    #expect(await queue.saveCount == 1)
    await queue.releaseFirstSave()

    try await repeatCommand.value
    try await shuffleCommand.value

    let persisted = try await queue.load()
    #expect(persisted.repeatMode == .all)
    #expect(persisted.shuffleMode == .on)
    #expect(persisted.shuffleSeed == 11)
    #expect(persisted.shuffleOrder == entries.map(\.id))
    #expect(await queue.saveCount == 2)
    #expect(container.playback.snapshot.queue.snapshot == persisted)
}

@MainActor
@Test("Rapid next commands advance cumulatively from the latest queue selection")
func appServicesRapidNextCommandsAreCumulative() async throws {
    let itemIDs = ["rapid-a", "rapid-b", "rapid-c"].map {
        MediaItemID(sourceID: .local, externalID: $0)
    }
    let entries = itemIDs.enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0002-%012d",
                index
            ))!,
            itemID: itemID
        )
    }
    let queue = BlockingFirstSaveQueueRepository(
        value: PlaybackQueueSnapshot(entries: entries, currentEntryID: entries[0].id)
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(
                tracks: itemIDs.map { Track(id: $0, title: $0.externalID) }
            ),
            playbackQueueRepository: queue,
            playbackEngine: TestPlaybackEngine(capabilities: [])
        )
    )
    _ = try await container.start()

    let first = Task { @MainActor in
        try? await container.playback.execute(.next)
    }
    await queue.waitUntilFirstSaveStarts()
    let second = Task { @MainActor in
        try? await container.playback.execute(.next)
    }
    await Task.yield()
    await queue.releaseFirstSave()
    _ = await first.value
    _ = await second.value

    #expect(container.playback.snapshot.currentItemID == itemIDs[2])
    #expect(container.playback.snapshot.queue.currentItemID == itemIDs[2])
    #expect(try await queue.load().currentItemID == itemIDs[2])
}

@MainActor
@Test("Next is a boundary no-op unless repeat all permits wrapping")
func appServicesNextBoundaryAndRepeatAllWrap() async throws {
    let itemIDs = ["boundary-first", "boundary-last"].map {
        MediaItemID(sourceID: .local, externalID: $0)
    }
    let entries = itemIDs.enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0003-%012d",
                index
            ))!,
            itemID: itemID
        )
    }
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(entries: entries, currentEntryID: entries[1].id)
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(
                tracks: itemIDs.map { Track(id: $0, title: $0.externalID) }
            ),
            playbackQueueRepository: queue,
            playbackEngine: TestPlaybackEngine(capabilities: [])
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.next)
    #expect(container.playback.snapshot.queue.currentItemID == itemIDs[1])
    #expect(try await queue.load().currentItemID == itemIDs[1])

    try await container.playback.execute(.editQueue(.setRepeatMode(.all)))
    try await container.playback.execute(.next)
    #expect(container.playback.snapshot.currentItemID == itemIDs[0])
    #expect(container.playback.snapshot.phase == .playing)
    #expect(try await queue.load().currentItemID == itemIDs[0])
}

@MainActor
@Test("Repeat and shuffle edits do not cancel in-flight playback preparation")
func appServicesQueueModesPreservePreparation() async throws {
    let itemIDs = ["prepare-first", "prepare-second"].map {
        MediaItemID(sourceID: .local, externalID: $0)
    }
    let entries = itemIDs.enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0004-%012d",
                index
            ))!,
            itemID: itemID
        )
    }
    let source = SuspendedResolutionTestSource(blockedItemID: itemIDs[0])
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(entries: entries, currentEntryID: entries[0].id)
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [source],
            libraryRepository: TestLibraryRepository(
                tracks: itemIDs.map { Track(id: $0, title: $0.externalID) }
            ),
            playbackQueueRepository: queue,
            playbackEngine: TestPlaybackEngine(capabilities: [])
        )
    )
    _ = try await container.start()

    let preparation = Task { @MainActor in
        try await container.playback.execute(.resume)
    }
    await source.waitUntilBlockedResolutionStarts()
    try await container.playback.execute(.editQueue(.setRepeatMode(.all)))
    try await container.playback.execute(
        .editQueue(.setShuffle(mode: .on, seed: 17, order: entries.map(\.id)))
    )
    await source.releaseBlockedResolution()
    try await preparation.value

    #expect(container.playback.snapshot.currentItemID == itemIDs[0])
    #expect(container.playback.snapshot.phase == .playing)
    #expect(container.playback.snapshot.queue.repeatMode == .all)
    #expect(container.playback.snapshot.queue.shuffleMode == .on)
}

@MainActor
@Test("Remote commands safely ignore an empty playback session")
func appServicesRemoteCommandsIgnoreNoCurrentItem() async throws {
    let remote = FakeRemoteCommandReceiver()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            remoteCommands: remote,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(
                platform: .iOS,
                capabilities: [.remoteCommands]
            )
        )
    )
    _ = try await container.start()

    #expect(remote.emit(.play))
    #expect(remote.emit(.next))
    await settleAppServiceEvents()

    #expect(container.playback.snapshot.phase == .idle)
    #expect(container.playback.snapshot.currentItemID == nil)
    #expect(container.playback.snapshot.error == nil)
}

@MainActor
@Test("Explicit pause during interruption suppresses automatic resume")
func appServicesExplicitPauseSuppressesInterruptionResume() async throws {
    let setup = try await makeAudioSessionPlaybackSetup(externalID: "interrupt-pause")
    await setup.container.playback.send(.resume)
    #expect(setup.container.playback.snapshot.phase == .playing)

    setup.audio.emit(.interruptionBegan)
    await settleAppServiceEvents()
    #expect(setup.container.playback.snapshot.phase == .paused)
    await setup.container.playback.send(.pause)
    setup.audio.emit(.interruptionEnded(shouldResume: true))
    await settleAppServiceEvents()

    #expect(setup.container.playback.snapshot.phase == .paused)
}

@MainActor
@Test("Explicit stop during interruption suppresses automatic resume")
func appServicesExplicitStopSuppressesInterruptionResume() async throws {
    let setup = try await makeAudioSessionPlaybackSetup(externalID: "interrupt-stop")
    await setup.container.playback.send(.resume)
    #expect(setup.container.playback.snapshot.phase == .playing)

    setup.audio.emit(.interruptionBegan)
    await settleAppServiceEvents()
    #expect(setup.container.playback.snapshot.phase == .paused)
    await setup.container.playback.send(.stop)
    setup.audio.emit(.interruptionEnded(shouldResume: true))
    await settleAppServiceEvents()

    #expect(setup.container.playback.snapshot.phase == .stopped)
}

@MainActor
@Test("Media-services reset reactivates the session when the engine still reports playing")
func appServicesMediaResetReactivatesPlayingEngine() async throws {
    let setup = try await makeAudioSessionPlaybackSetup(externalID: "media-reset-playing")
    await setup.container.playback.send(.resume)
    #expect(setup.container.playback.snapshot.phase == .playing)
    #expect(setup.audio.configureCallCount == 1)
    #expect(setup.audio.activateCallCount == 1)

    setup.audio.emit(.mediaServicesReset)
    await settleAppServiceEvents()

    #expect(setup.audio.configureCallCount == 2)
    #expect(setup.audio.activateCallCount == 2)
    #expect(setup.container.playback.snapshot.phase == .playing)
}

@MainActor
@Test("Media-services reset reactivates before restarting a paused engine")
func appServicesMediaResetReactivatesPausedEngine() async throws {
    let setup = try await makeAudioSessionPlaybackSetup(externalID: "media-reset-engine-paused")
    await setup.container.playback.send(.resume)
    setup.engine.simulateSystemPause()
    #expect(setup.container.playback.snapshot.phase == .playing)
    #expect(setup.engine.state.phase == .paused)

    setup.audio.emit(.mediaServicesReset)
    await settleAppServiceEvents()

    #expect(setup.audio.configureCallCount == 2)
    #expect(setup.audio.activateCallCount == 2)
    #expect(setup.engine.state.phase == .playing)
    #expect(setup.container.playback.snapshot.phase == .playing)
}

@MainActor
@Test("Media-services reset does not resume a session that was paused")
func appServicesMediaResetPreservesPausedIntent() async throws {
    let setup = try await makeAudioSessionPlaybackSetup(externalID: "media-reset-paused")
    await setup.container.playback.send(.resume)
    await setup.container.playback.send(.pause)
    #expect(setup.container.playback.snapshot.phase == .paused)
    #expect(setup.audio.configureCallCount == 1)
    #expect(setup.audio.activateCallCount == 1)

    setup.audio.emit(.mediaServicesReset)
    await settleAppServiceEvents()

    #expect(setup.container.playback.snapshot.phase == .paused)
    #expect(setup.audio.configureCallCount == 1)
    #expect(setup.audio.activateCallCount == 1)

    await setup.container.playback.send(.resume)
    #expect(setup.audio.configureCallCount == 2)
    #expect(setup.audio.activateCallCount == 2)
    #expect(setup.container.playback.snapshot.phase == .playing)
}

@MainActor
@Test("Now Playing artwork loads from the owning media source on demand")
func appServicesPublishesSourceBackedNowPlayingArtwork() async throws {
    let artworkID = ArtworkID("now-playing-artwork")
    let bytes = Data([0x01, 0x02, 0x03, 0x04])
    let itemID = MediaItemID(sourceID: .local, externalID: "artwork-track")
    let nowPlaying = FakeNowPlayingPublisher()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource(artworkData: bytes)],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(
                    id: itemID,
                    title: "Artwork Track",
                    artwork: ArtworkReference(id: artworkID)
                ),
            ]),
            playbackQueueRepository: TestQueueRepository(),
            playbackEngine: TestPlaybackEngine(capabilities: []),
            nowPlaying: nowPlaying,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(
                platform: .iOS,
                capabilities: [.nowPlaying]
            )
        )
    )
    _ = try await container.start()

    await container.playback.send(.play(itemID: itemID))
    let reference = try #require(nowPlaying.currentSnapshot?.artwork)
    let provider = try #require(reference.provider)

    #expect(reference.id == artworkID)
    #expect(try await provider.artworkData() == bytes)
}

@MainActor
@Test("Now Playing artwork rejects source data larger than 20 MiB")
func appServicesRejectsOversizedNowPlayingArtwork() async throws {
    let artworkID = ArtworkID("oversized-now-playing-artwork")
    let itemID = MediaItemID(sourceID: .local, externalID: "oversized-artwork-track")
    let nowPlaying = FakeNowPlayingPublisher()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [
                TestSource(artworkData: Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1)),
            ],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(
                    id: itemID,
                    title: "Oversized Artwork Track",
                    artwork: ArtworkReference(id: artworkID)
                ),
            ]),
            playbackQueueRepository: TestQueueRepository(),
            playbackEngine: TestPlaybackEngine(capabilities: []),
            nowPlaying: nowPlaying,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(
                platform: .iOS,
                capabilities: [.nowPlaying]
            )
        )
    )
    _ = try await container.start()
    await container.playback.send(.play(itemID: itemID))
    let provider = try #require(nowPlaying.currentSnapshot?.artwork?.provider)

    var rejected = false
    do {
        _ = try await provider.artworkData()
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@MainActor
@Test("Runtime capability changes update enabled remote commands")
func appServicesUpdatesRemoteCommandCapabilities() async throws {
    let remote = FakeRemoteCommandReceiver()
    let systemCapabilities = SystemIntegrationCapabilitySnapshot(
        platform: .iOS,
        capabilities: [.remoteCommands]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            remoteCommands: remote,
            systemCapabilities: systemCapabilities,
            playbackCapabilities: [.seeking, .variableRate]
        )
    )
    _ = try await container.start()

    #expect(remote.enabledCommands.contains(.seek))
    #expect(remote.enabledCommands.contains(.changeRate))

    await container.updatePlaybackCapabilities([])

    #expect(!remote.enabledCommands.contains(.seek))
    #expect(!remote.enabledCommands.contains(.changeRate))
}

@MainActor
@Test("Settings preserve user intent while clipping unsupported playback capabilities")
func appServicesSettingsCapabilityClipping() async throws {
    let settingsRepository = TestSettingsRepository()
    let rate = try PlaybackRate(value: 2)
    let requested = AppSettings(
        playbackPreferences: PlaybackPreferences(rate: rate)
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(settingsRepository: settingsRepository)
    )

    try await container.settings.update(requested)
    let effective = try await container.settings.effective()
    #expect(effective.settings.playbackPreferences.rate == rate)
    #expect(effective.effects.rate == 1)

    try await container.settings.reset()
    let resetSettings = try await container.settings.load()
    #expect(resetSettings == .defaults)
}

@MainActor
@Test("Settings expand persisted EQ intent to the runtime VLC band layout")
func appServicesSettingsBuildRuntimeEqualizerConfiguration() async throws {
    let descriptor = EqualizerDescriptor(
        bands: [
            EqualizerBandDescriptor(
                centerFrequencyHz: 60,
                minimumGainDecibels: -20,
                maximumGainDecibels: 20
            ),
            EqualizerBandDescriptor(
                centerFrequencyHz: 1_000,
                minimumGainDecibels: -20,
                maximumGainDecibels: 20
            )
        ],
        minimumPreampDecibels: -20,
        maximumPreampDecibels: 20
    )
    let savedBand = try EqualizerBand(
        frequencyHz: 1_000,
        gain: EqualizerGain(decibels: 4)
    )
    let settings = AppSettings(
        playbackPreferences: PlaybackPreferences(
            equalizer: try EqualizerPreferences(
                isEnabled: true,
                preamp: EqualizerGain(decibels: 2),
                bands: [savedBand]
            )
        )
    )
    let engine = TestPlaybackEngine(
        capabilities: [.equalizer],
        equalizerDescriptor: descriptor
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            settingsRepository: TestSettingsRepository(value: settings),
            playbackEngine: engine
        )
    )

    let effective = try await container.settings.effective()
    #expect(effective.equalizerDescriptor == descriptor)
    #expect(effective.effects.equalizer?.preampDecibels == 2)
    #expect(effective.effects.equalizer?.bandGains.map(\.centerFrequencyHz) == [60, 1_000])
    #expect(effective.effects.equalizer?.bandGains.map(\.gainDecibels) == [0, 4])
}

@MainActor
@Test("Settings mutations preserve cross-window intent order")
func appServicesSettingsMutationsPreserveIntentOrder() async throws {
    let repository = BlockingFirstSaveSettingsRepository()
    let requested = AppSettings(
        playbackPreferences: PlaybackPreferences(rate: try PlaybackRate(value: 1.5))
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(settingsRepository: repository)
    )
    let stream = await container.settings.makeChangeStream()
    var iterator = stream.makeAsyncIterator()

    let save = Task { @MainActor in
        try await container.settings.update(requested)
    }
    await repository.waitUntilFirstSaveStarts()

    let reset = Task { @MainActor in
        try await container.settings.reset()
    }
    await Task.yield()
    #expect(await repository.resetCount == 0)

    await repository.releaseFirstSave()
    try await save.value
    try await reset.value

    #expect(await repository.currentValue == .defaults)
    #expect(try await container.settings.load() == .defaults)
    #expect(await iterator.next() == requested)
    #expect(await iterator.next() == .defaults)
}

@MainActor
private func makeAudioSessionPlaybackSetup(
    externalID: String
) async throws -> (
    container: AppServiceContainer,
    audio: FakeAudioSessionManager,
    engine: TestPlaybackEngine
) {
    let itemID = MediaItemID(sourceID: .local, externalID: externalID)
    let entry = PlaybackQueueEntry(id: UUID(), itemID: itemID)
    let audio = FakeAudioSessionManager()
    let engine = TestPlaybackEngine(capabilities: [])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: itemID, title: externalID),
            ]),
            playbackQueueRepository: TestQueueRepository(
                value: PlaybackQueueSnapshot(entries: [entry], currentEntryID: entry.id)
            ),
            playbackEngine: engine,
            audioSession: audio,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(
                platform: .iOS,
                capabilities: [.audioSession, .audioSessionEvents]
            )
        )
    )
    _ = try await container.start()
    return (container, audio, engine)
}

private func settleAppServiceEvents() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

private func collect(
    _ stream: AsyncThrowingStream<MediaImportEvent, Error>
) async throws -> [MediaImportEvent] {
    var events: [MediaImportEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private struct TestImportScript: Sendable {
    let events: [MediaImportEvent]
    let autoFinish: Bool

    init(events: [MediaImportEvent], autoFinish: Bool = true) {
        self.events = events
        self.autoFinish = autoFinish
    }
}

private final class TestImporter: MediaImporting, @unchecked Sendable {
    private let lock = NSLock()
    private let scripts: [UUID: TestImportScript]
    private var active: [UUID: AsyncThrowingStream<MediaImportEvent, Error>.Continuation] = [:]

    init(scripts: [UUID: TestImportScript]) {
        self.scripts = scripts
    }

    func importMedia(_ request: MediaImportRequest)
        -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        let script = scripts[request.importID]
        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish()
                return
            }
            if !script.autoFinish {
                self.lock.lock()
                self.active[request.importID] = continuation
                self.lock.unlock()
            }
            Task {
                for event in script.events {
                    continuation.yield(event)
                }
                if script.autoFinish {
                    continuation.finish()
                }
            }
        }
    }

    func cancelImport(_ importID: UUID) async {
        let continuation = withLock(lock) {
            active.removeValue(forKey: importID)
        }
        guard let continuation else { return }
        let result = MediaImportResult(
            importID: importID,
            imported: 0,
            duplicate: 0,
            skipped: 0,
            failed: 0,
            cancelled: 1,
            status: .cancelled
        )
        continuation.yield(.cancelled(importID: importID, result: result))
        continuation.finish()
    }
}

private final class LateEventImporter: MediaImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var nextAttempt = 0
    private var continuations: [Int: AsyncThrowingStream<MediaImportEvent, Error>.Continuation] = [:]

    func importMedia(_ request: MediaImportRequest)
        -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        let attempt = withLock(lock) {
            nextAttempt += 1
            return nextAttempt
        }
        return AsyncThrowingStream { continuation in
            withLock(lock) {
                continuations[attempt] = continuation
            }
        }
    }

    func cancelImport(_ importID: UUID) async {}

    func emit(attempt: Int, event: MediaImportEvent) {
        let continuation = withLock(lock) { continuations[attempt] }
        continuation?.yield(event)
    }

    func finish(attempt: Int) {
        let continuation = withLock(lock) {
            continuations.removeValue(forKey: attempt)
        }
        continuation?.finish()
    }
}

private final class TestSource: MediaSource, @unchecked Sendable {
    let descriptor = MediaSourceDescriptor(
        sourceID: .local,
        kind: .local,
        displayName: "Local"
    )
    let capabilities: MediaSourceCapabilities = [.artwork]
    var failingItemIDs: Set<MediaItemID>
    var artworkData: Data?

    init(
        failingItemIDs: Set<MediaItemID> = [],
        artworkData: Data? = nil
    ) {
        self.failingItemIDs = failingItemIDs
        self.artworkData = artworkData
    }

    func resolve(_ itemID: MediaItemID) async throws -> PlaybackResource {
        if failingItemIDs.contains(itemID) {
            throw MediaSourceError.invalidResource
        }
        return .local(URL(fileURLWithPath: "/private/media/\(itemID.externalID).m4a"))
    }

    func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
        artworkData.map(ArtworkResource.inMemory)
    }
}

private actor ResolutionGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockUntilReleased() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class SuspendedResolutionTestSource: MediaSource, @unchecked Sendable {
    let descriptor = MediaSourceDescriptor(
        sourceID: .local,
        kind: .local,
        displayName: "Controlled Local"
    )
    let capabilities: MediaSourceCapabilities = []

    private let blockedItemID: MediaItemID
    private let gate = ResolutionGate()

    init(blockedItemID: MediaItemID) {
        self.blockedItemID = blockedItemID
    }

    func resolve(_ itemID: MediaItemID) async throws -> PlaybackResource {
        if itemID == blockedItemID {
            await gate.blockUntilReleased()
        }
        return .local(URL(fileURLWithPath: "/private/media/\(itemID.externalID).m4a"))
    }

    func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
        nil
    }

    func waitUntilBlockedResolutionStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseBlockedResolution() async {
        await gate.release()
    }
}

private final class TestLibraryRepository: LibraryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MediaItemID: Track]
    private var albumValues: [AlbumID: Album]
    private var artistValues: [ArtistID: Artist]
    private let metadataLookupGate: ResolutionGate?
    var removeError: LibraryError?

    init(
        tracks: [Track],
        albums: [Album] = [],
        artists: [Artist] = [],
        metadataLookupGate: ResolutionGate? = nil
    ) {
        values = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        albumValues = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        artistValues = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
        self.metadataLookupGate = metadataLookupGate
    }

    func track(id: MediaItemID) async throws -> Track? {
        withLock(lock) { values[id] }
    }

    func album(id: AlbumID) async throws -> Album? {
        await metadataLookupGate?.blockUntilReleased()
        return withLock(lock) { albumValues[id] }
    }

    func artist(id: ArtistID) async throws -> Artist? {
        await metadataLookupGate?.blockUntilReleased()
        return withLock(lock) { artistValues[id] }
    }

    func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        let all = withLock(lock) {
            Array(values.values).sorted { $0.id < $1.id }
        }
        let filtered = query.searchText.map { text in
            all.filter { $0.title.localizedCaseInsensitiveContains(text) }
        } ?? all
        return LibraryPage(elements: Array(filtered.prefix(page.limit)))
    }

    func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        let all = withLock(lock) { Array(albumValues.values).sorted { $0.id < $1.id } }
        return LibraryPage(elements: Array(all.prefix(page.limit)))
    }

    func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        let all = withLock(lock) { Array(artistValues.values).sorted { $0.id < $1.id } }
        return LibraryPage(elements: Array(all.prefix(page.limit)))
    }

    func apply(_ transaction: LibraryTransaction) async throws {
        withLock(lock) {
            for mutation in transaction.mutations {
                if case .upsert(.track(let track)) = mutation {
                    values[track.id] = track
                }
            }
        }
    }

    func remove(_ itemIDs: Set<MediaItemID>) async throws {
        try withLock(lock) {
            if let removeError {
                throw removeError
            }
            for itemID in itemIDs {
                values.removeValue(forKey: itemID)
            }
        }
    }

    func changes() -> AsyncStream<LibraryChange> {
        AsyncStream { $0.finish() }
    }
}

private final class TestRemoval: ManagedMediaRemoving, @unchecked Sendable {
    private enum State {
        case pending
        case committed
        case rolledBack
    }

    private let lock = NSLock()
    private var states: [UUID: (MediaRemovalTransaction, State)] = [:]
    private var nextID = 400
    private(set) var rollbackCount = 0
    private(set) var commitCount = 0

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.values.filter {
            if case .pending = $0.1 { return true }
            return false
        }.count
    }

    func pendingRemovals() async throws -> [MediaRemovalTransaction] {
        withLock(lock) {
            states.values.compactMap {
                if case .pending = $0.1 { return $0.0 }
                return nil
            }
        }
    }

    func prepareRemoval(of itemIDs: Set<MediaItemID>) async throws -> MediaRemovalTransaction {
        withLock(lock) {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", nextID))!
            nextID += 1
            let transaction = MediaRemovalTransaction(transactionID: id, itemIDs: itemIDs)
            states[id] = (transaction, .pending)
            return transaction
        }
    }

    func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {
        withLock(lock) {
            guard let value = states[transaction.transactionID] else { return }
            states[transaction.transactionID] = (value.0, .committed)
            commitCount += 1
        }
    }

    func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {
        withLock(lock) {
            guard let value = states[transaction.transactionID] else { return }
            states[transaction.transactionID] = (value.0, .rolledBack)
            rollbackCount += 1
        }
    }
}

private final class TestQueueRepository: PlaybackQueueRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlaybackQueueSnapshot
    private var saveCountValue = 0
    var failSave = false

    var saveCount: Int {
        withLock(lock) { saveCountValue }
    }

    init(value: PlaybackQueueSnapshot = .empty) {
        self.value = value
    }

    func load() async throws -> PlaybackQueueSnapshot {
        withLock(lock) { value }
    }

    func save(_ snapshot: PlaybackQueueSnapshot) async throws {
        try withLock(lock) {
            if failSave {
                throw LibraryError.capacity(.storageUnavailable)
            }
            value = snapshot
            saveCountValue += 1
        }
    }
}

private actor BlockingFirstSaveQueueRepository: PlaybackQueueRepository {
    private var value: PlaybackQueueSnapshot
    private var firstSaveStarted = false
    private var firstSaveReleased = false
    private var firstSaveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var saveCount = 0

    init(value: PlaybackQueueSnapshot) {
        self.value = value
    }

    func load() async throws -> PlaybackQueueSnapshot {
        value
    }

    func save(_ snapshot: PlaybackQueueSnapshot) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted = true
            let startWaiters = firstSaveStartWaiters
            firstSaveStartWaiters.removeAll()
            for waiter in startWaiters {
                waiter.resume()
            }
            if !firstSaveReleased {
                await withCheckedContinuation { continuation in
                    firstSaveReleaseWaiters.append(continuation)
                }
            }
        }
        value = snapshot
    }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            firstSaveStartWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveReleased = true
        let releaseWaiters = firstSaveReleaseWaiters
        firstSaveReleaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class AsyncTestOperationState {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = false
    private(set) var finished = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func markFinished() {
        finished = true
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor ControlledStartupRecovery: ManagedMediaRemoving {
    private var didStartPendingRemovals = false
    private var isPendingRemovalsReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingRemovalsCallCount = 0

    func pendingRemovals() async throws -> [MediaRemovalTransaction] {
        pendingRemovalsCallCount += 1
        didStartPendingRemovals = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !isPendingRemovalsReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return []
    }

    func waitUntilPendingRemovalsStarts() async {
        guard !didStartPendingRemovals else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePendingRemovals() {
        isPendingRemovalsReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func prepareRemoval(of itemIDs: Set<MediaItemID>) async throws
        -> MediaRemovalTransaction
    {
        MediaRemovalTransaction(transactionID: UUID(), itemIDs: itemIDs)
    }

    func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {}
    func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {}
}

private actor FailingFirstLoadQueueRepository: PlaybackQueueRepository {
    private var value = PlaybackQueueSnapshot.empty
    private(set) var loadCount = 0

    func load() async throws -> PlaybackQueueSnapshot {
        loadCount += 1
        if loadCount == 1 {
            throw LibraryError.capacity(.storageUnavailable)
        }
        return value
    }

    func save(_ snapshot: PlaybackQueueSnapshot) async throws {
        value = snapshot
    }
}

private final class TestSettingsRepository: SettingsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings
    private var loadCountValue = 0

    init(value: AppSettings = .defaults) {
        self.value = value
    }

    var loadCount: Int {
        withLock(lock) { loadCountValue }
    }

    func load() async throws -> AppSettings {
        withLock(lock) {
            loadCountValue += 1
            return value
        }
    }

    func save(_ settings: AppSettings) async throws {
        try withLock(lock) {
            value = try settings.validated()
        }
    }

    func reset() async throws {
        withLock(lock) {
            value = .defaults
        }
    }

    func changes() -> AsyncStream<AppSettings> {
        AsyncStream { $0.finish() }
    }
}

private actor ControlledStorageMaintenance: StorageMaintenanceServing {
    private let startsBlocked: Bool
    private let failsPruning: Bool
    private var pruningIsReleased: Bool
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pruneCallCount = 0
    private(set) var lastLimit: StorageByteLimit?
    private(set) var lastRetention: Duration?

    init(startsBlocked: Bool = true, failsPruning: Bool = false) {
        self.startsBlocked = startsBlocked
        self.failsPruning = failsPruning
        self.pruningIsReleased = !startsBlocked
    }

    func usage() async throws -> StorageUsageSnapshot {
        StorageUsageSnapshot()
    }

    func perform(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        StorageMaintenanceResult(
            usageBefore: StorageUsageSnapshot(),
            usageAfter: StorageUsageSnapshot()
        )
    }

    func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult {
        pruneCallCount += 1
        lastLimit = limit
        lastRetention = retention
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if failsPruning {
            throw StorageMaintenanceError.failed
        }
        if startsBlocked, !pruningIsReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return StorageMaintenanceResult(
            usageBefore: StorageUsageSnapshot(),
            usageAfter: StorageUsageSnapshot()
        )
    }

    func waitUntilPruningStarts() async {
        guard pruneCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePruning() {
        pruningIsReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor BlockingFirstSaveSettingsRepository: SettingsRepository {
    private var value = AppSettings.defaults
    private var firstSaveStarted = false
    private var firstSaveReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resetCount = 0

    var currentValue: AppSettings { value }

    func load() async throws -> AppSettings {
        value
    }

    func save(_ settings: AppSettings) async throws {
        if !firstSaveStarted {
            firstSaveStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if !firstSaveReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        value = try settings.validated()
    }

    func reset() async throws {
        resetCount += 1
        value = .defaults
    }

    nonisolated func changes() -> AsyncStream<AppSettings> {
        AsyncStream { $0.finish() }
    }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor FixedRandomSource: AppRandomSource {
    let value: UInt64

    init(value: UInt64) {
        self.value = value
    }

    func nextUInt64() -> UInt64 {
        value
    }
}

private func withLock<Result>(
    _ lock: NSLock,
    _ operation: () throws -> Result
) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
}

@MainActor
private final class TestPlaybackEngine: PlaybackEngine {
    let capabilities: PlaybackCapabilities
    let equalizerDescriptor: EqualizerDescriptor?
    private(set) var state = PlaybackState.idle
    private(set) var preparedItems: [PlaybackItem] = []
    private(set) var eventStreamCount = 0
    private(set) var disposeCount = 0
    private var preparedItemCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        capabilities: PlaybackCapabilities,
        equalizerDescriptor: EqualizerDescriptor? = nil
    ) {
        self.capabilities = capabilities
        self.equalizerDescriptor = equalizerDescriptor
    }

    func makeEventStream() -> AsyncStream<PlaybackEvent> {
        eventStreamCount += 1
        return AsyncStream { _ in }
    }

    func prepare(_ item: PlaybackItem, startAt: Duration?) async throws {
        preparedItems.append(item)
        resumePreparedItemCountWaiters()
        let generation = state.generation.advanced()
        state = PlaybackState(
            phase: .preparing,
            generation: generation,
            itemID: item.itemID,
            position: startAt ?? .zero,
            duration: item.display.duration
        )
    }

    func waitUntilPreparedItemCount(_ expectedCount: Int) async {
        guard preparedItems.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            preparedItemCountWaiters.append((expectedCount, continuation))
        }
    }

    private func resumePreparedItemCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in preparedItemCountWaiters {
            if preparedItems.count >= expectedCount {
                continuation.resume()
            } else {
                pending.append((expectedCount, continuation))
            }
        }
        preparedItemCountWaiters = pending
    }

    func play() throws {
        state = PlaybackState(
            phase: .playing,
            generation: state.generation,
            itemID: state.itemID,
            position: state.position,
            duration: state.duration
        )
    }

    func pause() {
        state = PlaybackState(
            phase: .paused,
            generation: state.generation,
            itemID: state.itemID,
            position: state.position,
            duration: state.duration
        )
    }

    func simulateSystemPause() {
        pause()
    }

    func stop() {
        state = PlaybackState(
            phase: .stopped,
            generation: state.generation,
            itemID: state.itemID,
            position: state.position,
            duration: state.duration
        )
    }

    func seek(to position: Duration) async throws {
        state = PlaybackState(
            phase: state.phase,
            generation: state.generation,
            itemID: state.itemID,
            position: position,
            duration: state.duration
        )
    }

    func setRate(_ rate: Float) throws {}

    func apply(_ effects: AudioEffectConfiguration) throws {}

    func dispose() {
        disposeCount += 1
    }
}
