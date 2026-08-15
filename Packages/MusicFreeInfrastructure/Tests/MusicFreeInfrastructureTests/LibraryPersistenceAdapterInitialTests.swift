import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import Testing

@testable import LibraryPersistenceAdapter

@Test("persistence dates retain precision and read legacy millisecond payloads")
func persistenceCodecDateCompatibility() throws {
    let preciseDate = Date(timeIntervalSinceReferenceDate: 123_456.789123)
    let preciseData = try PersistenceCodec.encode(DatePayload(date: preciseDate))
    let preciseRoundTrip = try PersistenceCodec.decode(DatePayload.self, from: preciseData)
    #expect(preciseRoundTrip.date == preciseDate)

    let legacyDate = Date(timeIntervalSince1970: 100.123)
    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .millisecondsSince1970
    let legacyData = try legacyEncoder.encode(DatePayload(date: legacyDate))
    let legacyRoundTrip = try PersistenceCodec.decode(DatePayload.self, from: legacyData)
    #expect(legacyRoundTrip.date == legacyDate)
}

@Test("records keep numbering and album type scalar fields in sync with payloads")
func recordMappersPersistNumberingAndAlbumType() throws {
    let album = Album(
        id: AlbumID("typed-album"),
        title: "Typed Album",
        albumType: .soundtrack
    )
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "numbered-track"),
        title: "Numbered Track",
        albumID: album.id,
        trackNumber: 8,
        discNumber: 2
    )

    let albumRecord = try LibraryRecordMapper.makeAlbum(album)
    let trackRecord = try LibraryRecordMapper.makeTrack(track)
    #expect(albumRecord.albumType == "soundtrack")
    #expect(trackRecord.trackNumber == 8)
    #expect(trackRecord.discNumber == 2)
    #expect(try LibraryRecordMapper.album(from: albumRecord) == album)
    #expect(try LibraryRecordMapper.track(from: trackRecord) == track)
}

@Test("artwork reference checks include tracks, collections, and playlists")
func artworkReferenceChecksIncludeAllLibraryOwners() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let playlistRepository = SwiftDataPlaylistRepository(store: store)
    let trackArtworkID = ArtworkID("artwork-track-owner")
    let albumArtworkID = ArtworkID("artwork-album-owner")
    let artistArtworkID = ArtworkID("artwork-artist-owner")
    let playlistArtworkID = ArtworkID("artwork-playlist-owner")
    let orphanArtworkID = ArtworkID("artwork-no-owner")
    let playlistArtworkOwnerID = MediaItemID(
        sourceID: .local,
        externalID: "playlist-artwork-owner"
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "artwork-owner-references",
        mutations: [
            .upsert(.artwork(ArtworkReference(id: trackArtworkID))),
            .upsert(.artwork(ArtworkReference(id: albumArtworkID))),
            .upsert(.artwork(ArtworkReference(id: artistArtworkID))),
            .upsert(.artwork(ArtworkReference(id: playlistArtworkID))),
            .upsert(.artwork(ArtworkReference(id: orphanArtworkID))),
            .upsert(.album(Album(
                id: AlbumID("artwork-owner-album"),
                title: "Album",
                artwork: ArtworkReference(id: albumArtworkID)
            ))),
            .upsert(.artist(Artist(
                id: ArtistID("artwork-owner-artist"),
                name: "Artist",
                artwork: ArtworkReference(id: artistArtworkID)
            ))),
            .upsert(.track(Track(
                id: MediaItemID(sourceID: .local, externalID: "artwork-owner-track"),
                title: "Track",
                albumID: AlbumID("artwork-owner-album"),
                artistIDs: [ArtistID("artwork-owner-artist")],
                artwork: ArtworkReference(id: trackArtworkID)
            ))),
            // Keep the playlist artwork record alive until the playlist is
            // created; the transaction prunes unreferenced artwork records.
            .upsert(.track(Track(
                id: playlistArtworkOwnerID,
                title: "Playlist artwork owner",
                artwork: ArtworkReference(id: playlistArtworkID)
            )))
        ]
    ))
    _ = try await playlistRepository.create(PlaylistDraft(
        name: "Playlist",
        artworkID: playlistArtworkID
    ))
    try await library.remove([playlistArtworkOwnerID])

    #expect(try await library.isArtworkReferenced(trackArtworkID))
    #expect(try await library.isArtworkReferenced(albumArtworkID))
    #expect(try await library.isArtworkReferenced(artistArtworkID))
    #expect(try await library.isArtworkReferenced(playlistArtworkID))
    #expect(!(try await library.isArtworkReferenced(orphanArtworkID)))
    await store.close()
}

@Test("library persistence round trips and paginates with stable ordering")
func libraryPersistenceRoundTripAndPagination() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("library.store")
    let configuration = try LibraryPersistenceConfiguration(storeURL: storeURL)

    let firstStore = try LibraryPersistenceStore(configuration: configuration)
    let schemaVersion = await firstStore.schemaVersion
    #expect(schemaVersion == 1)
    let firstLibrary = SwiftDataLibraryRepository(store: firstStore)
    let values = makeLibraryValues()
    try await firstLibrary.apply(try LibraryTransaction(
        idempotencyKey: "initial-library",
        mutations: values.mutations
    ))
    await firstStore.close()

    let reopenedStore = try LibraryPersistenceStore(configuration: configuration)
    let library = SwiftDataLibraryRepository(store: reopenedStore)
    let firstPage = try await library.tracks(
        matching: TrackQuery(),
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(firstPage.elements.map(\.title) == ["Alpha", "Beta"])
    #expect(firstPage.hasNextPage)

    guard let nextPage = try firstPage.nextPage(limit: 2) else {
        Issue.record("The first page should provide a continuation")
        return
    }
    let secondPage = try await library.tracks(
        matching: TrackQuery(),
        page: nextPage
    )
    #expect(secondPage.elements.map(\.title) == ["Gamma"])
    #expect(!secondPage.hasNextPage)
    let persistedTrack = try await library.track(id: values.tracks[0].id)
    #expect(persistedTrack == values.tracks[0])
    #expect(try await library.album(id: AlbumID("album-1"))?.title == "Album")
    #expect(try await library.artist(id: ArtistID("artist-1"))?.name == "Artist")
    await reopenedStore.close()
}

@Test("relation mutations preserve track numbering and metadata overrides")
func relationMutationsPreserveTrackMetadata() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "relation-metadata-track")
    let albumID = AlbumID("relation-metadata-album")
    let artistID = ArtistID("relation-metadata-artist")
    let genreID = GenreID("relation-metadata-genre")
    let artworkID = ArtworkID("relation-metadata-artwork")
    let track = Track(
        id: itemID,
        title: "Relation Metadata",
        trackNumber: 7,
        discNumber: 3,
        fileName: "relation.mp3",
        technicalInfo: nil,
        year: 2024,
        comment: "kept",
        lyrics: TrackLyrics(rawText: "line"),
        artwork: ArtworkReference(id: artworkID)
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "relation-metadata",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album"))),
            .upsert(.artist(Artist(id: artistID, name: "Artist"))),
            .upsert(.genre(Genre(id: genreID, name: "Genre"))),
            .upsert(.artwork(ArtworkReference(id: artworkID))),
            .upsert(.track(track)),
            .relation(.setAlbum(trackID: itemID, albumID: albumID)),
            .relation(.setArtists(trackID: itemID, artistIDs: [artistID])),
            .relation(.setGenres(trackID: itemID, genreIDs: [genreID])),
            .relation(.setArtwork(trackID: itemID, artworkID: artworkID)),
        ]
    ))

    #expect(try await library.track(id: itemID) == Track(
        id: itemID,
        title: "Relation Metadata",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 7,
        discNumber: 3,
        fileName: "relation.mp3",
        year: 2024,
        comment: "kept",
        lyrics: TrackLyrics(rawText: "line"),
        artwork: ArtworkReference(id: artworkID)
    ))
    await store.close()
}

@Test("source-aware artist browsing includes album artists")
func sourceAwareArtistBrowsingIncludesAlbumArtists() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "album-artist-source")
    let albumID = AlbumID("album-artist-source-album")
    let trackArtistID = ArtistID("album-artist-source-track-artist")
    let albumArtistID = ArtistID("album-artist-source-album-artist")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "album-artist-source",
        mutations: [
            .upsert(.album(Album(
                id: albumID,
                title: "Album",
                artistIDs: [albumArtistID]
            ))),
            .upsert(.artist(Artist(id: trackArtistID, name: "Track Artist"))),
            .upsert(.artist(Artist(id: albumArtistID, name: "Album Artist"))),
            .upsert(.track(Track(
                id: itemID,
                title: "Track",
                albumID: albumID,
                artistIDs: [trackArtistID]
            )))
        ]
    ))

    let localArtists = try await library.artists(
        matching: ArtistQuery(sourceID: .local),
        page: try LibraryPageRequest(limit: 10)
    )
    let remoteArtists = try await library.artists(
        matching: ArtistQuery(sourceID: MediaSourceID(rawValue: "remote")),
        page: try LibraryPageRequest(limit: 10)
    )

    #expect(Set(localArtists.elements.map(\.id)) == Set([trackArtistID, albumArtistID]))
    #expect(remoteArtists.elements.isEmpty)
    await store.close()
}

@Test("metadata replacement removes no-longer-referenced records atomically")
func metadataReplacementPrunesOrphanedRecords() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-prune-update")
    let albumID = AlbumID("metadata-prune-album")
    let artistID = ArtistID("metadata-prune-artist")
    let genreID = GenreID("metadata-prune-genre")
    let artworkID = ArtworkID("metadata-prune-artwork")
    let initialTrack = Track(
        id: itemID,
        title: "Initial",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        artwork: ArtworkReference(id: artworkID)
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-initial",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album", artistIDs: [artistID]))),
            .upsert(.artist(Artist(id: artistID, name: "Artist"))),
            .upsert(.genre(Genre(id: genreID, name: "Genre"))),
            .upsert(.artwork(ArtworkReference(id: artworkID))),
            .upsert(.track(initialTrack)),
        ]
    ))

    let changes = library.changes()
    var iterator = changes.makeAsyncIterator()
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-update",
        mutations: [.upsert(.track(Track(id: itemID, title: "Updated")))]
    ))

    #expect(try await library.album(id: albumID) == nil)
    #expect(try await library.artist(id: artistID) == nil)
    #expect(try await library.genres(
        matching: GenreQuery(),
        page: try LibraryPageRequest(limit: 10)
    ).elements.isEmpty)
    do {
        _ = try await SwiftDataPlaylistRepository(store: store).create(
            PlaylistDraft(name: "Artwork probe", artworkID: artworkID)
        )
        Issue.record("An unreferenced artwork record must be removed")
    } catch let error as LibraryError {
        #expect(error == .constraint(.danglingReference))
    }

    let change = try #require(await iterator.next())
    #expect(change.categories.contains(.deletions))
    #expect(change.affectedIDs.albumIDs == [albumID])
    #expect(change.affectedIDs.artistIDs == [artistID])
    #expect(change.affectedIDs.genreIDs == [genreID])
    #expect(change.affectedIDs.artworkIDs == [artworkID])
    await store.close()
}

@Test("removing the last track prunes its metadata records")
func removeLastTrackPrunesMetadataRecords() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let values = makeLibraryValues()
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-remove-initial",
        mutations: values.mutations
    ))

    try await library.remove(Set(values.tracks.map(\.id)))

    #expect(try await library.album(id: AlbumID("album-1")) == nil)
    #expect(try await library.artist(id: ArtistID("artist-1")) == nil)
    #expect(try await library.genres(
        matching: GenreQuery(),
        page: try LibraryPageRequest(limit: 10)
    ).elements.isEmpty)
    await store.close()
}

@Test("playlist metadata and ordered entries survive store recreation")
func playlistPersistenceSurvivesStoreRecreation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    )
    let values = makeLibraryValues()
    let expectedOrder = [values.tracks[2].id, values.tracks[0].id, values.tracks[1].id]

    let firstStore = try LibraryPersistenceStore(configuration: configuration)
    let firstLibrary = SwiftDataLibraryRepository(store: firstStore)
    let firstPlaylists = SwiftDataPlaylistRepository(store: firstStore)
    try await firstLibrary.apply(try LibraryTransaction(
        idempotencyKey: "playlist-reopen-library",
        mutations: values.mutations
    ))
    let removablePlaylist = try await firstPlaylists.create(PlaylistDraft(name: "Temporary"))
    let createdPlaylist = try await firstPlaylists.create(PlaylistDraft(name: "Road Trip"))
    let revisionBeforeRename = try await firstStore.currentRevision()
    let renamedPlaylist = try await firstPlaylists.update(PlaylistMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeRename,
        change: .rename("Road Trip Favorites")
    ))
    let revisionBeforeInsert = try await firstStore.currentRevision()
    try await firstPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeInsert,
        operation: .insert(expectedOrder.enumerated().map {
            PlaylistEntryInsertion(itemID: $0.element, position: $0.offset)
        })
    ))
    let persistedRevision = try await firstStore.currentRevision()
    await firstStore.close()

    let secondStore = try LibraryPersistenceStore(configuration: configuration)
    let secondPlaylists = SwiftDataPlaylistRepository(store: secondStore)
    #expect(try await secondStore.currentRevision() == persistedRevision)
    let restoredPage = try await secondPlaylists.playlists(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(restoredPage.elements.contains(renamedPlaylist))
    #expect(restoredPage.elements.contains(removablePlaylist))
    #expect(
        try await secondPlaylists.entries(in: createdPlaylist.id).map(\.trackID)
            == expectedOrder
    )

    do {
        _ = try await secondPlaylists.update(PlaylistMutation(
            playlistID: createdPlaylist.id,
            expectedRevision: .initial,
            change: .rename("Stale Rename")
        ))
        Issue.record("A stale playlist mutation must remain stale after reopening the store")
    } catch let error as LibraryError {
        #expect(error == .conflict(.revisionMismatch(
            expected: .initial,
            actual: persistedRevision
        )))
    }

    let reordered = [expectedOrder[1], expectedOrder[2], expectedOrder[0]]
    try await secondPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: persistedRevision,
        operation: .reorder(reordered)
    ))
    let revisionBeforeRemove = try await secondStore.currentRevision()
    try await secondPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeRemove,
        operation: .remove([reordered[1]])
    ))
    try await secondPlaylists.delete(removablePlaylist.id)
    let finalRevision = try await secondStore.currentRevision()
    await secondStore.close()

    let thirdStore = try LibraryPersistenceStore(configuration: configuration)
    let thirdPlaylists = SwiftDataPlaylistRepository(store: thirdStore)
    #expect(try await thirdStore.currentRevision() == finalRevision)
    #expect(
        try await thirdPlaylists.entries(in: createdPlaylist.id).map(\.trackID)
            == [reordered[0], reordered[2]]
    )
    let finalPage = try await thirdPlaylists.playlists(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(finalPage.elements == [renamedPlaylist])
    await thirdStore.close()
}

@Test("library transactions validate before save and enforce idempotency")
func libraryTransactionErrorsAndRollback() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LibraryPersistenceStore(configuration: try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    ))
    let library = SwiftDataLibraryRepository(store: store)

    let missingAlbumTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "missing-album-track"),
        title: "Invalid",
        albumID: AlbumID("missing-album")
    )
    do {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "invalid-transaction",
            mutations: [.upsert(.track(missingAlbumTrack))]
        ))
        Issue.record("A dangling relation should reject the complete transaction")
    } catch let error as LibraryError {
        #expect(error == .constraint(.danglingReference))
    }
    let missingTrack = try await library.track(id: missingAlbumTrack.id)
    #expect(missingTrack == nil)

    let validTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "valid-track"),
        title: "Valid"
    )
    let transaction = try LibraryTransaction(
        idempotencyKey: "valid-transaction",
        expectedRevision: .initial,
        mutations: [.upsert(.track(validTrack))]
    )
    try await library.apply(transaction)

    do {
        try await library.apply(transaction)
        Issue.record("The same idempotency key should not be applied twice")
    } catch let error as LibraryError {
        #expect(error == .conflict(.transactionAlreadyApplied))
    }

    do {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "stale-transaction",
            expectedRevision: .initial,
            mutations: [.upsert(.track(Track(
                id: MediaItemID(sourceID: .local, externalID: "stale-track"),
                title: "Stale"
            )))]
        ))
        Issue.record("An old revision should reject the transaction")
    } catch let error as LibraryError {
        #expect(error == .conflict(.revisionMismatch(expected: .initial, actual: LibraryRevision(1))))
    }

    let enrichedTrack = Track(
        id: validTrack.id,
        title: "Enriched",
        fileName: "enriched.flac",
        folderPath: "Albums/Live",
        technicalInfo: MediaTechnicalInfo(fileSizeBytes: 1234),
        year: 2024,
        comment: "Comment",
        lyrics: TrackLyrics(rawText: "[00:01.00]Line")
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "enriched-transaction",
        mutations: [.upsert(.track(enrichedTrack))]
    ))
    let restoredEnrichedTrack = try #require(await library.track(id: validTrack.id))
    #expect(restoredEnrichedTrack == enrichedTrack)
    await store.close()
}

@Test("library change streams register synchronously and buffer the next commit")
func libraryChangeStreamDoesNotMissImmediateCommit() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let stream = library.changes()
    #expect(store.changeSubscriberCount == 1)

    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "stream-track"),
        title: "Stream Track"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "stream-immediate-commit",
        mutations: [.upsert(.track(track))]
    ))

    var iterator = stream.makeAsyncIterator()
    let change = await iterator.next()
    #expect(change?.revision == LibraryRevision(1))
    #expect(change?.categories.contains(.tracks) == true)
    #expect(change?.affectedIDs.trackIDs == [track.id])

    await store.close()
    #expect(store.changeSubscriberCount == 0)
}

@Test("cancelling library change iteration removes the subscription")
func libraryChangeStreamCancellationUnregistersSynchronously() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let stream = library.changes()
    #expect(store.changeSubscriberCount == 1)

    let waiter = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    await Task.yield()
    waiter.cancel()
    _ = await waiter.value

    #expect(store.changeSubscriberCount == 0)
    await store.close()
}

@Test("scalar-sort browsing fetches only one bounded SwiftData page")
func scalarSortBrowseUsesBoundedFetch() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let tracks = (0..<12).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "bounded-\(index)"),
            title: "Bounded \(index)"
        )
    }
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "bounded-track-page",
        mutations: tracks.map { .upsert(.track($0)) }
    ))

    let query = TrackQuery(sort: TrackSortDescriptor(key: .dateAdded))
    let firstPage = try await library.tracks(
        matching: query,
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(firstPage.elements.count == 2)
    #expect(firstPage.hasNextPage)
    #expect(await store.lastBrowseRecordFetchCount() == 3)

    let pendingNextRequest = try firstPage.nextPage(limit: 2)
    let nextRequest = try #require(pendingNextRequest)
    let secondPage = try await library.tracks(matching: query, page: nextRequest)
    #expect(secondPage.elements.count == 2)
    #expect(await store.lastBrowseRecordFetchCount() == 3)

    _ = try await library.tracks(
        matching: TrackQuery(),
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(await store.lastBrowseRecordFetchCount() == nil)
    await store.close()
}

@Test("playlist history queue and deletion use one stable persistence boundary")
func playlistHistoryQueueAndDeletion() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LibraryPersistenceStore(configuration: try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    ))
    let library = SwiftDataLibraryRepository(store: store)
    let playlists = SwiftDataPlaylistRepository(store: store)
    let history = SwiftDataPlaybackHistoryRepository(store: store)
    let queue = SwiftDataPlaybackQueueRepository(store: store)
    let values = makeLibraryValues()
    let track = values.tracks[0]
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "playlist-library",
        mutations: values.mutations
    ))

    let playlist = try await playlists.create(PlaylistDraft(name: "Favorites"))
    try await playlists.apply(PlaylistEntriesMutation(
        playlistID: playlist.id,
        operation: .insert([
            PlaylistEntryInsertion(itemID: track.id, position: 0)
        ])
    ))
    let playlistTrackIDs = try await playlists.entries(in: playlist.id).map(\.trackID)
    #expect(playlistTrackIDs == [track.id])

    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 100)
    try await history.recordPlaybackStarted(PlaybackStart(
        sessionID: sessionID,
        itemID: track.id,
        startedAt: startedAt
    ))
    try await history.recordValidPlayback(ValidPlayback(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(30),
        playedDuration: .seconds(30)
    ))
    try await history.recordCompleted(PlaybackCompletion(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(31),
        reason: .ended
    ))
    let recent = try await history.recentHistory(page: try LibraryPageRequest(limit: 10))
    #expect(recent.elements.count == 1)
    #expect(recent.elements[0].totalPlayedDuration == .seconds(30))
    #expect(recent.elements[0].lastCompletionReason == .ended)

    let entry = PlaybackQueueEntry(id: UUID(), itemID: track.id)
    let snapshot = PlaybackQueueSnapshot(
        entries: [entry],
        currentEntryID: entry.id,
        resumePosition: .seconds(5)
    )
    try await queue.save(snapshot)
    let restoredQueue = try await queue.load()
    #expect(restoredQueue == snapshot)

    try await library.remove([track.id])
    let remainingPlaylistEntries = try await playlists.entries(in: playlist.id)
    #expect(remainingPlaylistEntries.isEmpty)
    let remainingHistory = try await history.recentHistory(page: try LibraryPageRequest(limit: 10))
    #expect(remainingHistory.elements.isEmpty)
    let clearedQueue = try await queue.load()
    #expect(clearedQueue == .empty)
    await store.close()
}

@Test("clearing persisted history keeps track statistics and publishes a history-only change")
func playbackHistoryClearKeepsStatistics() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let history = SwiftDataPlaybackHistoryRepository(store: store)
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "history-clear"),
        title: "History Clear"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "history-clear-track",
        mutations: [.upsert(.track(track))]
    ))

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let startedAt = Date(timeIntervalSince1970: 100)
    try await history.recordPlaybackStarted(PlaybackStart(
        sessionID: sessionID,
        itemID: track.id,
        startedAt: startedAt
    ))
    try await history.recordValidPlayback(ValidPlayback(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(20),
        playedDuration: .seconds(20)
    ))
    try await history.recordCompleted(PlaybackCompletion(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(21),
        reason: .ended
    ))
    let statisticsBeforeClear = try #require(
        try await library.track(id: track.id)
    ).statistics

    let changes = library.changes()
    var iterator = changes.makeAsyncIterator()
    try await history.clearHistory()
    let clearChange = try #require(await iterator.next())

    #expect(clearChange.categories == [.playbackHistory])
    #expect(clearChange.affectedIDs.trackIDs == [track.id])
    #expect(
        try await history.recentHistory(page: try LibraryPageRequest(limit: 10)).elements.isEmpty
    )
    #expect(try await library.track(id: track.id)?.statistics == statisticsBeforeClear)

    await store.close()
}

private struct LibraryValues {
    let tracks: [Track]
    let mutations: [LibraryMutation]
}

private struct DatePayload: Codable, Equatable {
    let date: Date
}

private func makeLibraryValues() -> LibraryValues {
    let album = Album(id: AlbumID("album-1"), title: "Album")
    let artist = Artist(id: ArtistID("artist-1"), name: "Artist")
    let genre = Genre(id: GenreID("genre-1"), name: "Genre")
    let artwork = ArtworkReference(id: ArtworkID("artwork-1"))
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-1"),
            title: "Gamma",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-2"),
            title: "Alpha",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-3"),
            title: "Beta",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        )
    ]
    return LibraryValues(
        tracks: tracks,
        mutations: [
            .upsert(.album(album)),
            .upsert(.artist(artist)),
            .upsert(.genre(genre)),
            .upsert(.artwork(artwork)),
            .upsert(.track(tracks[0])),
            .upsert(.track(tracks[1])),
            .upsert(.track(tracks[2]))
        ]
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeLibraryPersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
