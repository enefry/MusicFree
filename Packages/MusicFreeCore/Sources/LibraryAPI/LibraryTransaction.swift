import Foundation
import MusicDomain

/// Monotonic store revision used for optimistic concurrency checks.
public struct LibraryRevision: RawRepresentable, Codable, Comparable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.init(rawValue: rawValue)
    }

    public static let initial = Self(rawValue: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A non-negative change to playback counters applied atomically with a library transaction.
public struct PlaybackStatisticsDelta: Codable, Sendable {
    public let playCount: Int
    public let completionCount: Int
    public let skipCount: Int
    public let totalListeningDuration: Duration
    public let lastPlayedAt: Date?

    public init(
        playCount: Int = 0,
        completionCount: Int = 0,
        skipCount: Int = 0,
        totalListeningDuration: Duration = .zero,
        lastPlayedAt: Date? = nil
    ) {
        self.playCount = playCount
        self.completionCount = completionCount
        self.skipCount = skipCount
        self.totalListeningDuration = totalListeningDuration
        self.lastPlayedAt = lastPlayedAt
    }

    public var isNonNegative: Bool {
        playCount >= 0 && completionCount >= 0 && skipCount >= 0 && totalListeningDuration >= .zero
    }

    public var completedCount: Int { completionCount }
    public var skippedCount: Int { skipCount }
    public var totalPlayedDuration: Duration { totalListeningDuration }
}

/// A domain value to upsert as part of one atomic library transaction.
public enum LibraryUpsertMutation: Codable, Sendable {
    case track(Track)
    case album(Album)
    case artist(Artist)
    case genre(Genre)
    case artwork(ArtworkReference)
    case logicalTrack(LogicalTrack)
    case trackVariant(TrackVariant)
    case mediaAsset(MediaAsset)
    case albumGroup(AlbumGroup)
    case albumRelease(AlbumRelease)
    case disc(Disc)
    case collection(LibraryCollection)
    case collectionMember(LibraryCollectionMember)
}

/// A relationship replacement applied atomically with related library values.
public enum LibraryRelationMutation: Codable, Sendable {
    case setAlbum(trackID: MediaItemID, albumID: AlbumID?)
    case setArtists(trackID: MediaItemID, artistIDs: [ArtistID])
    case setGenres(trackID: MediaItemID, genreIDs: [GenreID])
    case setArtwork(trackID: MediaItemID, artworkID: ArtworkID?)
}

/// A statistics replacement or delta applied atomically with library values.
public enum LibraryStatisticsMutation: Codable, Sendable {
    case replace(trackID: MediaItemID, statistics: PlaybackStatistics)
    case increment(trackID: MediaItemID, delta: PlaybackStatisticsDelta)
}

/// One typed mutation in a library transaction.
public enum LibraryMutation: Codable, Sendable {
    case upsert(LibraryUpsertMutation)
    case relation(LibraryRelationMutation)
    case statistics(LibraryStatisticsMutation)
}

/// A complete atomic write with an idempotency key and optional optimistic revision.
public struct LibraryTransaction: Codable, Sendable {
    public let idempotencyKey: String
    public let expectedRevision: LibraryRevision?
    public let mutations: [LibraryMutation]

    public init(
        idempotencyKey: String,
        expectedRevision: LibraryRevision? = nil,
        mutations: [LibraryMutation]
    ) throws {
        let normalizedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw LibraryError.constraint(.invalidIdempotencyKey)
        }
        guard !mutations.isEmpty else {
            throw LibraryError.constraint(.emptyTransaction)
        }
        self.idempotencyKey = normalizedKey
        self.expectedRevision = expectedRevision
        self.mutations = mutations
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey
        case expectedRevision
        case mutations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            expectedRevision: container.decodeIfPresent(LibraryRevision.self, forKey: .expectedRevision),
            mutations: container.decode([LibraryMutation].self, forKey: .mutations)
        )
    }
}

public typealias LibraryUpsert = LibraryUpsertMutation
