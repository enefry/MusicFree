import SettingsAPI

/// Combines file-system maintenance with the library-aware pending-removal
/// recovery saga. The adapter never receives SwiftData or AppServices types.
@available(macOS 13.0, iOS 16.0, *)
internal actor StorageMaintenanceCoordinator: StorageMaintenanceServing {
    private let adapter: (any StorageMaintenanceServing)?
    private let library: LibraryCoordinator

    init(
        adapter: (any StorageMaintenanceServing)?,
        library: LibraryCoordinator
    ) {
        self.adapter = adapter
        self.library = library
    }

    func usage() async throws -> StorageUsageSnapshot {
        guard let adapter else { throw StorageMaintenanceError.unavailable }
        return try await adapter.usage()
    }

    func perform(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        guard let adapter else { throw StorageMaintenanceError.unavailable }
        let before = try await adapter.usage()
        let fileActions = actions.subtracting([.repairPendingRemovals])
        if !fileActions.isEmpty {
            _ = try await adapter.perform(fileActions)
        }
        var repairedCount = 0
        if actions.contains(.repairPendingRemovals) {
            let recovery = try await library.recoverPendingRemovals()
            repairedCount = recovery.rolledBackTransactionIDs.count
                + recovery.finalizedTransactionIDs.count
        }
        let after = try await adapter.usage()
        return StorageMaintenanceResult(
            usageBefore: before,
            usageAfter: after,
            freedBytes: max(0, before.totalBytes - after.totalBytes),
            repairedPendingRemovalCount: repairedCount
        )
    }

    func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult {
        guard let adapter else { throw StorageMaintenanceError.unavailable }
        return try await adapter.pruneCache(
            to: limit,
            retainingStagingFor: retention
        )
    }

    func enforceAutomaticPruning(_ preferences: StoragePreferences) async throws {
        guard preferences.automaticallyPruneCache, let adapter else { return }
        _ = try await adapter.pruneCache(
            to: preferences.cacheLimit,
            retainingStagingFor: preferences.stagingRetention
        )
    }
}
