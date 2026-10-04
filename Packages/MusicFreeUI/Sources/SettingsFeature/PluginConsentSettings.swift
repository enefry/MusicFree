import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import SettingsAPI

/// Plugin and source grants cannot accept the application's privacy policy.
/// Network services still require their independent application privacy gate.
enum PluginConsentSettings {
    static func grant(descriptor: PluginDescriptor, current: AppSettings) -> AppSettings {
        var preferences = current.pluginPreferences
        var preference = preferences.first { $0.pluginID == descriptor.id } ?? PluginPreference(pluginID: descriptor.id)
        preference.grantedPermissions = descriptor.permissions
        preference.acceptedPolicyVersion = descriptor.policyVersion
        preferences.removeAll { $0.pluginID == descriptor.id }; preferences.append(preference)
        var imports = current.importPreferences
        if descriptor.kinds.contains(.lyrics) || descriptor.kinds.contains(.metadata) || descriptor.permissions.contains(.network) {
            imports = imports.settingPrivacyPreferences(imports.privacyPreferences.acceptingProviderPolicy(descriptor.id.rawValue))
        }
        if descriptor.kinds.contains(.lyrics) {
            let id = LyricsProviderID(rawValue: descriptor.id.rawValue)
            imports = imports.settingLyricsProviders(imports.lyricsProviders.filter { $0.provider != id } + [.init(provider: id, isEnabled: true)])
        }
        if descriptor.kinds.contains(.metadata) {
            let id = MetadataProviderID(rawValue: descriptor.id.rawValue)
            imports = imports.settingMetadataProviders(imports.metadataProviders.filter { $0.provider != id } + [.init(provider: id, isEnabled: true)])
        }
        return AppSettings(importPreferences: imports, playbackPreferences: current.playbackPreferences,
            storagePreferences: current.storagePreferences, loggingPreferences: current.loggingPreferences, pluginPreferences: preferences)
    }

    static func revoke(descriptor: PluginDescriptor, current: AppSettings) -> AppSettings {
        var preferences = current.pluginPreferences
        var preference = preferences.first { $0.pluginID == descriptor.id } ?? PluginPreference(pluginID: descriptor.id)
        preference.grantedPermissions = []
        preference.acceptedPolicyVersion = nil
        preference.isEnabled = false
        preferences.removeAll { $0.pluginID == descriptor.id }; preferences.append(preference)
        var imports = current.importPreferences
        imports = imports.settingPrivacyPreferences(imports.privacyPreferences.revokingProviderPolicy(descriptor.id.rawValue))
        imports = imports.settingLyricsProviders(imports.lyricsProviders.map {
            .init(provider: $0.provider, isEnabled: $0.provider.rawValue == descriptor.id.rawValue ? false : $0.isEnabled)
        })
        imports = imports.settingMetadataProviders(imports.metadataProviders.map {
            .init(provider: $0.provider, isEnabled: $0.provider.rawValue == descriptor.id.rawValue ? false : $0.isEnabled)
        })
        return AppSettings(importPreferences: imports, playbackPreferences: current.playbackPreferences,
            storagePreferences: current.storagePreferences, loggingPreferences: current.loggingPreferences, pluginPreferences: preferences)
    }

    static func save(source: OnlineSourceConfiguration, instance: PluginInstanceConfiguration,
                     descriptor: PluginDescriptor, isNew: Bool, current: AppSettings) throws -> AppSettings {
        var sources = current.importPreferences.onlineSourcePreferences
        sources = isNew ? try sources.adding(source) : try sources.updating(source)
        let imports = current.importPreferences.settingOnlineSourcePreferences(sources)
        var preferences = current.pluginPreferences
        var preference = preferences.first { $0.pluginID == descriptor.id } ?? PluginPreference(pluginID: descriptor.id)
        preference.instances.removeAll { $0.instanceID == source.sourceID.rawValue }
        preference.instances.append(instance)
        preferences.removeAll { $0.pluginID == descriptor.id }; preferences.append(preference)
        return AppSettings(importPreferences: imports, playbackPreferences: current.playbackPreferences,
            storagePreferences: current.storagePreferences, loggingPreferences: current.loggingPreferences, pluginPreferences: preferences)
    }
}
