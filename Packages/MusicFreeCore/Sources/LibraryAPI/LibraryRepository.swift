import Foundation
import MusicDomain

/// Repository contract for paged library reads and atomic library writes.
public protocol LibraryRepository: Sendable {
    func track(id: MediaItemID) async throws -> Track?
    func album(id: AlbumID) async throws -> Album?
    func artist(id: ArtistID) async throws -> Artist?
    func genre(id: GenreID) async throws -> Genre?
    func artwork(id: ArtworkID) async throws -> ArtworkReference?
    /// Returns whether any durable library object still points at the artwork.
    /// This is intentionally distinct from `artwork(id:)`: a record may remain
    /// after a failed migration or a custom repository may retain unreferenced
    /// metadata while the managed file is eligible for cleanup.
    func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool

    func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track>

    func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album>

    func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist>

    func genres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre>

    /// Returns logical source folders. Absolute filesystem paths are never
    /// exposed by this contract.
    func folders(page: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder>

    /// The transaction must commit all mutations or make no visible change.
    func apply(_ transaction: LibraryTransaction) async throws

    /// Removes tracks and prunes their relationships, playlist entries, and statistics atomically.
    func remove(_ itemIDs: Set<MediaItemID>) async throws

    /// Emits only committed changes and finishes when the repository is disposed.
    func changes() -> AsyncStream<LibraryChange>
}

public extension LibraryRepository {
    func genre(id: GenreID) async throws -> Genre? {
        let page = try await genres(
            matching: GenreQuery(),
            page: LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        return page.elements.first { $0.id == id }
    }

    func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
        try await artwork(id: artworkID) != nil
    }

    func genres(
        matching _: GenreQuery,
        page _: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        LibraryPage(elements: [])
    }

    func folders(page _: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        LibraryPage(elements: [])
    }
}
