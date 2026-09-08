import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing

@MainActor
@Test("Saving an album name merges all local matches and honors the artwork edit", arguments: [0, 1, 2])
func albumMetadataSaveMergesSameNamedAlbums(artworkMode: Int) async throws {
    let albumIDs = (0..<3).map { AlbumID("manual-merge-\($0)") }
    let cover = ArtworkReference(id: ArtworkID("manual-merge-cover"))
    let data = Data([0x11, 0x22, 0x33])
    let replacementID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(data))")
    let remoteAlbumID = AlbumID("manual-merge-remote")
    let remoteTrack = Track(
        id: MediaItemID(sourceID: MediaSourceID("remote"), externalID: "remote-track"),
        title: "Remote track", albumID: remoteAlbumID
    )
    let artistIDs = (0..<3).map { ArtistID("manual-merge-artist-\($0)") }
    let tracks = (0..<3).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "manual-merge-track-\(index)"),
            title: "Track \(index)", albumID: albumIDs[index], artistIDs: [artistIDs[index]],
            trackNumber: 2, discNumber: index + 1,
            artwork: index == 1 ? nil : ArtworkReference(id: ArtworkID("track-cover-\(index)")),
            isFavorite: true
        )
    }
    let repository = InMemoryLibraryRepository(
        tracks: tracks + [remoteTrack],
        albums: [
            Album(id: albumIDs[0], title: "Wrong Name", trackCount: 1),
            Album(id: albumIDs[1], title: "宝丽金辉煌60年 · 女人篇", artwork: cover, trackCount: 1),
            Album(id: albumIDs[2], title: "宝丽金辉煌60年·女人篇", trackCount: 1),
            Album(id: remoteAlbumID, title: "宝丽金辉煌60年·女人篇", trackCount: 1)
        ],
        artists: artistIDs.enumerated().map { Artist(id: $0.element, name: "Artist \($0.offset)") }
    )
    let container = try AppServiceContainer(dependencies: AppDependencies(
        artworkWriter: { _, _ in ArtworkWriteReceipt(wasCreated: true) },
        libraryRepository: repository
    ))
    let edit: ArtworkEdit = artworkMode == 0 ? .keep : artworkMode == 1 ? .remove : .replace(data)
    let saved = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: albumIDs[0], title: "宝丽金辉煌60年·女人篇", artistNames: [], artwork: edit
    ))
    #expect(saved.id == albumIDs[0])
    #expect(saved.trackCount == 3)
    #expect(saved.artistIDs.isEmpty)
    #expect(saved.artworkID == (artworkMode == 0 ? cover.id : artworkMode == 1 ? nil : replacementID))
    #expect(try await repository.album(id: albumIDs[1]) == nil)
    #expect(try await repository.album(id: albumIDs[2]) == nil)
    for track in tracks {
        let stored = try #require(await repository.track(id: track.id))
        #expect(stored.albumID == saved.id)
        #expect(stored.artistIDs == track.artistIDs)
        #expect(stored.discNumber == track.discNumber)
        #expect(stored.trackNumber == track.trackNumber)
        #expect(stored.isFavorite)
        let expectedArtwork = artworkMode == 0 ? track.artwork : saved.artwork
        #expect(stored.artwork == expectedArtwork)
        #expect(try await repository.logicalTrack(id: track.logicalTrackID)?.artwork == expectedArtwork)
    }
    #expect(try await repository.track(id: remoteTrack.id) == remoteTrack)
    #expect(try await repository.album(id: remoteAlbumID) != nil)
    let repeated = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: saved.id, title: saved.title, artistNames: []
    ))
    #expect(repeated == saved)
}

@MainActor
@Test("Album rename finds matching albums past the first library page")
func albumMetadataMergePaginatesAlbums() async throws {
    let destinationID = AlbumID("paginated-merge-destination")
    let sourceID = AlbumID("paginated-merge-source")
    let fillers = (0..<LibraryPageRequest.maximumLimit).map { Album(id: AlbumID("filler-\($0)"), title: "A filler \($0)") }
    let albums = fillers + [Album(id: destinationID, title: "Original"), Album(id: sourceID, title: "Z Target")]
    let tracks = albums.map { Track(id: MediaItemID(sourceID: .local, externalID: $0.id.rawValue), title: "Song", albumID: $0.id) }
    let repository = InMemoryLibraryRepository(tracks: tracks, albums: albums)
    let container = try AppServiceContainer(dependencies: AppDependencies(libraryRepository: repository))
    let saved = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(albumID: destinationID, title: "Z Target"))
    #expect(saved.trackCount == 2)
    #expect(try await repository.album(id: sourceID) == nil)
    #expect(try await repository.album(id: fillers[0].id) == fillers[0])
}

@Test("Manual album merge compares complete names without stripping edition or disc suffixes")
func albumMetadataMergeTitleComparison() {
    #expect(LibraryAlbumMerge.normalizedTitle("  Album · Name  ") == LibraryAlbumMerge.normalizedTitle("album·name"))
    #expect(LibraryAlbumMerge.normalizedTitle("Album CD1") != LibraryAlbumMerge.normalizedTitle("Album CD2"))
    #expect(LibraryAlbumMerge.normalizedTitle("Album") != LibraryAlbumMerge.normalizedTitle("Album Deluxe"))
}

@Test("Legacy library transactions decode without album merge instructions")
func albumMetadataMergeTransactionCompatibility() throws {
    let transaction = try LibraryTransaction(idempotencyKey: "legacy", mutations: [.upsert(.album(Album(id: AlbumID("legacy"), title: "Album")))])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(transaction)) as? [String: Any])
    object.removeValue(forKey: "albumMerge")
    let decoded = try JSONDecoder().decode(LibraryTransaction.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.albumMerge == nil)
}

@MainActor
@Test("Album cover replacement and removal apply to every song beyond one page")
func albumArtworkAppliesToAllTracks() async throws {
    let albumID = AlbumID("album-cover-all-tracks")
    let originalArtwork = ArtworkReference(id: ArtworkID("original-cover"))
    let tracks = (0...LibraryPageRequest.maximumLimit).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "cover-track-\(index)"),
            title: "Track \(index)", albumID: albumID,
            artwork: index.isMultiple(of: 2) ? originalArtwork : nil
        )
    }
    let unrelated = Track(
        id: MediaItemID(sourceID: .local, externalID: "unrelated-cover-track"),
        title: "Unrelated", artwork: originalArtwork
    )
    let repository = InMemoryLibraryRepository(
        tracks: tracks + [unrelated],
        albums: [Album(id: albumID, title: "Album", artwork: originalArtwork, trackCount: tracks.count)]
    )
    let writes = AlbumArtworkWriteCounter()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        artworkWriter: { _, _ in
            await writes.record()
            return ArtworkWriteReceipt(wasCreated: true)
        },
        libraryRepository: repository
    ))
    let saved = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: albumID, title: "Album", artwork: .replace(Data([0x41, 0x42, 0x43]))
    ))
    #expect(saved.artworkID != nil)
    #expect(await writes.count == 1)
    for track in tracks {
        #expect(try await repository.track(id: track.id)?.artwork == saved.artwork)
        #expect(try await repository.logicalTrack(id: track.logicalTrackID)?.artwork == saved.artwork)
    }
    _ = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: albumID, title: "Album", artwork: .remove
    ))
    for track in tracks {
        #expect(try await repository.track(id: track.id)?.artwork == nil)
        #expect(try await repository.logicalTrack(id: track.logicalTrackID)?.artwork == nil)
    }
    #expect(await writes.count == 1)
    #expect(try await repository.track(id: unrelated.id) == unrelated)
}

private actor AlbumArtworkWriteCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
