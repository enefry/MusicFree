import Foundation
import LibraryAPI
import MusicDomain

/// SwiftData-backed implementation of playlist metadata and ordering.
public final class SwiftDataPlaylistRepository: PlaylistRepository, Sendable {
    private let store: LibraryPersistenceStore

    public init(store: LibraryPersistenceStore) {
        self.store = store
    }

    public func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist> {
        try await store.playlists(page: page)
    }

    public func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        try await store.entries(in: playlistID)
    }

    public func create(_ draft: PlaylistDraft) async throws -> Playlist {
        try await store.createPlaylist(draft)
    }

    public func update(_ mutation: PlaylistMutation) async throws -> Playlist {
        try await store.updatePlaylist(mutation)
    }

    public func apply(_ mutation: PlaylistEntriesMutation) async throws {
        try await store.applyPlaylistEntries(mutation)
    }

    public func delete(_ playlistID: PlaylistID) async throws {
        try await store.deletePlaylist(playlistID)
    }
}
