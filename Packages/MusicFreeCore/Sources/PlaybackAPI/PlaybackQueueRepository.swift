import Foundation

/// Persists only `PlaybackQueueSnapshot` values. Missing persisted state is
/// represented by `PlaybackQueueSnapshot.empty` by the adapter.
public protocol PlaybackQueueRepository: Sendable {
  func load() async throws -> PlaybackQueueSnapshot
  func save(_ snapshot: PlaybackQueueSnapshot) async throws
}

public extension PlaybackQueueRepository {
  func loadSnapshot() async throws -> PlaybackQueueSnapshot {
    try await load()
  }

  func saveSnapshot(_ snapshot: PlaybackQueueSnapshot) async throws {
    try await save(snapshot)
  }
}
