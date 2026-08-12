import Foundation
import MusicDomain

/// Repository contract for paged library reads and atomic library writes.
public protocol LibraryRepository: Sendable {
    func track(id: MediaItemID) async throws -> Track?
    func album(id: AlbumID) async throws -> Album?
    func artist(id: ArtistID) async throws -> Artist?

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
