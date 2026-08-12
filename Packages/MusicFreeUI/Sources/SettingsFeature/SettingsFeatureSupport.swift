import AppServices
import Foundation
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

/// Compatibility marker retained after the initial empty module shell.
public enum SettingsFeatureModule {}

struct SettingsFeatureFailure: Equatable, Sendable, LocalizedError {
    let diagnosticCode: String
    let message: String
    let isRetryable: Bool

    var errorDescription: String? {
        message
    }
}

enum SettingsFeatureLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(SettingsFeatureFailure)

    var failure: SettingsFeatureFailure? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }
}

enum SettingsFeatureMutationState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case cancelled
    case failed(SettingsFeatureFailure)

    var failure: SettingsFeatureFailure? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }

    var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }
}

enum SettingsMaintenanceState: Equatable, Sendable {
    case idle
    case loading
    case completed(StorageMaintenanceResult)
    case failed(String)

    var isRunning: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// The feature-facing store. It keeps SettingsFeature independent from a
/// repository while allowing deterministic main-actor fakes in tests.
@MainActor
protocol SettingsFeatureStore: AnyObject {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
    func reset() async throws
    func effective() async throws -> EffectivePlaybackSettings
    func makeChangeStream() async -> AsyncStream<AppSettings>
    func storageUsage() async throws -> StorageUsageSnapshot
    func performStorageMaintenance(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult
}

extension SettingsFeatureStore {
    func effective() async throws -> EffectivePlaybackSettings {
        let settings = try await load()
        return EffectivePlaybackSettings(
            settings: settings,
            effects: .neutral,
            playbackCapabilities: [],
            systemCapabilities: SystemIntegrationCapabilitySnapshot()
        )
    }

    func makeChangeStream() async -> AsyncStream<AppSettings> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func storageUsage() async throws -> StorageUsageSnapshot {
        throw StorageMaintenanceError.unavailable
    }

    func performStorageMaintenance(
        _: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        throw StorageMaintenanceError.unavailable
    }
}

@MainActor
final class AppServicesSettingsStore: SettingsFeatureStore {
    private let serving: any SettingsServing
    private let storageMaintenance: (any StorageMaintenanceServing)?

    init(
        serving: any SettingsServing,
        storageMaintenance: (any StorageMaintenanceServing)? = nil
    ) {
        self.serving = serving
        self.storageMaintenance = storageMaintenance
    }

    func load() async throws -> AppSettings {
        try await serving.load()
    }

    func save(_ settings: AppSettings) async throws {
        try await serving.update(settings)
    }

    func reset() async throws {
        try await serving.reset()
    }

    func effective() async throws -> EffectivePlaybackSettings {
        try await serving.effective()
    }

    func makeChangeStream() async -> AsyncStream<AppSettings> {
        await serving.makeChangeStream()
    }

    func storageUsage() async throws -> StorageUsageSnapshot {
        guard let storageMaintenance else { throw StorageMaintenanceError.unavailable }
        return try await storageMaintenance.usage()
    }

    func performStorageMaintenance(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        guard let storageMaintenance else { throw StorageMaintenanceError.unavailable }
        return try await storageMaintenance.perform(actions)
    }
}

/// The no-argument scene initializer remains useful for previews and package
/// graph checks, but it must expose an explicit configuration failure.
@MainActor
final class UnconfiguredSettingsStore: SettingsFeatureStore {
    func load() async throws -> AppSettings {
        throw AppServiceError.missingDependency("settingsRepository")
    }

    func save(_ settings: AppSettings) async throws {
        throw AppServiceError.missingDependency("settingsRepository")
    }

    func reset() async throws {
        throw AppServiceError.missingDependency("settingsRepository")
    }

    func effective() async throws -> EffectivePlaybackSettings {
        throw AppServiceError.missingDependency("settingsRepository")
    }
}

/// Release metadata supplied by the composition root from a read-only
/// manifest. Empty values are omitted by the UI rather than shown as claims.
public struct SettingsReleaseInfo: Equatable, Sendable {
    public let appVersion: String?
    public let buildNumber: String?
    public let dependencies: [SettingsDependencyLicense]

    public init(
        appVersion: String? = nil,
        buildNumber: String? = nil,
        dependencies: [SettingsDependencyLicense] = []
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.dependencies = dependencies
    }
}

public enum SettingsDependencyKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case source
    case binary
    case other
}

public struct SettingsDependencyLicense: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let license: String?
    public let kind: SettingsDependencyKind
    public let sourceURL: URL?
    public let buildMaterialsURL: URL?
    public let licenseURL: URL?
    /// The relative path recorded in the release manifest for the bundled
    /// license text. It is display metadata only; the Feature never reads the
    /// filesystem directly.
    public let licenseFile: String?
    /// Complete license text loaded from the read-only App bundle, when the
    /// release contains the referenced file.
    public let licenseText: String?
    /// Source revision or binary checksum recorded for reproducible releases.
    public let revision: String?
    public let checksum: String?

    public init(
        id: String,
        name: String,
        version: String? = nil,
        license: String? = nil,
        kind: SettingsDependencyKind = .other,
        sourceURL: URL? = nil,
        buildMaterialsURL: URL? = nil,
        licenseURL: URL? = nil,
        licenseFile: String? = nil,
        licenseText: String? = nil,
        revision: String? = nil,
        checksum: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.kind = kind
        self.sourceURL = sourceURL
        self.buildMaterialsURL = buildMaterialsURL
        self.licenseURL = licenseURL
        self.licenseFile = licenseFile
        self.licenseText = licenseText
        self.revision = revision
        self.checksum = checksum
    }
}

public protocol SettingsReleaseInfoProviding: Sendable {
    func releaseInfo() async -> SettingsReleaseInfo?
}

public struct EmptySettingsReleaseInfoProvider: SettingsReleaseInfoProviding {
    public init() {}

    public func releaseInfo() async -> SettingsReleaseInfo? {
        nil
    }
}

public struct SettingsDiagnosticEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let message: String
    public let timestamp: Date?

    public init(
        id: String? = nil,
        code: String,
        message: String,
        timestamp: Date? = nil
    ) {
        self.id = id ?? code
        self.code = code
        self.message = message
        self.timestamp = timestamp
    }
}

public struct SettingsDiagnosticsSnapshot: Equatable, Sendable {
    public let entries: [SettingsDiagnosticEntry]

    public init(entries: [SettingsDiagnosticEntry] = []) {
        self.entries = entries
    }
}

public protocol SettingsDiagnosticsProviding: Sendable {
    func diagnostics() async -> SettingsDiagnosticsSnapshot
}

public struct EmptySettingsDiagnosticsProvider: SettingsDiagnosticsProviding {
    public init() {}

    public func diagnostics() async -> SettingsDiagnosticsSnapshot {
        SettingsDiagnosticsSnapshot()
    }
}
