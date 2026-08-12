import Foundation
import MediaSourceAPI

internal actor ImportCoordinator: ImportServing {
    private let importer: (any MediaImporting)?
    private var sessions: [UUID: ImportSessionSnapshot] = [:]
    private var sessionTokens: [UUID: UUID] = [:]
    private var stateContinuations: [UUID: AsyncStream<ImportSessionSnapshot>.Continuation] = [:]

    init(importer: (any MediaImporting)?) {
        self.importer = importer
    }

    func start(_ request: MediaImportRequest)
        async throws -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        guard !request.urls.isEmpty else {
            throw AppServiceError.invalidRequest(operation: "import")
        }
        guard let importer else {
            throw AppServiceError.missingDependency("mediaImporter")
        }

        if let existing = sessions[request.importID] {
            if existing.isActive {
                throw AppServiceError.operationInProgress(operation: "import")
            }
            if let result = existing.result {
                return Self.replay(result: result)
            }
        }

        let sessionToken = UUID()
        sessionTokens[request.importID] = sessionToken
        sessions[request.importID] = ImportSessionSnapshot(importID: request.importID)
        publish(sessions[request.importID]!)

        let upstream = importer.importMedia(request)
        return AsyncThrowingStream { [weak self] continuation in
            let task = Task { [weak self] in
                await self?.consume(
                    importID: request.importID,
                    sessionToken: sessionToken,
                    upstream: upstream,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                Task {
                    await self?.consumerTerminated(
                        request.importID,
                        sessionToken: sessionToken
                    )
                }
            }
        }
    }

    func cancel(_ importID: UUID) async {
        guard sessions[importID]?.isActive == true else { return }
        await importer?.cancelImport(importID)
    }

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        sessions[importID]
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ImportSessionSnapshot>.makeStream()
        install(continuation, for: subscriptionID)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscription(subscriptionID)
            }
        }
        return stream
    }

    private func consume(
        importID: UUID,
        sessionToken: UUID,
        upstream: AsyncThrowingStream<MediaImportEvent, Error>,
        continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
    ) async {
        do {
            for try await event in upstream {
                guard isActive(importID: importID, sessionToken: sessionToken) else { break }
                update(with: event, sessionToken: sessionToken)
                continuation.yield(event)
                if event.isTerminal {
                    continuation.finish()
                    return
                }
            }

            guard isActive(importID: importID, sessionToken: sessionToken) else {
                continuation.finish()
                return
            }
            markFinishedWithoutResult(importID: importID, sessionToken: sessionToken)
            continuation.finish(
                throwing: AppServiceError.unknown(operation: "import")
            )
        } catch {
            if isActive(importID: importID, sessionToken: sessionToken) {
                markInactive(importID: importID, sessionToken: sessionToken)
                let mapped = AppServiceError.mapped(error, operation: "import")
                continuation.finish(throwing: mapped)
            } else {
                continuation.finish()
            }
        }
    }

    private func update(with event: MediaImportEvent, sessionToken: UUID) {
        guard sessionTokens[event.importID] == sessionToken else { return }
        guard var session = sessions[event.importID] else { return }
        var processedCount = session.processedCount
        var lastItemID = session.lastItemID
        var result = session.result
        var isActive = session.isActive

        switch event {
        case .persisting(_, let itemID):
            processedCount += 1
            lastItemID = itemID
        case .itemFailed:
            processedCount += 1
        case .completed(_, let value), .cancelled(_, let value):
            result = value
            isActive = false
        case .discovered, .hashing, .probing, .copying:
            break
        }

        session = ImportSessionSnapshot(
            importID: session.importID,
            processedCount: processedCount,
            lastItemID: lastItemID,
            result: result,
            isActive: isActive
        )
        sessions[event.importID] = session
        publish(session)
    }

    private func markFinishedWithoutResult(importID: UUID, sessionToken: UUID) {
        guard sessionTokens[importID] == sessionToken else { return }
        guard let session = sessions[importID] else { return }
        let updated = ImportSessionSnapshot(
            importID: session.importID,
            processedCount: session.processedCount,
            lastItemID: session.lastItemID,
            result: nil,
            isActive: false
        )
        sessions[importID] = updated
        publish(updated)
    }

    private func markInactive(importID: UUID, sessionToken: UUID) {
        guard sessionTokens[importID] == sessionToken else { return }
        guard let session = sessions[importID] else { return }
        let updated = ImportSessionSnapshot(
            importID: session.importID,
            processedCount: session.processedCount,
            lastItemID: session.lastItemID,
            result: nil,
            isActive: false
        )
        sessions[importID] = updated
        publish(updated)
    }

    private func consumerTerminated(_ importID: UUID, sessionToken: UUID) async {
        guard isActive(importID: importID, sessionToken: sessionToken) else { return }

        // The stream consumer can disappear before the upstream importer emits
        // its terminal event. Close the application session immediately so a
        // later request with the same ID is not rejected forever. The upstream
        // cancellation remains best-effort and may still emit a late event.
        markInactive(importID: importID, sessionToken: sessionToken)
        await importer?.cancelImport(importID)
    }

    private func isActive(importID: UUID, sessionToken: UUID) -> Bool {
        sessionTokens[importID] == sessionToken && sessions[importID]?.isActive == true
    }

    private func install(
        _ continuation: AsyncStream<ImportSessionSnapshot>.Continuation,
        for id: UUID
    ) {
        stateContinuations[id] = continuation
    }

    private func removeSubscription(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func publish(_ snapshot: ImportSessionSnapshot) {
        for continuation in stateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private static func replay(result: MediaImportResult)
        -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        AsyncThrowingStream { continuation in
            if result.status == .cancelled {
                continuation.yield(.cancelled(importID: result.importID, result: result))
            } else {
                continuation.yield(.completed(importID: result.importID, result: result))
            }
            continuation.finish()
        }
    }
}
