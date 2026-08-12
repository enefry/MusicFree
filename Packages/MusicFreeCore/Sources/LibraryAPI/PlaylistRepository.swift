import Foundation
import MusicDomain

/// Values needed to create a playlist without exposing a persistence record.
public struct PlaylistDraft: Codable, Sendable {
    public let name: String
    public let sortName: String?
    public let artworkID: ArtworkID?

    public init(
        name: String,
        sortName: String? = nil,
        artworkID: ArtworkID? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortName = sortName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artworkID = artworkID
    }
}

/// A single metadata change to an existing playlist.
public enum PlaylistMetadataMutation: Codable, Sendable {
    case rename(String)
    case setSortName(String?)
    case setArtwork(ArtworkID?)
    case replace(name: String, sortName: String?, artworkID: ArtworkID?)
}

/// An optimistic, typed playlist metadata mutation.
public struct PlaylistMutation: Codable, Sendable {
    public let playlistID: PlaylistID
    public let expectedRevision: LibraryRevision?
    public let change: PlaylistMetadataMutation

    public init(
        playlistID: PlaylistID,
        expectedRevision: LibraryRevision? = nil,
        change: PlaylistMetadataMutation
    ) {
        self.playlistID = playlistID
        self.expectedRevision = expectedRevision
        self.change = change
    }
}

/// A member insertion with an explicit, stable position.
public struct PlaylistEntryInsertion: Codable, Sendable {
    public let itemID: MediaItemID
    public let position: Int

    public init(itemID: MediaItemID, position: Int) {
        self.itemID = itemID
        self.position = position
    }

    public var hasValidPosition: Bool { position >= 0 }
}

/// A member move with an explicit destination position.
public struct PlaylistEntryMove: Codable, Sendable {
    public let itemID: MediaItemID
    public let position: Int

    public init(itemID: MediaItemID, position: Int) {
        self.itemID = itemID
        self.position = position
    }

    public var hasValidPosition: Bool { position >= 0 }
}

/// One atomic member edit. Reorder accepts the complete desired order.
public struct PlaylistEntriesMutation: Codable, Sendable {
    public enum Operation: Codable, Sendable {
        case insert([PlaylistEntryInsertion])
        case move([PlaylistEntryMove])
        case remove(Set<MediaItemID>)
        case reorder([MediaItemID])
    }

    public let playlistID: PlaylistID
    public let expectedRevision: LibraryRevision?
    public let operation: Operation

    public init(
        playlistID: PlaylistID,
        expectedRevision: LibraryRevision? = nil,
        operation: Operation
    ) {
        self.playlistID = playlistID
        self.expectedRevision = expectedRevision
        self.operation = operation
    }
}

/// Repository contract for playlist metadata and member ordering.
public protocol PlaylistRepository: Sendable {
    func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist>
    func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry]
    func create(_ draft: PlaylistDraft) async throws -> Playlist
    func update(_ mutation: PlaylistMutation) async throws -> Playlist
    func apply(_ mutation: PlaylistEntriesMutation) async throws
    func delete(_ playlistID: PlaylistID) async throws
}
