import Foundation
import SettingsAPI

/// File-system accounting and non-destructive cache cleanup for the local
/// media adapter. Pending removal records are repaired by AppServices because
/// that operation also needs the library transaction state.
@available(macOS 13.0, iOS 16.0, *)
public actor LocalMediaStorageMaintenance: StorageMaintenanceServing {
    private struct CacheEntry: Sendable {
        let url: URL
        let byteCount: Int64
        let modificationDate: Date
    }

    private let configuration: LocalMediaConfiguration
    private let coordinator: ImportCoordinator
    private let store: ManagedMediaStore
    private let fileManager = FileManager.default
    private let now: @Sendable () -> Date

    public init(configuration: LocalMediaConfiguration) throws {
        let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
        self.configuration = configuration
        self.coordinator = coordinator
        self.store = coordinator.store
        self.now = Date.init
    }

    init(
        configuration: LocalMediaConfiguration,
        now: @escaping @Sendable () -> Date
    ) throws {
        let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
        self.configuration = configuration
        self.coordinator = coordinator
        self.store = coordinator.store
        self.now = now
    }

    public func usage() async throws -> StorageUsageSnapshot {
        let pendingCount = try await store.pendingRemovalEntryCount()
        return StorageUsageSnapshot(
            managedMediaBytes: try byteCount(in: configuration.managedRoot),
            cacheBytes: try byteCount(in: configuration.stagingRoot),
            quarantineBytes: try byteCount(in: configuration.quarantineRoot),
            pendingRemovalCount: pendingCount,
            availableBytes: availableCapacity(at: configuration.managedRoot)
        )
    }

    public func perform(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        let coordinatesStaging = actions.contains(.clearImportStaging)
        if coordinatesStaging {
            await coordinator.maintenanceGate.enterMaintenance()
        }
        do {
            let before = try await usage()
            if coordinatesStaging {
                try clearChildren(of: configuration.stagingRoot)
            }
            if actions.contains(.clearFinalizedQuarantine) {
                try clearChildren(of: configuration.quarantineRoot, preserving: ["pending"])
            }
            let after = try await usage()
            let result = StorageMaintenanceResult(
                usageBefore: before,
                usageAfter: after,
                freedBytes: max(0, before.totalBytes - after.totalBytes)
            )
            if coordinatesStaging {
                await coordinator.maintenanceGate.leaveMaintenance()
            }
            return result
        } catch {
            if coordinatesStaging {
                await coordinator.maintenanceGate.leaveMaintenance()
            }
            throw error
        }
    }

    public func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult {
        await coordinator.maintenanceGate.enterMaintenance()
        do {
            let before = try await usage()
            try pruneStaging(
                to: limit.bytes,
                retainingFor: retention,
                referenceDate: now()
            )
            let after = try await usage()
            let result = StorageMaintenanceResult(
                usageBefore: before,
                usageAfter: after,
                freedBytes: max(0, before.totalBytes - after.totalBytes)
            )
            await coordinator.maintenanceGate.leaveMaintenance()
            return result
        } catch {
            await coordinator.maintenanceGate.leaveMaintenance()
            throw error
        }
    }

    private func byteCount(in root: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let rootValues = try root.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        if rootValues.isSymbolicLink == true { return 0 }
        if rootValues.isRegularFile == true {
            return Int64(max(0, rootValues.fileSize ?? 0))
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            throw StorageMaintenanceError.failed
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += Int64(max(0, values.fileSize ?? 0))
        }
        return total
    }

    private func clearChildren(of root: URL, preserving names: Set<String> = []) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )
        for entry in entries where !names.contains(entry.lastPathComponent) {
            let standardized = entry.resolvingSymlinksInPath().standardizedFileURL
            guard standardized.path == root.standardizedFileURL.path
                || standardized.path.hasPrefix(root.standardizedFileURL.path + "/")
            else { throw StorageMaintenanceError.failed }
            try fileManager.removeItem(at: entry)
        }
    }

    private func pruneStaging(
        to byteLimit: Int64,
        retainingFor retention: Duration,
        referenceDate: Date
    ) throws {
        try fileManager.createDirectory(
            at: configuration.stagingRoot,
            withIntermediateDirectories: true
        )
        var entries = try cacheEntries()
        var totalBytes = try byteCount(in: configuration.stagingRoot)
        let components = retention.components
        let retentionSeconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        let staleCutoff = referenceDate.addingTimeInterval(-retentionSeconds)

        entries.sort {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate < $1.modificationDate
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        let staleEntries = entries.filter { $0.modificationDate <= staleCutoff }
        for entry in staleEntries {
            try removeCacheEntry(entry)
            totalBytes = max(0, totalBytes - entry.byteCount)
        }

        guard totalBytes > byteLimit else { return }
        let staleURLs = Set(staleEntries.map(\.url))
        for entry in entries where !staleURLs.contains(entry.url) {
            try removeCacheEntry(entry)
            totalBytes = max(0, totalBytes - entry.byteCount)
            if totalBytes <= byteLimit { break }
        }
    }

    private func cacheEntries() throws -> [CacheEntry] {
        let urls = try fileManager.contentsOfDirectory(
            at: configuration.stagingRoot,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        return try urls.compactMap { url in
            guard url.lastPathComponent != ".keep" else { return nil }
            guard Self.isContained(url, in: configuration.stagingRoot) else {
                throw StorageMaintenanceError.failed
            }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .isSymbolicLinkKey,
            ])
            return CacheEntry(
                url: url,
                byteCount: values.isSymbolicLink == true ? 0 : try byteCount(in: url),
                modificationDate: values.contentModificationDate
                    ?? values.creationDate
                    ?? .distantFuture
            )
        }
    }

    private func removeCacheEntry(_ entry: CacheEntry) throws {
        guard Self.isContained(entry.url, in: configuration.stagingRoot) else {
            throw StorageMaintenanceError.failed
        }
        try fileManager.removeItem(at: entry.url)
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage.map { max(0, Int64($0)) }
    }
}
