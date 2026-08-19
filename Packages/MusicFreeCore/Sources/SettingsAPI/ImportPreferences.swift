import Foundation
import MusicDomain

/// The action taken when an imported item matches an existing library item.
public enum DuplicateImportPolicy: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case skipExisting
    case replaceExisting
    case keepBoth
}

/// User intent for importing media into the library.
public struct ImportPreferences: Codable, Equatable, Hashable, Sendable {
    public let duplicatePolicy: DuplicateImportPolicy
    public let metadataProviders: [MetadataProviderPreference]

    public static let defaultMetadataProviders: [MetadataProviderPreference] = [
        MetadataProviderPreference(provider: .musicKit),
        MetadataProviderPreference(provider: .metadataServer),
        MetadataProviderPreference(provider: .discogs)
    ]

    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        metadataProviders: [MetadataProviderPreference] = Self.defaultMetadataProviders
    ) {
        self.duplicatePolicy = duplicatePolicy
        self.metadataProviders = Self.normalizedProviders(metadataProviders)
    }

    /// Compatibility initializer for callers written against the original
    /// MusicKit-only settings surface.
    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        useMusicKitMetadataEnrichment: Bool
    ) {
        self.init(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: [
                MetadataProviderPreference(
                    provider: .musicKit,
                    isEnabled: useMusicKitMetadataEnrichment
                ),
                MetadataProviderPreference(provider: .metadataServer),
                MetadataProviderPreference(provider: .discogs)
            ]
        )
    }

    public static let defaults = Self()

    /// Compatibility view for the previous single-provider API.
    public var useMusicKitMetadataEnrichment: Bool {
        metadataProviders.first {
            $0.provider == .musicKit
        }?.isEnabled ?? false
    }

    public func isMetadataProviderEnabled(_ provider: MetadataProviderID) -> Bool {
        metadataProviders.first { $0.provider == provider }?.isEnabled ?? false
    }

    public func settingMetadataProvider(
        _ provider: MetadataProviderID,
        enabled: Bool
    ) -> Self {
        var providers = metadataProviders
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            providers[index] = providers[index].settingEnabled(enabled)
        } else {
            providers.append(MetadataProviderPreference(provider: provider, isEnabled: enabled))
        }
        return Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: providers
        )
    }

    public func settingMetadataProviders(
        _ providers: [MetadataProviderPreference]
    ) -> Self {
        Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: providers
        )
    }

    private enum CodingKeys: String, CodingKey {
        case duplicatePolicy
        case metadataProviders
        case useMusicKitMetadataEnrichment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duplicatePolicy = try container.decodeIfPresent(
            DuplicateImportPolicy.self,
            forKey: .duplicatePolicy
        ) ?? .skipExisting
        if let providers = try container.decodeIfPresent(
            [MetadataProviderPreference].self,
            forKey: .metadataProviders
        ) {
            self.init(
                duplicatePolicy: duplicatePolicy,
                metadataProviders: Self.providersAfterMigration(providers)
            )
        } else {
            self.init(
                duplicatePolicy: duplicatePolicy,
                useMusicKitMetadataEnrichment: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .useMusicKitMetadataEnrichment
                ) ?? false
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(duplicatePolicy, forKey: .duplicatePolicy)
        try container.encode(metadataProviders, forKey: .metadataProviders)
        // Keep emitting the legacy value so an older app can still read the
        // MusicKit preference while newer apps use the ordered provider list.
        try container.encode(
            useMusicKitMetadataEnrichment,
            forKey: .useMusicKitMetadataEnrichment
        )
    }

    public func settingMusicKitMetadataEnrichment(_ enabled: Bool) -> Self {
        settingMetadataProvider(.musicKit, enabled: enabled)
    }

    private static func normalizedProviders(
        _ providers: [MetadataProviderPreference]
    ) -> [MetadataProviderPreference] {
        var seen = Set<MetadataProviderID>()
        let normalized = providers.filter { seen.insert($0.provider).inserted }
        return normalized.isEmpty ? defaultMetadataProviders : normalized
    }

    /// Adds providers introduced after the ordered-provider setting was first
    /// persisted without changing any existing order or enablement.
    private static func providersAfterMigration(
        _ providers: [MetadataProviderPreference]
    ) -> [MetadataProviderPreference] {
        var migrated = normalizedProviders(providers)
        guard !migrated.contains(where: { $0.provider == .discogs }) else {
            return migrated
        }
        migrated.append(MetadataProviderPreference(provider: .discogs))
        return migrated
    }
}
