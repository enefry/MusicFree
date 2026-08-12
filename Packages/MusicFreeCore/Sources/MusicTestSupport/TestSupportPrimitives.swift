import Foundation

/// Namespace marker for test-only fakes and deterministic dependencies.
public enum MusicTestSupportModule {}

/// Failures used when a fake has deliberately not been configured for an
/// operation. Keeping this error in the support target makes missing scripts
/// visible without coupling production code to a test framework.
public enum TestSupportError: Error, Equatable, Sendable, CustomStringConvertible {
    case unconfigured(operation: String)
    case duplicateActiveSubscription
    case operationFailed(operation: String)
    case invalidScript
    case cancelled

    public var description: String {
        switch self {
        case .unconfigured(let operation):
            return "TestSupportError.unconfigured(\(operation))"
        case .duplicateActiveSubscription:
            return "TestSupportError.duplicateActiveSubscription"
        case .operationFailed(let operation):
            return "TestSupportError.operationFailed(\(operation))"
        case .invalidScript:
            return "TestSupportError.invalidScript"
        case .cancelled:
            return "TestSupportError.cancelled"
        }
    }
}

/// Collects values from an asynchronous stream without XCTest or Swift
/// Testing dependencies. The actor also makes snapshots safe to inspect from
/// concurrent test tasks.
public actor AsyncStreamRecorder<Element: Sendable> {
    public private(set) var values: [Element] = []
    public private(set) var isFinished = false
    public private(set) var failureDescription: String?
    private var countWaiters: [CountWaiter] = []

    private struct CountWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    public init() {}

    public func append(_ value: Element) {
        guard !isFinished else { return }
        values.append(value)
        resumeReadyCountWaiters()
    }

    public func finish() {
        isFinished = true
        resumeAllCountWaiters()
    }

    public func fail(with error: Error) {
        failureDescription = String(describing: error)
        isFinished = true
        resumeAllCountWaiters()
    }

    public func snapshot() -> [Element] {
        values
    }

    /// Suspends until the recorder has consumed at least `minimumCount`
    /// values, or the stream has finished. This keeps tests deterministic
    /// without coupling them to task scheduling.
    public func waitForCount(_ minimumCount: Int) async {
        guard minimumCount > values.count, !isFinished else { return }

        await withCheckedContinuation { continuation in
            if minimumCount <= values.count || isFinished {
                continuation.resume()
            } else {
                countWaiters.append(
                    CountWaiter(
                        minimumCount: minimumCount,
                        continuation: continuation
                    )
                )
            }
        }
    }

    public func record(_ stream: AsyncStream<Element>) async -> [Element] {
        for await value in stream {
            append(value)
        }
        finish()
        return values
    }

    public func record(_ stream: AsyncThrowingStream<Element, Error>) async -> [Element] {
        do {
            for try await value in stream {
                append(value)
            }
        } catch {
            fail(with: error)
        }
        finish()
        return values
    }

    private func resumeReadyCountWaiters() {
        let ready = countWaiters.filter { $0.minimumCount <= values.count }
        countWaiters.removeAll { $0.minimumCount <= values.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeAllCountWaiters() {
        let pending = countWaiters
        countWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
    }
}

/// A lock-backed hot stream hub for non-actor protocol methods such as
/// `changes()`. It broadcasts only after a caller has subscribed and removes
/// continuations through the stream termination hook.
final class TestAsyncStreamHub<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var isFinished = false

    func makeStream() -> AsyncStream<Element> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            let shouldFinish = self.withLock {
                if isFinished {
                    return true
                }
                continuations[subscriptionID] = continuation
                return false
            }
            if shouldFinish {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.remove(subscriptionID)
            }
        }
    }

    func yield(_ value: Element) {
        let active = withLock { Array(continuations.values) }
        for continuation in active {
            continuation.yield(value)
        }
    }

    func finish() {
        let active = withLock { () -> [AsyncStream<Element>.Continuation] in
            let result = Array(continuations.values)
            continuations.removeAll()
            isFinished = true
            return result
        }
        for continuation in active {
            continuation.finish()
        }
    }

    func activeSubscriptionCount() -> Int {
        withLock { continuations.count }
    }

    private func remove(_ subscriptionID: UUID) {
        _ = withLock { continuations.removeValue(forKey: subscriptionID) }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
