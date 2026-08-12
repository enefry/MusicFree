import Foundation
import MusicDomain

/// A playback session start supplied by the playback coordinator.
public struct PlaybackStart: Codable, Sendable {
    public let sessionID: UUID
    public let itemID: MediaItemID
    public let startedAt: Date

    public init(sessionID: UUID, itemID: MediaItemID, startedAt: Date) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.startedAt = startedAt
    }
}

/// A playback observation that qualifies as valid listening time.
public struct ValidPlayback: Codable, Sendable {
    public let sessionID: UUID
    public let itemID: MediaItemID
    public let occurredAt: Date
    public let playedDuration: Duration

    public init(
        sessionID: UUID,
        itemID: MediaItemID,
        occurredAt: Date,
        playedDuration: Duration
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.occurredAt = occurredAt
        self.playedDuration = playedDuration
    }
}

/// A completion event used to update recent history and statistics.
public struct PlaybackCompletion: Codable, Sendable {
    public let sessionID: UUID
    public let itemID: MediaItemID
    public let occurredAt: Date
    public let reason: PlaybackCompletionReason

    public init(
        sessionID: UUID,
        itemID: MediaItemID,
        occurredAt: Date,
        reason: PlaybackCompletionReason
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

/// A skip event that is distinct from a normal completion.
public struct PlaybackSkip: Codable, Sendable {
    public let sessionID: UUID
    public let itemID: MediaItemID
    public let occurredAt: Date
    public let playedDuration: Duration

    public init(
        sessionID: UUID,
        itemID: MediaItemID,
        occurredAt: Date,
        playedDuration: Duration
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.occurredAt = occurredAt
        self.playedDuration = playedDuration
    }
}

/// Events accepted by a playback-history repository.
public enum PlaybackHistoryEvent: Codable, Sendable {
    case started(PlaybackStart)
    case validPlayback(ValidPlayback)
    case completed(PlaybackCompletion)
    case skipped(PlaybackSkip)
}

/// A compact recent-history record. It contains stable IDs, not domain objects.
public struct PlaybackHistoryRecord: Codable, Sendable {
    public let sessionID: UUID
    public let itemID: MediaItemID
    public let lastStartedAt: Date
    public let lastEventAt: Date
    public let totalPlayedDuration: Duration
    public let lastPosition: Duration?
    public let lastCompletionReason: PlaybackCompletionReason?

    public init(
        sessionID: UUID,
        itemID: MediaItemID,
        lastStartedAt: Date,
        lastEventAt: Date,
        totalPlayedDuration: Duration,
        lastPosition: Duration? = nil,
        lastCompletionReason: PlaybackCompletionReason? = nil
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.lastStartedAt = lastStartedAt
        self.lastEventAt = lastEventAt
        self.totalPlayedDuration = totalPlayedDuration
        self.lastPosition = lastPosition
        self.lastCompletionReason = lastCompletionReason
    }
}

/// Repository contract for playback lifecycle events and recent history.
public protocol PlaybackHistoryRepository: Sendable {
    func recordPlaybackStarted(_ event: PlaybackStart) async throws
    func recordValidPlayback(_ event: ValidPlayback) async throws
    func recordCompleted(_ event: PlaybackCompletion) async throws
    func recordSkipped(_ event: PlaybackSkip) async throws
    func recentHistory(page: LibraryPageRequest) async throws -> LibraryPage<PlaybackHistoryRecord>
    func clearHistory() async throws
}

public extension PlaybackHistoryRepository {
    func record(_ event: PlaybackHistoryEvent) async throws {
        switch event {
        case .started(let event):
            try await recordPlaybackStarted(event)
        case .validPlayback(let event):
            try await recordValidPlayback(event)
        case .completed(let event):
            try await recordCompleted(event)
        case .skipped(let event):
            try await recordSkipped(event)
        }
    }
}
