import Foundation
import MusicFreePluginAPI

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
    public let loggingPreferences: LoggingPreferences
    public let pluginPreferences: [PluginPreference]

    public init(
        importPreferences: ImportPreferences = .defaults,
        playbackPreferences: PlaybackPreferences = .defaults,
        storagePreferences: StoragePreferences = .defaults,
        loggingPreferences: LoggingPreferences = .defaults,
        pluginPreferences: [PluginPreference] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.importPreferences = importPreferences
        self.playbackPreferences = playbackPreferences
        self.storagePreferences = storagePreferences
        self.loggingPreferences = loggingPreferences
        self.pluginPreferences = pluginPreferences
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
            crossfadeDuration: playbackPreferences.transition.crossfadeDuration,
            fadeInDuration: playbackPreferences.transition.fadeInDuration,
            fadeOutDuration: playbackPreferences.transition.fadeOutDuration
        )
        _ = try SleepTimerPreferences(schedules: playbackPreferences.sleepTimer.schedules)
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
        case loggingPreferences
        case pluginPreferences
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
            ) ?? .legacyDefaults,
            storagePreferences: try container.decodeIfPresent(
                StoragePreferences.self,
                forKey: .storagePreferences
            ) ?? .defaults,
            loggingPreferences: try container.decodeIfPresent(
                LoggingPreferences.self,
                forKey: .loggingPreferences
            ) ?? .defaults,
            pluginPreferences: try container.decodeIfPresent([PluginPreference].self, forKey: .pluginPreferences) ?? []
        )
    }

    public func settingLoggingPreferences(_ preferences: LoggingPreferences) -> Self {
        Self(
            importPreferences: importPreferences,
            playbackPreferences: playbackPreferences,
            storagePreferences: storagePreferences,
            loggingPreferences: preferences,
            pluginPreferences: pluginPreferences
        )
    }

    public func settingPluginPreferences(_ preferences: [PluginPreference]) -> Self {
        Self(importPreferences: importPreferences, playbackPreferences: playbackPreferences,
             storagePreferences: storagePreferences, loggingPreferences: loggingPreferences,
             pluginPreferences: preferences)
    }

    public func settingPlaybackPreferences(_ preferences: PlaybackPreferences) -> Self {
        Self(importPreferences: importPreferences, playbackPreferences: preferences,
             storagePreferences: storagePreferences, loggingPreferences: loggingPreferences,
             pluginPreferences: pluginPreferences)
    }
}
