import Foundation
import SettingsAPI
import Testing

@Test("Settings defaults keep advanced playback features off")
func settingsDefaultsAreSafe() {
    let settings = AppSettings.defaults

    #expect(settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(settings.importPreferences.duplicatePolicy == .skipExisting)
    #expect(settings.playbackPreferences.rate == .normal)
    #expect(!settings.playbackPreferences.equalizer.isEnabled)
    #expect(settings.playbackPreferences.equalizer.preamp == .zero)
    #expect(settings.playbackPreferences.replayGain == .off)
    #expect(settings.playbackPreferences.transition.crossfadeDuration == .zero)
    #expect(settings.playbackPreferences.transition.gaplessPlaybackEnabled)
    #expect(settings.storagePreferences.cacheLimit == .fiveGiB)
    #expect(settings.storagePreferences.automaticallyPruneCache)
    #expect(settings.storagePreferences.stagingRetention == .seconds(7 * 24 * 60 * 60))
}

@Test("Typed setting values reject invalid ranges and duplicate bands")
func typedSettingValuesRejectInvalidInput() throws {
    do {
        _ = try PlaybackRate(value: 0.1)
        Issue.record("A playback rate below the contract range should fail")
    } catch let error as SettingsError {
        #expect(error == .invalidValue(field: "playback.rate", reason: .outOfRange))
    }

    do {
        _ = try EqualizerGain(decibels: .infinity)
        Issue.record("A non-finite equalizer gain should fail")
    } catch let error as SettingsError {
        #expect(error == .invalidValue(field: "playback.equalizer.gain", reason: .nonFinite))
    }

    let gain = try EqualizerGain(decibels: 3.0)
    let firstBand = try EqualizerBand(frequencyHz: 1_000, gain: gain)
    let duplicateBand = try EqualizerBand(frequencyHz: 1_000, gain: gain)

    do {
        _ = try EqualizerPreferences(bands: [firstBand, duplicateBand])
        Issue.record("Equalizer bands should have unique frequencies")
    } catch let error as SettingsError {
        #expect(error == .invalidValue(field: "playback.equalizer.bands", reason: .duplicate))
    }
}

@Test("Settings Codable migration fills defaults and rejects newer schemas")
func settingsCodableMigrationIsBounded() throws {
    let oldPayload = #"{"importPreferences":{"duplicatePolicy":"keepBoth"},"futureField":true}"#
        .data(using: .utf8)!

    let migrated = try JSONDecoder().decode(AppSettings.self, from: oldPayload)
    #expect(migrated.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(migrated.importPreferences.duplicatePolicy == .keepBoth)
    #expect(migrated.playbackPreferences == .defaults)
    #expect(migrated.storagePreferences == .defaults)

    let roundTripped = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONEncoder().encode(migrated)
    )
    #expect(roundTripped == migrated)

    let futurePayload = #"{"schemaVersion":2}"#.data(using: .utf8)!
    do {
        _ = try JSONDecoder().decode(AppSettings.self, from: futurePayload)
        Issue.record("A newer settings schema should not be silently downgraded")
    } catch let error as SettingsError {
        #expect(error == .unsupportedSchemaVersion(found: 2, current: 1))
    }
}

@Test("Settings repository publishes only successful value changes")
func settingsRepositoryChangeSemantics() async throws {
    let repository = TestSettingsRepository()
    let stream = repository.changes()
    var iterator = stream.makeAsyncIterator()
    let changedSettings = AppSettings(
        playbackPreferences: PlaybackPreferences(rate: try PlaybackRate(value: 1.25))
    )

    let initialSettings = try await repository.load()
    #expect(initialSettings == .defaults)
    try await repository.save(changedSettings)
    #expect(await iterator.next() == changedSettings)
    let savedSettings = try await repository.load()
    #expect(savedSettings == changedSettings)

    try await repository.save(changedSettings)
    #expect(await repository.publishedChangeCount() == 1)

    try await repository.reset()
    #expect(await iterator.next() == .defaults)
    #expect(await repository.publishedChangeCount() == 2)

    try await repository.reset()
    #expect(await repository.publishedChangeCount() == 2)
}

private final class TestSettingsRepository: SettingsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var value = AppSettings.defaults
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]
    private var changeCount = 0

    func load() async throws -> AppSettings {
        withLock { value }
    }

    func save(_ settings: AppSettings) async throws {
        let validated = try settings.validated()
        let subscribers: [AsyncStream<AppSettings>.Continuation]? = withLock {
            guard value != validated else {
                return nil
            }
            value = validated
            changeCount += 1
            return Array(continuations.values)
        }

        guard let subscribers else { return }

        for subscriber in subscribers {
            subscriber.yield(validated)
        }
    }

    func reset() async throws {
        try await save(.defaults)
    }

    func changes() -> AsyncStream<AppSettings> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[subscriptionID] = continuation
            lock.unlock()

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeSubscription(subscriptionID)
            }
        }
    }

    func publishedChangeCount() async -> Int {
        withLock { changeCount }
    }

    private func removeSubscription(_ subscriptionID: UUID) {
        _ = withLock {
            continuations.removeValue(forKey: subscriptionID)
        }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
