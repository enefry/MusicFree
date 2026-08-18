import Foundation
import LibraryAPI
import MusicDomain

/// SwiftData-backed implementation of the library repository contract.
public final class SwiftDataLibraryRepository: LibraryRepository, Sendable {
    private let store: LibraryPersistenceStore

    public init(store: LibraryPersistenceStore) {
        self.store = store
    }

    public func track(id: MediaItemID) async throws -> Track? {
        try await store.track(id: id)
    }

    public func album(id: AlbumID) async throws -> Album? {
        try await store.album(id: id)
    }

    public func artist(id: ArtistID) async throws -> Artist? {
        try await store.artist(id: id)
    }

    public func genre(id: GenreID) async throws -> Genre? {
        try await store.genre(id: id)
    }

    public func artwork(id: ArtworkID) async throws -> ArtworkReference? {
        try await store.artwork(id: id)
    }

    public func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
        try await store.isArtworkReferenced(artworkID)
    }

    public func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        try await store.tracks(matching: query, page: page)
    }

    public func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        try await store.albums(matching: query, page: page)
    }

    public func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        try await store.artists(matching: query, page: page)
    }

    public func genres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        try await store.genres(matching: query, page: page)
    }

    public func folders(page: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        try await store.folders(page: page)
    }

    public func apply(_ transaction: LibraryTransaction) async throws {
        try await store.apply(transaction)
    }

    public func remove(_ itemIDs: Set<MediaItemID>) async throws {
        try await store.remove(itemIDs)
    }

    public func changes() -> AsyncStream<LibraryChange> {
        store.makeChangeStream()
    }
}
