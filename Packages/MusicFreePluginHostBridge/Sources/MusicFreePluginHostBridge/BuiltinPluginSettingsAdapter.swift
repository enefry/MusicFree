import Foundation
import MusicDomain
import MediaSourceAPI
import SettingsAPI
import MusicFreePluginAPI
import EqualizerDSPPlugin

/// Import legacy intent once, then reconcile only fields explicitly changed by
/// the corresponding settings editor. Persisted plugin revocations win on load.
enum BuiltinPluginSettingsAdapter {
    static func adapt(_ settings: AppSettings, previous: AppSettings?, descriptors: [PluginDescriptor]) throws -> AppSettings {
        var preferences = settings.pluginPreferences
        var imports = settings.importPreferences
        var playback = settings.playbackPreferences
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            let existing = preferences.first { $0.pluginID == descriptor.id }
            let oldPlugin = previous?.pluginPreferences.first { $0.pluginID == descriptor.id }
            var preference = existing ?? .init(pluginID: descriptor.id, isLoadAllowed: true)
            if let providerID = descriptor.dataProviderID {
                let lyrics = descriptor.kinds.contains(.lyrics)
                func enabled(_ value: AppSettings) -> Bool {
                    lyrics ? value.importPreferences.isLyricsProviderEnabled(.init(rawValue: providerID))
                        : value.importPreferences.isMetadataProviderEnabled(.init(rawValue: providerID))
                }
                func consent(_ value: AppSettings) -> Bool {
                    value.importPreferences.privacyPreferences.providerConsents.contains {
                        $0.providerID == providerID && $0.policyVersion == PrivacyPreferences.currentProviderPolicyVersion
                    }
                }
                if existing == nil || (existing == oldPlugin && previous.map { enabled($0) != enabled(settings) } == true) {
                    preference.isEnabled = enabled(settings)
                }
                if existing == nil || (existing == oldPlugin && previous.map { consent($0) != consent(settings) } == true) {
                    preference.grantedPermissions = consent(settings) ? descriptor.permissions : []
                    preference.acceptedPolicyVersion = consent(settings) ? descriptor.policyVersion : nil
                }
                if lyrics { imports = imports.settingLyricsProvider(.init(rawValue: providerID), enabled: preference.isEnabled) }
                else { imports = imports.settingMetadataProvider(.init(rawValue: providerID), enabled: preference.isEnabled) }
            } else if NativeOnlineSourceRegistrationProvider.ids.contains(descriptor.id) {
                let sources = imports.onlineSourcePreferences.sources.filter { $0.providerKind.rawValue == descriptor.onlineProviderID }
                // The existing source disclosure covers the same service and
                // credential access. It never accepts application privacy.
                let disclosed = sources.contains { $0.privacyPolicyVersion == descriptor.policyVersion }
                if existing == nil {
                    preference.isEnabled = true
                    preference.grantedPermissions = disclosed ? descriptor.permissions : []
                    preference.acceptedPolicyVersion = disclosed ? descriptor.policyVersion : nil
                } else if existing == oldPlugin, let previous,
                          sources.contains(where: { source in
                              source.privacyPolicyVersion == descriptor.policyVersion &&
                                  previous.importPreferences.onlineSourcePreferences.sources.first { $0.sourceID == source.sourceID }?.privacyPolicyVersion != descriptor.policyVersion
                          }) {
                    preference.grantedPermissions = descriptor.permissions
                    preference.acceptedPolicyVersion = descriptor.policyVersion
                }
                preference.instances = try sources.map { try NativeOnlineSourceRegistrationProvider.instance($0) }
            } else if descriptor.id == EqualizerDSPPlugin.id {
                let eq = playback.equalizer
                if existing == nil || (existing == oldPlugin && previous?.playbackPreferences.equalizer != eq) {
                    preference.isEnabled = eq.isEnabled
                    preference.configuration = ["preamp": .number(eq.preamp.decibels)]
                    for band in eq.bands where EqualizerDSPPlugin.frequencies.contains(band.frequencyHz) {
                        preference.configuration[String(band.frequencyHz)] = .number(band.gain.decibels)
                    }
                }
                let legacyGains = Dictionary(uniqueKeysWithValues: eq.bands.map { (String($0.frequencyHz), $0.gain.decibels) })
                func parameter(_ key: String) -> Double {
                    if case .number(let value) = preference.configuration[key] { return value }; return 0
                }
                let matchesLegacy = preference.isEnabled == eq.isEnabled && parameter("preamp") == eq.preamp.decibels
                    && EqualizerDSPPlugin.frequencies.allSatisfy { parameter(String($0)) == (legacyGains[String($0)] ?? 0) }
                if !matchesLegacy, preference.schemaVersion == descriptor.configuration.version,
                   (try? descriptor.configuration.validate(preference.configuration, credentialRecordID: preference.credentialRecordID)) != nil {
                    func gain(_ key: String) throws -> EqualizerGain {
                        if case .number(let value) = preference.configuration[key] { return try .init(decibels: value) }
                        return .zero
                    }
                    let bands = try EqualizerDSPPlugin.frequencies.map { try EqualizerBand(frequencyHz: $0, gain: gain(String($0))) }
                    playback = .init(rate: playback.rate,
                        equalizer: try .init(isEnabled: preference.isEnabled, preamp: gain("preamp"), bands: bands),
                        replayGain: playback.replayGain, transition: playback.transition, sleepTimer: playback.sleepTimer)
                }
            } else { continue }
            preferences.removeAll { $0.pluginID == descriptor.id }; preferences.append(preference)
        }
        return AppSettings(importPreferences: imports, playbackPreferences: playback,
            storagePreferences: settings.storagePreferences, loggingPreferences: settings.loggingPreferences, pluginPreferences: preferences)
    }
}
