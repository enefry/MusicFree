import Foundation
import MediaSourceAPI

/// FIFO worker gate used by every audio conversion source in the application.
public actor MediaConversionScheduler: MediaConversionScheduling {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var maximumConcurrency: Int
    private var isInBackground = false
    private var isPlaybackPlaying = false
    private var activeIDs: [UUID] = []
    private var waiters: [Waiter] = []
    private var checkpointWaiters: [Waiter] = []

    public init(maximumConcurrency: MediaConversionConcurrency = .default) {
        self.maximumConcurrency = maximumConcurrency.rawValue
    }

    public func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) {
        maximumConcurrency = maximum.rawValue
        resumeCheckpointsIfPossible()
        resumeWaitersIfPossible()
    }

    public func updateApplicationInBackground(_ isInBackground: Bool) async {
        self.isInBackground = isInBackground
        resumeCheckpointsIfPossible()
        resumeWaitersIfPossible()
    }

    public func updatePlaybackIsPlaying(_ isPlaying: Bool) async {
        isPlaybackPlaying = isPlaying
        resumeCheckpointsIfPossible()
        resumeWaitersIfPossible()
    }

    private var effectiveMaximumConcurrency: Int {
        guard isPlaybackPlaying else { return 0 }
        return isInBackground ? 1 : maximumConcurrency
    }

    public func schedule(
        _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
    ) async throws -> MediaTranscodeResult {
        let operationID = UUID()
        guard await acquire(operationID) else { throw CancellationError() }
        defer { release(operationID) }
        return try await MediaConversionExecution.$checkpoint.withValue({
            try await self.waitUntilRunnable(operationID)
        }) {
            try await MediaConversionExecution.waitUntilRunnable()
            return try await operation()
        }
    }

    private func acquire(_ operationID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeIDs.count < effectiveMaximumConcurrency {
            activeIDs.append(operationID)
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: operationID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(operationID) }
        }
    }

    private func release(_ operationID: UUID) {
        activeIDs.removeAll { $0 == operationID }
        resumeCheckpointsIfPossible()
        resumeWaitersIfPossible()
    }

    private func resumeWaitersIfPossible() {
        while activeIDs.count < effectiveMaximumConcurrency, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            activeIDs.append(waiter.id)
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(returning: false)
        }
        if let index = checkpointWaiters.firstIndex(where: { $0.id == id }) {
            checkpointWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }

    private func canRun(_ operationID: UUID) -> Bool {
        activeIDs.prefix(effectiveMaximumConcurrency).contains(operationID)
    }

    private func waitUntilRunnable(_ operationID: UUID) async throws {
        while true {
            try Task.checkCancellation()
            if canRun(operationID) { return }
            let resumed = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        checkpointWaiters.append(Waiter(
                            id: operationID,
                            continuation: continuation
                        ))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(operationID) }
            }
            guard resumed else { throw CancellationError() }
        }
    }

    private func resumeCheckpointsIfPossible() {
        let ready = checkpointWaiters.filter { canRun($0.id) }
        checkpointWaiters.removeAll { canRun($0.id) }
        for waiter in ready {
            waiter.continuation.resume(returning: true)
        }
    }
}
