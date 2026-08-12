import Foundation
import PlaybackAPI

/// SwiftData-backed single-snapshot queue persistence.
public final class SwiftDataPlaybackQueueRepository: PlaybackQueueRepository, Sendable {
    private let store: LibraryPersistenceStore

    public init(store: LibraryPersistenceStore) {
        self.store = store
    }

    public func load() async throws -> PlaybackQueueSnapshot {
        try await store.loadQueue()
    }

    public func save(_ snapshot: PlaybackQueueSnapshot) async throws {
        try await store.saveQueue(snapshot)
    }
}
