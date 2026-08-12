import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

/// Compatibility service for the existing no-argument scene initializer.
/// It is deliberately not an adapter and returns an empty local library.
struct UnconfiguredLibraryServing: AppServices.LibraryServing {
    func track(id: MediaItemID) async throws -> Track? {
        nil
    }

    func browseTracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func browseAlbums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        LibraryPage(elements: [])
    }

    func browseArtists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        LibraryPage(elements: [])
    }

    func searchTracks(
        text: String,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
        throw AppServiceError.invalidRequest(operation: "library is not configured")
    }

    func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
        throw AppServiceError.invalidRequest(operation: "library is not configured")
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        throw AppServiceError.invalidRequest(operation: "library is not configured")
    }

    func makeChangeStream() async -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
