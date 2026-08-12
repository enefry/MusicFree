import Foundation
import MusicDomain

/// Direction used by a repository sort descriptor.
public enum LibrarySortDirection: String, Codable, Hashable, Sendable {
    case ascending
    case descending
}

/// The stable tie-breaker appended by every repository sort.
public enum LibraryTieBreaker: String, Codable, Hashable, Sendable {
    case stableIdentifier
}

/// Search fields used by structured library queries.
public enum LibrarySearchScope: String, Codable, Hashable, Sendable {
    case all
    case title
    case album
    case artist
    case genre
}

/// Favorite-state filter for tracks.
public enum LibraryFavoriteFilter: String, Codable, Hashable, Sendable {
    case any
    case favorite
    case notFavorite
}

/// Fields supported when sorting tracks.
public enum TrackSortKey: String, Codable, Hashable, Sendable {
    case title
    case albumTitle
    case artistName
    case dateAdded
    case duration
    case lastPlayed
    case playCount
}

/// A track sort descriptor. Repositories must append the stable identifier tie-breaker.
public struct TrackSortDescriptor: Codable, Hashable, Sendable {
    public let key: TrackSortKey
    public let direction: LibrarySortDirection
    public let tieBreaker: LibraryTieBreaker

    public init(
        key: TrackSortKey,
        direction: LibrarySortDirection = .ascending,
        tieBreaker: LibraryTieBreaker = .stableIdentifier
    ) {
        self.key = key
        self.direction = direction
        self.tieBreaker = tieBreaker
    }

    public static let `default` = Self(key: .title)
}

/// Fields supported when sorting albums.
public enum AlbumSortKey: String, Codable, Hashable, Sendable {
    case title
    case artistName
    case dateAdded
    case year
    case trackCount
}

/// A stable album sort descriptor.
public struct AlbumSortDescriptor: Codable, Hashable, Sendable {
    public let key: AlbumSortKey
    public let direction: LibrarySortDirection
    public let tieBreaker: LibraryTieBreaker

    public init(
        key: AlbumSortKey,
        direction: LibrarySortDirection = .ascending,
        tieBreaker: LibraryTieBreaker = .stableIdentifier
    ) {
        self.key = key
        self.direction = direction
        self.tieBreaker = tieBreaker
    }

    public static let `default` = Self(key: .title)
}

/// Fields supported when sorting artists.
public enum ArtistSortKey: String, Codable, Hashable, Sendable {
    case name
    case dateAdded
    case albumCount
    case trackCount
}

/// A stable artist sort descriptor.
public struct ArtistSortDescriptor: Codable, Hashable, Sendable {
    public let key: ArtistSortKey
    public let direction: LibrarySortDirection
    public let tieBreaker: LibraryTieBreaker

    public init(
        key: ArtistSortKey,
        direction: LibrarySortDirection = .ascending,
        tieBreaker: LibraryTieBreaker = .stableIdentifier
    ) {
        self.key = key
        self.direction = direction
        self.tieBreaker = tieBreaker
    }

    public static let `default` = Self(key: .name)
}

/// Structured filtering and sorting for track queries.
public struct TrackQuery: Codable, Hashable, Sendable {
    public let searchText: String?
    public let searchScope: LibrarySearchScope
    public let sourceID: MediaSourceID?
    public let albumID: AlbumID?
    public let artistID: ArtistID?
    public let genreID: GenreID?
    public let favorite: LibraryFavoriteFilter
    public let sort: TrackSortDescriptor

    public init(
        searchText: String? = nil,
        searchScope: LibrarySearchScope = .all,
        sourceID: MediaSourceID? = nil,
        albumID: AlbumID? = nil,
        artistID: ArtistID? = nil,
        genreID: GenreID? = nil,
        favorite: LibraryFavoriteFilter = .any,
        sort: TrackSortDescriptor = .default
    ) {
        self.searchText = Self.normalizedSearchText(searchText)
        self.searchScope = searchScope
        self.sourceID = sourceID
        self.albumID = albumID
        self.artistID = artistID
        self.genreID = genreID
        self.favorite = favorite
        self.sort = sort
    }

    private static func normalizedSearchText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Structured filtering and sorting for album queries.
public struct AlbumQuery: Codable, Hashable, Sendable {
    public let searchText: String?
    public let searchScope: LibrarySearchScope
    public let sourceID: MediaSourceID?
    public let artistID: ArtistID?
    public let sort: AlbumSortDescriptor

    public init(
        searchText: String? = nil,
        searchScope: LibrarySearchScope = .all,
        sourceID: MediaSourceID? = nil,
        artistID: ArtistID? = nil,
        sort: AlbumSortDescriptor = .default
    ) {
        self.searchText = Self.normalizedSearchText(searchText)
        self.searchScope = searchScope
        self.sourceID = sourceID
        self.artistID = artistID
        self.sort = sort
    }

    private static func normalizedSearchText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Structured filtering and sorting for artist queries.
public struct ArtistQuery: Codable, Hashable, Sendable {
    public let searchText: String?
    public let sourceID: MediaSourceID?
    public let sort: ArtistSortDescriptor

    public init(
        searchText: String? = nil,
        sourceID: MediaSourceID? = nil,
        sort: ArtistSortDescriptor = .default
    ) {
        self.searchText = Self.normalizedSearchText(searchText)
        self.sourceID = sourceID
        self.sort = sort
    }

    private static func normalizedSearchText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Fields supported when sorting genres.
public enum GenreSortKey: String, Codable, Hashable, Sendable {
    case name
    case trackCount
}

public struct GenreSortDescriptor: Codable, Hashable, Sendable {
    public let key: GenreSortKey
    public let direction: LibrarySortDirection
    public let tieBreaker: LibraryTieBreaker

    public init(
        key: GenreSortKey = .name,
        direction: LibrarySortDirection = .ascending,
        tieBreaker: LibraryTieBreaker = .stableIdentifier
    ) {
        self.key = key
        self.direction = direction
        self.tieBreaker = tieBreaker
    }

    public static let `default` = Self()
}

public struct GenreQuery: Codable, Hashable, Sendable {
    public let searchText: String?
    public let sourceID: MediaSourceID?
    public let sort: GenreSortDescriptor

    public init(
        searchText: String? = nil,
        sourceID: MediaSourceID? = nil,
        sort: GenreSortDescriptor = .default
    ) {
        let normalized = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchText = normalized?.isEmpty == false ? normalized : nil
        self.sourceID = sourceID
        self.sort = sort
    }
}

/// A bounded page request. The cursor is opaque and must not be inspected by callers.
public struct LibraryPageRequest: Codable, Hashable, Sendable {
    public static let defaultLimit = 100
    public static let maximumLimit = 500

    public let limit: Int
    public let cursor: LibraryCursor?

    public init(
        limit: Int = Self.defaultLimit,
        cursor: LibraryCursor? = nil
    ) throws {
        guard (1...Self.maximumLimit).contains(limit) else {
            throw LibraryError.query(.invalidPageSize(requested: limit, maximum: Self.maximumLimit))
        }
        if cursor?.isEmpty == true {
            throw LibraryError.query(.invalidCursor)
        }
        self.limit = limit
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: container.decode(Int.self, forKey: .limit),
            cursor: container.decodeIfPresent(LibraryCursor.self, forKey: .cursor)
        )
    }
}
