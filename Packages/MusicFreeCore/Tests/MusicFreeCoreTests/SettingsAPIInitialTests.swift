import Foundation
import MusicDomain
import SettingsAPI
import Testing

@Test("Settings defaults keep advanced playback features off")
func settingsDefaultsAreSafe() {
    let settings = AppSettings.defaults

    #expect(settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(settings.importPreferences.duplicatePolicy == .skipExisting)
    #expect(settings.importPreferences.metadataProviders.map(\.provider) == [
        .musicKit,
        .musicBrainz,
        .metadataServer,
        .discogs
    ])
    #expect(settings.importPreferences.metadataProviders.allSatisfy { !$0.isEnabled })
    #expect(settings.importPreferences.lyricsProviders.map(\.provider) == [
        .metadataServer,
        .lrclib
    ])
    #expect(settings.importPreferences.lyricsProviders.allSatisfy { !$0.isEnabled })
    #expect(!settings.importPreferences.lyricsProvidersEnabled)
    #expect(settings.importPreferences.privacyPreferences == .defaults)
    #expect(settings.playbackPreferences.rate == .normal)
    #expect(!settings.playbackPreferences.equalizer.isEnabled)
    #expect(settings.playbackPreferences.equalizer.preamp == .zero)
    #expect(settings.playbackPreferences.replayGain == .off)
    #expect(settings.playbackPreferences.transition.crossfadeDuration == .zero)
    #expect(settings.playbackPreferences.transition.gaplessPlaybackEnabled)
    #expect(settings.playbackPreferences.sleepTimer == .defaults)
    #expect(settings.storagePreferences.cacheLimit == .fiveGiB)
    #expect(settings.storagePreferences.automaticallyPruneCache)
    #expect(settings.storagePreferences.stagingRetention == .seconds(7 * 24 * 60 * 60))
}

@Test("Import preferences migrate the legacy MusicKit flag and preserve provider order")
func importPreferencesMigrateMetadataProviders() throws {
    let legacyPayload = #"{"duplicatePolicy":"keepBoth","useMusicKitMetadataEnrichment":true}"#
        .data(using: .utf8)!
    let migrated = try JSONDecoder().decode(ImportPreferences.self, from: legacyPayload)
    #expect(migrated.duplicatePolicy == .keepBoth)
    #expect(migrated.metadataProviders.map(\.provider) == [
        .musicKit,
        .musicBrainz,
        .metadataServer,
        .discogs
    ])
    #expect(migrated.isMetadataProviderEnabled(.musicKit))
    #expect(!migrated.isMetadataProviderEnabled(.metadataServer))
    #expect(!migrated.isMetadataProviderEnabled(.discogs))
    #expect(migrated.lyricsProviders.allSatisfy { !$0.isEnabled })
    #expect(!migrated.lyricsProvidersEnabled)

    let customProvider = MetadataProviderID(rawValue: "customProvider")
    let configured = ImportPreferences(
        metadataProviders: [
            MetadataProviderPreference(provider: .metadataServer, isEnabled: true),
            MetadataProviderPreference(provider: .musicKit, isEnabled: false),
            MetadataProviderPreference(provider: customProvider, isEnabled: true)
        ],
        lyricsProvidersEnabled: false
    )
    let roundTripped = try JSONDecoder().decode(
        ImportPreferences.self,
        from: JSONEncoder().encode(configured)
    )
    #expect(roundTripped.metadataProviders.map(\.provider) == [
        .metadataServer,
        .musicKit,
        customProvider,
        .musicBrainz,
        .discogs
    ])
    #expect(Array(roundTripped.metadataProviders.prefix(3)) == configured.metadataProviders)
    #expect(!roundTripped.isMetadataProviderEnabled(.discogs))
    #expect(!roundTripped.lyricsProvidersEnabled)

    let perProvider = ImportPreferences(
        lyricsProviders: [
            LyricsProviderPreference(provider: .lrclib, isEnabled: false),
            LyricsProviderPreference(provider: .metadataServer, isEnabled: true)
        ]
    )
    let perProviderRoundTrip = try JSONDecoder().decode(
        ImportPreferences.self,
        from: JSONEncoder().encode(perProvider)
    )
    #expect(perProviderRoundTrip.lyricsProviders.map(\.provider) == [
        .lrclib,
        .metadataServer
    ])
    #expect(!perProviderRoundTrip.isLyricsProviderEnabled(.lrclib))
    #expect(perProviderRoundTrip.isLyricsProviderEnabled(.metadataServer))
    #expect(perProviderRoundTrip.lyricsProvidersEnabled)
}

@Test("Import preferences append Discogs to previously saved provider orders")
func importPreferencesMigratePreviouslySavedProviderOrder() throws {
    let previousPayload = #"{"metadataProviders":[{"provider":"metadataServer","isEnabled":true},{"provider":"musicKit","isEnabled":false}]}"#
        .data(using: .utf8)!

    let migrated = try JSONDecoder().decode(
        ImportPreferences.self,
        from: previousPayload
    )

    #expect(migrated.metadataProviders.map(\.provider) == [
        .metadataServer,
        .musicKit,
        .musicBrainz,
        .discogs
    ])
    #expect(migrated.isMetadataProviderEnabled(.metadataServer))
    #expect(!migrated.isMetadataProviderEnabled(.musicKit))
    #expect(!migrated.isMetadataProviderEnabled(.discogs))
    #expect(migrated.lyricsProviders.allSatisfy { !$0.isEnabled })
    #expect(!migrated.lyricsProvidersEnabled)
}

@Test("Online providers require application and provider privacy consent")
func privacyConsentGatesRuntimeProviders() throws {
    let preferences = ImportPreferences(
        metadataProviders: [
            MetadataProviderPreference(provider: .musicBrainz, isEnabled: true)
        ],
        lyricsProviders: [
            LyricsProviderPreference(provider: .lrclib, isEnabled: true)
        ]
    )

    #expect(preferences.runtimeMetadataProviders.allSatisfy { !$0.isEnabled })
    #expect(preferences.runtimeLyricsProviders.allSatisfy { !$0.isEnabled })

    let consentedPrivacy = PrivacyPreferences.defaults
        .acceptingPrivacyPolicy()
        .acceptingProviderPolicy(MetadataProviderID.musicBrainz.rawValue)
        .acceptingProviderPolicy(LyricsProviderID.lrclib.rawValue)
    let consented = preferences.settingPrivacyPreferences(consentedPrivacy)

    #expect(consented.runtimeMetadataProviders.first?.isEnabled == true)
    #expect(consented.runtimeLyricsProviders.first?.isEnabled == true)

    let roundTripped = try JSONDecoder().decode(
        ImportPreferences.self,
        from: JSONEncoder().encode(consented)
    )
    #expect(roundTripped.privacyPreferences == consentedPrivacy)
    #expect(roundTripped.runtimeMetadataProviders.first?.isEnabled == true)
    #expect(roundTripped.runtimeLyricsProviders.first?.isEnabled == true)
}

@Test("Provider consent cannot be granted before application privacy consent")
func providerConsentRequiresApplicationPrivacyConsent() {
    let providerOnly = PrivacyPreferences.defaults.acceptingProviderPolicy(
        MetadataProviderID.musicBrainz.rawValue
    )

    #expect(providerOnly == .defaults)

    let outdatedApplicationConsent = PrivacyPreferences(
        privacyPolicyVersion: "1.0.0",
        providerConsents: [
            ProviderPrivacyConsent(
                providerID: MetadataProviderID.musicBrainz.rawValue,
                policyVersion: PrivacyPreferences.currentProviderPolicyVersion
            )
        ]
    ).acceptingPrivacyPolicy()

    #expect(!outdatedApplicationConsent.isProviderPolicyAccepted(
        MetadataProviderID.musicBrainz.rawValue
    ))
}

@Test("Import preferences reject empty metadata provider IDs")
func importPreferencesRejectEmptyMetadataProviderID() {
    let payload = #"{"metadataProviders":[{"provider":"","isEnabled":true}]}"#
        .data(using: .utf8)!

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ImportPreferences.self, from: payload)
    }
}

@Test("Sleep timer schedules handle daytime, overnight, and overlapping windows")
func sleepTimerScheduleWindowsAndPriority() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let overnightID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let lunchID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let overlapID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let preferences = try SleepTimerPreferences(schedules: [
        SleepTimerSchedule(
            id: overnightID,
            startMinute: 23 * 60,
            endMinute: 5 * 60,
            durationMinutes: 20
        ),
        SleepTimerSchedule(
            id: lunchID,
            startMinute: 13 * 60,
            endMinute: 14 * 60,
            durationMinutes: 30
        ),
        SleepTimerSchedule(
            id: overlapID,
            startMinute: 23 * 60 + 30,
            endMinute: 1 * 60,
            durationMinutes: 10
        ),
    ])

    let lateNight = calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 14,
        hour: 23,
        minute: 45
    ))!
    let lunch = calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 14,
        hour: 13,
        minute: 30
    ))!
    let overnightEnd = calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 15,
        hour: 5
    ))!

    let lateNightMatches = preferences.activeSchedules(at: lateNight, calendar: calendar)
    #expect(Set(lateNightMatches.map(\.id)) == [overnightID, overlapID])
    #expect(lateNightMatches.map(\.durationMinutes).min() == 10)
    #expect(preferences.activeSchedules(at: lunch, calendar: calendar).map(\.id) == [lunchID])
    #expect(preferences.activeSchedules(at: overnightEnd, calendar: calendar).isEmpty)
}

@Test("Sleep timer schedules reject invalid values and duplicate IDs")
func sleepTimerScheduleValidation() throws {
    #expect(throws: SettingsError.self) {
        try SleepTimerSchedule(startMinute: -1, endMinute: 60, durationMinutes: 20)
    }
    #expect(throws: SettingsError.self) {
        try SleepTimerSchedule(startMinute: 0, endMinute: 60, durationMinutes: 0)
    }

    let id = UUID()
    let schedule = try SleepTimerSchedule(
        id: id,
        startMinute: 0,
        endMinute: 60,
        durationMinutes: 20
    )
    #expect(throws: SettingsError.self) {
        try SleepTimerPreferences(schedules: [schedule, schedule])
    }
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
