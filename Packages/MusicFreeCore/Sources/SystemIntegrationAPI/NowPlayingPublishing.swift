import Foundation
import MusicDomain

/// Supplies artwork bytes on demand without making a framework object part of
/// the public API.
public protocol NowPlayingArtworkProviding: Sendable {
    func artworkData() async throws -> Data?
}

/// A short-lived reference used by a Now Playing publisher to obtain artwork.
/// The provider is intentionally not a persistence value; artworkID is the
/// stable identity used for equality and hashing.
public struct NowPlayingArtworkReference: Sendable, Equatable, Hashable {
    public let artworkID: ArtworkID?
    public let provider: (any NowPlayingArtworkProviding)?

    public init(
        artworkID: ArtworkID? = nil,
        provider: (any NowPlayingArtworkProviding)? = nil
    ) {
        precondition(
            artworkID != nil || provider != nil,
            "NowPlayingArtworkReference requires an artwork ID or provider"
        )
        self.artworkID = artworkID
        self.provider = provider
    }

    public init(
        id: ArtworkID,
        provider: (any NowPlayingArtworkProviding)? = nil
    ) {
        self.init(artworkID: id, provider: provider)
    }

    public var id: ArtworkID? {
        artworkID
    }

    public var dataProvider: (any NowPlayingArtworkProviding)? {
        provider
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artworkID == rhs.artworkID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(artworkID)
    }
}

/// Whether the current Now Playing item is producing audio.
public enum NowPlayingPlaybackState: String, Codable, CaseIterable, Hashable, Sendable {
    case playing
    case paused
}

/// A framework-neutral snapshot for lock-screen and system playback metadata.
public struct NowPlayingSnapshot: Sendable, Equatable, Hashable {
    public let itemID: MediaItemID
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: Duration?
    public let elapsed: Duration
    public let playbackState: NowPlayingPlaybackState
    public let rate: Float
    /// Zero-based queue position, when the coordinator has queue context.
    public let queuePosition: Int?
    public let queueCount: Int?
    public let artwork: NowPlayingArtworkReference?
    public let updatedAt: Date

    public init(
        itemID: MediaItemID,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Duration? = nil,
        elapsed: Duration = .zero,
        isPlaying: Bool = false,
        rate: Float = 0,
        queuePosition: Int? = nil,
        queueCount: Int? = nil,
        artwork: NowPlayingArtworkReference? = nil,
        updatedAt: Date = Date()
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedTitle.isEmpty, "NowPlayingSnapshot.title cannot be empty")
        if let duration {
            precondition(duration >= .zero, "NowPlayingSnapshot.duration cannot be negative")
        }
        precondition(elapsed >= .zero, "NowPlayingSnapshot.elapsed cannot be negative")
        if let duration {
            precondition(
                elapsed <= duration,
                "NowPlayingSnapshot.elapsed cannot exceed duration"
            )
        }
        precondition(rate.isFinite && rate >= 0, "NowPlayingSnapshot.rate must be finite")
        if let queuePosition {
            precondition(queuePosition >= 0, "NowPlayingSnapshot.queuePosition cannot be negative")
        }
        if let queueCount {
            precondition(queueCount > 0, "NowPlayingSnapshot.queueCount must be positive")
            if let queuePosition {
                precondition(
                    queuePosition < queueCount,
                    "NowPlayingSnapshot.queuePosition must be within queueCount"
                )
            }
        }

        self.itemID = itemID
        self.title = normalizedTitle
        self.artist = Self.normalized(artist)
        self.album = Self.normalized(album)
        self.duration = duration
        self.elapsed = elapsed
        self.playbackState = isPlaying ? .playing : .paused
        self.rate = rate
        self.queuePosition = queuePosition
        self.queueCount = queueCount
        self.artwork = artwork
        self.updatedAt = updatedAt
    }

    public var isPlaying: Bool {
        playbackState == .playing
    }

    public var state: NowPlayingPlaybackState {
        playbackState
    }

    public var playbackRate: Float {
        rate
    }

    public var elapsedTime: Duration {
        elapsed
    }

    public var timestamp: Date {
        updatedAt
    }

    /// Projects the elapsed position to a later publication time. The result
    /// is monotonic and never exceeds a known duration.
    public func projectedElapsed(at date: Date) -> Duration {
        guard isPlaying, rate > 0, date > updatedAt else {
            return elapsed
        }

        let seconds = date.timeIntervalSince(updatedAt) * Double(rate)
        var projected = elapsed + .seconds(seconds)
        if let duration {
            projected = min(projected, duration)
        }
        return projected
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Publishes and clears the current system playback metadata.
@MainActor
public protocol NowPlayingPublishing: AnyObject {
    func publish(_ snapshot: NowPlayingSnapshot)
    func clear()
}
