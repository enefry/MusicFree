@testable import SettingsFeature
import AppServices
import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing

@MainActor
private final class SettingsFeatureTestStore: SettingsFeatureStore {
    var current: AppSettings
    var playbackCapabilities: PlaybackCapabilities
    var equalizerDescriptor: EqualizerDescriptor?
    var systemCapabilities: SystemIntegrationCapabilitySnapshot
    var savedValues: [AppSettings] = []
    var loadCount = 0
    var resetCount = 0
    var nextLoadError: Error?
    var nextSaveError: Error?
    var nextResetError: Error?
    var storageUsageValue = StorageUsageSnapshot()
    var storageUsageCallCount = 0
    var maintenanceResult: StorageMaintenanceResult?
    var maintenanceCallCount = 0
    var suspendNextStorageUsage = false
    var nextStorageUsageError: Error?

    private var changeContinuation: AsyncStream<AppSettings>.Continuation?
    private var storageUsageContinuation: CheckedContinuation<StorageUsageSnapshot, Error>?

    init(
        settings: AppSettings = .defaults,
        playbackCapabilities: PlaybackCapabilities = [.variableRate, .replayGain, .gapless],
        equalizerDescriptor: EqualizerDescriptor? = nil,
        systemCapabilities: SystemIntegrationCapabilitySnapshot = .init()
    ) {
        self.current = settings
        self.playbackCapabilities = playbackCapabilities
        self.equalizerDescriptor = equalizerDescriptor
        self.systemCapabilities = systemCapabilities
    }

    func load() async throws -> AppSettings {
        loadCount += 1
        if let nextLoadError {
            self.nextLoadError = nil
            throw nextLoadError
        }
        return current
    }

    func save(_ settings: AppSettings) async throws {
        if let nextSaveError {
            self.nextSaveError = nil
            throw nextSaveError
        }
        current = settings
        savedValues.append(settings)
        changeContinuation?.yield(settings)
    }

    func reset() async throws {
        if let nextResetError {
            self.nextResetError = nil
            throw nextResetError
        }
        resetCount += 1
        current = .defaults
        changeContinuation?.yield(.defaults)
    }

    func effective() async throws -> EffectivePlaybackSettings {
        EffectivePlaybackSettings(
            settings: current,
            effects: .neutral,
            playbackCapabilities: playbackCapabilities,
            equalizerDescriptor: equalizerDescriptor,
            systemCapabilities: systemCapabilities
        )
    }

    func makeChangeStream() async -> AsyncStream<AppSettings> {
        AsyncStream { continuation in
            changeContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.changeContinuation = nil
                }
            }
        }
    }

    func storageUsage() async throws -> StorageUsageSnapshot {
        storageUsageCallCount += 1
        if let nextStorageUsageError {
            self.nextStorageUsageError = nil
            throw nextStorageUsageError
        }
        if suspendNextStorageUsage {
            suspendNextStorageUsage = false
            return try await withCheckedThrowingContinuation { continuation in
                storageUsageContinuation = continuation
            }
        }
        return storageUsageValue
    }

    func performStorageMaintenance(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        maintenanceCallCount += 1
        guard let maintenanceResult else {
            throw StorageMaintenanceError.unavailable
        }
        return maintenanceResult
    }

    func resumeStorageUsage(with result: Result<StorageUsageSnapshot, Error>) {
        let continuation = storageUsageContinuation
        storageUsageContinuation = nil
        continuation?.resume(with: result)
    }

    func publishExternal(_ settings: AppSettings) {
        current = settings
        changeContinuation?.yield(settings)
    }
}

private enum SettingsFeatureTestError: Error, Sendable {
    case write
    case reset
}

private func acceptedPrivacy(for providerIDs: [String]) -> PrivacyPreferences {
    providerIDs.reduce(PrivacyPreferences.defaults.acceptingPrivacyPolicy()) {
        $0.acceptingProviderPolicy($1)
    }
}

@MainActor
private final class SettingsAppIconTestProvider: SettingsAppIconProviding {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var nextError: Error?
    private(set) var requestedNames: [String?] = []

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        requestedNames.append(alternateIconName)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        self.alternateIconName = alternateIconName
    }
}

private actor SettingsMetadataEnrichmentTestService: MetadataEnrichmentServing {
    private var current: MetadataEnrichmentSnapshot
    private let requestedAuthorization: MetadataEnrichmentAuthorizationStatus
    private var continuation: AsyncStream<MetadataEnrichmentSnapshot>.Continuation?
    private(set) var enabledValues: [Bool] = []
    private(set) var providerPreferenceValues: [[MetadataProviderPreference]] = []
    private(set) var startScanCount = 0
    private(set) var cancelScanCount = 0

    init(
        authorization: MetadataEnrichmentAuthorizationStatus,
        requestedAuthorization: MetadataEnrichmentAuthorizationStatus? = nil
    ) {
        self.current = MetadataEnrichmentSnapshot(authorization: authorization)
        self.requestedAuthorization = requestedAuthorization ?? authorization
    }

    func snapshot() async -> MetadataEnrichmentSnapshot {
        current
    }

    func makeSnapshotStream() async -> AsyncStream<MetadataEnrichmentSnapshot> {
        let (stream, continuation) = AsyncStream<MetadataEnrichmentSnapshot>.makeStream()
        self.continuation = continuation
        continuation.yield(current)
        return stream
    }

    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        current = MetadataEnrichmentSnapshot(
            authorization: requestedAuthorization,
            scan: current.scan
        )
        continuation?.yield(current)
        return requestedAuthorization
    }

    func setEnabled(_ enabled: Bool) async {
        enabledValues.append(enabled)
        current = MetadataEnrichmentSnapshot(
            isEnabled: enabled && current.authorization == .authorized,
            authorization: current.authorization,
            scan: current.scan
        )
        continuation?.yield(current)
    }

    func setProviderPreferences(_ preferences: [MetadataProviderPreference]) async {
        providerPreferenceValues.append(preferences)
    }

    func enqueue(itemID: MediaItemID) async {}
    func startScan() async {
        startScanCount += 1
        current = MetadataEnrichmentSnapshot(
            isEnabled: current.isEnabled,
            authorization: current.authorization,
            scan: MetadataEnrichmentScanSnapshot(status: .scanning),
            activeProvider: current.activeProvider,
            providerStatuses: current.providerStatuses
        )
        continuation?.yield(current)
    }

    func cancelScan() async {
        cancelScanCount += 1
        let scan = current.scan
        current = MetadataEnrichmentSnapshot(
            isEnabled: current.isEnabled,
            authorization: current.authorization,
            scan: MetadataEnrichmentScanSnapshot(
                status: .cancelled,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed
            ),
            activeProvider: current.activeProvider,
            providerStatuses: current.providerStatuses
        )
        continuation?.yield(current)
    }

    func recordedEnabledValues() -> [Bool] {
        enabledValues
    }

    func recordedProviderPreferences() -> [[MetadataProviderPreference]] {
        providerPreferenceValues
    }

    func recordedScanCounts() -> (start: Int, cancel: Int) {
        (startScanCount, cancelScanCount)
    }
}

private actor SettingsLyricsTestService: LyricsServing {
    private let registeredProviderIDs: Set<LyricsProviderID>

    init(registeredProviderIDs: Set<LyricsProviderID>) {
        self.registeredProviderIDs = registeredProviderIDs
    }

    func registeredLyricsProviderIDs() async -> Set<LyricsProviderID> {
        registeredProviderIDs
    }

    func fetchLyrics(
        for _: LyricsQuery,
        forceRefresh _: Bool
    ) async throws -> TrackLyrics? {
        nil
    }
}

@MainActor
@Test("Settings loads, validates, and serializes a saved playback change")
func settingsFeatureLoadsAndSaves() async throws {
    let rate = try PlaybackRate(value: 1.5)
    let initial = AppSettings(
        playbackPreferences: PlaybackPreferences(rate: rate)
    )
    let store = SettingsFeatureTestStore(settings: initial)
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.settings == initial)
    #expect(viewModel.playbackCapabilities.contains(.variableRate))

    viewModel.setPlaybackRate(2.0)
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(viewModel.settings.playbackPreferences.rate.value == 2.0)
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Privacy consent enables providers and revocation closes them")
func settingsFeaturePrivacyConsentControlsOnlineProviders() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.acceptPrivacyPolicy()
    viewModel.acceptProviderPrivacy(for: MetadataProviderID.musicKit.rawValue)
    viewModel.setMetadataProviderEnabled(.musicKit, true)
    await viewModel.waitForPendingWork()

    #expect(viewModel.isPrivacyPolicyAccepted)
    #expect(viewModel.settings.importPreferences.isMetadataProviderEnabled(.musicKit))
    #expect(viewModel.settings.importPreferences.runtimeMetadataProviders.contains {
        $0.provider == .musicKit && $0.isEnabled
    })

    viewModel.revokeOnlinePrivacy()
    await viewModel.waitForPendingWork()

    #expect(!viewModel.isPrivacyPolicyAccepted)
    #expect(viewModel.settings.importPreferences.metadataProviders.allSatisfy { !$0.isEnabled })
    #expect(viewModel.settings.importPreferences.runtimeMetadataProviders.allSatisfy { !$0.isEnabled })
}

@MainActor
@Test("Debug privacy reset clears consent and disables every Provider")
func settingsFeatureDebugPrivacyResetClearsAllOnlineConsent() async {
    let initial = AppSettings(
        importPreferences: ImportPreferences(
            metadataProviders: [
                MetadataProviderPreference(provider: .musicKit, isEnabled: true),
                MetadataProviderPreference(provider: .musicBrainz, isEnabled: true)
            ],
            lyricsProviders: [
                LyricsProviderPreference(provider: .lrclib, isEnabled: true)
            ],
            privacyPreferences: acceptedPrivacy(
                for: [
                    MetadataProviderID.musicKit.rawValue,
                    MetadataProviderID.musicBrainz.rawValue,
                    LyricsProviderID.lrclib.rawValue
                ]
            )
        )
    )
    let store = SettingsFeatureTestStore(settings: initial)
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.resetAllPrivacy()
    await viewModel.waitForPendingWork()

    #expect(!viewModel.isPrivacyPolicyAccepted)
    #expect(viewModel.settings.importPreferences.metadataProviders.allSatisfy { !$0.isEnabled })
    #expect(viewModel.settings.importPreferences.lyricsProviders.allSatisfy { !$0.isEnabled })
    #expect(!viewModel.settings.importPreferences.privacyPreferences
        .isProviderPolicyAccepted(MetadataProviderID.musicKit.rawValue))
}

@MainActor
@Test("MusicKit metadata toggle persists only after authorization succeeds")
func settingsFeatureGatesMusicKitMetadataByAuthorization() async {
    let store = SettingsFeatureTestStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                privacyPreferences: acceptedPrivacy(
                    for: [MetadataProviderID.musicKit.rawValue]
                )
            )
        )
    )
    let service = SettingsMetadataEnrichmentTestService(
        authorization: .notDetermined,
        requestedAuthorization: .authorized
    )
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    viewModel.setMusicKitMetadataEnrichmentEnabled(true)
    await viewModel.waitForMetadataWork()
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings.importPreferences.useMusicKitMetadataEnrichment)
    #expect(store.savedValues.last?.importPreferences.useMusicKitMetadataEnrichment == true)
    #expect(await service.recordedEnabledValues().last == true)
    #expect((await service.snapshot()).isEnabled)
}

@MainActor
@Test("MusicKit metadata toggle remains off when authorization is denied")
func settingsFeatureDoesNotPersistUnauthorizedMusicKitMetadata() async {
    let store = SettingsFeatureTestStore()
    let service = SettingsMetadataEnrichmentTestService(
        authorization: .denied,
        requestedAuthorization: .denied
    )
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    viewModel.setMusicKitMetadataEnrichmentEnabled(true)
    await viewModel.waitForMetadataWork()
    await viewModel.waitForPendingWork()

    #expect(!viewModel.settings.importPreferences.useMusicKitMetadataEnrichment)
    #expect(store.savedValues.isEmpty)
    #expect(!(await service.snapshot()).isEnabled)
}

@MainActor
@Test("Metadata snapshot observation resumes for nested settings pages")
func settingsFeatureResumesMetadataObservationAfterNavigation() async throws {
    let store = SettingsFeatureTestStore()
    let service = SettingsMetadataEnrichmentTestService(authorization: .authorized)
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    viewModel.stopObservingChanges()
    await service.setEnabled(true)

    #expect(!viewModel.metadataEnrichmentSnapshot.isEnabled)

    viewModel.resumeMetadataObservation()
    for _ in 0..<50 {
        if viewModel.metadataEnrichmentSnapshot.isEnabled { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(viewModel.metadataEnrichmentSnapshot.isEnabled)
}

@MainActor
@Test("Metadata scan actions refresh the settings UI immediately")
func settingsFeatureMetadataScanActionsRefreshUI() async throws {
    let store = SettingsFeatureTestStore()
    let service = SettingsMetadataEnrichmentTestService(authorization: .authorized)
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    await service.setEnabled(true)
    viewModel.resumeMetadataObservation()
    for _ in 0..<50 {
        if viewModel.metadataEnrichmentSnapshot.isEnabled { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(viewModel.metadataEnrichmentSnapshot.isEnabled)

    viewModel.startMetadataScan()
    #expect(viewModel.metadataEnrichmentSnapshot.scan.status == .scanning)
    await viewModel.waitForMetadataScanWork()
    #expect(await service.recordedScanCounts().start == 1)

    viewModel.cancelMetadataScan()
    #expect(viewModel.metadataEnrichmentSnapshot.scan.status == .cancelled)
    await viewModel.waitForMetadataScanWork()
    #expect(await service.recordedScanCounts().cancel == 1)
    #expect(viewModel.metadataEnrichmentSnapshot.scan.status == .cancelled)
}

@MainActor
@Test("Settings preserves metadata provider enablement and order")
func settingsFeaturePreservesMetadataProviderPreferences() async {
    let store = SettingsFeatureTestStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                metadataProviders: [
                    MetadataProviderPreference(provider: .musicKit),
                    MetadataProviderPreference(provider: .metadataServer)
                ],
                privacyPreferences: acceptedPrivacy(
                    for: [
                        MetadataProviderID.musicKit.rawValue,
                        MetadataProviderID.metadataServer.rawValue
                    ]
                )
            )
        )
    )
    let service = SettingsMetadataEnrichmentTestService(authorization: .authorized)
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    viewModel.setMetadataProviderEnabled(.musicKit, true)
    await viewModel.waitForMetadataWork()
    await viewModel.waitForPendingWork()

    viewModel.setMetadataProviderEnabled(.metadataServer, true)
    await viewModel.waitForMetadataWork()
    await viewModel.waitForPendingWork()

    viewModel.moveMetadataProvider(at: 1, by: -1)
    await viewModel.waitForMetadataWork()
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings.importPreferences.metadataProviders.map(\.provider) == [
        .metadataServer,
        .musicKit
    ])
    #expect(viewModel.settings.importPreferences.metadataProviders.allSatisfy { $0.isEnabled })
    #expect(await service.recordedProviderPreferences().contains {
        $0.map(\.provider) == [.metadataServer, .musicKit]
    })

    viewModel.setDuplicateImportPolicy(.keepBoth)
    await viewModel.waitForPendingWork()
    #expect(viewModel.settings.importPreferences.duplicatePolicy == .keepBoth)
    #expect(viewModel.settings.importPreferences.metadataProviders.map(\.provider) == [
        .metadataServer,
        .musicKit
    ])
}

@MainActor
@Test("Settings reorders visible metadata providers around a hidden provider")
func settingsFeatureReordersVisibleMetadataProvidersAroundHiddenProvider() async {
    let store = SettingsFeatureTestStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                metadataProviders: [
                    MetadataProviderPreference(provider: .musicKit),
                    MetadataProviderPreference(provider: .metadataServer),
                    MetadataProviderPreference(provider: .discogs)
                ]
            )
        )
    )
    let service = SettingsMetadataEnrichmentTestService(authorization: .authorized)
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    viewModel.moveMetadataProviders(
        from: IndexSet(integer: 0),
        to: 2,
        within: [.musicKit, .discogs]
    )
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings.importPreferences.metadataProviders.map(\.provider) == [
        .discogs,
        .metadataServer,
        .musicKit
    ])
}

@MainActor
@Test("Settings persists independent lyrics provider switches")
func settingsFeaturePersistsLyricsProviderSwitches() async {
    let store = SettingsFeatureTestStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                lyricsProviders: [
                    LyricsProviderPreference(provider: .metadataServer, isEnabled: true),
                    LyricsProviderPreference(provider: .lrclib, isEnabled: true)
                ],
                privacyPreferences: acceptedPrivacy(
                    for: [
                        LyricsProviderID.metadataServer.rawValue,
                        LyricsProviderID.lrclib.rawValue
                    ]
                )
            )
        )
    )
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.hasEnabledLyricsProviders)
    #expect(viewModel.settings.importPreferences.isLyricsProviderEnabled(.metadataServer))
    #expect(viewModel.settings.importPreferences.isLyricsProviderEnabled(.lrclib))

    viewModel.setLyricsProviderEnabled(.metadataServer, false)
    await viewModel.waitForPendingWork()

    #expect(!viewModel.settings.importPreferences.isLyricsProviderEnabled(.metadataServer))
    #expect(viewModel.settings.importPreferences.isLyricsProviderEnabled(.lrclib))
    #expect(viewModel.hasEnabledLyricsProviders)
    #expect(!store.current.importPreferences.isLyricsProviderEnabled(.metadataServer))

    viewModel.setDuplicateImportPolicy(.keepBoth)
    await viewModel.waitForPendingWork()
    #expect(!viewModel.settings.importPreferences.isLyricsProviderEnabled(.metadataServer))
    #expect(viewModel.settings.importPreferences.isLyricsProviderEnabled(.lrclib))

    viewModel.setLyricsProviderEnabled(.lrclib, false)
    await viewModel.waitForPendingWork()
    #expect(!viewModel.hasEnabledLyricsProviders)

    viewModel.setLyricsProviderEnabled(.metadataServer, true)
    await viewModel.waitForPendingWork()
    #expect(viewModel.hasEnabledLyricsProviders)
    #expect(viewModel.settings.importPreferences.isLyricsProviderEnabled(.metadataServer))
    #expect(!viewModel.settings.importPreferences.isLyricsProviderEnabled(.lrclib))
    #expect(store.current.importPreferences.isLyricsProviderEnabled(.metadataServer))
}

@MainActor
@Test("Settings ignores enabled lyrics providers unavailable at runtime")
func settingsFeatureIgnoresUnavailableLyricsProviders() async {
    let store = SettingsFeatureTestStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                lyricsProviders: [
                    LyricsProviderPreference(provider: .metadataServer, isEnabled: true),
                    LyricsProviderPreference(provider: .lrclib, isEnabled: false)
                ]
            )
        )
    )
    let service = SettingsLyricsTestService(registeredProviderIDs: [.lrclib])
    let viewModel = SettingsViewModel(store: store, lyricsServing: service)

    await viewModel.load()

    #expect(!viewModel.hasEnabledLyricsProviders)
    #expect(!viewModel.canPreloadLyrics)
}

@MainActor
@Test("Resetting settings disables MusicKit metadata runtime")
func settingsFeatureResetDisablesMusicKitMetadataRuntime() async {
    let initial = AppSettings(
        importPreferences: ImportPreferences(
            useMusicKitMetadataEnrichment: true,
            privacyPreferences: acceptedPrivacy(
                for: [MetadataProviderID.musicKit.rawValue]
            )
        )
    )
    let store = SettingsFeatureTestStore(settings: initial)
    let service = SettingsMetadataEnrichmentTestService(authorization: .authorized)
    let viewModel = SettingsViewModel(store: store, metadataEnrichment: service)

    await viewModel.load()
    await viewModel.waitForMetadataWork()
    #expect((await service.snapshot()).isEnabled)

    viewModel.requestReset()
    await viewModel.confirmReset()
    await viewModel.waitForPendingWork()
    await viewModel.waitForMetadataWork()

    #expect(viewModel.settings == .defaults)
    #expect(!(await service.snapshot()).isEnabled)
    #expect(await service.recordedEnabledValues().last == false)
}

@MainActor
@Test("Playback rate dragging previews every step and saves only the final value")
func settingsFeatureCoalescesPlaybackRateDragging() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.beginPlaybackRateEditing()
    viewModel.updatePlaybackRateDraft(1.25)
    viewModel.updatePlaybackRateDraft(1.5)
    viewModel.updatePlaybackRateDraft(1.75)

    #expect(viewModel.displayedPlaybackRate == 1.75)
    #expect(viewModel.settings.playbackPreferences.rate == .normal)
    #expect(store.savedValues.isEmpty)

    viewModel.endPlaybackRateEditing()
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(store.savedValues.first?.playbackPreferences.rate.value == 1.75)
    #expect(viewModel.displayedPlaybackRate == 1.75)
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Settings saves automatic cache pruning changes")
func settingsFeatureSavesAutomaticCachePruning() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.setAutomaticallyPruneCache(false)
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(store.savedValues.first?.storagePreferences.automaticallyPruneCache == false)
    #expect(viewModel.settings.storagePreferences.automaticallyPruneCache == false)
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Cache limit uses feasible local capacity and saves only when dragging ends")
func settingsFeatureCoalescesCacheLimitDragging() async {
    let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    let store = SettingsFeatureTestStore()
    store.storageUsageValue = StorageUsageSnapshot(
        cacheBytes: 4 * gibibyte,
        availableBytes: 20 * gibibyte
    )
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()

    #expect(viewModel.maximumCacheLimitBytes == 24 * gibibyte)
    viewModel.beginCacheLimitEditing()
    viewModel.updateCacheLimitDraft(bytes: 12 * gibibyte)
    viewModel.updateCacheLimitDraft(bytes: 18 * gibibyte)
    viewModel.updateCacheLimitDraft(bytes: 128 * gibibyte)

    #expect(viewModel.displayedCacheLimitBytes == 24 * gibibyte)
    #expect(viewModel.settings.storagePreferences.cacheLimit == .fiveGiB)
    #expect(store.savedValues.isEmpty)

    viewModel.endCacheLimitEditing()
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(store.savedValues.first?.storagePreferences.cacheLimit.bytes == 24 * gibibyte)
    #expect(viewModel.displayedCacheLimitBytes == 24 * gibibyte)
    #expect(viewModel.mutationState == .saved)
}

@Test("Cache limit slider favors smaller values and formats whole units")
func cacheLimitSliderUsesNonlinearWholeUnitScale() {
    let gigabyte: Int64 = 1_000_000_000
    let maximumBytes = 100 * gigabyte

    let midpointBytes = CacheLimitSliderScale.bytes(
        for: 0.5,
        maximumBytes: maximumBytes
    )

    #expect(midpointBytes == 25 * gigabyte)
    #expect(CacheLimitSliderScale.position(
        for: midpointBytes,
        maximumBytes: maximumBytes
    ) < 0.51)
    #expect(CacheLimitSliderScale.text(for: 5 * 1_024 * 1_024 * 1_024) == "5 GB")
    #expect(CacheLimitSliderScale.text(for: StorageByteLimit.minimumBytes) == "67 MB")
}

@MainActor
@Test("Settings add, edit, preserve, and delete automatic sleep schedules")
func settingsFeatureEditsSleepTimerSchedules() async throws {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)
    let scheduleID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

    await viewModel.load()
    viewModel.addSleepTimerSchedule(id: scheduleID)
    await viewModel.waitForPendingWork()

    var schedule = try #require(
        viewModel.settings.playbackPreferences.sleepTimer.schedules.first
    )
    #expect(schedule.id == scheduleID)
    #expect(schedule.startMinute == 23 * 60)
    #expect(schedule.endMinute == 5 * 60)
    #expect(schedule.durationMinutes == 20)

    viewModel.setSleepTimerScheduleStartMinute(13 * 60, id: scheduleID)
    await viewModel.waitForPendingWork()
    viewModel.setSleepTimerScheduleEndMinute(14 * 60, id: scheduleID)
    await viewModel.waitForPendingWork()
    viewModel.setSleepTimerScheduleDuration(30, id: scheduleID)
    await viewModel.waitForPendingWork()
    viewModel.setSleepTimerScheduleEnabled(false, id: scheduleID)
    await viewModel.waitForPendingWork()
    viewModel.setPlaybackRate(1.5)
    await viewModel.waitForPendingWork()

    schedule = try #require(
        viewModel.settings.playbackPreferences.sleepTimer.schedules.first
    )
    #expect(schedule.startMinute == 13 * 60)
    #expect(schedule.endMinute == 14 * 60)
    #expect(schedule.durationMinutes == 30)
    #expect(!schedule.isEnabled)
    #expect(viewModel.settings.playbackPreferences.rate.value == 1.5)

    viewModel.deleteSleepTimerSchedule(id: scheduleID)
    await viewModel.waitForPendingWork()
    #expect(viewModel.settings.playbackPreferences.sleepTimer.schedules.isEmpty)
}

@MainActor
@Test("Settings keeps advanced user intent editable when playback capabilities are unavailable")
func settingsFeatureKeepsUnsupportedPreferences() async throws {
    let store = SettingsFeatureTestStore(playbackCapabilities: [])
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(!viewModel.supportsEqualizer)
    #expect(!viewModel.supportsVariableRate)
    #expect(!viewModel.supportsReplayGain)
    #expect(!viewModel.supportsGapless)
    #expect(!viewModel.supportsCrossfade)

    viewModel.setPlaybackRate(1.5)
    await viewModel.waitForPendingWork()
    viewModel.setEqualizerEnabled(true)
    await viewModel.waitForPendingWork()
    viewModel.setEqualizerPreamp(3.5)
    await viewModel.waitForPendingWork()
    viewModel.setReplayGain(.album)
    await viewModel.waitForPendingWork()
    viewModel.setGaplessPlaybackEnabled(false)
    await viewModel.waitForPendingWork()
    viewModel.setCrossfadeDuration(.seconds(4))
    await viewModel.waitForPendingWork()
    viewModel.setDuplicateImportPolicy(.keepBoth)
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings.playbackPreferences.equalizer.isEnabled)
    #expect(viewModel.settings.playbackPreferences.rate.value == 1.5)
    #expect(viewModel.settings.playbackPreferences.equalizer.preamp.decibels == 3.5)
    #expect(viewModel.settings.playbackPreferences.replayGain == .album)
    #expect(!viewModel.settings.playbackPreferences.transition.gaplessPlaybackEnabled)
    #expect(viewModel.settings.playbackPreferences.transition.crossfadeDuration == .seconds(4))
    #expect(viewModel.settings.importPreferences.duplicatePolicy == .keepBoth)
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Settings saves gains for every runtime VLC equalizer band")
func settingsFeatureSavesRuntimeEqualizerBands() async throws {
    let descriptor = EqualizerDescriptor(
        bands: [
            EqualizerBandDescriptor(
                centerFrequencyHz: 60,
                minimumGainDecibels: -20,
                maximumGainDecibels: 20
            ),
            EqualizerBandDescriptor(
                centerFrequencyHz: 1_000,
                minimumGainDecibels: -20,
                maximumGainDecibels: 20
            )
        ],
        minimumPreampDecibels: -20,
        maximumPreampDecibels: 20
    )
    let store = SettingsFeatureTestStore(
        playbackCapabilities: [.equalizer],
        equalizerDescriptor: descriptor
    )
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.supportsEqualizer)
    #expect(viewModel.equalizerBands == descriptor.bands)

    viewModel.setEqualizerEnabled(true)
    await viewModel.waitForPendingWork()
    viewModel.setEqualizerGain(4.5, for: descriptor.bands[1])
    await viewModel.waitForPendingWork()

    let bands = viewModel.settings.playbackPreferences.equalizer.bands
    #expect(bands.map(\.frequencyHz) == [60, 1_000])
    #expect(bands.map(\.gain.decibels) == [0, 4.5])
    #expect(store.savedValues.count == 2)
}

@MainActor
@Test("Equalizer dragging previews every step and saves once per gesture")
func settingsFeatureCoalescesEqualizerDragging() async throws {
    let bands = [
        EqualizerBandDescriptor(
            centerFrequencyHz: 60,
            minimumGainDecibels: -20,
            maximumGainDecibels: 20
        ),
        EqualizerBandDescriptor(
            centerFrequencyHz: 1_000,
            minimumGainDecibels: -20,
            maximumGainDecibels: 20
        )
    ]
    let descriptor = EqualizerDescriptor(
        bands: bands,
        minimumPreampDecibels: -20,
        maximumPreampDecibels: 20
    )
    let equalizer = try EqualizerPreferences(isEnabled: true)
    let initial = AppSettings(
        playbackPreferences: PlaybackPreferences(equalizer: equalizer)
    )
    let store = SettingsFeatureTestStore(
        settings: initial,
        playbackCapabilities: [.equalizer],
        equalizerDescriptor: descriptor
    )
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.beginEqualizerPreampEditing()
    viewModel.updateEqualizerPreampDraft(0.5)
    viewModel.updateEqualizerPreampDraft(1)
    viewModel.updateEqualizerPreampDraft(1.5)

    #expect(viewModel.displayedEqualizerPreamp == 1.5)
    #expect(viewModel.settings.playbackPreferences.equalizer.preamp == .zero)
    #expect(store.savedValues.isEmpty)

    viewModel.endEqualizerPreampEditing()
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(store.savedValues.last?.playbackPreferences.equalizer.preamp.decibels == 1.5)

    viewModel.beginEqualizerGainEditing(for: bands[1])
    viewModel.updateEqualizerGainDraft(2, for: bands[1])
    viewModel.updateEqualizerGainDraft(3, for: bands[1])
    viewModel.updateEqualizerGainDraft(4.5, for: bands[1])

    #expect(viewModel.equalizerGain(for: bands[1]) == 4.5)
    #expect(viewModel.settings.playbackPreferences.equalizer.bands.isEmpty)
    #expect(store.savedValues.count == 1)

    viewModel.endEqualizerGainEditing(for: bands[1])
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 2)
    #expect(store.savedValues.last?.playbackPreferences.equalizer.bands.map(\.gain.decibels) == [0, 4.5])
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Settings applies runtime VLC presets and recognizes later custom edits")
func settingsFeatureAppliesRuntimeEqualizerPreset() async throws {
    let bands = [
        EqualizerBandDescriptor(
            centerFrequencyHz: 60,
            minimumGainDecibels: -20,
            maximumGainDecibels: 20
        ),
        EqualizerBandDescriptor(
            centerFrequencyHz: 1_000,
            minimumGainDecibels: -20,
            maximumGainDecibels: 20
        )
    ]
    let presetConfiguration = EqualizerConfiguration(
        preampDecibels: 1,
        bandGains: [
            EqualizerBandGain(centerFrequencyHz: 60, gainDecibels: -2),
            EqualizerBandGain(centerFrequencyHz: 1_000, gainDecibels: 4)
        ]
    )
    let descriptor = EqualizerDescriptor(
        bands: bands,
        minimumPreampDecibels: -20,
        maximumPreampDecibels: 20,
        presets: [
            EqualizerPresetDescriptor(
                id: 7,
                name: "Rock",
                configuration: presetConfiguration
            )
        ]
    )
    let store = SettingsFeatureTestStore(
        playbackCapabilities: [.equalizer],
        equalizerDescriptor: descriptor
    )
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.setEqualizerEnabled(true)
    await viewModel.waitForPendingWork()
    viewModel.applyEqualizerPreset(id: 7)
    await viewModel.waitForPendingWork()

    #expect(viewModel.selectedEqualizerPresetID == 7)
    #expect(viewModel.settings.playbackPreferences.equalizer.preamp.decibels == 1)
    #expect(viewModel.settings.playbackPreferences.equalizer.bands.map(\.gain.decibels) == [-2, 4])

    viewModel.setEqualizerGain(3, for: bands[1])
    await viewModel.waitForPendingWork()
    #expect(viewModel.selectedEqualizerPresetID == nil)
}

@MainActor
@Test("Settings rejects an out-of-range rate before calling the store")
func settingsFeatureValidatesBeforeSave() async throws {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.setPlaybackRate(PlaybackRate.maximumValue + 1)
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.isEmpty)
    #expect(viewModel.settings == .defaults)
    if case .failed(let failure) = viewModel.mutationState {
        #expect(failure.diagnosticCode.contains("playback.rate"))
    } else {
        Issue.record("Expected a validation failure")
    }
}

@MainActor
@Test("A failed optimistic save rolls settings back to the committed value")
func settingsFeatureRollsBackFailedSave() async throws {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    store.nextSaveError = SettingsError.writeFailed
    viewModel.setPlaybackRate(1.75)

    #expect(viewModel.settings.playbackPreferences.rate.value == 1.75)
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings == .defaults)
    if case .failed(let failure) = viewModel.mutationState {
        #expect(failure.diagnosticCode == SettingsError.writeFailed.description)
        #expect(failure.isRetryable)
    } else {
        Issue.record("Expected a failed mutation state")
    }

    #expect(viewModel.canRetryFailedSave)
    viewModel.retryFailedSave()
    await viewModel.waitForPendingWork()

    #expect(store.savedValues.count == 1)
    #expect(store.savedValues.first?.playbackPreferences.rate.value == 1.75)
    #expect(viewModel.settings.playbackPreferences.rate.value == 1.75)
    #expect(viewModel.mutationState == .saved)
    #expect(!viewModel.canRetryFailedSave)
}

@MainActor
@Test("Repeated storage refreshes share one request and expose in-flight state")
func settingsFeatureSerializesStorageRefresh() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)
    await viewModel.load()
    let initialCallCount = store.storageUsageCallCount

    let refreshed = StorageUsageSnapshot(managedMediaBytes: 42)
    store.suspendNextStorageUsage = true
    let first = Task { await viewModel.refreshStorageUsage() }
    await settleSettingsFeature()
    #expect(viewModel.isRefreshingStorage)

    let second = Task { await viewModel.refreshStorageUsage() }
    await settleSettingsFeature()
    #expect(store.storageUsageCallCount == initialCallCount + 1)

    store.resumeStorageUsage(with: .success(refreshed))
    await first.value
    await second.value

    #expect(viewModel.storageUsage == refreshed)
    #expect(!viewModel.isRefreshingStorage)
}

@MainActor
@Test("Storage refresh reports failure after the request finishes")
func settingsFeatureReportsStorageRefreshFailure() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)
    await viewModel.load()

    store.nextStorageUsageError = StorageMaintenanceError.failed
    let succeeded = await viewModel.refreshStorageUsage()

    #expect(!succeeded)
    #expect(viewModel.storageUsage == nil)
    #expect(!viewModel.isRefreshingStorage)
}

@MainActor
@Test("Storage maintenance invalidates an older refresh result")
func settingsFeatureFencesStorageRefreshBeforeMaintenance() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)
    await viewModel.load()

    let stale = StorageUsageSnapshot(managedMediaBytes: 10)
    let maintained = StorageUsageSnapshot(managedMediaBytes: 8)
    store.maintenanceResult = StorageMaintenanceResult(
        usageBefore: stale,
        usageAfter: maintained,
        freedBytes: 2
    )
    store.suspendNextStorageUsage = true

    let refresh = Task { await viewModel.refreshStorageUsage() }
    await settleSettingsFeature()
    let maintenance = Task {
        await viewModel.performStorageMaintenance([.clearImportStaging])
    }
    await settleSettingsFeature()

    store.resumeStorageUsage(with: .success(stale))
    await refresh.value
    await maintenance.value

    #expect(store.maintenanceCallCount == 1)
    #expect(viewModel.storageUsage == maintained)
    #expect(viewModel.maintenanceState == .completed(store.maintenanceResult!))
    #expect(!viewModel.isRefreshingStorage)
}

@MainActor
@Test("Reset requires confirmation and restores defaults through the store")
func settingsFeatureResetsAfterConfirmation() async throws {
    let rate = try PlaybackRate(value: 1.25)
    let initial = AppSettings(
        importPreferences: ImportPreferences(duplicatePolicy: .keepBoth),
        playbackPreferences: PlaybackPreferences(rate: rate)
    )
    let store = SettingsFeatureTestStore(settings: initial)
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.requestReset()
    #expect(viewModel.isResetConfirmationPresented)
    await viewModel.confirmReset()
    await viewModel.waitForPendingWork()

    #expect(store.resetCount == 1)
    #expect(viewModel.settings == AppSettings.defaults)
    #expect(viewModel.mutationState == SettingsFeatureMutationState.saved)
}

@MainActor
@Test("A failed settings load resets only after confirmation and reloads defaults")
func settingsFeatureRecoversFailedLoadWithConfirmedReset() async throws {
    let rate = try PlaybackRate(value: 1.5)
    let store = SettingsFeatureTestStore(
        settings: AppSettings(playbackPreferences: PlaybackPreferences(rate: rate))
    )
    store.nextLoadError = SettingsError.decoding
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.loadState.failure?.diagnosticCode == SettingsError.decoding.description)
    #expect(store.resetCount == 0)

    viewModel.requestReset()
    #expect(viewModel.isResetConfirmationPresented)
    viewModel.cancelReset()
    #expect(store.resetCount == 0)
    #expect(viewModel.loadState.failure != nil)

    viewModel.requestReset()
    await viewModel.confirmReset()

    #expect(store.resetCount == 1)
    #expect(store.loadCount == 2)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.settings == .defaults)
}

@MainActor
@Test("External settings changes apply while self-write echoes are deduplicated")
func settingsFeatureConsumesExternalChanges() async throws {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)
    await viewModel.load()

    viewModel.setPlaybackRate(1.5)
    await viewModel.waitForPendingWork()
    await settleSettingsFeature()
    #expect(store.savedValues.count == 1)
    #expect(viewModel.mutationState == .saved)

    let externalRate = try PlaybackRate(value: 0.75)
    let external = AppSettings(
        playbackPreferences: PlaybackPreferences(rate: externalRate)
    )
    store.publishExternal(external)
    await settleSettingsFeature()

    #expect(viewModel.settings == external)
    #expect(viewModel.mutationState == .saved)
    #expect(store.savedValues.count == 1)
}

@Test("Dependency license metadata preserves bundled release evidence")
func dependencyLicenseMetadataRoundTrips() throws {
    let dependency = SettingsDependencyLicense(
        id: "vlckit-binary",
        name: "VLCKit / libVLC binary",
        version: "4.0.0-alpha.20260805.1123",
        license: "LGPL-2.1-or-later",
        kind: .binary,
        licenseFile: "VLCKit-LGPL-2.1.txt",
        licenseText: "GNU LESSER GENERAL PUBLIC LICENSE",
        revision: "818aca0e9cd605c69a3a5670c2ae662b1ca0783e",
        checksum: "a8bd5703c324ed8e7c39241c6d091c56e99f13cf585b42fbeb0d4c6523f9386f"
    )

    let data = try JSONEncoder().encode(dependency)
    let decoded = try JSONDecoder().decode(SettingsDependencyLicense.self, from: data)

    #expect(decoded == dependency)
    #expect(decoded.licenseText?.contains("GENERAL PUBLIC LICENSE") == true)
}

@MainActor
@Test("App icon selection reflects the icon accepted by the system provider")
func appIconSelectionUpdatesAfterSuccess() async {
    let provider = SettingsAppIconTestProvider()
    let viewModel = AppIconSettingsViewModel(provider: provider)
    let option = SettingsAppIconOption(
        id: "circle",
        title: "Circle",
        alternateIconName: "AppIcon-cicle",
        previewAssetName: "preview"
    )

    await viewModel.select(option)

    #expect(provider.requestedNames.count == 1)
    #expect(provider.requestedNames[0] == "AppIcon-cicle")
    #expect(viewModel.isSelected(option))
    #expect(viewModel.failureMessage == nil)
}

@MainActor
@Test("App icon selection keeps the current icon when the system rejects a change")
func appIconSelectionRollsBackAfterFailure() async {
    let provider = SettingsAppIconTestProvider()
    provider.nextError = SettingsFeatureTestError.write
    let viewModel = AppIconSettingsViewModel(provider: provider)
    let option = SettingsAppIconOption(
        id: "music",
        title: "Music",
        alternateIconName: "AppIcon-music",
        previewAssetName: "preview"
    )

    await viewModel.select(option)

    #expect(provider.alternateIconName == nil)
    #expect(!viewModel.isSelected(option))
    #expect(viewModel.failureMessage != nil)
}

private func settleSettingsFeature() async {
    try? await Task.sleep(nanoseconds: 20_000_000)
    await Task.yield()
}
