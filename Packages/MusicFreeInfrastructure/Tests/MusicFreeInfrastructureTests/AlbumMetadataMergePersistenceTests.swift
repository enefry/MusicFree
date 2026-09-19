import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import MusicDomain
import PlaybackAPI
import Testing

@Test("Album rename merge migrates graph and collection references without changing playback identities")
func albumMetadataMergePreservesPersistenceGraph() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let playlists = SwiftDataPlaylistRepository(store: store)
    let queue = SwiftDataPlaybackQueueRepository(store: store)
    let history = SwiftDataPlaybackHistoryRepository(store: store)
    let albumIDs = (0..<3).map { AlbumID("manual-merge-\($0)") }
    let releaseIDs = albumIDs.map(AlbumReleaseID.init(legacyAlbumID:))
    let artwork = ArtworkReference(id: ArtworkID("manual-merge-artwork"))
    let tracks = (0..<3).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "manual-merge-song-\(index)"),
            title: "Song \(index)", albumID: albumIDs[index],
            trackNumber: 2, trackTotal: 5, discNumber: index + 1, discTotal: 3,
            artwork: artwork, isFavorite: true
        )
    }
    let collection = LibraryCollection(id: LibraryCollectionID("merge-box"), kind: .boxSet, title: "Box")
    let soloCollection = LibraryCollection(id: LibraryCollectionID("merge-folder"), kind: .importedFolder, title: "Folder")
    var mutations: [LibraryMutation] = [.upsert(.artwork(artwork)), .upsert(.collection(collection)), .upsert(.collection(soloCollection))]
    for (index, albumID) in albumIDs.enumerated() {
        mutations.append(.upsert(.album(Album(id: albumID, title: index == 0 ? "Old Name" : "New Name", artwork: artwork, trackCount: 1))))
        mutations.append(.upsert(.track(tracks[index])))
        mutations.append(.upsert(.mediaAsset(MediaAsset(
            id: tracks[index].assetID, contentRevision: "asset-\(index)", fileName: "song-\(index).flac", byteCount: 800
        ))))
        mutations.append(.upsert(.trackVariant(TrackVariant(
            id: tracks[index].id,
            logicalTrackID: tracks[index].logicalTrackID,
            assetID: tracks[index].assetID,
            sourceIdentityHint: "source-\(index)",
            sourceMetadataRevision: "original-revision",
            sourceMetadata: TrackSourceMetadataSnapshot(track: tracks[index])
        ))))
        mutations.append(.upsert(.collectionMember(LibraryCollectionMember(collectionID: collection.id, releaseID: releaseIDs[index], position: index))))
    }
    mutations.append(.upsert(.collectionMember(LibraryCollectionMember(collectionID: soloCollection.id, releaseID: releaseIDs[1], position: 0))))
    try await library.apply(try LibraryTransaction(idempotencyKey: "merge-seed", mutations: mutations))
    let originalVariants = try await tracks.asyncVariants(from: library)
    let playlist = try await playlists.create(PlaylistDraft(name: "Favorites"))
    try await playlists.apply(PlaylistEntriesMutation(playlistID: playlist.id, operation: .insert(tracks.enumerated().map {
        PlaylistEntryInsertion(itemID: $0.element.id, position: $0.offset)
    })))
    let entries = tracks.map { PlaybackQueueEntry(id: UUID(), itemID: $0.id) }
    let queueSnapshot = PlaybackQueueSnapshot(entries: entries, currentEntryID: entries[1].id, resumePosition: .seconds(20))
    try await queue.save(queueSnapshot)
    try await history.recordPlaybackStarted(PlaybackStart(sessionID: UUID(), itemID: tracks[1].id, startedAt: Date()))
    let originalHistory = try await history.recentHistory(page: LibraryPageRequest(limit: 10))
    let stream = library.changes()
    var iterator = stream.makeAsyncIterator()

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "merge-save",
        mutations: [.upsert(.album(Album(id: albumIDs[0], title: "New Name", artwork: artwork)))],
        albumMerge: LibraryAlbumMerge(sourceAlbumIDs: Set(albumIDs.dropFirst()), destinationAlbumID: albumIDs[0])
    ))
    let change = try #require(await iterator.next())
    #expect(change.affectedIDs.albumIDs == Set(albumIDs))
    #expect(change.affectedIDs.trackIDs.isSuperset(of: Set(tracks.dropFirst().map(\.id))))
    #expect(change.categories.isSuperset(of: [.tracks, .albums, .deletions]))
    #expect(try await library.albums(matching: AlbumQuery(), page: LibraryPageRequest(limit: 10)).elements.count == 1)
    #expect(try await library.album(id: albumIDs[0])?.trackCount == 3)
    #expect(try await library.album(id: albumIDs[0])?.artwork == artwork)
    for track in tracks {
        let stored = try #require(await library.track(id: track.id))
        #expect(stored.albumID == albumIDs[0])
        #expect(stored.logicalTrackID == track.logicalTrackID)
        #expect(stored.assetID == track.assetID)
        #expect(stored.playbackSelection == track.playbackSelection)
        #expect(stored.discNumber == track.discNumber)
        #expect(stored.discTotal == track.discTotal)
        #expect(stored.trackNumber == track.trackNumber)
        #expect(stored.trackTotal == track.trackTotal)
        #expect(stored.isFavorite)
        let logical = try #require(await library.logicalTrack(id: track.logicalTrackID))
        #expect(logical.releaseID == releaseIDs[0])
        #expect(logical.discID == DiscID(releaseID: releaseIDs[0], number: track.discNumber!))
        #expect(try await library.trackVariant(id: track.id) == originalVariants[track.id])
        let asset = try #require(await library.mediaAsset(id: track.assetID))
        #expect(asset.contentRevision != nil)
        #expect(asset.byteCount == 800)
    }
    for releaseID in releaseIDs.dropFirst() {
        #expect(try await library.release(id: releaseID) == nil)
        #expect(try await library.discs(for: releaseID).isEmpty == true)
    }
    #expect(try await library.discs(for: releaseIDs[0]).map(\.number) == [1, 2, 3])
    #expect(try await library.members(in: collection.id) == [LibraryCollectionMember(collectionID: collection.id, releaseID: releaseIDs[0], position: 0)])
    #expect(try await library.members(in: soloCollection.id) == [LibraryCollectionMember(collectionID: soloCollection.id, releaseID: releaseIDs[0], position: 0)])
    #expect(try await playlists.entries(in: playlist.id).map(\.trackID) == tracks.map(\.id))
    #expect(try await queue.load() == queueSnapshot)
    let savedHistory = try await history.recentHistory(page: LibraryPageRequest(limit: 10))
    #expect(savedHistory.elements.map(\.sessionID) == originalHistory.elements.map(\.sessionID))
    #expect(savedHistory.elements.map(\.itemID) == originalHistory.elements.map(\.itemID))
    #expect(savedHistory.elements.map(\.lastStartedAt) == originalHistory.elements.map(\.lastStartedAt))
    #expect(savedHistory.elements.map(\.totalPlayedDuration) == originalHistory.elements.map(\.totalPlayedDuration))
    await store.close()
}

@Test("An invalid album merge rolls back the title edit and leaves both albums intact")
func albumMetadataMergeRollsBackOnInvalidSource() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let album = Album(id: AlbumID("merge-rollback"), title: "Original")
    let track = Track(id: MediaItemID(sourceID: .local, externalID: "merge-rollback-song"), title: "Song", albumID: album.id)
    try await library.apply(try LibraryTransaction(idempotencyKey: "rollback-seed", mutations: [.upsert(.album(album)), .upsert(.track(track))]))
    await #expect(throws: LibraryError.self) {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "rollback-save",
            mutations: [.upsert(.album(Album(id: album.id, title: "Edited")))],
            albumMerge: LibraryAlbumMerge(sourceAlbumIDs: [AlbumID("does-not-exist")], destinationAlbumID: album.id)
        ))
    }
    #expect(try await library.album(id: album.id) == album)
    #expect(try await library.track(id: track.id) == track)
    await store.close()
}

@Test("Album merge preserves graph-only media assets, variants and source snapshots")
func albumMetadataMergePreservesGraphOnlyMedia() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let destination = Album(id: AlbumID("graph-merge-destination"), title: "Album")
    let source = Album(id: AlbumID("graph-merge-source"), title: "Album")
    let destinationReleaseID = AlbumReleaseID(legacyAlbumID: destination.id)
    let destinationTrack = Track(id: MediaItemID(sourceID: .local, externalID: "destination-song"), title: "Destination", albumID: destination.id)
    let sourceTrack = Track(id: MediaItemID(sourceID: .local, externalID: "graph-song"), title: "Graph Song", albumID: source.id, trackNumber: 3, isFavorite: true)
    let asset = MediaAsset(id: sourceTrack.assetID, contentRevision: "asset-revision", fileName: "original.flac", folderPath: "Original Folder", byteCount: 800)
    let variant = TrackVariant(
        id: sourceTrack.id, logicalTrackID: sourceTrack.logicalTrackID, assetID: asset.id,
        sourceIdentityHint: "source-identity", sourceMetadataRevision: "source-revision",
        sourceMetadata: TrackSourceMetadataSnapshot(track: sourceTrack)
    )
    try await library.apply(try LibraryTransaction(idempotencyKey: "graph-merge-seed", mutations: [
        .upsert(.album(destination)), .upsert(.album(source)), .upsert(.albumRelease(source.releaseProjection)),
        .upsert(.track(destinationTrack)),
        .upsert(.mediaAsset(asset)), .upsert(.logicalTrack(sourceTrack.logicalTrackProjection)),
        .upsert(.disc(sourceTrack.discProjection!)), .upsert(.trackVariant(variant))
    ]))
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "graph-merge-save",
        mutations: [.upsert(.album(destination))],
        albumMerge: LibraryAlbumMerge(sourceAlbumIDs: [source.id], destinationAlbumID: destination.id)
    ))
    #expect(try await library.album(id: source.id) == nil)
    #expect(try await library.album(id: destination.id)?.trackCount == 2)
    #expect(try await library.logicalTrack(id: sourceTrack.logicalTrackID)?.releaseID == destinationReleaseID)
    #expect(try await library.logicalTrack(id: sourceTrack.logicalTrackID)?.isFavorite == true)
    #expect(try await library.mediaAsset(id: asset.id) == asset)
    #expect(try await library.trackVariant(id: sourceTrack.id) == variant)
    #expect(try await library.discs(for: destinationReleaseID).map(\.trackCount) == [2])
    // A graph-only variant stays graph-only; merging must not invent a legacy file row.
    #expect(try await library.track(id: sourceTrack.id) == nil)
    await store.close()
}

private extension Array where Element == Track {
    func asyncVariants(from library: SwiftDataLibraryRepository) async throws -> [MediaItemID: TrackVariant] {
        var variants: [MediaItemID: TrackVariant] = [:]
        for track in self { variants[track.id] = try await library.trackVariant(id: track.id) }
        return variants
    }
}
