import Foundation
import XCTest
import SettingsAPI
import PreferencesPersistenceAdapter
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge
import AppServices
@testable import SettingsFeature

@MainActor final class PluginPersistenceTests: XCTestCase {
    func testFuturePluginValuesPreserveWholeSettingsEnvelope() async throws {
        let suite = "musicfree.tests.plugins.future.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PluginPreference(pluginID: .init(rawValue: "future.plugin"),
            configuration: ["future": .unknown(.object(["futureCase": .array([.text("value"), .null])]))],
            grantedPermissions: [.init(rawValue: "futurePermission")], dspPlacement: .init(rawValue: "futurePosition"))
        let settings = AppSettings.defaults.settingPluginPreferences([preference])
        let repository = try UserDefaultsSettingsRepository(suiteName: suite)
        try await repository.save(settings)
        let restored = try await repository.load()
        XCTAssertEqual(restored, settings)
    }
    func testPluginPreferencesPersistInExistingUserDefaultsEnvelope() async throws {
        let suite = "musicfree.tests.plugins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try UserDefaultsSettingsRepository(suiteName: suite)
        let preference = PluginPreference(pluginID: .init(rawValue: "reference.gain"), isVisible: false,
            isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(0.5)], dspPlacement: .perTrack)
        let settings = AppSettings.defaults.settingPluginPreferences([preference])
        try await repository.save(settings)
        let reopened = try UserDefaultsSettingsRepository(suiteName: suite)
        let restored = try await reopened.load()
        XCTAssertEqual(restored.pluginPreferences, [preference])
        XCTAssertEqual(restored.playbackPreferences, settings.playbackPreferences)
    }
    func testLegacyEnvelopeKeepsExistingSourceAndDecodesEmptyPlugins() async throws {
        let suite = "musicfree.tests.plugins.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"schemaVersion\":1}".utf8), forKey: PreferencesConfiguration.defaultKey)
        let repository = try UserDefaultsSettingsRepository(suiteName: suite)
        let restored = try await repository.load()
        XCTAssertTrue(restored.pluginPreferences.isEmpty)
    }
}

private actor BuiltinAuthorizationFixture: MetadataPlugin {
    var authorization = PluginMetadataAuthorizationStatus.notDetermined
    func authorizationStatus() async -> PluginMetadataAuthorizationStatus { authorization }
    func requestAuthorization() async -> PluginMetadataAuthorizationStatus { authorization = .authorized; return authorization }
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] { [] }
}
extension PluginPersistenceTests {
    func testExistingMetadataSettingsToggleAuthorizesBeforeEnablingPlugin() async throws {
        let suite = "musicfree.tests.plugin-migration.metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try UserDefaultsSettingsRepository(suiteName: suite)
        let fixture = BuiltinAuthorizationFixture(), id = PluginID(rawValue: "builtin.metadata.fixture")
        let runtime = PluginRuntime(registry: PluginRegistry([
            .init(descriptor: .init(id: id, name: "MusicKit fixture", kinds: [.metadata], permissions: [.network], policyVersion: "1.2.0", dataProviderID: "musicKit"),
                metadata: { _ in fixture }, metadataAuthorization: .init(status: { await fixture.authorizationStatus() }, request: { await fixture.requestAuthorization() }))
        ]))
        let service = PluginHostService(runtime: runtime)
        try await repository.save(.init(importPreferences: .defaults.settingPrivacyPreferences(
            .defaults.acceptingPrivacyPolicy().acceptingProviderPolicy("musicKit"))))
        let container = try AppServiceContainer(dependencies: AppDependencies(settingsRepository: repository,
            metadataEnrichmentProviders: service.metadataProviders, plugins: service))
        _ = try await container.start()
        let model = SettingsViewModel(store: AppServicesSettingsStore(serving: container.settings), metadataEnrichment: container.metadataEnrichment)
        defer { model.stopObservingChanges() }
        await model.load()
        XCTAssertFalse(model.settings.importPreferences.isMetadataProviderEnabled(.musicKit))
        model.setMetadataProviderEnabled(.musicKit, true)
        await model.waitForMetadataWork(); await model.waitForPendingWork()
        XCTAssertTrue(model.settings.importPreferences.isMetadataProviderEnabled(.musicKit))
        XCTAssertEqual(model.settings.pluginPreferences.first { $0.pluginID == id }?.isEnabled, true)
        let saved = try await repository.load()
        XCTAssertTrue(saved.importPreferences.isMetadataProviderEnabled(.musicKit))
        let authorization = await fixture.authorizationStatus()
        XCTAssertEqual(authorization, .authorized)
        model.setMetadataProviderEnabled(.musicKit, false)
        await model.waitForMetadataWork(); await model.waitForPendingWork()
        XCTAssertEqual(model.settings.pluginPreferences.first { $0.pluginID == id }?.isEnabled, false)
        await service.stop()
    }
}
