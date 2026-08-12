import Foundation
import MediaSourceAPI
import MusicDomain

public enum FakeRemovalOperation: Hashable, Sendable {
    case pending
    case prepare
    case commit
    case rollback
}

/// Failure and delay knobs for the recoverable removal state machine.
public struct FakeRemovalScript: Sendable {
    public var pendingError: MediaRemovalError?
    public var prepareError: MediaRemovalError?
    public var commitError: MediaRemovalError?
    public var rollbackError: MediaRemovalError?
    public var delay: Duration

    public init(
        pendingError: MediaRemovalError? = nil,
        prepareError: MediaRemovalError? = nil,
        commitError: MediaRemovalError? = nil,
        rollbackError: MediaRemovalError? = nil,
        delay: Duration = .zero
    ) {
        self.pendingError = pendingError
        self.prepareError = prepareError
        self.commitError = commitError
        self.rollbackError = rollbackError
        self.delay = delay
    }
}

/// A deterministic prepare/commit/rollback fake with persistent in-memory
/// transaction state and observable calls.
public final class FakeManagedMediaRemover: ManagedMediaRemoving, @unchecked Sendable {
    private enum State {
        case pending
        case committed
        case rolledBack
    }

    private let lock = NSLock()
    private var transactions: [UUID: (transaction: MediaRemovalTransaction, state: State)] = [:]
    private var order: [UUID] = []
    private var nextTransactionIndex = 0
    private var script: FakeRemovalScript
    private var pendingCalls = 0
    private var prepareCallLog: [Set<MediaItemID>] = []
    private var commitCallLog: [MediaRemovalTransaction] = []
    private var rollbackCallLog: [MediaRemovalTransaction] = []

    public init(
        pending: [MediaRemovalTransaction] = [],
        script: FakeRemovalScript = .init()
    ) {
        self.script = script
        for transaction in pending {
            transactions[transaction.transactionID] = (transaction, .pending)
            order.append(transaction.transactionID)
        }
    }

    public func pendingRemovals() async throws -> [MediaRemovalTransaction] {
        let state = withLock { () -> (FakeRemovalScript, [MediaRemovalTransaction]) in
            pendingCalls += 1
            let values = order.compactMap { id -> MediaRemovalTransaction? in
                guard let value = transactions[id], value.state == .pending else { return nil }
                return value.transaction
            }
            return (script, values)
        }
        try await wait(state.0.delay)
        if let error = state.0.pendingError {
            throw MediaSourceError.removalFailed(error)
        }
        return state.1
    }

    public func prepareRemoval(of itemIDs: Set<MediaItemID>) async throws
        -> MediaRemovalTransaction
    {
        let current = withLock { () -> FakeRemovalScript in
            prepareCallLog.append(itemIDs)
            return script
        }
        try await wait(current.delay)
        try Task.checkCancellation()
        if let error = current.prepareError {
            throw MediaSourceError.removalFailed(error)
        }
        guard !itemIDs.isEmpty else {
            throw MediaSourceError.removalFailed(.invalidState)
        }

        let transaction: MediaRemovalTransaction = withLock {
            let id = deterministicTransactionID(nextTransactionIndex)
            nextTransactionIndex += 1
            let value = MediaRemovalTransaction(transactionID: id, itemIDs: itemIDs)
            transactions[id] = (value, .pending)
            order.append(id)
            return value
        }
        return transaction
    }

    public func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {
        let current = withLock { () -> FakeRemovalScript in
            commitCallLog.append(transaction)
            return script
        }
        try await wait(current.delay)
        try Task.checkCancellation()
        if let error = current.commitError {
            throw MediaSourceError.removalFailed(error)
        }

        try transition(of: transaction, operation: .commit)
    }

    public func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {
        let current = withLock { () -> FakeRemovalScript in
            rollbackCallLog.append(transaction)
            return script
        }
        try await wait(current.delay)
        try Task.checkCancellation()
        if let error = current.rollbackError {
            throw MediaSourceError.removalFailed(error)
        }

        try transition(of: transaction, operation: .rollback)
    }

    public func setScript(_ script: FakeRemovalScript) {
        withLock { self.script = script }
    }

    public var pendingCallCount: Int {
        withLock { pendingCalls }
    }

    public var prepareCalls: [Set<MediaItemID>] {
        withLock { prepareCallLog }
    }

    public var commitCalls: [MediaRemovalTransaction] {
        withLock { commitCallLog }
    }

    public var rollbackCalls: [MediaRemovalTransaction] {
        withLock { rollbackCallLog }
    }

    public func resetCallHistory() {
        withLock {
            pendingCalls = 0
            prepareCallLog.removeAll()
            commitCallLog.removeAll()
            rollbackCallLog.removeAll()
        }
    }

    private func transition(
        of transaction: MediaRemovalTransaction,
        operation: FakeRemovalOperation
    ) throws {
        let error: MediaRemovalError? = withLock {
            guard let existing = transactions[transaction.transactionID],
                  existing.transaction == transaction
            else {
                return .unknownTransaction
            }
            switch operation {
            case .commit:
                switch existing.state {
                case .committed:
                    return .alreadyCommitted
                case .rolledBack:
                    return .alreadyRolledBack
                case .pending:
                    transactions[transaction.transactionID] = (existing.transaction, .committed)
                    return nil
                }
            case .rollback:
                switch existing.state {
                case .rolledBack:
                    return .alreadyRolledBack
                case .committed:
                    return .alreadyCommitted
                case .pending:
                    transactions[transaction.transactionID] = (existing.transaction, .rolledBack)
                    return nil
                }
            case .pending, .prepare:
                return nil
            }
        }
        if let error {
            throw MediaSourceError.removalFailed(error)
        }
    }

    private func wait(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw MediaSourceError.cancelled
        }
    }

    private func deterministicTransactionID(_ index: Int) -> UUID {
        FixtureFactory.stableUUID(index + 10_000)
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
