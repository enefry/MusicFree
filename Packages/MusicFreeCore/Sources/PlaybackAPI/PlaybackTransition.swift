import Foundation
import MusicDomain

/// Ephemeral authorization for exactly one queue successor. Never persisted.
public struct PlaybackTransitionTicket: Equatable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let intent: UInt64
    public let queueRevision: UInt64
    public let generation: PlaybackGeneration
    public let currentItemID: MediaItemID
    public let nextEntryID: UUID

    public init(id: UUID = UUID(), sessionID: UUID, intent: UInt64, queueRevision: UInt64,
                generation: PlaybackGeneration, currentItemID: MediaItemID, nextEntryID: UUID) {
        self.id = id
        self.sessionID = sessionID
        self.intent = intent
        self.queueRevision = queueRevision
        self.generation = generation
        self.currentItemID = currentItemID
        self.nextEntryID = nextEntryID
    }
}

public struct LogicalPlaybackCommit: Sendable {
    public let ticket: PlaybackTransitionTicket
    public let item: PlaybackItem
    public let renderFrame: Int64
    public let sampleRate: Double
    public init(ticket: PlaybackTransitionTicket, item: PlaybackItem, renderFrame: Int64, sampleRate: Double) {
        self.ticket = ticket
        self.item = item
        self.renderFrame = renderFrame
        self.sampleRate = sampleRate
    }
}

public struct PlaybackTransitionRetirement: Sendable {
    public let ticket: PlaybackTransitionTicket
    public let renderFrame: Int64
    public let playedDuration: Duration
    public let reason: PlaybackCompletionReason
    public init(ticket: PlaybackTransitionTicket, renderFrame: Int64, playedDuration: Duration,
                reason: PlaybackCompletionReason = .ended) {
        self.ticket = ticket; self.renderFrame = renderFrame; self.playedDuration = playedDuration
        self.reason = reason
    }
}

public enum PlaybackTransitionInvalidationReason: Sendable {
    case outputRebuilt
    case preparationFailed
}

/// Optional engine extension: a queue owner authorizes the next resource;
/// only the engine's first rendered successor frame commits logical identity.
@MainActor
public protocol PlaybackTransitionControlling: AnyObject {
    func makeTransitionStream() -> AsyncStream<LogicalPlaybackCommit>
    func prepareNext(_ item: PlaybackItem, ticket: PlaybackTransitionTicket) async throws
    func cancelNext()
    func hardPause()
    func hardStop()
    func waitForSoftStop() async
    func setTransitionCommitHandler(_ handler: (@MainActor (LogicalPlaybackCommit) -> Void)?)
    func setTransitionRetirementHandler(_ handler: (@MainActor (PlaybackTransitionRetirement) -> Void)?)
    func setTransitionInvalidationHandler(_ handler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?)
}

public extension PlaybackTransitionControlling {
    func waitForSoftStop() async {}
    func setTransitionCommitHandler(_ handler: (@MainActor (LogicalPlaybackCommit) -> Void)?) {}
    func setTransitionRetirementHandler(_ handler: (@MainActor (PlaybackTransitionRetirement) -> Void)?) {}
    func setTransitionInvalidationHandler(_ handler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?) {}
}
