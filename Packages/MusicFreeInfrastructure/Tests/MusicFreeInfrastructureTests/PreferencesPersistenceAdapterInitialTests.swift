import Foundation
import PreferencesPersistenceAdapter
import SettingsAPI
import Testing

@Test("Preferences adapter returns defaults and round-trips settings")
func preferencesAdapterDefaultsAndRoundTrip() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    let initialSettings = try await repository.load()
    #expect(initialSettings == .defaults)

    let settings = try makeChangedSettings()
    try await repository.save(settings)
    let restoredSettings = try await repository.load()
    #expect(restoredSettings == settings)
}

@Test("Preferences adapter reset restores defaults")
func preferencesAdapterResetRestoresDefaults() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    try await repository.save(try makeChangedSettings())
    try await repository.reset()

    let resetSettings = try await repository.load()
    #expect(resetSettings == .defaults)
    try await repository.reset()
    let repeatedResetSettings = try await repository.load()
    #expect(repeatedResetSettings == .defaults)
}

@Test("Preferences adapter migrates schema zero payloads without rewriting them")
func preferencesAdapterMigratesLegacyPayload() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let legacyData = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 0,
        "payload": [
            "importPreferences": ["duplicatePolicy": "keepBoth"],
            "futureField": true
        ]
    ])
    let defaults = try #require(UserDefaults(suiteName: configuration.suiteName))
    defaults.set(legacyData, forKey: configuration.key)

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    let migrated = try await repository.load()

    #expect(migrated.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(migrated.importPreferences.duplicatePolicy == .keepBoth)
    #expect(migrated.playbackPreferences == .defaults)
    #expect(migrated.storagePreferences == .defaults)
    #expect(defaults.data(forKey: configuration.key) == legacyData)
}

@Test("Preferences adapter rejects future schemas and preserves their data")
func preferencesAdapterRejectsFutureSchema() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let futureData = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": AppSettings.currentSchemaVersion + 1,
        "payload": ["storagePreferences": ["automaticallyPruneCache": false]]
    ])
    let defaults = try #require(UserDefaults(suiteName: configuration.suiteName))
    defaults.set(futureData, forKey: configuration.key)

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    do {
        _ = try await repository.load()
        Issue.record("A future preferences schema should not be silently downgraded")
    } catch let error as SettingsError {
        #expect(
            error == .unsupportedSchemaVersion(
                found: AppSettings.currentSchemaVersion + 1,
                current: AppSettings.currentSchemaVersion
            )
        )
    }

    #expect(defaults.data(forKey: configuration.key) == futureData)
}

@Test("Preferences adapter rejects corrupt data and reset is explicit recovery")
func preferencesAdapterRejectsCorruptDataAndResetsExplicitly() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let corruptData = Data([0x00, 0xFF, 0x02, 0x7F])
    let defaults = try #require(UserDefaults(suiteName: configuration.suiteName))
    defaults.set(corruptData, forKey: configuration.key)

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    do {
        _ = try await repository.load()
        Issue.record("Corrupt preferences should not become defaults silently")
    } catch let error as SettingsError {
        #expect(error == .decoding)
    }

    #expect(defaults.data(forKey: configuration.key) == corruptData)
    try await repository.reset()
    let recoveredSettings = try await repository.load()
    #expect(recoveredSettings == .defaults)
}

@Test("Preferences adapter publishes one event per changed commit and supports cancellation")
func preferencesAdapterChangeSemantics() async throws {
    let configuration = try makeTestConfiguration()
    defer { removeTestSuite(configuration) }

    let repository = try UserDefaultsSettingsRepository(configuration: configuration)
    let observer = StreamObserver(repository.changes())

    let settings = try makeChangedSettings()
    try await repository.save(settings)
    try await repository.save(settings)
    try await repository.reset()

    #expect(await observer.waitForLast(.defaults))
    #expect(await observer.snapshot() == [settings, .defaults])
    observer.cancel()
}

private func makeTestConfiguration() throws -> PreferencesConfiguration {
    try PreferencesConfiguration(
        suiteName: "com.musicfree.infrastructure-tests.\(UUID().uuidString)"
    )
}

private func removeTestSuite(_ configuration: PreferencesConfiguration) {
    UserDefaults(suiteName: configuration.suiteName)?
        .removePersistentDomain(forName: configuration.suiteName)
}

private func makeChangedSettings() throws -> AppSettings {
    AppSettings(
        playbackPreferences: PlaybackPreferences(
            rate: try PlaybackRate(value: 1.25)
        )
    )
}

private final class StreamObserver: @unchecked Sendable {
    private let state: StreamObserverState
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<AppSettings>) {
        let state = StreamObserverState()
        self.state = state
        self.task = Task {
            for await value in stream {
                await state.append(value)
            }
        }
    }

    func waitForLast(_ expected: AppSettings) async -> Bool {
        for _ in 0..<1_000 {
            if await state.last == expected {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func snapshot() async -> [AppSettings] {
        await state.snapshot()
    }

    func cancel() {
        task.cancel()
    }
}

private actor StreamObserverState {
    private var values: [AppSettings] = []

    var last: AppSettings? {
        values.last
    }

    func append(_ value: AppSettings) {
        values.append(value)
    }

    func snapshot() -> [AppSettings] {
        values
    }
}
