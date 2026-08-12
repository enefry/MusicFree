import Foundation
import LibraryAPI
import MusicDomain

/// SwiftData-backed implementation of playback history and statistics updates.
public final class SwiftDataPlaybackHistoryRepository: PlaybackHistoryRepository, Sendable {
    private let store: LibraryPersistenceStore

    public init(store: LibraryPersistenceStore) {
        self.store = store
    }

    public func recordPlaybackStarted(_ event: PlaybackStart) async throws {
        try await store.recordHistory(.started(event))
    }

    public func recordValidPlayback(_ event: ValidPlayback) async throws {
        try await store.recordHistory(.validPlayback(event))
    }

    public func recordCompleted(_ event: PlaybackCompletion) async throws {
        try await store.recordHistory(.completed(event))
    }

    public func recordSkipped(_ event: PlaybackSkip) async throws {
        try await store.recordHistory(.skipped(event))
    }

    public func recentHistory(page: LibraryPageRequest) async throws -> LibraryPage<PlaybackHistoryRecord> {
        try await store.recentHistory(page: page)
    }

    public func clearHistory() async throws {
        try await store.clearHistory()
    }
}
