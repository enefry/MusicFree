import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import MusicDomain
import Testing

@Test("Album cover edits propagate after merging while preserving assets and source snapshots")
func albumArtworkPropagationPersistsAcrossMerge() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let albumID = AlbumID("cover-destination")
    let sourceID = AlbumID("cover-source")
    let oldArtwork = ArtworkReference(id: ArtworkID("cover-old"))
    let newArtwork = ArtworkReference(id: ArtworkID("cover-new"), variants: [.original], preferredVariant: .original)
    let albums = [
        Album(id: albumID, title: "Album", artwork: oldArtwork),
        Album(id: sourceID, title: "Album", artwork: oldArtwork)
    ]
    let tracks = (0..<3).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "cover-track-\(index)"),
            title: "Song \(index)", albumID: index == 0 ? albumID : sourceID,
            trackNumber: index + 1, discNumber: 1,
            artwork: index == 1 ? nil : oldArtwork, isFavorite: true
        )
    }
    let graphTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "cover-graph-only"),
        title: "Graph song", albumID: sourceID, artwork: oldArtwork
    )
    let unrelated = Track(
        id: MediaItemID(sourceID: .local, externalID: "cover-unrelated"),
        title: "Unrelated", artwork: oldArtwork
    )
    let allAlbumTracks = tracks + [graphTrack]
    let variants = allAlbumTracks.map {
        TrackVariant(
            id: $0.id, logicalTrackID: $0.logicalTrackID, assetID: $0.assetID,
            sourceIdentityHint: "source-\($0.id.externalID)",
            sourceMetadataRevision: "unchanged", sourceMetadata: TrackSourceMetadataSnapshot(track: $0)
        )
    }
    let assets = allAlbumTracks.map {
        MediaAsset(id: $0.assetID, contentRevision: "unchanged", fileName: "original.flac", byteCount: 800)
    }
    var mutations: [LibraryMutation] = [.upsert(.artwork(oldArtwork)), .upsert(.track(unrelated))]
    mutations += albums.map { .upsert(.album($0)) }
    mutations += albums.map { .upsert(.albumRelease($0.releaseProjection)) }
    mutations += tracks.map { .upsert(.track($0)) }
    mutations += [.upsert(.logicalTrack(graphTrack.logicalTrackProjection)), .upsert(.disc(graphTrack.discProjection!))]
    mutations += variants.map { .upsert(.trackVariant($0)) }
    mutations += assets.map { .upsert(.mediaAsset($0)) }
    try await library.apply(try LibraryTransaction(idempotencyKey: "cover-seed", mutations: mutations))

    let stream = library.changes()
    var iterator = stream.makeAsyncIterator()
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "cover-replace",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album", artwork: newArtwork))),
            .upsert(.artwork(newArtwork)),
            .relation(.setAlbumTracksArtwork(albumID: albumID, artworkID: newArtwork.id))
        ],
        albumMerge: LibraryAlbumMerge(sourceAlbumIDs: [sourceID], destinationAlbumID: albumID)
    ))
    let change = try #require(await iterator.next())
    #expect(change.affectedIDs.trackIDs == Set(allAlbumTracks.map(\.id)))
    #expect(change.categories.isSuperset(of: [.tracks, .albums, .artwork]))
    #expect(try await library.album(id: sourceID) == nil)
    #expect(try await library.album(id: albumID)?.artwork == newArtwork)
    for track in tracks {
        let stored = try #require(await library.track(id: track.id))
        #expect(stored.albumID == albumID)
        #expect(stored.artwork == newArtwork)
        #expect(stored.trackNumber == track.trackNumber)
        #expect(stored.isFavorite)
    }
    for track in allAlbumTracks {
        #expect(try await library.logicalTrack(id: track.logicalTrackID)?.artwork == newArtwork)
    }
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "cover-remove",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album"))),
            .relation(.setAlbumTracksArtwork(albumID: albumID, artworkID: nil))
        ]
    ))
    let removal = try #require(await iterator.next())
    #expect(removal.affectedIDs.trackIDs == Set(allAlbumTracks.map(\.id)))
    #expect(try await library.album(id: albumID)?.artwork == nil)
    for track in tracks {
        #expect(try await library.track(id: track.id)?.artwork == nil)
    }
    for track in allAlbumTracks {
        #expect(try await library.logicalTrack(id: track.logicalTrackID)?.artwork == nil)
    }
    for variant in variants {
        #expect(try await library.trackVariant(id: variant.id) == variant)
    }
    for asset in assets {
        #expect(try await library.mediaAsset(id: asset.id) == asset)
    }
    #expect(try await library.track(id: graphTrack.id) == nil)
    #expect(try await library.track(id: unrelated.id) == unrelated)
    #expect(try await library.isArtworkReferenced(oldArtwork.id))
    #expect(try await library.isArtworkReferenced(newArtwork.id) == false)
    await store.close()
}

@Test("Invalid album cover propagation rolls back the whole metadata edit")
func albumArtworkPropagationRollsBackInvalidArtwork() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let album = Album(id: AlbumID("cover-rollback"), title: "Original")
    let track = Track(id: MediaItemID(sourceID: .local, externalID: "cover-rollback-track"), title: "Song", albumID: album.id)
    try await library.apply(try LibraryTransaction(idempotencyKey: "cover-rollback-seed", mutations: [
        .upsert(.album(album)), .upsert(.track(track))
    ]))
    let revision = try await store.currentRevision()
    await #expect(throws: LibraryError.self) {
        try await library.apply(try LibraryTransaction(idempotencyKey: "cover-rollback-edit", mutations: [
            .upsert(.album(Album(id: album.id, title: "Edited"))),
            .relation(.setAlbumTracksArtwork(albumID: album.id, artworkID: ArtworkID("not-stored")))
        ]))
    }
    #expect(try await library.album(id: album.id) == album)
    #expect(try await library.track(id: track.id) == track)
    #expect(try await store.currentRevision() == revision)
    await store.close()
}
