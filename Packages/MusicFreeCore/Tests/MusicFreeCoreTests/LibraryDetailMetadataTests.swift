import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing

@Test("Old library payloads decode without supplemental details")
func libraryDetailsLegacyDecoding() throws {
    let track = Track(id: MediaItemID(sourceID: .local, externalID: "legacy-details"), title: "Song")
    let album = Album(id: AlbumID("legacy-details"), title: "Album")
    let artist = Artist(id: ArtistID("legacy-details"), name: "Artist")
    #expect(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)).details == nil)
    #expect(try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(album)).details == nil)
    #expect(try JSONDecoder().decode(Artist.self, from: JSONEncoder().encode(artist)).details == nil)
}

@MainActor
@Test("Artist editing retains relationship identities and artwork through later track edits")
func artistDetailEditingRetainsRelationships() async throws {
    let artist = Artist(id: ArtistID("detail-artist"), name: "Artist")
    let album = Album(id: AlbumID("detail-album"), title: "Album", artistIDs: [artist.id])
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "detail-song"), title: "Song",
        albumID: album.id, artistIDs: [artist.id]
    )
    let repository = InMemoryLibraryRepository(tracks: [track], albums: [album], artists: [artist])
    let container = try AppServiceContainer(dependencies: AppDependencies(
        artworkWriter: { _, _ in ArtworkWriteReceipt(wasCreated: true) }, libraryRepository: repository
    ))
    let details = ArtistDetailMetadata(origin: "Shanghai", birthDate: Date(timeIntervalSince1970: 1_000), biography: "Biography")
    let updated = try await container.library.updateArtistMetadata(ArtistMetadataUpdate(
        artistID: artist.id, name: "Renamed Artist", details: details, artwork: .replace(Data([1, 2, 3]))
    ))
    #expect(updated.id == artist.id)
    #expect(updated.details == details)
    #expect(updated.artworkID != nil)
    #expect(try await repository.track(id: track.id)?.artistIDs == [artist.id])
    #expect(try await repository.album(id: album.id)?.artistIDs == [artist.id])
    _ = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: track.id, title: track.title, artistNames: [updated.name],
        albumArtistNames: [updated.name], albumName: album.title
    ))
    #expect(try await repository.artist(id: artist.id) == updated)
    #expect(try await repository.track(id: track.id)?.artistIDs == [artist.id])
}

@MainActor
@Test("Supplemental song and album metadata survives favorites and legacy updates; empty values clear edits")
func libraryDetailUpdatesPreserveAndClear() async throws {
    let album = Album(id: AlbumID("details-retention"), title: "Album")
    let track = Track(id: MediaItemID(sourceID: .local, externalID: "details-retention"), title: "Song", albumID: album.id)
    let repository = InMemoryLibraryRepository(tracks: [track], albums: [album])
    let container = try AppServiceContainer(dependencies: AppDependencies(libraryRepository: repository))
    let songDetails = TrackDetailMetadata(composers: ["Composer"], additionalArtists: ["Guest"], contentRating: .explicit)
    let albumDetails = AlbumDetailMetadata(summary: "Summary", genres: ["Jazz"], discCount: 2, recordLabel: "Label", copyright: "Copyright")
    _ = try await container.library.updateAlbumMetadata(AlbumMetadataUpdate(
        albumID: album.id, title: album.title, albumType: .live, details: albumDetails
    ))
    _ = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: track.id, title: track.title, albumName: album.title, details: songDetails
    ))
    #expect(try await container.library.setFavorite(true, for: track.id).details == songDetails)
    #expect(try await container.library.setAlbumFavorite(true, for: album.id).details == albumDetails)
    let saved = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: track.id, title: "Updated", albumName: album.title
    ))
    #expect(saved.details == songDetails)
    #expect(try await repository.album(id: album.id)?.details == albumDetails)
    #expect(try await repository.album(id: album.id)?.albumType == .live)
    let cleared = try await container.library.updateMetadata(TrackMetadataUpdate(
        itemID: track.id, title: saved.title, albumName: album.title, details: TrackDetailMetadata()
    ))
    #expect(cleared.details?.composers.isEmpty == true)
    #expect(cleared.details?.contentRating == .unknown)
}
