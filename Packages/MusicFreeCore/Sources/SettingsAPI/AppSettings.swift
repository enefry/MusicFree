import Foundation

/// The current persisted settings schema version.
@available(macOS 13.0, iOS 16.0, *)
public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    /// The schema emitted by this module.
    public static let currentSchemaVersion = 1

    /// The unversioned payload is the only legacy payload upgraded in this release.
    public static let minimumReadableSchemaVersion = 0

    public let schemaVersion: Int
    public let importPreferences: ImportPreferences
    public let playbackPreferences: PlaybackPreferences
    public let storagePreferences: StoragePreferences

    public init(
        importPreferences: ImportPreferences = .defaults,
        playbackPreferences: PlaybackPreferences = .defaults,
        storagePreferences: StoragePreferences = .defaults
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.importPreferences = importPreferences
        self.playbackPreferences = playbackPreferences
        self.storagePreferences = storagePreferences
    }

    public static let defaults = Self()

    /// Re-validates the aggregate before a repository commits it.
    public func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SettingsError.unsupportedSchemaVersion(
                found: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        _ = try EqualizerPreferences(
            isEnabled: playbackPreferences.equalizer.isEnabled,
            preamp: playbackPreferences.equalizer.preamp,
            bands: playbackPreferences.equalizer.bands
        )
        _ = try TransitionPreferences(
            gaplessPlaybackEnabled: playbackPreferences.transition.gaplessPlaybackEnabled,
            crossfadeDuration: playbackPreferences.transition.crossfadeDuration
        )
        _ = try StoragePreferences(
            cacheLimit: storagePreferences.cacheLimit,
            automaticallyPruneCache: storagePreferences.automaticallyPruneCache,
            stagingRetention: storagePreferences.stagingRetention
        )
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case importPreferences
        case playbackPreferences
        case storagePreferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0

        guard (Self.minimumReadableSchemaVersion...Self.currentSchemaVersion).contains(encodedVersion) else {
            throw SettingsError.unsupportedSchemaVersion(
                found: encodedVersion,
                current: Self.currentSchemaVersion
            )
        }

        self.init(
            importPreferences: try container.decodeIfPresent(
                ImportPreferences.self,
                forKey: .importPreferences
            ) ?? .defaults,
            playbackPreferences: try container.decodeIfPresent(
                PlaybackPreferences.self,
                forKey: .playbackPreferences
            ) ?? .defaults,
            storagePreferences: try container.decodeIfPresent(
                StoragePreferences.self,
                forKey: .storagePreferences
            ) ?? .defaults
        )
    }
}
