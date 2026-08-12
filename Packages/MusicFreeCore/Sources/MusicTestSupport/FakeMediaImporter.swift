import Foundation
import MediaSourceAPI
import MusicDomain

/// A complete scripted import response. Scripts may leave a stream open when
/// `autoFinish` is false so cancellation and consumer termination can be
/// tested explicitly.
public struct FakeImportScript: Sendable {
    public let events: [MediaImportEvent]
    public let streamError: TestSupportError?
    public let delay: Duration
    public let autoFinish: Bool

    public init(
        events: [MediaImportEvent],
        streamError: TestSupportError? = nil,
        delay: Duration = .zero,
        autoFinish: Bool = true
    ) {
        self.events = events
        self.streamError = streamError
        self.delay = delay
        self.autoFinish = autoFinish
    }

    public static func completed(
        _ result: MediaImportResult,
        progress: [MediaImportEvent] = [],
        delay: Duration = .zero
    ) -> Self {
        Self(
            events: progress + [.completed(importID: result.importID, result: result)],
            delay: delay
        )
    }
}

/// A cancellable, lock-backed importer fake with per-request scripts.
public final class FakeMediaImporter: MediaImporting, @unchecked Sendable {
    private struct ActiveImport {
        let continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
        var task: Task<Void, Never>?
        var isTerminal: Bool
    }

    private let lock = NSLock()
    private var scripts: [UUID: FakeImportScript] = [:]
    private var defaultScript: FakeImportScript?
    private var active: [UUID: ActiveImport] = [:]
    private var requestsLog: [MediaImportRequest] = []
    private var cancellationsLog: [UUID] = []
    private var terminationLog: [UUID] = []

    public init(
        script: FakeImportScript? = nil,
        scripts: [UUID: FakeImportScript] = [:]
    ) {
        defaultScript = script
        self.scripts = scripts
    }

    public func importMedia(_ request: MediaImportRequest)
        -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        let script = withLock { () -> FakeImportScript? in
            requestsLog.append(request)
            return scripts[request.importID] ?? defaultScript
        }
        let stream = AsyncThrowingStream<MediaImportEvent, Error> { continuation in
            let shouldFail = self.withLock { () -> Bool in
                guard script != nil else { return true }
                active[request.importID] = ActiveImport(
                    continuation: continuation,
                    task: nil,
                    isTerminal: false
                )
                return false
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.consumerTerminated(request.importID)
            }

            guard !shouldFail else {
                continuation.finish(
                    throwing: TestSupportError.unconfigured(operation: "importMedia")
                )
                return
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.emitScript(for: request.importID)
            }
            self.withLock {
                guard var current = active[request.importID], !current.isTerminal else {
                    task.cancel()
                    return
                }
                current.task = task
                active[request.importID] = current
            }
        }
        return stream
    }

    public func cancelImport(_ importID: UUID) async {
        let cancellation: (
            AsyncThrowingStream<MediaImportEvent, Error>.Continuation,
            Task<Void, Never>?
        )? = withLock {
            guard var current = active[importID], !current.isTerminal else { return nil }
            current.isTerminal = true
            active[importID] = current
            cancellationsLog.append(importID)
            return (current.continuation, current.task)
        }

        guard let cancellation else { return }
        cancellation.1?.cancel()
        let result = MediaImportResult(
            importID: importID,
            imported: 0,
            duplicate: 0,
            skipped: 0,
            failed: 0,
            cancelled: 1,
            status: .cancelled
        )
        cancellation.0.yield(.cancelled(importID: importID, result: result))
        cancellation.0.finish()
        removeActive(importID)
    }

    public func setDefaultScript(_ script: FakeImportScript?) {
        withLock { defaultScript = script }
    }

    public func setScript(_ script: FakeImportScript, for importID: UUID) {
        withLock { scripts[importID] = script }
    }

    public var requests: [MediaImportRequest] {
        withLock { requestsLog }
    }

    public var cancelledImportIDs: [UUID] {
        withLock { cancellationsLog }
    }

    public var terminatedImportIDs: [UUID] {
        withLock { terminationLog }
    }

    public var activeImportIDs: [UUID] {
        withLock { Array(active.keys) }
    }

    public func resetCallHistory() {
        withLock {
            requestsLog.removeAll()
            cancellationsLog.removeAll()
            terminationLog.removeAll()
        }
    }

    private func emitScript(for importID: UUID) async {
        guard let script = withLock({ scripts[importID] ?? defaultScript }) else { return }

        do {
            for event in script.events {
                try Task.checkCancellation()
                guard event.importID == importID else {
                    finish(importID: importID, error: TestSupportError.invalidScript)
                    return
                }
                if script.delay > .zero {
                    try await Task.sleep(for: script.delay)
                }
                guard let current = withLock({ active[importID] }), !current.isTerminal else {
                    return
                }
                current.continuation.yield(event)
                if event.isTerminal {
                    finish(importID: importID, error: nil)
                    return
                }
            }

            if script.autoFinish {
                let hasTerminal = script.events.last?.isTerminal == true
                finish(
                    importID: importID,
                    error: script.streamError ?? (hasTerminal ? nil : TestSupportError.invalidScript)
                )
            }
        } catch {
            if !isTerminal(importID) {
                finish(importID: importID, error: TestSupportError.cancelled)
            }
        }
    }

    private func finish(importID: UUID, error: Error?) {
        let current: ActiveImport? = withLock {
            guard var value = active[importID], !value.isTerminal else { return nil }
            value.isTerminal = true
            active[importID] = value
            return value
        }
        guard let current else { return }
        if let error {
            current.continuation.finish(throwing: error)
        } else {
            current.continuation.finish()
        }
        removeActive(importID)
    }

    private func consumerTerminated(_ importID: UUID) {
        let task = withLock { () -> Task<Void, Never>? in
            terminationLog.append(importID)
            let task = active[importID]?.task
            active.removeValue(forKey: importID)
            return task
        }
        task?.cancel()
    }

    private func removeActive(_ importID: UUID) {
        _ = withLock { active.removeValue(forKey: importID) }
    }

    private func isTerminal(_ importID: UUID) -> Bool {
        withLock { active[importID] == nil || active[importID]?.isTerminal == true }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
