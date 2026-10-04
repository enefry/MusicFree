import Foundation
import XCTest
import SettingsAPI
import PreferencesPersistenceAdapter
import MusicFreePluginAPI

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
