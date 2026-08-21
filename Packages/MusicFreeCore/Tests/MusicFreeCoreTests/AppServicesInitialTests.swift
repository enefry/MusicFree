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
    #expect(await maintenance.orphanPruneCallCount == 1)
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
    #expect(await maintenance.orphanPruneCallCount == 1)
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
        tracks: [Track(
            id: itemID,
            title: "Repeat Favorite",
            trackNumber: 4,
            discNumber: 2
        )]
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
    #expect(favorite.trackNumber == 4)
    #expect(favorite.discNumber == 2)
    #expect(unfavorite.trackNumber == 4)
    #expect(unfavorite.discNumber == 2)
    #expect(favoriteAgain.trackNumber == 4)
    #expect(favoriteAgain.discNumber == 2)
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
    let pendingMaintenance = ControlledStorageMaintenance(startsBlocked: false)
    let recoveryContainer = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: pendingRemover,
            libraryRepository: pendingLibrary,
            playbackQueueRepository: pendingQueue,
            storageMaintenance: pendingMaintenance
        )
    )
    let recovery = try await recoveryContainer.library.recoverPendingRemovals()
    #expect(recovery.finalizedTransactionIDs.count == 1)
    #expect(recovery.pendingTransactionIDs.isEmpty)
    #expect(pendingRemover.commitCount == 1)
    await pendingMaintenance.waitUntilOrphanPruningStarts()
    #expect(await pendingMaintenance.orphanPruneCallCount == 1)
}

@MainActor
@Test("Library metadata updates replace app-owned fields atomically")
func appServicesUpdateTrackMetadata() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-track")
    let artistID = ArtistID("metadata-artist")
    let albumID = AlbumID("metadata-album")
    let genreID = GenreID("metadata-genre")
    let track = Track(
        id: itemID,
        title: "Original",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 1,
        discNumber: 1,
        year: 2020,
        comment: "Original comment"
    )
    let repository = TestLibraryRepository(
        tracks: [track],
        albums: [Album(id: albumID, title: "Original Album", artistIDs: [artistID])],
        artists: [Artist(id: artistID, name: "Original Artist")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            artworkWriter: { _, _ in ArtworkWriteReceipt(wasCreated: true) },
            libraryRepository: repository
        )
    )
    let lyrics = TrackLyrics(rawText: "[00:01.00]Updated line")

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "  Updated  ",
        artistName: "Updated Artist",
        albumArtistName: "Updated Album Artist",
        albumName: "Updated Album",
        genreName: "Updated Genre",
        trackNumber: 7,
        discNumber: 2,
        year: 2024,
        comment: "Updated comment",
        lyrics: lyrics,
        artwork: .replace(Data("cover".utf8))
    ))

    #expect(updated.title == "Updated")
    #expect(updated.artistIDs.count == 1)
    #expect(updated.genreIDs.count == 1)
    #expect(updated.trackNumber == 7)
    #expect(updated.discNumber == 2)
    #expect(updated.year == 2024)
    #expect(updated.comment == "Updated comment")
    #expect(updated.lyrics == lyrics)
    #expect(updated.artworkID?.rawValue.hasPrefix("sha256-") == true)
    #expect(try await repository.track(id: itemID) == updated)
}

@MainActor
@Test("Album metadata updates one shared album for every track")
func appServicesUpdateAlbumMetadata() async throws {
    let albumID = AlbumID("album-level-edit")
    let firstID = MediaItemID(sourceID: .local, externalID: "album-level-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "album-level-second")
    let originalArtwork = ArtworkReference(
        id: ArtworkID("album-level-artwork"),
        variants: [.original],
        preferredVariant: .original
    )
    let repository = TestLibraryRepository(
        tracks: [
            Track(id: firstID, title: "First", albumID: albumID),
            Track(id: secondID, title: "Second", albumID: albumID),
        ],
        albums: [Album(
            id: albumID,
            title: "Wrong Album Name",
            sortTitle: "Wrong Album Name",
            artistIDs: [ArtistID("old-album-artist")],
            artwork: originalArtwork,
            releaseYear: 2001,
            trackCount: 2,
            albumType: .album
        )],
        artists: [Artist(id: ArtistID("old-album-artist"), name: "Old Album Artist")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: albumID,
        title: "Correct Album Name",
        artistNames: ["Correct Album Artist"],
        releaseYear: 2024
    ))

    #expect(updated.id == albumID)
    #expect(updated.title == "Correct Album Name")
    #expect(updated.artistIDs == [
        ArtistID("local-artist-\(MusicContentIdentity.token("Correct Album Artist"))")
    ])
    #expect(updated.releaseYear == 2024)
    #expect(updated.artwork == originalArtwork)
    #expect(updated.trackCount == 2)
    #expect(updated.albumType == .album)
    #expect(try await repository.album(id: albumID) == updated)
    #expect(try await repository.track(id: firstID)?.albumID == albumID)
    #expect(try await repository.track(id: secondID)?.albumID == albumID)
}

@MainActor
@Test("Renaming one track album does not mutate a shared album")
func appServicesMetadataRenameSplitsSharedAlbum() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "shared-album-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "shared-album-second")
    let albumID = AlbumID("shared-album")
    let albumArtistID = ArtistID("shared-album-artist")
    let repository = TestLibraryRepository(
        tracks: [
            Track(id: firstID, title: "First", albumID: albumID),
            Track(id: secondID, title: "Second", albumID: albumID),
        ],
        albums: [Album(
            id: albumID,
            title: "Original Album",
            sortTitle: "Original Sort",
            artistIDs: [albumArtistID],
            trackCount: 12
        )]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: firstID,
        title: "First",
        albumArtistName: "Shared Album Artist",
        albumName: "Renamed Album"
    ))

    #expect(updated.albumID != albumID)
    #expect(try await repository.track(id: secondID)?.albumID == albumID)
    #expect(try await repository.album(id: albumID)?.title == "Original Album")
    #expect(try await repository.album(id: albumID)?.sortTitle == "Original Sort")
    #expect(try await repository.album(id: albumID)?.trackCount == 12)
    #expect(try await repository.album(id: updated.albumID!)?.title == "Renamed Album")
    #expect(try await repository.album(id: updated.albumID!)?.sortTitle == nil)
    #expect(try await repository.album(id: updated.albumID!)?.trackCount == nil)
}

@MainActor
@Test("Metadata updates preserve existing album sort and count")
func appServicesMetadataUpdatePreservesAlbumPresentationFields() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "same-album-track")
    let albumID = AlbumID("same-album")
    let artistID = ArtistID("same-album-artist")
    let album = Album(
        id: albumID,
        title: "Album",
        sortTitle: "Album, The",
        artistIDs: [artistID],
        releaseYear: 2001,
        trackCount: 10
    )
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track", albumID: albumID)],
        albums: [album]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    _ = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated Track",
        albumName: "Album"
    ))

    let updatedAlbum = try #require(await repository.album(id: albumID))
    #expect(updatedAlbum.sortTitle == album.sortTitle)
    #expect(updatedAlbum.trackCount == album.trackCount)
    #expect(updatedAlbum.releaseYear == album.releaseYear)
}

@MainActor
@Test("Metadata updates preserve existing album artwork")
func appServicesPreserveAlbumArtworkDuringTrackUpdate() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "album-artwork-track")
    let albumID = AlbumID("album-artwork-album")
    let albumArtwork = ArtworkReference(
        id: ArtworkID("existing-album-cover"),
        variants: [.original],
        preferredVariant: .original
    )
    let albumArtistID = ArtistID("album-artwork-artist")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track", albumID: albumID)],
        albums: [Album(id: albumID, title: "Album", artistIDs: [albumArtistID], artwork: albumArtwork)]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated",
        albumName: "Album"
    ))

    #expect(updated.albumID == albumID)
    #expect(try await repository.album(id: albumID)?.artwork == albumArtwork)
}

@MainActor
@Test("Metadata updates preserve explicit multi-value relationships")
func appServicesPreserveMultiValueMetadataRelationships() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "multi-metadata-track")
    let albumID = AlbumID("multi-metadata-album")
    let track = Track(
        id: itemID,
        title: "Original",
        albumID: albumID,
        artistIDs: [ArtistID("legacy-artist-1"), ArtistID("legacy-artist-2")],
        genreIDs: [GenreID("legacy-genre-1"), GenreID("legacy-genre-2")]
    )
    let repository = TestLibraryRepository(
        tracks: [track],
        albums: [Album(id: albumID, title: "Album", artistIDs: [ArtistID("legacy-album-artist-1")])]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated",
        artistNames: ["Artist One", "Artist One", "Artist Two"],
        albumArtistNames: ["Album Artist One", "Album Artist One", "Album Artist Two"],
        albumName: "Album",
        genreNames: ["Rock", "Rock", "Live"]
    ))

    #expect(updated.artistIDs == [
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist One"))"),
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist Two"))")
    ])
    #expect(updated.genreIDs == [
        GenreID("local-genre-\(MusicContentIdentity.token("Rock"))"),
        GenreID("local-genre-\(MusicContentIdentity.token("Live"))")
    ])
}

@MainActor
@Test("Editing track artists preserves an existing album identity and artists")
func appServicesMetadataArtistEditPreservesExistingAlbumRelationship() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "existing-album-artist-edit")
    let albumID = AlbumID("existing-album-artist-edit-album")
    let albumArtistID = ArtistID("existing-album-artist")
    let repository = TestLibraryRepository(
        tracks: [Track(
            id: itemID,
            title: "Track",
            albumID: albumID,
            artistIDs: [ArtistID("old-track-artist")]
        )],
        albums: [Album(
            id: albumID,
            title: "Album",
            artistIDs: [albumArtistID]
        )]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Track",
        artistNames: ["New Track Artist"],
        albumName: "Album"
    ))

    #expect(updated.albumID == albumID)
    #expect(try await repository.album(id: albumID)?.artistIDs == [albumArtistID])
    #expect(updated.artistIDs == [
        ArtistID("local-artist-\(MusicContentIdentity.token("New Track Artist"))")
    ])
}

@MainActor
@Test("Renamed albums keep the importer-compatible artist-name identity")
func appServicesMetadataAlbumRenameUsesArtistNamesForIdentity() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "album-identity-rename")
    let albumID = AlbumID("album-identity-rename-original")
    let albumArtistID = ArtistID("album-identity-rename-artist")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track", albumID: albumID)],
        albums: [Album(id: albumID, title: "Original Album", artistIDs: [albumArtistID])],
        artists: [Artist(id: albumArtistID, name: "Album Artist")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Track",
        albumName: "Renamed Album"
    ))

    #expect(updated.albumID == AlbumID(
        "local-album-\(MusicContentIdentity.token("Renamed Album|Album Artist"))"
    ))
}

@MainActor
@Test("Concurrent metadata updates serialize around the complete read-modify-write")
func appServicesSerializeConcurrentMetadataUpdates() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "serialized-metadata-update")
    let albumID = AlbumID("serialized-metadata-album")
    let lookupGate = ResolutionGate(releaseSubsequentLookupsImmediately: true)
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Original", albumID: albumID)],
        albums: [Album(id: albumID, title: "Album")],
        metadataLookupGate: lookupGate
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let firstTask = Task { @MainActor in
        try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "First",
            albumName: "Album"
        ))
    }
    await lookupGate.waitUntilStarted()

    let secondTask = Task { @MainActor in
        try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Second",
            albumName: "Album"
        ))
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(await lookupGate.lookupCount() == 1)

    await lookupGate.release()
    let first = try await firstTask.value
    let second = try await secondTask.value
    #expect(first.title == "First")
    #expect(second.title == "Second")
    #expect(try await repository.track(id: itemID)?.title == "Second")
}

@MainActor
@Test("Library deletion waits for an in-flight metadata update")
func appServicesSerializesDeletionWithMetadataUpdates() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "delete-during-metadata")
    let albumID = AlbumID("delete-during-metadata-album")
    let lookupGate = ResolutionGate(releaseSubsequentLookupsImmediately: true)
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Original", albumID: albumID)],
        albums: [Album(id: albumID, title: "Album")],
        metadataLookupGate: lookupGate
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            managedMediaRemover: TestRemoval(),
            libraryRepository: repository
        )
    )

    let updateTask = Task { @MainActor in
        try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Updated",
            albumName: "Album"
        ))
    }
    await lookupGate.waitUntilStarted()

    let deletionTask = Task { @MainActor in
        try await container.library.delete([itemID])
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(try await repository.track(id: itemID)?.title == "Original")

    await lookupGate.release()
    _ = try await updateTask.value
    _ = try await deletionTask.value
    #expect(try await repository.track(id: itemID) == nil)
}

@MainActor
@Test("Metadata updates can explicitly clear album-artist relationships")
func appServicesMetadataCanClearAlbumArtists() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "clear-album-artist")
    let albumID = AlbumID("clear-album-artist-album")
    let albumArtistID = ArtistID("clear-album-artist")
    let repository = TestLibraryRepository(
        tracks: [Track(
            id: itemID,
            title: "Track",
            albumID: albumID,
            artistIDs: [ArtistID("track-artist-one"), ArtistID("track-artist-two")]
        )],
        albums: [Album(id: albumID, title: "Album", artistIDs: [albumArtistID])]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Track",
        albumArtistNames: [],
        albumName: "Album"
    ))

    let updatedAlbum = try #require(await repository.album(id: updated.albumID!))
    #expect(updated.albumID != albumID)
    #expect(updatedAlbum.artistIDs.isEmpty)
    #expect(try await repository.album(id: albumID)?.artistIDs == [albumArtistID])
}

@MainActor
@Test("Metadata updates use structured track artists for a new album fallback")
func appServicesMetadataAlbumArtistFallbackPreservesMultipleArtists() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "multi-artist-album-fallback")
    let artistNames = ["Artist One", "Artist Two"]
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Track",
        artistName: artistNames.joined(separator: " / "),
        artistNames: artistNames,
        albumName: "New Album"
    ))

    let album = try #require(await repository.album(id: updated.albumID!))
    #expect(album.artistIDs == artistNames.map {
        ArtistID("local-artist-\(MusicContentIdentity.token($0))")
    })
}

@MainActor
@Test("Same-title albums keep distinct ordered multi-artist identities")
func appServicesMetadataSeparatesSameTitleMultiArtistAlbums() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "same-title-multi-artist-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "same-title-multi-artist-second")
    let repository = TestLibraryRepository(
        tracks: [
            Track(id: firstID, title: "First Track"),
            Track(id: secondID, title: "Second Track")
        ]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let first = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: firstID,
        title: "First Track",
        artistNames: ["Artist One", "Artist Two"],
        albumArtistNames: ["Artist One", "Artist Two"],
        albumName: "Shared Title"
    ))
    let second = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: secondID,
        title: "Second Track",
        artistNames: ["Artist One", "Artist Three"],
        albumArtistNames: ["Artist One", "Artist Three"],
        albumName: "Shared Title"
    ))

    #expect(first.albumID != nil)
    #expect(second.albumID != nil)
    #expect(first.albumID != second.albumID)
    #expect(try await repository.album(id: first.albumID!)?.artistIDs == [
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist One"))"),
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist Two"))")
    ])
    #expect(try await repository.album(id: second.albumID!)?.artistIDs == [
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist One"))"),
        ArtistID("local-artist-\(MusicContentIdentity.token("Artist Three"))")
    ])
}

@MainActor
@Test("Metadata updates preserve a custom track sort title")
func appServicesMetadataPreservesCustomTrackSortTitle() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "custom-sort-title")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Original", sortTitle: "Original, The")]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated"
    ))

    #expect(updated.sortTitle == "Original, The")
}

@MainActor
@Test("Metadata replacement clears fields that are intentionally omitted")
func appServicesMetadataReplacementClearsOmittedFields() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-replacement")
    let albumID = AlbumID("metadata-replacement-album")
    let artistID = ArtistID("metadata-replacement-artist")
    let genreID = GenreID("metadata-replacement-genre")
    let repository = TestLibraryRepository(
        tracks: [Track(
            id: itemID,
            title: "Original",
            albumID: albumID,
            artistIDs: [artistID],
            genreIDs: [genreID],
            trackNumber: 3,
            discNumber: 2,
            year: 2020,
            comment: "Comment",
            lyrics: TrackLyrics(rawText: "Original lyrics"),
            artwork: ArtworkReference(id: ArtworkID("original-artwork"))
        )],
        albums: [Album(id: albumID, title: "Album", artistIDs: [artistID])]
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated"
    ))

    #expect(updated.title == "Updated")
    #expect(updated.albumID == nil)
    #expect(updated.artistIDs.isEmpty)
    #expect(updated.genreIDs.isEmpty)
    #expect(updated.trackNumber == nil)
    #expect(updated.discNumber == nil)
    #expect(updated.year == nil)
    #expect(updated.comment == nil)
    #expect(updated.lyrics == nil)
    #expect(updated.artwork?.id == ArtworkID("original-artwork"))
}

@MainActor
@Test("Metadata relationship read failures are mapped at the app boundary")
func appServicesMapMetadataRelationshipReadFailures() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-read-failure")
    let albumID = AlbumID("metadata-read-failure-album")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track", albumID: albumID)],
        albums: [Album(id: albumID, title: "Album")],
        metadataReadError: .capacity(.storageUnavailable)
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    do {
        _ = try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Updated",
            albumName: "Album"
        ))
        Issue.record("Metadata update unexpectedly succeeded after album lookup failed")
    } catch let error as AppServiceError {
        #expect(error == .library(.capacity(.storageUnavailable)))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@MainActor
@Test("Cancelled metadata updates do not apply a library transaction")
func appServicesCancelMetadataUpdateBeforeCommit() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-cancelled")
    let albumID = AlbumID("metadata-cancelled-album")
    let gate = ResolutionGate()
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Original", albumID: albumID)],
        albums: [Album(id: albumID, title: "Original Album")],
        metadataLookupGate: gate
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(libraryRepository: repository)
    )

    let update = Task { @MainActor in
        try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Updated",
            albumName: "Updated Album"
        ))
    }
    await gate.waitUntilStarted()
    update.cancel()
    await gate.release()

    switch await update.result {
    case .success:
        Issue.record("A cancelled metadata update unexpectedly committed")
    case .failure:
        break
    }
    #expect(try await repository.track(id: itemID)?.title == "Original")
}

@MainActor
@Test("Metadata artwork cleanup runs when the library transaction fails")
func appServicesCleanUpNewArtworkAfterMetadataFailure() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-artwork-failure")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track")],
        applyError: .capacity(.storageUnavailable)
    )
    let cleanup = ArtworkCleanupRecorder()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            artworkWriter: { _, artworkID in
                ArtworkWriteReceipt(wasCreated: true) { committed in
                    if !committed {
                        await cleanup.append(artworkID)
                    }
                }
            },
            libraryRepository: repository
        )
    )

    do {
        _ = try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Updated",
            artwork: .replace(Data("failed-cover".utf8))
        ))
        Issue.record("Metadata update unexpectedly succeeded")
    } catch let error as AppServiceError {
        #expect(error == .library(.capacity(.storageUnavailable)))
    }

    #expect(await cleanup.ids == [
        ArtworkID(rawValue: "sha256-\(MusicContentIdentity.sha256Hex(Data("failed-cover".utf8)))")
    ])
}

@MainActor
@Test("Artwork cleanup failure does not roll back committed metadata")
func appServicesKeepMetadataWhenArtworkCleanupFails() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-artwork-prune-failure")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Original")]
    )
    let maintenance = ControlledStorageMaintenance(
        startsBlocked: false,
        failsOrphanPruning: true
    )
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: repository,
            storageMaintenance: maintenance
        )
    )

    let updated = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: itemID,
        title: "Updated"
    ))
    await maintenance.waitUntilOrphanPruningStarts()

    #expect(updated.title == "Updated")
    #expect(try await repository.track(id: itemID)?.title == "Updated")
    #expect(await maintenance.orphanPruneCallCount == 1)
}

@Test("Artwork write receipts finish only once")
func artworkWriteReceiptFinishesOnlyOnce() async {
    let cleanup = ArtworkCleanupRecorder()
    let artworkID = ArtworkID("receipt-once")
    let receipt = ArtworkWriteReceipt(wasCreated: true) { committed in
        if !committed {
            await cleanup.append(artworkID)
        }
    }

    await receipt.finish(committed: false)
    await receipt.finish(committed: true)

    #expect(await cleanup.ids == [artworkID])
}

@MainActor
@Test("Metadata updates reject oversized artwork before writing")
func appServicesRejectOversizedArtworkBeforeWriting() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "oversized-metadata-artwork")
    let repository = TestLibraryRepository(
        tracks: [Track(id: itemID, title: "Track")]
    )
    let writerRecorder = ArtworkWriterCallRecorder()
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            artworkWriter: { _, _ in
                await writerRecorder.record()
                return ArtworkWriteReceipt(wasCreated: true)
            },
            libraryRepository: repository
        )
    )

    do {
        _ = try await container.library.updateMetadata(TrackMetadataUpdate(
            itemID: itemID,
            title: "Track",
            artwork: .replace(Data(repeating: 0x7f, count: ArtworkDataLimits.maximumByteCount + 1))
        ))
        Issue.record("Oversized artwork unexpectedly succeeded")
    } catch let error as AppServiceError {
        #expect(error == .invalidRequest(operation: "library.metadata.artworkSize"))
    }

    #expect(await writerRecorder.count == 0)
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
@Test("Playback completion starts the next track from the beginning")
func appServicesNaturalCompletionStartsNextTrackFromTheBeginning() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "completion-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "completion-second")
    let entries = [firstID, secondID].enumerated().map { index, itemID in
        PlaybackQueueEntry(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                450 + index
            ))!,
            itemID: itemID
        )
    }
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: entries[0].id,
            resumePosition: .seconds(10)
        )
    )
    let engine = FakePlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "Completion First", duration: .seconds(20)),
                Track(id: secondID, title: "Completion Second", duration: .seconds(5)),
            ]),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.resume)
    #expect(engine.prepareCalls.count == 1)
    #expect(engine.prepareCalls[0].startAt == .seconds(10))

    let firstGeneration = engine.state.generation
    engine.emit(.positionChanged(
        generation: firstGeneration,
        itemID: firstID,
        position: .seconds(18),
        duration: .seconds(20)
    ))
    engine.emit(.phaseChanged(
        generation: firstGeneration,
        itemID: firstID,
        phase: .stopped
    ))
    engine.emit(.ended(
        generation: firstGeneration,
        itemID: firstID,
        reason: .ended
    ))
    await waitForPreparedItemCount(2, on: engine)

    #expect(engine.prepareCalls.map(\.item.itemID) == [firstID, secondID])
    guard engine.prepareCalls.count >= 2 else { return }
    #expect(engine.prepareCalls[1].startAt == nil)
    #expect(container.playback.snapshot.currentItemID == secondID)
    #expect(container.playback.snapshot.phase == .playing)
    #expect(container.playback.snapshot.queue.resumePosition == nil)
}

@MainActor
@Test("Playback completion skips queue entries without an available variant")
func appServicesCompletionSkipsUnavailableQueueEntries() async throws {
    let firstID = MediaItemID(sourceID: .local, externalID: "skip-first")
    let unavailableEntry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000471")!,
        logicalTrackID: LogicalTrackID("skip-unavailable"),
        preferredVariantID: nil
    )
    let secondID = MediaItemID(sourceID: .local, externalID: "skip-second")
    let entries = [
        PlaybackQueueEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000472")!,
            itemID: firstID
        ),
        unavailableEntry,
        PlaybackQueueEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000473")!,
            itemID: secondID
        )
    ]
    let queue = TestQueueRepository(value: PlaybackQueueSnapshot(
        entries: entries,
        currentEntryID: entries[0].id
    ))
    let engine = FakePlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(tracks: [
                Track(id: firstID, title: "Skip First", duration: .seconds(20)),
                Track(id: secondID, title: "Skip Second", duration: .seconds(5))
            ]),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.resume)
    let generation = engine.state.generation
    engine.emit(.ended(
        generation: generation,
        itemID: firstID,
        reason: .ended
    ))

    await waitForPreparedItemCount(2, on: engine)

    #expect(engine.prepareCalls.map(\.item.itemID) == [firstID, secondID])
    #expect(container.playback.snapshot.currentItemID == secondID)
    #expect(container.playback.snapshot.phase == .playing)
}

@MainActor
@Test("Single-track repeat restarts from the beginning after natural completion")
func appServicesSingleRepeatRestartsFromTheBeginning() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "repeat-one")
    let entry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000470")!,
        itemID: itemID
    )
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [entry],
            currentEntryID: entry.id,
            repeatMode: .one,
            resumePosition: .seconds(4)
        )
    )
    let engine = FakePlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(
                tracks: [Track(id: itemID, title: "Repeat One", duration: .seconds(20))]
            ),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.resume)
    #expect(engine.prepareCalls[0].startAt == .seconds(4))

    let generation = engine.state.generation
    engine.emit(.positionChanged(
        generation: generation,
        itemID: itemID,
        position: .seconds(20),
        duration: .seconds(20)
    ))
    engine.emit(.phaseChanged(
        generation: generation,
        itemID: itemID,
        phase: .stopped
    ))
    engine.emit(.ended(
        generation: generation,
        itemID: itemID,
        reason: .ended
    ))

    await waitForPreparedItemCount(2, on: engine)
    for _ in 0..<2_000 where container.playback.snapshot.phase != .playing {
        try? await Task.sleep(for: .milliseconds(1))
    }

    #expect(engine.prepareCalls.count >= 2)
    guard engine.prepareCalls.count >= 2 else { return }
    #expect(engine.prepareCalls[1].startAt == .zero)
    #expect(container.playback.snapshot.currentItemID == itemID)
    #expect(container.playback.snapshot.phase == .playing)
    #expect(container.playback.snapshot.queue.resumePosition == nil)
}

@MainActor
@Test("Playback completion at queue end clears the persisted EOF position")
func appServicesQueueEndClearsResumePositionBeforeManualResume() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "queue-end")
    let entry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000480")!,
        itemID: itemID
    )
    let queue = TestQueueRepository(
        value: PlaybackQueueSnapshot(
            entries: [entry],
            currentEntryID: entry.id,
            resumePosition: .seconds(20)
        )
    )
    let engine = FakePlaybackEngine(capabilities: [.seeking])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(
                tracks: [Track(id: itemID, title: "Queue End", duration: .seconds(20))]
            ),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.resume)
    #expect(engine.prepareCalls[0].startAt == .seconds(20))

    let generation = engine.state.generation
    engine.emit(.positionChanged(
        generation: generation,
        itemID: itemID,
        position: .seconds(20),
        duration: .seconds(20)
    ))
    engine.emit(.ended(
        generation: generation,
        itemID: itemID,
        reason: .ended
    ))

    for _ in 0..<2_000 where container.playback.snapshot.phase != .stopped {
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(container.playback.snapshot.queue.resumePosition == nil)

    try await container.playback.execute(.resume)
    #expect(engine.prepareCalls.count == 2)
    #expect(engine.prepareCalls[1].startAt == nil)
}

@MainActor
@Test("New playback queue entries preserve logical track and variant identity")
func appServicesQueueEntriesUseCanonicalTrackIdentity() async throws {
    let variantIDs = ["canonical-a", "canonical-b", "canonical-c"].map {
        MediaItemID(sourceID: .local, externalID: $0)
    }
    let logicalIDs = [
        LogicalTrackID("release:canonical:track:1"),
        LogicalTrackID("release:canonical:track:2"),
        LogicalTrackID("release:canonical:track:3"),
    ]
    let assetIDs = [
        MediaAssetID(sourceID: .local, externalID: "canonical-disc.flac"),
        MediaAssetID(sourceID: .local, externalID: "canonical-disc.flac"),
        MediaAssetID(sourceID: .local, externalID: "canonical-disc.flac"),
    ]
    let tracks = zip(variantIDs.indices, variantIDs).map { index, variantID in
        Track(
            id: variantID,
            logicalTrackID: logicalIDs[index],
            assetID: assetIDs[index],
            playbackSelection: PlaybackSelection(
                range: PlaybackRange(
                    start: .seconds(Double(index) * 60),
                    end: .seconds(Double(index + 1) * 60)
                )
            ),
            title: "Canonical " + String(index + 1),
            duration: .seconds(60)
        )
    }
    let queue = TestQueueRepository()
    let engine = TestPlaybackEngine(capabilities: [])
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(tracks: tracks),
            playbackQueueRepository: queue,
            playbackEngine: engine
        )
    )
    _ = try await container.start()

    try await container.playback.execute(.play(itemID: variantIDs[0]))
    try await container.playback.execute(.enqueue(itemID: variantIDs[1], at: nil))
    try await container.playback.execute(.enqueueItems(itemIDs: [variantIDs[2]]))

    let persisted = try await queue.load()
    #expect(persisted.entries.map(\.logicalTrackID) == logicalIDs)
    #expect(persisted.entries.map(\.preferredVariantID) == variantIDs.map(Optional.some))
    #expect(persisted.itemIDs == variantIDs)
    #expect(engine.preparedItems.first?.itemID == variantIDs[0])
    #expect(engine.preparedItems.first?.selection == tracks[0].playbackSelection)
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
@Test("Playback startup canonicalizes legacy queue identity without dropping unavailable entries")
func playbackStartupCanonicalizesLegacyQueueIdentity() async throws {
    let availableID = MediaItemID(sourceID: .local, externalID: "legacy-available")
    let unavailableID = MediaItemID(sourceID: .local, externalID: "legacy-unavailable")
    let availableLogicalID = LogicalTrackID("release:legacy:track:1")
    let availableTrack = Track(
        id: availableID,
        logicalTrackID: availableLogicalID,
        title: "Legacy Available",
        duration: .seconds(30)
    )
    let availableEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    let unavailableEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    let legacyQueue = PlaybackQueueSnapshot(
        entries: [
            PlaybackQueueEntry(id: availableEntryID, itemID: availableID),
            PlaybackQueueEntry(id: unavailableEntryID, itemID: unavailableID)
        ],
        currentEntryID: availableEntryID,
        repeatMode: .one,
        shuffleMode: .on,
        shuffleSeed: 42,
        shuffleOrder: [unavailableEntryID, availableEntryID],
        resumePosition: .seconds(8)
    )
    let queue = TestQueueRepository(value: legacyQueue)
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            mediaSources: [TestSource()],
            libraryRepository: TestLibraryRepository(tracks: [availableTrack]),
            playbackQueueRepository: queue,
            playbackEngine: TestPlaybackEngine(capabilities: [.seeking])
        )
    )

    _ = try await container.start()

    let persisted = try await queue.load()
    #expect(queue.saveCount == 1)
    #expect(persisted.entries.map(\.id) == [availableEntryID, unavailableEntryID])
    #expect(persisted.entries[0].logicalTrackID == availableLogicalID)
    #expect(persisted.entries[0].preferredVariantID == availableID)
    #expect(persisted.entries[1] == legacyQueue.entries[1])
    #expect(persisted.currentEntryID == legacyQueue.currentEntryID)
    #expect(persisted.repeatMode == legacyQueue.repeatMode)
    #expect(persisted.shuffleMode == legacyQueue.shuffleMode)
    #expect(persisted.shuffleSeed == legacyQueue.shuffleSeed)
    #expect(persisted.shuffleOrder == legacyQueue.shuffleOrder)
    #expect(persisted.resumePosition == legacyQueue.resumePosition)
    #expect(container.playback.snapshot.currentItemID == availableID)
    #expect(container.playback.snapshot.position == .seconds(8))

    await container.stop()
}

@MainActor
@Test("Playback startup tolerates a logical-only restored queue entry")
func playbackStartupToleratesLogicalOnlyQueueEntry() async throws {
    let entry = PlaybackQueueEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000603")!,
        logicalTrackID: LogicalTrackID("logical-only-restored-entry"),
        preferredVariantID: nil
    )
    let queue = TestQueueRepository(value: PlaybackQueueSnapshot(
        entries: [entry],
        currentEntryID: entry.id,
        resumePosition: .seconds(8)
    ))
    let container = try AppServiceContainer(
        dependencies: AppDependencies(
            libraryRepository: TestLibraryRepository(tracks: []),
            playbackQueueRepository: queue
        )
    )

    _ = try await container.start()

    #expect(container.playback.snapshot.currentItemID == nil)
    #expect(container.playback.snapshot.queue.entries == [entry])
    await container.stop()
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
        persisted.entries.first { $0.id == entryID }?.itemID ?? nil
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

@MainActor
private func waitForPreparedItemCount(
    _ expectedCount: Int,
    on engine: FakePlaybackEngine
) async {
    for _ in 0..<2_000 {
        if engine.prepareCalls.count >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
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
    private let releaseSubsequentLookupsImmediately: Bool
    private var didStart = false
    private var isReleased = false
    private var lookupCalls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(releaseSubsequentLookupsImmediately: Bool = false) {
        self.releaseSubsequentLookupsImmediately = releaseSubsequentLookupsImmediately
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockUntilReleased() async {
        lookupCalls += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased,
              !releaseSubsequentLookupsImmediately || lookupCalls == 1
        else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func lookupCount() -> Int {
        lookupCalls
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
    private var artworkValues: [ArtworkID: ArtworkReference]
    private let metadataLookupGate: ResolutionGate?
    private let metadataReadError: LibraryError?
    private let applyError: LibraryError?
    var removeError: LibraryError?

    init(
        tracks: [Track],
        albums: [Album] = [],
        artists: [Artist] = [],
        metadataLookupGate: ResolutionGate? = nil,
        metadataReadError: LibraryError? = nil,
        applyError: LibraryError? = nil
    ) {
        values = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        albumValues = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        artistValues = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
        artworkValues = [:]
        self.metadataLookupGate = metadataLookupGate
        self.metadataReadError = metadataReadError
        self.applyError = applyError
    }

    func track(id: MediaItemID) async throws -> Track? {
        withLock(lock) { values[id] }
    }

    func album(id: AlbumID) async throws -> Album? {
        await metadataLookupGate?.blockUntilReleased()
        if let metadataReadError { throw metadataReadError }
        return withLock(lock) { albumValues[id] }
    }

    func artist(id: ArtistID) async throws -> Artist? {
        await metadataLookupGate?.blockUntilReleased()
        if let metadataReadError { throw metadataReadError }
        return withLock(lock) { artistValues[id] }
    }

    func artwork(id: ArtworkID) async throws -> ArtworkReference? {
        withLock(lock) { artworkValues[id] }
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
        if let applyError { throw applyError }
        withLock(lock) {
            for mutation in transaction.mutations {
                guard case .upsert(let upsert) = mutation else { continue }
                switch upsert {
                case .track(let track):
                    values[track.id] = track
                case .album(let album):
                    albumValues[album.id] = album
                case .artist(let artist):
                    artistValues[artist.id] = artist
                case .genre:
                    break
                case .artwork(let artwork):
                    artworkValues[artwork.id] = artwork
                default:
                    break
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

private actor ArtworkCleanupRecorder {
    private(set) var ids: [ArtworkID] = []

    func append(_ artworkID: ArtworkID) {
        ids.append(artworkID)
    }
}

private actor ArtworkWriterCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
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
    private let failsOrphanPruning: Bool
    private var pruningIsReleased: Bool
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var orphanPruneStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pruneCallCount = 0
    private(set) var orphanPruneCallCount = 0
    private(set) var lastLimit: StorageByteLimit?
    private(set) var lastRetention: Duration?

    init(
        startsBlocked: Bool = true,
        failsPruning: Bool = false,
        failsOrphanPruning: Bool = false
    ) {
        self.startsBlocked = startsBlocked
        self.failsPruning = failsPruning
        self.failsOrphanPruning = failsOrphanPruning
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

    func pruneOrphanedArtwork() async throws -> StorageMaintenanceResult {
        orphanPruneCallCount += 1
        let waiters = orphanPruneStartWaiters
        orphanPruneStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if failsOrphanPruning {
            throw StorageMaintenanceError.failed
        }
        return StorageMaintenanceResult(
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

    func waitUntilOrphanPruningStarts() async {
        guard orphanPruneCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            orphanPruneStartWaiters.append(continuation)
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
