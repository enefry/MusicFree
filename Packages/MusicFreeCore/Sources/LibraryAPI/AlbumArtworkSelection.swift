import Foundation
import MusicDomain

/// Identifies where a local album artwork candidate came from.
public enum AlbumArtworkOrigin: Int, Sendable {
    case embedded
    case folderOrSidecar
}

/// An artwork reference together with the source information needed to choose
/// one stable album cover from several imported tracks.
public struct AlbumArtworkCandidate: Sendable {
    public let artwork: ArtworkReference
    public let origin: AlbumArtworkOrigin
    public let stableKey: String

    public init(
        artwork: ArtworkReference,
        origin: AlbumArtworkOrigin,
        stableKey: String
    ) {
        self.artwork = artwork
        self.origin = origin
        self.stableKey = stableKey
    }
}

private struct AlbumArtworkScore {
    let artwork: ArtworkReference
    let origin: AlbumArtworkOrigin
    let count: Int
    let stableKey: String
}

/// Selects one cover without relying on collection iteration order.
public enum AlbumArtworkSelector {
    public static func select(
        from candidates: some Sequence<AlbumArtworkCandidate>
    ) -> ArtworkReference? {
        var scores: [ArtworkID: AlbumArtworkScore] = [:]
        for candidate in candidates {
            let artworkID = candidate.artwork.id
            if let existing = scores[artworkID] {
                scores[artworkID] = AlbumArtworkScore(
                    artwork: existing.artwork,
                    origin: existing.origin.rawValue >= candidate.origin.rawValue
                        ? existing.origin : candidate.origin,
                    count: existing.count + 1,
                    stableKey: min(existing.stableKey, candidate.stableKey)
                )
            } else {
                scores[artworkID] = AlbumArtworkScore(
                    artwork: candidate.artwork,
                    origin: candidate.origin,
                    count: 1,
                    stableKey: candidate.stableKey
                )
            }
        }

        let preferredScores = scores.values.filter {
            $0.origin == .folderOrSidecar
        }
        let pool = preferredScores.isEmpty ? Array(scores.values) : Array(preferredScores)
        return pool.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            if lhs.stableKey != rhs.stableKey {
                return lhs.stableKey < rhs.stableKey
            }
            return lhs.artwork.id.rawValue < rhs.artwork.id.rawValue
        }.first?.artwork
    }
}
