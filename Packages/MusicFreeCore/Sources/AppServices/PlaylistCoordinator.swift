import Foundation
import LibraryAPI
import MusicDomain
import MediaSourceAPI

internal actor PlaylistCoordinator: PlaylistServing {
    private let repository: (any PlaylistRepository)?
    private let libraryRepository: (any LibraryRepository)?
    private let artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)?

    init(
        repository: (any PlaylistRepository)?,
        libraryRepository: (any LibraryRepository)? = nil,
        artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)? = nil
    ) {
        self.repository = repository
        self.libraryRepository = libraryRepository
        self.artworkWriter = artworkWriter
    }

    func setArtwork(_ data: Data?, for playlistID: PlaylistID) async throws -> Playlist {
        guard let data else {
            return try await update(PlaylistMutation(playlistID: playlistID, change: .setArtwork(nil)))
        }
        guard !data.isEmpty, data.count <= ArtworkDataLimits.maximumByteCount else {
            throw AppServiceError.invalidRequest(operation: "playlist.artwork")
        }
        guard let libraryRepository, let artworkWriter, repository != nil else {
            throw AppServiceError.missingDependency("playlistArtworkWriter")
        }
        let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(data))")
        var receipt: ArtworkWriteReceipt?
        var artworkIsPersisted = false
        do {
            receipt = try await artworkWriter(data, artworkID)
            try Task.checkCancellation()
            try await libraryRepository.apply(LibraryTransaction(
                idempotencyKey: "playlist-artwork.\(UUID().uuidString)",
                mutations: [.upsert(.artwork(ArtworkReference(id: artworkID, variants: [.original])))]
            ))
            artworkIsPersisted = true
            let playlist = try await update(PlaylistMutation(
                playlistID: playlistID, change: .setArtwork(artworkID)
            ))
            await receipt?.finish(committed: true)
            return playlist
        } catch {
            // Once the artwork record exists, retain its file even if attaching
            // it fails. The normal artwork pruner can reclaim unused records.
            await receipt?.finish(committed: artworkIsPersisted)
            throw AppServiceError.mapped(error, operation: "playlist.artwork")
        }
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
