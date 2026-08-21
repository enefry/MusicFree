import Foundation
import MusicDomain
import PlaybackAPI
import SystemIntegrationAPI

/// The queue value exposed to Feature targets. It contains no resolved resource.
public struct PlaybackQueueSummary: Codable, Equatable, Hashable, Sendable {
    public let entries: [PlaybackQueueEntry]
    public let currentEntryID: UUID?
    public let repeatMode: PlaybackRepeatMode
    public let shuffleMode: PlaybackShuffleMode
    public let shuffleSeed: UInt64?
    public let shuffleOrder: [UUID]
    public let resumePosition: Duration?

    public init(snapshot: PlaybackQueueSnapshot) {
        entries = snapshot.entries
        currentEntryID = snapshot.currentEntryID
        repeatMode = snapshot.repeatMode
        shuffleMode = snapshot.shuffleMode
        shuffleSeed = snapshot.shuffleSeed
        shuffleOrder = snapshot.shuffleOrder
        resumePosition = snapshot.resumePosition
    }

    public init(
        entries: [PlaybackQueueEntry] = [],
        currentEntryID: UUID? = nil,
        repeatMode: PlaybackRepeatMode = .off,
        shuffleMode: PlaybackShuffleMode = .off,
        shuffleSeed: UInt64? = nil,
        shuffleOrder: [UUID] = [],
        resumePosition: Duration? = nil
    ) {
        self.init(
            snapshot: PlaybackQueueSnapshot(
                entries: entries,
                currentEntryID: currentEntryID,
                repeatMode: repeatMode,
                shuffleMode: shuffleMode,
                shuffleSeed: shuffleSeed,
                shuffleOrder: shuffleOrder,
                resumePosition: resumePosition
            )
        )
    }

    public var itemIDs: [MediaItemID] {
        entries.compactMap(\.itemID)
    }

    public var currentItemID: MediaItemID? {
        guard let currentEntryID else { return nil }
        return entries.first(where: { $0.id == currentEntryID })?.itemID ?? nil
    }

    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var snapshot: PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: currentEntryID,
            repeatMode: repeatMode,
            shuffleMode: shuffleMode,
            shuffleSeed: shuffleSeed,
            shuffleOrder: shuffleOrder,
            resumePosition: resumePosition
        )
    }
}

/// The single playback-session value observed by Feature targets.
@available(macOS 13.0, iOS 16.0, *)
public struct PlaybackSessionSnapshot: Codable, Equatable, Hashable, Sendable {
    public let state: PlaybackState
    public let currentItem: PlaybackDisplaySnapshot?
    public let queue: PlaybackQueueSummary
    public let capabilities: PlaybackCapabilities
    public let effectiveEffects: AudioEffectConfiguration
    public let systemCapabilities: SystemIntegrationCapabilitySnapshot

    public init(
        state: PlaybackState = .idle,
        currentItem: PlaybackDisplaySnapshot? = nil,
        queue: PlaybackQueueSummary = .init(),
        capabilities: PlaybackCapabilities = [],
        effectiveEffects: AudioEffectConfiguration = .neutral,
        systemCapabilities: SystemIntegrationCapabilitySnapshot = .init()
    ) {
        self.state = state
        self.currentItem = currentItem
        self.queue = queue
        self.capabilities = capabilities
        self.effectiveEffects = effectiveEffects
        self.systemCapabilities = systemCapabilities
    }

    public var phase: PlaybackPhase { state.phase }
    public var generation: PlaybackGeneration { state.generation }
    public var currentItemID: MediaItemID? { state.itemID ?? queue.currentItemID }
    public var position: Duration { state.position }
    public var duration: Duration? { state.duration ?? currentItem?.duration }
    public var error: PlaybackError? { state.error }
    public var queueSummary: PlaybackQueueSummary { queue }
    public var effects: AudioEffectConfiguration { effectiveEffects }
}

/// User intent sent through the common UI/remote playback state machine.
public enum PlaybackSessionCommand: Codable, Equatable, Hashable, Sendable {
    case play(itemID: MediaItemID)
    case playItems(itemIDs: [MediaItemID], shuffle: Bool)
    case resume
    case pause
    case toggle
    case stop
    case next
    case previous
    case seek(to: Duration)
    case setRate(Float)
    case setEffects(AudioEffectConfiguration)
    case enqueue(itemID: MediaItemID, at: Int?)
    case enqueueItems(itemIDs: [MediaItemID])
    case enqueueNext(itemIDs: [MediaItemID])
    case editQueue(PlaybackQueueEdit)

    public static func play(_ itemID: MediaItemID) -> Self {
        .play(itemID: itemID)
    }

    public static var togglePlayPause: Self { .toggle }

    public static func seek(_ position: Duration) -> Self {
        .seek(to: position)
    }

    public static func enqueue(_ itemID: MediaItemID, at position: Int? = nil) -> Self {
        .enqueue(itemID: itemID, at: position)
    }
}
