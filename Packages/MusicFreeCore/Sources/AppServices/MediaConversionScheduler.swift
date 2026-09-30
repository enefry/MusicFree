import Foundation
import MediaSourceAPI

/// FIFO worker gate used by every audio conversion source in the application.
public actor MediaConversionScheduler: MediaConversionScheduling {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var maximumConcurrency: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    public init(maximumConcurrency: MediaConversionConcurrency = .default) {
        self.maximumConcurrency = maximumConcurrency.rawValue
    }

    public func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) {
        maximumConcurrency = maximum.rawValue
        resumeWaitersIfPossible()
    }

    public func schedule(
        _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
    ) async throws -> MediaTranscodeResult {
        guard await acquire() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeCount < maximumConcurrency {
            activeCount += 1
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func release() {
        precondition(activeCount > 0)
        activeCount -= 1
        resumeWaitersIfPossible()
    }

    private func resumeWaitersIfPossible() {
        while activeCount < maximumConcurrency, !waiters.isEmpty {
            activeCount += 1
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
