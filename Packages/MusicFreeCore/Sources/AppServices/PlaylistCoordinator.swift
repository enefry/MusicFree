import Foundation
import LibraryAPI
import MusicDomain

internal actor PlaylistCoordinator: PlaylistServing {
    private let repository: (any PlaylistRepository)?

    init(repository: (any PlaylistRepository)?) {
        self.repository = repository
    }

    func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist> {
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.playlists(page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.browse")
        }
    }

    func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.entries(in: playlistID)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.entries")
        }
    }

    func create(_ draft: PlaylistDraft) async throws -> Playlist {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppServiceError.library(.constraint(.invalidPlaylistName))
        }
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.create(draft)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.create")
        }
    }

    func update(_ mutation: PlaylistMutation) async throws -> Playlist {
        guard Self.hasValidName(mutation.change) else {
            throw AppServiceError.library(.constraint(.invalidPlaylistName))
        }
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.update(mutation)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.update")
        }
    }

    func apply(_ mutation: PlaylistEntriesMutation) async throws {
        guard Self.hasValidOperation(mutation.operation) else {
            throw AppServiceError.library(.constraint(.invalidPlaylistPosition))
        }
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            try await repository.apply(mutation)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.entries.apply")
        }
    }

    func delete(_ playlistID: PlaylistID) async throws {
        guard let repository else {
            throw AppServiceError.missingDependency("playlistRepository")
        }
        do {
            try Task.checkCancellation()
            try await repository.delete(playlistID)
        } catch {
            throw AppServiceError.mapped(error, operation: "playlist.delete")
        }
    }

    private static func hasValidName(_ mutation: PlaylistMetadataMutation) -> Bool {
        switch mutation {
        case .rename(let name):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .replace(let name, _, _):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .setSortName, .setArtwork:
            return true
        }
    }

    private static func hasValidOperation(_ operation: PlaylistEntriesMutation.Operation) -> Bool {
        switch operation {
        case .insert(let values):
            return values.allSatisfy(\.hasValidPosition)
                && Set(values.map(\.itemID)).count == values.count
        case .move(let values):
            return values.allSatisfy(\.hasValidPosition)
                && Set(values.map(\.itemID)).count == values.count
        case .remove:
            return true
        case .reorder(let itemIDs):
            return Set(itemIDs).count == itemIDs.count
        }
    }
}
