import Foundation

/// An actor-backed clock whose time advances only when the test asks it to.
/// Sleeping tasks are resumed when their deadline is reached and cancellation
/// removes their pending continuation.
public actor TestClock {
    private struct PendingSleep {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentDate: Date
    private var pendingSleeps: [UUID: PendingSleep] = [:]

    public init(startDate: Date = Date(timeIntervalSince1970: 0)) {
        currentDate = startDate
    }

    public func now() -> Date {
        currentDate
    }

    public func pendingSleepCount() -> Int {
        pendingSleeps.count
    }

    public func advance(by duration: Duration) {
        let seconds = duration.timeInterval
        precondition(seconds >= 0, "TestClock cannot move backwards")
        currentDate = currentDate.addingTimeInterval(seconds)
        resumeReadySleeps()
    }

    public func advance(to date: Date) {
        precondition(date >= currentDate, "TestClock cannot move backwards")
        currentDate = date
        resumeReadySleeps()
    }

    public func sleep(for duration: Duration) async throws {
        try await sleep(until: currentDate.addingTimeInterval(duration.timeInterval))
    }

    public func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline > currentDate else { return }

        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= currentDate {
                    continuation.resume()
                } else {
                    pendingSleeps[token] = PendingSleep(
                        deadline: deadline,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(token) }
        }
    }

    public func cancelAllSleeps() {
        let continuations = pendingSleeps.values.map(\.continuation)
        pendingSleeps.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelSleep(_ token: UUID) {
        guard let pending = pendingSleeps.removeValue(forKey: token) else { return }
        pending.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadySleeps() {
        let ready = pendingSleeps.filter { $0.value.deadline <= currentDate }
        for (token, pending) in ready {
            pendingSleeps.removeValue(forKey: token)
            pending.continuation.resume()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
