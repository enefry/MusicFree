import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import MusicDomain
import Testing

@Test("Supplemental details and import date persist across reopening and source upserts")
func libraryDetailMetadataPersistence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicFree-DetailMetadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try LibraryPersistenceConfiguration(storeURL: directory.appendingPathComponent("Library.store"))
    let store = try LibraryPersistenceStore(configuration: configuration)
    let repository = SwiftDataLibraryRepository(store: store)
    let artist = Artist(id: ArtistID("details"), name: "Artist", details: ArtistDetailMetadata(origin: "City", biography: "Biography"))
    let album = Album(id: AlbumID("details"), title: "Album", artistIDs: [artist.id], releaseYear: 1970, albumType: .live, details: AlbumDetailMetadata(summary: "Summary", releaseDate: Date(timeIntervalSince1970: 10_000), genres: ["Jazz"], discCount: 2, format: "Digital", recordLabel: "Label", copyright: "Copyright"))
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "details"), title: "Song", albumID: album.id,
        artistIDs: [artist.id], details: TrackDetailMetadata(composers: ["Composer"], contentRating: .clean)
    )
    try await repository.apply(LibraryTransaction(idempotencyKey: "details-seed", mutations: [
        .upsert(.artist(artist)), .upsert(.album(album)), .upsert(.track(track))
    ]))
    let dateAdded = try #require(await repository.trackDateAdded(id: track.id))
    try await repository.apply(LibraryTransaction(idempotencyKey: "details-source-rescan", mutations: [
        .upsert(.artist(Artist(id: artist.id, name: "Source Artist"))),
        .upsert(.album(Album(id: album.id, title: album.title, artistIDs: [artist.id]))),
        .upsert(.track(Track(id: track.id, title: track.title, albumID: album.id, artistIDs: [artist.id])))
    ]))
    await store.close()
    let reopened = try LibraryPersistenceStore(configuration: configuration)
    let durable = SwiftDataLibraryRepository(store: reopened)
    #expect(try await durable.track(id: track.id)?.details == track.details)
    #expect(try await durable.album(id: album.id)?.details == album.details)
    #expect(try await durable.album(id: album.id)?.releaseYear == album.releaseYear)
    #expect(try await durable.album(id: album.id)?.albumType == .live)
    #expect(try await durable.artist(id: artist.id)?.details == artist.details)
    #expect(try await durable.artist(id: artist.id)?.name == artist.name)
    #expect(try await durable.trackDateAdded(id: track.id) == dateAdded)
    try await durable.apply(LibraryTransaction(idempotencyKey: "details-relationship-update", mutations: [
        .relation(.setArtists(trackID: track.id, artistIDs: [artist.id]))
    ]))
    #expect(try await durable.track(id: track.id)?.details == track.details)
    await reopened.close()
}
