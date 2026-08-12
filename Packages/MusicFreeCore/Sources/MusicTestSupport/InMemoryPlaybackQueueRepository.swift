import Foundation
import PlaybackAPI

public struct InMemoryPlaybackQueueFailureScript: Sendable {
    public var loadError: PlaybackError?
    public var saveError: PlaybackError?
    public var delay: Duration

    public init(
        loadError: PlaybackError? = nil,
        saveError: PlaybackError? = nil,
        delay: Duration = .zero
    ) {
        self.loadError = loadError
        self.saveError = saveError
        self.delay = delay
    }
}

/// A minimal queue persistence fake. It stores only the value snapshot and
/// leaves all queue editing semantics to `PlaybackQueueSnapshot` itself.
public actor InMemoryPlaybackQueueRepository: PlaybackQueueRepository {
    private var snapshot: PlaybackQueueSnapshot
    private var failureScript: InMemoryPlaybackQueueFailureScript

    public private(set) var loadCount = 0
    public private(set) var saveCalls: [PlaybackQueueSnapshot] = []

    public init(
        snapshot: PlaybackQueueSnapshot = .empty,
        failureScript: InMemoryPlaybackQueueFailureScript = .init()
    ) {
        self.snapshot = snapshot
        self.failureScript = failureScript
    }

    public func load() async throws -> PlaybackQueueSnapshot {
        loadCount += 1
        try await wait()
        if let error = failureScript.loadError { throw error }
        return snapshot
    }

    public func save(_ snapshot: PlaybackQueueSnapshot) async throws {
        saveCalls.append(snapshot)
        try await wait()
        if let error = failureScript.saveError { throw error }
        self.snapshot = snapshot
    }

    public func setFailureScript(_ script: InMemoryPlaybackQueueFailureScript) {
        failureScript = script
    }

    public func currentSnapshot() -> PlaybackQueueSnapshot {
        snapshot
    }

    private func wait() async throws {
        guard failureScript.delay > .zero else { return }
        do {
            try await Task.sleep(for: failureScript.delay)
        } catch {
            throw CancellationError()
        }
    }
}
