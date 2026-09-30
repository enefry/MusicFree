import Foundation
import MediaSourceAPI

internal actor LibraryConversionCoordinator: LibraryConversionServing {
    private let converter: (any ManagedLibraryConverting)?

    init(converter: (any ManagedLibraryConverting)?) {
        self.converter = converter
    }

    func preflight(
        scope: LibraryConversionScope,
        target: AudioConversionTarget
    ) async throws -> LibraryConversionPreflight {
        guard let converter else {
            throw AppServiceError.missingDependency("managedLibraryConverter")
        }
        return try await converter.preflight(scope: scope, target: target)
    }

    func start(
        scope: LibraryConversionScope,
        target: AudioConversionTarget
    ) async throws -> UUID {
        guard let converter else {
            throw AppServiceError.missingDependency("managedLibraryConverter")
        }
        return try await converter.start(scope: scope, target: target)
    }

    func snapshots() async -> [LibraryConversionBatchSnapshot] {
        await converter?.snapshots() ?? []
    }

    func snapshot(id: UUID) async -> LibraryConversionBatchSnapshot? {
        await converter?.snapshot(id: id)
    }

    func pause(id: UUID) async {
        await converter?.pause(id: id)
    }

    func resume(id: UUID) async {
        await converter?.resume(id: id)
    }

    func cancel(id: UUID) async {
        await converter?.cancel(id: id)
    }

    func retryFailures(id: UUID) async throws -> UUID {
        guard let converter else {
            throw AppServiceError.missingDependency("managedLibraryConverter")
        }
        return try await converter.retryFailures(id: id)
    }

    func makeEventStream() async -> AsyncStream<LibraryConversionEvent> {
        guard let converter else {
            return AsyncStream { $0.finish() }
        }
        return await converter.makeEventStream()
    }

    func recover() async {
        await converter?.recover()
    }
}
