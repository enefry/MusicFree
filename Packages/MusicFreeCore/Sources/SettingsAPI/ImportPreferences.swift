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
    public let lyricsProviders: [LyricsProviderPreference]
    public let privacyPreferences: PrivacyPreferences

    public static let defaultMetadataProviders: [MetadataProviderPreference] = [
        MetadataProviderPreference(provider: .musicKit),
        MetadataProviderPreference(provider: .musicBrainz),
        MetadataProviderPreference(provider: .metadataServer),
        MetadataProviderPreference(provider: .discogs)
    ]

    public static let defaultLyricsProviders: [LyricsProviderPreference] = [
        LyricsProviderPreference(provider: .metadataServer, isEnabled: false),
        LyricsProviderPreference(provider: .lrclib, isEnabled: false)
    ]

    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        metadataProviders: [MetadataProviderPreference] = Self.defaultMetadataProviders,
        lyricsProviders: [LyricsProviderPreference] = Self.defaultLyricsProviders,
        privacyPreferences: PrivacyPreferences = .defaults
    ) {
        self.duplicatePolicy = duplicatePolicy
        self.metadataProviders = Self.normalizedProviders(metadataProviders)
        self.lyricsProviders = Self.providersAfterMigration(lyricsProviders)
        self.privacyPreferences = privacyPreferences
    }

    /// Compatibility initializer for the temporary all-providers lyrics switch.
    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        metadataProviders: [MetadataProviderPreference] = Self.defaultMetadataProviders,
        lyricsProvidersEnabled: Bool,
        privacyPreferences: PrivacyPreferences = .defaults
    ) {
        self.init(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: metadataProviders,
            lyricsProviders: Self.defaultLyricsProviders.map {
                $0.settingEnabled(lyricsProvidersEnabled)
            },
            privacyPreferences: privacyPreferences
        )
    }

    /// Compatibility initializer for callers written against the original
    /// MusicKit-only settings surface.
    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        useMusicKitMetadataEnrichment: Bool,
        lyricsProvidersEnabled: Bool = false,
        privacyPreferences: PrivacyPreferences = .defaults
    ) {
        self.init(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: [
                MetadataProviderPreference(
                    provider: .musicKit,
                    isEnabled: useMusicKitMetadataEnrichment
                ),
                MetadataProviderPreference(provider: .musicBrainz),
                MetadataProviderPreference(provider: .metadataServer),
                MetadataProviderPreference(provider: .discogs)
            ],
            lyricsProvidersEnabled: lyricsProvidersEnabled,
            privacyPreferences: privacyPreferences
        )
    }

    public static let defaults = Self()

    /// Compatibility view for the previous single-provider API.
    public var useMusicKitMetadataEnrichment: Bool {
        metadataProviders.first {
            $0.provider == .musicKit
        }?.isEnabled ?? false
    }

    /// Compatibility view for the temporary all-providers lyrics switch.
    public var lyricsProvidersEnabled: Bool {
        lyricsProviders.contains(where: \.isEnabled)
    }

    /// Provider preferences after the application and provider disclosures
    /// have granted permission for online requests.
    public var runtimeMetadataProviders: [MetadataProviderPreference] {
        metadataProviders.map { preference in
            preference.settingEnabled(
                preference.isEnabled
                    && privacyPreferences.isProviderPolicyAccepted(
                        preference.provider.rawValue
                    )
            )
        }
    }

    public var runtimeLyricsProviders: [LyricsProviderPreference] {
        lyricsProviders.map { preference in
            preference.settingEnabled(
                preference.isEnabled
                    && privacyPreferences.isProviderPolicyAccepted(
                        preference.provider.rawValue
                    )
            )
        }
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
            metadataProviders: providers,
            lyricsProviders: lyricsProviders,
            privacyPreferences: privacyPreferences
        )
    }

    public func settingMetadataProviders(
        _ providers: [MetadataProviderPreference]
    ) -> Self {
        Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: providers,
            lyricsProviders: lyricsProviders,
            privacyPreferences: privacyPreferences
        )
    }

    public func isLyricsProviderEnabled(_ provider: LyricsProviderID) -> Bool {
        lyricsProviders.first { $0.provider == provider }?.isEnabled ?? false
    }

    public func settingLyricsProvider(
        _ provider: LyricsProviderID,
        enabled: Bool
    ) -> Self {
        var providers = lyricsProviders
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            providers[index] = providers[index].settingEnabled(enabled)
        } else {
            providers.append(LyricsProviderPreference(provider: provider, isEnabled: enabled))
        }
        return Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: metadataProviders,
            lyricsProviders: providers,
            privacyPreferences: privacyPreferences
        )
    }

    public func settingLyricsProviders(
        _ providers: [LyricsProviderPreference]
    ) -> Self {
        Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: metadataProviders,
            lyricsProviders: providers,
            privacyPreferences: privacyPreferences
        )
    }

    public func settingLyricsProvidersEnabled(_ enabled: Bool) -> Self {
        settingLyricsProviders(lyricsProviders.map { $0.settingEnabled(enabled) })
    }

    public func settingPrivacyPreferences(_ preferences: PrivacyPreferences) -> Self {
        Self(
            duplicatePolicy: duplicatePolicy,
            metadataProviders: metadataProviders,
            lyricsProviders: lyricsProviders,
            privacyPreferences: preferences
        )
    }

    private enum CodingKeys: String, CodingKey {
        case duplicatePolicy
        case metadataProviders
        case lyricsProviders
        case privacyPreferences
        case lyricsProvidersEnabled
        case useMusicKitMetadataEnrichment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duplicatePolicy = try container.decodeIfPresent(
            DuplicateImportPolicy.self,
            forKey: .duplicatePolicy
        ) ?? .skipExisting
        let legacyLyricsProvidersEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .lyricsProvidersEnabled
        ) ?? false
        let privacyPreferences = try container.decodeIfPresent(
            PrivacyPreferences.self,
            forKey: .privacyPreferences
        ) ?? .defaults
        let lyricsProviders = try container.decodeIfPresent(
            [LyricsProviderPreference].self,
            forKey: .lyricsProviders
        )
        if let providers = try container.decodeIfPresent(
            [MetadataProviderPreference].self,
            forKey: .metadataProviders
        ) {
            self.init(
                duplicatePolicy: duplicatePolicy,
                metadataProviders: Self.providersAfterMigration(providers),
                lyricsProviders: lyricsProviders.map(Self.providersAfterMigration)
                    ?? Self.defaultLyricsProviders.map {
                        $0.settingEnabled(legacyLyricsProvidersEnabled)
                    },
                privacyPreferences: privacyPreferences
            )
        } else {
            self.init(
                duplicatePolicy: duplicatePolicy,
                useMusicKitMetadataEnrichment: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .useMusicKitMetadataEnrichment
                ) ?? false,
                lyricsProvidersEnabled: legacyLyricsProvidersEnabled,
                privacyPreferences: privacyPreferences
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(duplicatePolicy, forKey: .duplicatePolicy)
        try container.encode(metadataProviders, forKey: .metadataProviders)
        try container.encode(lyricsProviders, forKey: .lyricsProviders)
        try container.encode(privacyPreferences, forKey: .privacyPreferences)
        // Keep emitting the legacy aggregate value so an older app can still
        // read whether at least one lyrics provider is enabled.
        try container.encode(lyricsProvidersEnabled, forKey: .lyricsProvidersEnabled)
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

    private static func normalizedLyricsProviders(
        _ providers: [LyricsProviderPreference]
    ) -> [LyricsProviderPreference] {
        var seen = Set<LyricsProviderID>()
        let normalized = providers.filter { seen.insert($0.provider).inserted }
        return normalized.isEmpty ? defaultLyricsProviders : normalized
    }

    /// Adds lyrics providers introduced after the ordered provider setting was
    /// first persisted without changing any existing enablement.
    private static func providersAfterMigration(
        _ providers: [LyricsProviderPreference]
    ) -> [LyricsProviderPreference] {
        var migrated = normalizedLyricsProviders(providers)
        for defaultProvider in defaultLyricsProviders where !migrated.contains(where: {
            $0.provider == defaultProvider.provider
        }) {
            migrated.append(defaultProvider)
        }
        return migrated
    }

    /// Adds providers introduced after the ordered-provider setting was first
    /// persisted without changing any existing order or enablement.
    private static func providersAfterMigration(
        _ providers: [MetadataProviderPreference]
    ) -> [MetadataProviderPreference] {
        var migrated = normalizedProviders(providers)
        for defaultProvider in defaultMetadataProviders where !migrated.contains(where: {
            $0.provider == defaultProvider.provider
        }) {
            if defaultProvider.provider == .musicBrainz,
               let discogsIndex = migrated.firstIndex(where: { $0.provider == .discogs }) {
                migrated.insert(defaultProvider, at: discogsIndex)
            } else {
                migrated.append(defaultProvider)
            }
        }
        return migrated
    }
}
