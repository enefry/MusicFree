import Foundation
import MusicDomain

/// Categories emitted after a repository commit succeeds.
public enum LibraryChangeCategory: String, Codable, Hashable, Sendable {
    case tracks
    case albums
    case artists
    case genres
    case artwork
    case playlists
    case playlistEntries
    case playbackStatistics
    case playbackHistory
    case deletions
}

/// Typed identifiers affected by a committed change.
public struct LibraryAffectedIDs: Codable, Equatable, Sendable {
    public let trackIDs: Set<MediaItemID>
    public let albumIDs: Set<AlbumID>
    public let artistIDs: Set<ArtistID>
    public let genreIDs: Set<GenreID>
    public let artworkIDs: Set<ArtworkID>
    public let playlistIDs: Set<PlaylistID>

    public init(
        trackIDs: Set<MediaItemID> = [],
        albumIDs: Set<AlbumID> = [],
        artistIDs: Set<ArtistID> = [],
        genreIDs: Set<GenreID> = [],
        artworkIDs: Set<ArtworkID> = [],
        playlistIDs: Set<PlaylistID> = []
    ) {
        self.trackIDs = trackIDs
        self.albumIDs = albumIDs
        self.artistIDs = artistIDs
        self.genreIDs = genreIDs
        self.artworkIDs = artworkIDs
        self.playlistIDs = playlistIDs
    }

    public var isEmpty: Bool {
        trackIDs.isEmpty && albumIDs.isEmpty && artistIDs.isEmpty && genreIDs.isEmpty
            && artworkIDs.isEmpty && playlistIDs.isEmpty
    }
}

/// A compact post-commit notification. It contains IDs and categories, never store objects.
public struct LibraryChange: Codable, Equatable, Sendable {
    public let revision: LibraryRevision
    public let categories: Set<LibraryChangeCategory>
    public let affectedIDs: LibraryAffectedIDs

    public init(
        revision: LibraryRevision,
        categories: Set<LibraryChangeCategory>,
        affectedIDs: LibraryAffectedIDs
    ) {
        self.revision = revision
        self.categories = categories
        self.affectedIDs = affectedIDs
    }
}
