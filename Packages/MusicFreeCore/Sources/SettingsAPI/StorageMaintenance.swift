import Foundation

/// Read-only storage accounting exposed to SettingsFeature.
@available(macOS 13.0, iOS 16.0, *)
public struct StorageUsageSnapshot: Codable, Equatable, Hashable, Sendable {
    public let managedMediaBytes: Int64
    public let cacheBytes: Int64
    public let quarantineBytes: Int64
    public let pendingRemovalCount: Int
    public let availableBytes: Int64?

    public init(
        managedMediaBytes: Int64 = 0,
        cacheBytes: Int64 = 0,
        quarantineBytes: Int64 = 0,
        pendingRemovalCount: Int = 0,
        availableBytes: Int64? = nil
    ) {
        precondition(managedMediaBytes >= 0)
        precondition(cacheBytes >= 0)
        precondition(quarantineBytes >= 0)
        precondition(pendingRemovalCount >= 0)
        if let availableBytes { precondition(availableBytes >= 0) }
        self.managedMediaBytes = managedMediaBytes
        self.cacheBytes = cacheBytes
        self.quarantineBytes = quarantineBytes
        self.pendingRemovalCount = pendingRemovalCount
        self.availableBytes = availableBytes
    }

    public var totalBytes: Int64 {
        managedMediaBytes + cacheBytes + quarantineBytes
    }
}

/// Explicit, user-confirmed maintenance actions. No action is destructive to
/// managed media; removal transactions are repaired through AppServices.
public enum StorageMaintenanceAction: String, Codable, CaseIterable, Hashable, Sendable {
    case clearImportStaging
    case repairPendingRemovals
    case clearFinalizedQuarantine
}

@available(macOS 13.0, iOS 16.0, *)
public struct StorageMaintenanceResult: Codable, Equatable, Hashable, Sendable {
    public let usageBefore: StorageUsageSnapshot
    public let usageAfter: StorageUsageSnapshot
    public let freedBytes: Int64
    public let repairedPendingRemovalCount: Int

    public init(
        usageBefore: StorageUsageSnapshot,
        usageAfter: StorageUsageSnapshot,
        freedBytes: Int64 = 0,
        repairedPendingRemovalCount: Int = 0
    ) {
        precondition(freedBytes >= 0)
        precondition(repairedPendingRemovalCount >= 0)
        self.usageBefore = usageBefore
        self.usageAfter = usageAfter
        self.freedBytes = freedBytes
        self.repairedPendingRemovalCount = repairedPendingRemovalCount
    }
}

public enum StorageMaintenanceError: Error, Equatable, Hashable, Sendable, LocalizedError {
    case unavailable
    case failed

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "存储维护服务不可用。"
        case .failed: return "存储维护未完成。"
        }
    }
}

/// Storage accounting and maintenance boundary. SettingsFeature never
/// accesses a URL, FileManager, SwiftData, or a removal transaction directly.
@available(macOS 13.0, iOS 16.0, *)
public protocol StorageMaintenanceServing: Sendable {
    func usage() async throws -> StorageUsageSnapshot
    func perform(_ actions: Set<StorageMaintenanceAction>) async throws -> StorageMaintenanceResult
    func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult
}

public extension StorageMaintenanceServing {
    /// Optional automatic-maintenance capability. Adapters without a cache
    /// return a no-op result while preserving the existing maintenance port.
    func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult {
        let snapshot = try await usage()
        return StorageMaintenanceResult(usageBefore: snapshot, usageAfter: snapshot)
    }
}
