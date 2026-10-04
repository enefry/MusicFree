@testable import SettingsFeature
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import SettingsAPI
import Testing

struct PluginConsentSettingsTests {
    @Test(arguments: [false, true], [false, true])
    func grantKeepsApplicationAndOtherProviderConsent(_ appAccepted: Bool, _ network: Bool) {
        let privacy = PrivacyPreferences(
            privacyPolicyVersion: appAccepted ? PrivacyPreferences.currentPrivacyPolicyVersion : nil,
            providerConsents: [.init(providerID: "existing-service", policyVersion: PrivacyPreferences.currentProviderPolicyVersion)])
        let current = AppSettings(importPreferences: .defaults.settingPrivacyPreferences(privacy))
        let descriptor = PluginDescriptor(id: .init(rawValue: "test.lyrics"), name: "Lyrics",
            kinds: [.lyrics], permissions: network ? [.network] : [])
        let updated = PluginConsentSettings.grant(descriptor: descriptor, current: current)
        let result = updated.importPreferences.privacyPreferences
        #expect(result.privacyPolicyVersion == privacy.privacyPolicyVersion)
        #expect(result.providerConsents.filter { $0.providerID != descriptor.id.rawValue } == privacy.providerConsents)
        #expect(result.isProviderPolicyAccepted("lrclib") == privacy.isProviderPolicyAccepted("lrclib"))
        #expect(updated.pluginPreferences.first?.acceptedPolicyVersion == descriptor.policyVersion)
        #expect(updated.pluginPreferences.first?.grantedPermissions == descriptor.permissions)
        #expect(updated.importPreferences.lyricsProviders.contains { $0.provider.rawValue == descriptor.id.rawValue && $0.isEnabled })
    }

    @Test func revokeDisablesOnlyMatchingProviderAndKeepsAppConsent() {
        let descriptor = PluginDescriptor(id: .init(rawValue: "test.service"), name: "Service", kinds: [.lyrics, .metadata])
        let current = PluginConsentSettings.grant(descriptor: descriptor,
            current: AppSettings(importPreferences: .defaults.settingPrivacyPreferences(.defaults.acceptingPrivacyPolicy())))
        let revoked = PluginConsentSettings.revoke(descriptor: descriptor, current: current)
        #expect(revoked.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
        #expect(!revoked.importPreferences.privacyPreferences.isProviderPolicyAccepted(descriptor.id.rawValue))
        #expect(revoked.importPreferences.lyricsProviders.first { $0.provider.rawValue == descriptor.id.rawValue }?.isEnabled == false)
        #expect(revoked.importPreferences.metadataProviders.first { $0.provider.rawValue == descriptor.id.rawValue }?.isEnabled == false)
        #expect(revoked.pluginPreferences.first?.isEnabled == false)
    }

    @Test(arguments: [false, true], [false, true])
    func sourceConsentKeepsApplicationPrivacyGate(_ appAccepted: Bool, _ consent: Bool) throws {
        let privacy = appAccepted ? PrivacyPreferences.defaults.acceptingPrivacyPolicy() : .defaults
        let current = AppSettings(importPreferences: .defaults.settingPrivacyPreferences(privacy))
        let descriptor = PluginDescriptor(id: .init(rawValue: "test.source"), name: "Source", kinds: [.onlineSource])
        let source = try OnlineSourceConfiguration(sourceID: .init(rawValue: "test-account"),
            providerKind: .init(rawValue: descriptor.id.rawValue), displayName: "Account",
            privacyPolicyVersion: consent ? descriptor.policyVersion : nil, isEnabled: true)
        let instance = PluginInstanceConfiguration(instanceID: source.sourceID.rawValue,
            acceptedPolicyVersion: consent ? descriptor.policyVersion : nil)
        let updated = try PluginConsentSettings.save(source: source, instance: instance,
            descriptor: descriptor, isNew: true, current: current)
        #expect(updated.importPreferences.privacyPreferences == privacy)
        #expect(updated.importPreferences.onlineSourcePreferences.sources == [source])
        #expect(updated.pluginPreferences.first?.instances == [instance])
        if !appAccepted {
            #expect(updated.importPreferences.onlineSourcePreferences.runtimeSources(applicationPrivacyAccepted: false).isEmpty)
        }
    }
}

@Test func builtinDataGrantKeepsStableProviderOrderAndAppGate() {
    let descriptor = PluginDescriptor(id: .init(rawValue: "builtin.metadata.musicKit"), name: "MusicKit", kinds: [.metadata],
        permissions: [.network], policyVersion: "1.2.0", dataProviderID: "musicKit")
    let current = AppSettings.defaults
    let updated = PluginConsentSettings.grant(descriptor: descriptor, current: current)
    #expect(updated.importPreferences.metadataProviders.map(\.provider) == current.importPreferences.metadataProviders.map(\.provider))
    #expect(updated.importPreferences.isMetadataProviderEnabled(.musicKit))
    #expect(!updated.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
    #expect(updated.importPreferences.privacyPreferences.providerConsents.first?.providerID == "musicKit")
    #expect(!updated.importPreferences.metadataProviders.contains { $0.provider.rawValue == descriptor.id.rawValue })
    let revoked = PluginConsentSettings.revoke(descriptor: descriptor, current: updated)
    #expect(!revoked.importPreferences.isMetadataProviderEnabled(.musicKit))
    #expect(revoked.importPreferences.privacyPreferences.providerConsents.isEmpty)
}
