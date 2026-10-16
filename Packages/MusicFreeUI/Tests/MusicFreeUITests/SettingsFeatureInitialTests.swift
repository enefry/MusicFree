@testable import BuiltinPluginSettings
@testable import SettingsFeature
import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing
import UIKit
import MusicFreePluginAPI

@MainActor
private final class SettingsFeatureTestStore: SettingsFeatureStore {
    var normalize: ((AppSettings) -> AppSettings)?
    var current: AppSettings
    var playbackCapabilities: PlaybackCapabilities
    var equalizerDescriptor: EqualizerDescriptor?
    var systemCapabilities: SystemIntegrationCapabilitySnapshot
    var savedValues: [AppSettings] = []
    var loadCount = 0
    var resetCount = 0
    var nextLoadError: Error?
    var nextSaveError: Error?
    var suspendNextSave = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    var isSaveSuspended: Bool { saveContinuation != nil }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
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
        if suspendNextSave {
            suspendNextSave = false
            await withCheckedContinuation { saveContinuation = $0 }
        }
        if let nextSaveError {
            self.nextSaveError = nil
            throw nextSaveError
        }
        current = normalize?(settings) ?? settings
        savedValues.append(settings)
        changeContinuation?.yield(current)
        if normalize != nil { await Task.yield() }
    }

    func reset() async throws {
        if let nextResetError {
            self.nextResetError = nil
            throw nextResetError
        }
        resetCount += 1
        current = normalize?(.defaults) ?? .defaults
        changeContinuation?.yield(current)
        if normalize != nil { await Task.yield() }
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
@Test("File logging toggle persists and survives unrelated settings changes")
func settingsFeaturePersistsFileLoggingToggle() async {
    let store = SettingsFeatureTestStore()
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    viewModel.setFileLoggingEnabled(true)
    await viewModel.waitForPendingWork()
    await settleSettingsFeature()

    #expect(viewModel.isFileLoggingEnabled)
    #expect(store.current.loggingPreferences.isFileLoggingEnabled)

    viewModel.setReplayGain(.track)
    await viewModel.waitForPendingWork()
    await settleSettingsFeature()

    #expect(viewModel.isFileLoggingEnabled)
    #expect(store.current.loggingPreferences.isFileLoggingEnabled)
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
        requestedAuthorization: MetadataEnrichmentAuthorizationStatus? = nil,
        providerStatuses: [MetadataEnrichmentProviderSnapshot] = []
    ) {
        self.current = MetadataEnrichmentSnapshot(authorization: authorization, providerStatuses: providerStatuses)
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
            scan: current.scan,
            providerStatuses: current.providerStatuses
        )
        continuation?.yield(current)
        return requestedAuthorization
    }

    func setEnabled(_ enabled: Bool) async {
        enabledValues.append(enabled)
        current = MetadataEnrichmentSnapshot(
            isEnabled: enabled && current.authorization == .authorized,
            authorization: current.authorization,
            scan: current.scan,
            providerStatuses: current.providerStatuses
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

private actor SettingsPluginVisibilityTestService: SettingsServing, PluginServing {
    private var current: AppSettings
    private let values: [PluginSnapshot]
    init(settings: AppSettings, snapshots: [PluginSnapshot]) {
        current = settings; values = snapshots
    }
    func load() -> AppSettings { current }
    func update(_ settings: AppSettings) { current = settings }
    func reset() { current = .defaults }
    func effective() -> EffectivePlaybackSettings {
        .init(settings: current, effects: .neutral, playbackCapabilities: [], systemCapabilities: .init())
    }
    func makeChangeStream() -> AsyncStream<AppSettings> { AsyncStream { $0.finish() } }
    func apply(_ settings: AppSettings) { current = settings }
    func snapshots() -> [PluginSnapshot] { values }
    func stop() {}
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
@Test("Provider privacy revocation disables matching metadata and lyrics providers")
func settingsFeatureProviderPrivacyRevocationDisablesMatchingProviders() async {
    let providerID = MetadataProviderID.metadataServer.rawValue
    let initial = AppSettings(
        importPreferences: ImportPreferences(
            metadataProviders: [
                MetadataProviderPreference(provider: .metadataServer, isEnabled: true)
            ],
            lyricsProviders: [
                LyricsProviderPreference(provider: .metadataServer, isEnabled: true)
            ],
            privacyPreferences: acceptedPrivacy(for: [providerID])
        )
    )
    let store = SettingsFeatureTestStore(settings: initial)
    let viewModel = SettingsViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.settings.importPreferences.runtimeMetadataProviders.first?.isEnabled == true)
    #expect(viewModel.settings.importPreferences.runtimeLyricsProviders.first?.isEnabled == true)

    viewModel.revokeProviderPrivacy(for: providerID)
    await viewModel.waitForPendingWork()

    #expect(!viewModel.settings.importPreferences.isMetadataProviderEnabled(.metadataServer))
    #expect(!viewModel.settings.importPreferences.isLyricsProviderEnabled(.metadataServer))
    #expect(!viewModel.settings.importPreferences.privacyPreferences
        .isProviderPolicyAccepted(providerID))
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
    #expect(!viewModel.supportsFade)

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
    viewModel.setCrossfadeDuration(.seconds(3))
    await viewModel.waitForPendingWork()
    viewModel.setDuplicateImportPolicy(.keepBoth)
    await viewModel.waitForPendingWork()

    #expect(viewModel.settings.playbackPreferences.equalizer.isEnabled)
    #expect(viewModel.settings.playbackPreferences.rate.value == 1.5)
    #expect(viewModel.settings.playbackPreferences.equalizer.preamp.decibels == 3.5)
    #expect(viewModel.settings.playbackPreferences.replayGain == .album)
    #expect(!viewModel.settings.playbackPreferences.transition.gaplessPlaybackEnabled)
    #expect(viewModel.settings.playbackPreferences.transition.crossfadeDuration == .seconds(3))
    #expect(viewModel.settings.importPreferences.duplicatePolicy == .keepBoth)
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Suite struct SettingsBoundarySilenceTests {
    @Test("Smart mode retains its cap and intent across disabling, saving, and reopening")
    func smartCrossfadePersistsAndDisplaysCap() async throws {
        let store = SettingsFeatureTestStore(playbackCapabilities: [.fade, .gapless, .crossfade, .boundarySilenceSkipping, .smartCrossfade])
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model).child(.transitions)
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.playback.smartCrossfade"]?.enabled == false)
        controller.rows["settings.playback.crossfade"]?.action?()
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        guard case .toggle(_, let enable) = controller.rows["settings.playback.smartCrossfade"]?.control else {
            Issue.record("Missing smart transition control"); return
        }
        enable(true)
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        model.viewModel.setCrossfadeDuration(.seconds(12))
        model.viewModel.setFadeDuration(.milliseconds(120), isFadeIn: false)
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        #expect(store.current.playbackPreferences.transition.smartCrossfadeEnabled)
        #expect(!store.current.playbackPreferences.transition.skipBoundarySilence)
        if case .toggle(let effective, _) = controller.rows["settings.playback.skipBoundarySilence"]?.control {
            #expect(effective)
        } else { Issue.record("Missing effective silence state") }
        #expect(controller.rows["settings.playback.skipBoundarySilence"]?.enabled == false)
        #expect(controller.rows["settings.playback.crossfadeDuration"]?.title == L("最长过渡时长"))
        #expect(controller.rows["settings.playback.crossfade"]?.trailingValue == String(format: L("自动 · 最长 %.1f s"), 12.0))
        model.viewModel.setSongTransition(gaplessEnabled: false, crossfadeDuration: .zero)
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        #expect(store.current.playbackPreferences.transition.smartCrossfadeEnabled)
        #expect(controller.rows["settings.playback.smartCrossfade"]?.enabled == false)
        #expect(controller.rows["settings.playback.skipBoundarySilence"]?.enabled == true)
        if case .toggle(let effective, _) = controller.rows["settings.playback.skipBoundarySilence"]?.control { #expect(!effective) }
        model.viewModel.setSongTransition(gaplessEnabled: false, crossfadeDuration: .seconds(12))
        await model.viewModel.waitForPendingWork()
        let reopened = SettingsViewModel(store: store)
        await reopened.load()
        defer { reopened.stopObservingChanges() }
        #expect(reopened.settings.playbackPreferences.transition.smartCrossfadeEnabled)
        let unsupported = SettingsViewModel(store: SettingsFeatureTestStore())
        #expect(!unsupported.supportsSmartCrossfade)
    }

    @Test("Silence skipping survives independent transition edits and a 12-second crossfade")
    func settingsFeaturePreservesSilenceSkipping() async throws {
        let store = SettingsFeatureTestStore(playbackCapabilities: [.fade, .gapless, .crossfade, .boundarySilenceSkipping])
        let viewModel = SettingsViewModel(store: store)
        await viewModel.load()
        #expect(viewModel.supportsBoundarySilenceSkipping)
        viewModel.setSongTransition(gaplessEnabled: true, crossfadeDuration: .zero, skipBoundarySilence: true)
        await viewModel.waitForPendingWork()
        viewModel.setCrossfadeDuration(.seconds(12))
        await viewModel.waitForPendingWork()
        viewModel.setFadeDuration(.seconds(1), isFadeIn: true)
        await viewModel.waitForPendingWork()
        viewModel.setGaplessPlaybackEnabled(false)
        await viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.transition.skipBoundarySilence)
        #expect(store.current.playbackPreferences.transition.crossfadeDuration == .seconds(12))
        viewModel.setSongTransition(gaplessEnabled: false, crossfadeDuration: .zero)
        await viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.transition.skipBoundarySilence)
    }

}

@MainActor
@Test("Settings persists fade controls independently from crossfade and gapless")
func settingsFeatureEditsIndependentTransitionDurations() async throws {
    let store = SettingsFeatureTestStore(playbackCapabilities: [.fade, .gapless, .crossfade])
    let viewModel = SettingsViewModel(store: store)
    await viewModel.load()
    viewModel.setFadeDuration(.seconds(3), isFadeIn: true)
    await viewModel.waitForPendingWork()
    viewModel.setFadeDuration(.seconds(1), isFadeIn: false)
    await viewModel.waitForPendingWork()
    viewModel.setCrossfadeDuration(.seconds(2))
    await viewModel.waitForPendingWork()
    viewModel.setGaplessPlaybackEnabled(false)
    await viewModel.waitForPendingWork()
    #expect(store.current.playbackPreferences.transition == (try TransitionPreferences(
        gaplessPlaybackEnabled: false, crossfadeDuration: .seconds(2),
        fadeInDuration: .seconds(3), fadeOutDuration: .seconds(1))))

    viewModel.setFadeDuration(.zero, isFadeIn: true)
    await viewModel.waitForPendingWork()
    viewModel.setCrossfadeDuration(.zero)
    await viewModel.waitForPendingWork()
    #expect(store.current.playbackPreferences.transition == (try TransitionPreferences(
        gaplessPlaybackEnabled: false, crossfadeDuration: .zero,
        fadeInDuration: .zero, fadeOutDuration: .seconds(1))))
    #expect(viewModel.mutationState == .saved)
}

@MainActor
@Test("Settings saves gains for every runtime equalizer band")
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
@Test("Settings applies runtime equalizer presets and recognizes later custom edits")
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
        id: "ffmpeg-audio",
        name: "FFmpeg audio libraries",
        version: "8.1.2",
        license: "LGPL-2.1-or-later",
        kind: .binary,
        licenseFile: "FFmpegAudio/COPYING.LGPLv2.1",
        licenseText: "GNU LESSER GENERAL PUBLIC LICENSE",
        revision: nil,
        checksum: "1c65e5ec6be5329fc632847f914e602aa33cc1fd53908f0a498150a26fb2c9f8"
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

@Test @MainActor func settingsFeatureRebasesNormalizedPluginEchoBeforeNextSave() async throws {
    let id = PluginID(rawValue: "builtin.dsp.equalizer")
    let store = SettingsFeatureTestStore()
    store.normalize = { settings in
        settings.settingPluginPreferences([.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
            configuration: ["preamp": .number(settings.playbackPreferences.equalizer.preamp.decibels)])])
    }
    let descriptor = EqualizerDescriptor(bands: [.init(centerFrequencyHz: 500, minimumGainDecibels: -12, maximumGainDecibels: 12)])
    store.playbackCapabilities = [.equalizer]; store.equalizerDescriptor = descriptor
    let model = SettingsViewModel(store: store)
    await model.load()
    model.setEqualizerPreamp(2)
    await model.waitForPendingWork(); await settleSettingsFeature()
    #expect(model.mutationState == .saved)
    #expect(model.settings.pluginPreferences.first?.configuration["preamp"] == .number(2))
    model.setEqualizerPreamp(4)
    await model.waitForPendingWork(); await settleSettingsFeature()
    #expect(model.mutationState == .saved)
    #expect(model.settings.pluginPreferences.first?.configuration["preamp"] == .number(4))
    #expect(store.savedValues.last?.pluginPreferences.first?.configuration["preamp"] == .number(2))
    #expect(model.settings == store.current)
}

@Test @MainActor func settingsFeatureRetainsPluginDefaultsFromNormalizedResetEcho() async throws {
    let id = PluginID(rawValue: "builtin.dsp.equalizer")
    let store = SettingsFeatureTestStore(settings: .init(playbackPreferences: .init(rate: try .init(value: 1.5))))
    store.normalize = { $0.settingPluginPreferences([.init(pluginID: id, isLoadAllowed: true)]) }
    let model = SettingsViewModel(store: store)
    await model.load()
    model.requestReset(); await model.confirmReset()
    await model.waitForPendingWork(); await settleSettingsFeature()
    #expect(model.mutationState == .saved)
    #expect(model.settings.playbackPreferences.rate == .normal)
    #expect(model.settings.pluginPreferences.first?.pluginID == id)
    #expect(model.settings == store.current)
}


@Suite(.serialized)
@MainActor
struct NativeSettingsPresentationTests {
    @Test("Playback rate disclosure preserves its expanded state across saves")
    func playbackRateDisclosure() async {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model, layout: .detail(.playback))
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.playback.rate"] == nil)
        controller.rows["settings.playback.rate.expand"]?.action?()
        #expect(controller.rows["settings.playback.rate"] != nil)
        model.viewModel.setPlaybackRate(1.5)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(controller.rows["settings.playback.rate.expand"]?.trailingValue == "1.5x")
        #expect(controller.isPlaybackRateExpanded)
        controller.rows["settings.playback.rate.expand"]?.action?()
        #expect(controller.rows["settings.playback.rate"] == nil)
    }

    @Test("Icon selection moves the trailing checkmark after success and preserves it on failure")
    func iconTrailingSelection() async {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let provider = SettingsAppIconTestProvider()
        let controller = SettingsViewController(model: model, appIconOptions: [
            .init(id: "default", title: "Default", alternateIconName: nil, previewAssetName: ""),
            .init(id: "alternate", title: "Alternate", alternateIconName: "alternate", previewAssetName: "")
        ], appIconProvider: provider).child(.icons)
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.icon.default"]?.isSelected == true)
        controller.rows["settings.icon.alternate"]?.action?()
        await settleSettingsFeature()
        #expect(controller.rows["settings.icon.default"]?.isSelected == false)
        #expect(controller.rows["settings.icon.alternate"]?.isSelected == true)
        #expect(controller.rows["settings.icon.alternate"]?.detail == "")
        #expect(controller.rows["settings.icon.alternate"]?.trailingValue.isEmpty == false)
        provider.nextError = SettingsFeatureTestError.write
        controller.rows["settings.icon.default"]?.action?()
        await settleSettingsFeature()
        #expect(controller.rows["settings.icon.alternate"]?.isSelected == true)
    }

    @Test("Root refresh reflects the selected icon and storage opens a dedicated page")
    func selectedRootIconAndStorageNavigation() async throws {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let provider = SettingsAppIconTestProvider()
        let root = SettingsViewController(model: model, appIconOptions: [
            .init(id: "default", title: "Default", alternateIconName: nil, previewAssetName: ""),
            .init(id: "alternate", title: "Alternate", alternateIconName: "alternate", previewAssetName: "")
        ], appIconProvider: provider)
        let navigation = UINavigationController(rootViewController: root)
        root.loadViewIfNeeded()
        #expect(root.rows["settings.appIcon"]?.trailingValue == "Default")
        provider.alternateIconName = "alternate"
        root.viewWillAppear(false)
        #expect(root.rows["settings.appIcon"]?.trailingValue == "Alternate")
        #expect(root.rows["settings.language"]?.image != nil)
        #expect(root.rows["settings.appearance"]?.image != nil)
        #expect(root.rows["settings.playback.rate.expand"]?.image != nil)
        #expect(root.rows["storage.media"] == nil)
        root.rows["settings.storage.status"]?.action?()
        let storage = try #require(navigation.topViewController as? SettingsViewController)
        storage.loadViewIfNeeded()
        #expect(storage.tableView.accessibilityIdentifier == "settings.storage.status.form")
        #expect(storage.rows["settings.storage.maintenance"] != nil)
        store.storageUsageValue = .init(managedMediaBytes: 42)
        storage.viewWillAppear(false); await settleSettingsFeature()
        #expect(model.viewModel.storageUsage?.managedMediaBytes == 42)
        #expect(storage.rows["storage.media"] != nil)
        store.storageUsageValue = .init(managedMediaBytes: 84)
        storage.viewWillAppear(false); await settleSettingsFeature()
        #expect(model.viewModel.storageUsage?.managedMediaBytes == 84)
    }

    @Test("Native metadata reordering confines moves to provider rows and persists around hidden providers")
    func nativeMetadataReordering() async throws {
        let store = SettingsFeatureTestStore(settings: .init(importPreferences: .init(metadataProviders: [
            .init(provider: .musicKit), .init(provider: .metadataServer), .init(provider: .musicBrainz), .init(provider: .discogs)
        ])))
        let service = SettingsMetadataEnrichmentTestService(authorization: .authorized,
            providerStatuses: store.current.importPreferences.metadataProviders.map {
                .init(provider: $0.provider, isRegistered: true, authorization: .authorized)
            })
        let model = SettingsSceneModel(store: store, metadataEnrichment: service)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model, metadataServerEnabled: false).child(.metadata)
        controller.loadViewIfNeeded()
        let section = try #require(controller.sections.firstIndex { $0.id == "metadata" })
        let operations = try #require(controller.sections.firstIndex { $0.id == "metadataOperations" })
        let from = IndexPath(row: 0, section: section)
        let to = IndexPath(row: 2, section: section)
        #expect(controller.tableView.isEditing)
        #expect(controller.tableView.dataSource?.tableView?(controller.tableView, canMoveRowAt: from) == true)
        #expect(controller.tableView.dataSource?.tableView?(controller.tableView, canMoveRowAt: .init(row: 0, section: operations)) == false)
        #expect(!controller.rows.keys.contains { $0.hasPrefix("metadata.order.") })
        #expect(controller.tableView(controller.tableView, targetIndexPathForMoveFromRowAt: from,
            toProposedIndexPath: .init(row: 0, section: operations)) == to)
        controller.tableView.dataSource?.tableView?(controller.tableView, moveRowAt: from, to: to)
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        #expect(store.current.importPreferences.metadataProviders.map(\.provider) == [.musicBrainz, .metadataServer, .discogs, .musicKit])
        let diffable = try #require(controller.tableView.dataSource as? UITableViewDiffableDataSource<String, String>)
        #expect(diffable.snapshot().itemIdentifiers(inSection: "metadata") == controller.sections[section].rows.map(\.id))
    }

    @Test("Provider pages omit removed plugins and gate hidden plugins while preserving reorder slots",
          arguments: [nil, false, true] as [Bool?])
    func nativeProviderVisibility(showHidden: Bool?) async throws {
        let defaults = UserDefaults.standard
        let key = PluginSettingsViewController.showHiddenStorageKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        if let showHidden { defaults.set(showHidden, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        let definitions: [(PluginKind, String, Bool, PluginLifecycleState)] = [
            (.metadata, "musicBrainz", true, .registered),
            (.metadata, "reference.metadata", true, .compiledOut),
            (.metadata, "discogs", false, .registered),
            (.metadata, "musicKit", true, .disabled),
            (.lyrics, "lrclib", true, .registered),
            (.lyrics, "reference.lyrics", true, .compiledOut),
            (.lyrics, "netEase", false, .registered)
        ]
        let snapshots = definitions.map { kind, provider, visible, state in
            let id = PluginID(rawValue: state == .compiledOut ? provider : "test.\(kind.rawValue).\(provider)")
            return PluginSnapshot(descriptor: .init(id: id, name: provider, kinds: [kind],
                dataProviderID: state == .compiledOut ? nil : provider),
                preference: .init(pluginID: id, isVisible: visible, isEnabled: state != .disabled), state: state)
        }
        let metadataIDs = ["musicBrainz", "reference.metadata", "discogs", "musicKit", "unregistered"]
        let lyricsIDs = ["lrclib", "reference.lyrics", "netEase", "unregistered"]
        let initial = AppSettings(importPreferences: .init(
            metadataProviders: metadataIDs.map { .init(provider: .init(rawValue: $0), isEnabled: true) },
            lyricsProviders: lyricsIDs.map { .init(provider: .init(rawValue: $0), isEnabled: true) }),
            pluginPreferences: snapshots.map(\.preference))
        let store = SettingsFeatureTestStore(settings: initial)
        let metadata = SettingsMetadataEnrichmentTestService(authorization: .authorized,
            providerStatuses: metadataIDs.map {
                .init(provider: .init(rawValue: $0), isRegistered: !["reference.metadata", "unregistered"].contains($0),
                      authorization: .authorized)
            })
        let lyrics = SettingsLyricsTestService(registeredProviderIDs: [.lrclib, .init(rawValue: "netEase")])
        let model = SettingsSceneModel(store: store, metadataEnrichment: metadata, lyricsServing: lyrics)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let plugins = SettingsPluginVisibilityTestService(settings: initial, snapshots: snapshots)
        let host = PluginSettingsPageHost(registry: .init(), plugins: plugins, settings: plugins)
        host.start(); await host.model.waitForPendingWork()
        let root = SettingsViewController(model: model, pluginPages: host)
        let controller = root.child(.metadata)
        controller.loadViewIfNeeded()
        let visibleMetadata = showHidden == true ? ["musicBrainz", "discogs", "musicKit"] : ["musicBrainz", "musicKit"]
        let visibleLyrics = showHidden == true ? ["lrclib", "netEase"] : ["lrclib"]
        #expect(controller.visibleMetadataProviders.map { $0.provider.rawValue } == visibleMetadata)
        #expect(controller.visibleLyricsProviders.map { $0.provider.rawValue } == visibleLyrics)
        #expect(controller.rows["settings.import.metadataProvider.reference.metadata.enabled"] == nil)
        #expect(controller.rows["settings.import.lyricsProvider.reference.lyrics.enabled"] == nil)
        #expect(controller.rows["settings.import.musicKitEnrichment"] != nil) // Disabled capabilities remain configurable.
        #expect((controller.rows["settings.import.metadataProvider.discogs.enabled"] != nil) == (showHidden == true))
        #expect((controller.rows["settings.import.lyricsProvider.netEase.enabled"] != nil) == (showHidden == true))
        let privacy = root.child(.category(.privacy))
        privacy.loadViewIfNeeded()
        #expect(privacy.rows["settings.privacy.provider.reference.metadata"] == nil)
        #expect(privacy.rows["settings.privacy.provider.reference.lyrics"] == nil)
        #expect((privacy.rows["settings.privacy.provider.discogs"] != nil) == (showHidden == true))
        #expect((privacy.rows["settings.privacy.provider.netEase"] != nil) == (showHidden == true))
        let section = try #require(controller.sections.firstIndex { $0.id == "metadata" })
        controller.reorderMetadata(from: .init(row: 0, section: section),
            to: .init(row: visibleMetadata.count - 1, section: section))
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        let expectedOrder = showHidden == true
            ? ["discogs", "reference.metadata", "musicKit", "musicBrainz", "unregistered"]
            : ["musicKit", "reference.metadata", "discogs", "musicBrainz", "unregistered"]
        #expect(store.current.importPreferences.metadataProviders.map { $0.provider.rawValue } == expectedOrder)
        #expect(store.current.importPreferences.lyricsProviders == initial.importPreferences.lyricsProviders)
        #expect(store.current.pluginPreferences == initial.pluginPreferences)
    }

    @Test("Duplicate menu persists executable reporting and retains unsupported legacy choices until edited")
    func duplicatePolicyMenuPersists() async throws {
        let store = SettingsFeatureTestStore(settings: .init(importPreferences: .init(duplicatePolicy: .keepBoth)))
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model, layout: .detail(.importing))
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.import.duplicatePolicy"]?.image != nil)
        guard case .menu(let title, let menu) = controller.rows["settings.import.duplicatePolicy"]?.control else {
            Issue.record("Missing duplicate policy menu"); return
        }
        #expect(title == L("保留两份（暂不支持）"))
        #expect(store.current.importPreferences.duplicatePolicy == .keepBoth)
        #expect(menu.children.count == 2)
        // Exercise the same save path as a selected menu action.
        model.viewModel.setDuplicateImportPolicy(.reportExisting)
        await model.viewModel.waitForPendingWork(); await settleSettingsFeature()
        guard case .menu(let updated, _) = controller.rows["settings.import.duplicatePolicy"]?.control else { return }
        #expect(updated == L("报告重复内容"))
        #expect(store.current.importPreferences.duplicatePolicy == .reportExisting)
    }

    @Test("Accent presets persist while custom picker edits remain a draft until completion")
    func accentPresetAndCustomDraft() async {
        let saved = UserDefaults.standard.object(forKey: DesignSystem.MusicFreeAccentColorStore.storageKey)
        let custom = UserDefaults.standard.object(forKey: "musicfree.customAccentColor")
        defer {
            UserDefaults.standard.set(saved, forKey: DesignSystem.MusicFreeAccentColorStore.storageKey)
            UserDefaults.standard.set(custom, forKey: "musicfree.customAccentColor")
        }
        DesignSystem.MusicFreeAccentColorStore.reset()
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model, setAccentColor: { color in
            DesignSystem.MusicFreeAccentColorStore.setHexValue(DesignSystem.MusicFreeAccentColorStore.hexString(for: color))
        }).child(.accentColor)
        controller.loadViewIfNeeded()
        controller.rows["settings.accentColor.preset.1"]?.action?()
        #expect(DesignSystem.MusicFreeAccentColorStore.hexValue == "007AFF")
        #expect(controller.rows["settings.accentColor.preset.1"]?.isSelected == true)
        let picker = UIColorPickerViewController()
        picker.selectedColor = DesignSystem.MusicFreeAccentColorStore.uiColor(forHex: "123456")
        controller.colorPickerViewControllerDidSelectColor(picker)
        #expect(DesignSystem.MusicFreeAccentColorStore.hexValue == "007AFF")
        controller.colorPickerViewControllerDidFinish(picker)
        #expect(DesignSystem.MusicFreeAccentColorStore.hexValue == "123456")
        #expect(controller.rows["settings.accentColor.custom"]?.isSelected == true)
    }

    @Test("Transition styles update atomically and disabling retains the edited crossfade duration")
    func nativeTransitionStyleAndDuration() async throws {
        let store = SettingsFeatureTestStore(playbackCapabilities: [.fade, .gapless, .crossfade, .boundarySilenceSkipping])
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        let root = SettingsViewController(model: model, layout: .detail(.playback))
        root.loadViewIfNeeded()
        #expect(root.rows["settings.playback.fadeIn"] == nil)
        #expect(root.rows["settings.playback.transitions.entry"] != nil)
        let controller = root.child(.transitions)
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.playback.crossfadeDuration"] != nil)
        #expect(controller.rows["settings.playback.crossfadeDuration"]?.enabled == false)
        controller.rows["settings.playback.crossfade"]?.action?()
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(!store.current.playbackPreferences.transition.gaplessPlaybackEnabled)
        #expect(controller.rows["settings.playback.crossfadeDuration"]?.enabled == true)
        guard case .slider(_, let range, _, _, let save) = controller.rows["settings.playback.crossfadeDuration"]?.control else { Issue.record("Missing crossfade duration"); return }
        #expect(range.upperBound == 12)
        guard case .toggle(_, let skipSilence) = controller.rows["settings.playback.skipBoundarySilence"]?.control else {
            Issue.record("Missing boundary silence toggle"); return
        }
        skipSilence(true)
        await model.viewModel.waitForPendingWork()
        save(2.25)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        guard case .toggle(_, let toggle) = controller.rows["settings.playback.transitions.enabled"]?.control else { Issue.record("Missing transition toggle"); return }
        toggle(false)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(!store.current.playbackPreferences.transition.isCrossfadeEnabled)
        #expect(store.current.playbackPreferences.transition.skipBoundarySilence)
        #expect(controller.rows["settings.playback.crossfadeDuration"] != nil)
        #expect(controller.rows["settings.playback.crossfadeDuration"]?.enabled == false)
        #expect(controller.rememberedCrossfadeDuration == .seconds(2.25))
        toggle(true)
        await model.viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.transition.crossfadeDuration == .seconds(2.25))
        let reopened = root.child(.transitions)
        reopened.loadViewIfNeeded()
        guard case .slider(let value, _, _, _, _) = reopened.rows["settings.playback.crossfadeDuration"]?.control else {
            Issue.record("Missing reopened crossfade duration"); return
        }
        #expect(value == 2.25)
        #expect(reopened.rows["settings.playback.crossfadeDuration"]?.enabled == true)
    }

    @Test("Transition taps accept the latest selection while an earlier save is pending")
    func transitionTapsDuringSave() async throws {
        let store = SettingsFeatureTestStore(playbackCapabilities: [.fade, .gapless, .crossfade])
        // A real settings service broadcasts its commit before update() returns.
        store.normalize = { $0 }
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { store.resumeSave(); model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model).child(.transitions)
        controller.loadViewIfNeeded()
        func tap(_ id: String) throws {
            let section = try #require(controller.sections.firstIndex { $0.rows.contains { $0.id == id } })
            let row = try #require(controller.sections[section].rows.firstIndex { $0.id == id })
            controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: row, section: section))
        }
        store.suspendNextSave = true
        try tap("settings.playback.crossfade")
        for _ in 0..<50 where !store.isSaveSuspended { await Task.yield() }
        #expect(store.isSaveSuspended)
        controller.render()
        #expect(controller.rows["settings.playback.gapless"]?.enabled == true)
        try tap("settings.playback.gapless")
        #expect(model.viewModel.settings.playbackPreferences.transition.gaplessPlaybackEnabled)
        #expect(!model.viewModel.settings.playbackPreferences.transition.isCrossfadeEnabled)
        store.resumeSave()
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(store.current.playbackPreferences.transition.gaplessPlaybackEnabled)
        #expect(!store.current.playbackPreferences.transition.isCrossfadeEnabled)
        #expect(store.savedValues.count == 2)
    }

    @Test("Native settings accept rapid switches, menus and slider edits while saving")
    func controlsRemainEditableDuringSave() async throws {
        let store = SettingsFeatureTestStore()
        store.normalize = { $0 }
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { store.resumeSave(); model.viewModel.stopObservingChanges() }
        let controller = SettingsViewController(model: model).child(.conversion)
        controller.loadViewIfNeeded()
        store.suspendNextSave = true
        guard case .toggle(_, let toggle) = controller.rows["settings.import.audioConversion.enabled"]?.control else {
            Issue.record("Missing import conversion toggle"); return
        }
        toggle(true)
        for _ in 0..<100 where !store.isSaveSuspended { await Task.yield() }
        controller.render()
        #expect(controller.rows["settings.import.audioConversion.enabled"]?.enabled == true)
        #expect(controller.rows["settings.import.audioConversion.target"]?.enabled == true)
        #expect(controller.rows["settings.import.audioConversion.concurrency"]?.enabled == true)
        let slider = controller.slider("test.slider", "Slider", value: 1, range: 0...3, step: 0.5, valueText: "1") { _ in }
        #expect(slider.enabled)
        toggle(false)
        store.resumeSave(); await model.viewModel.waitForPendingWork()
        #expect(!store.current.importPreferences.audioConversion.automaticallyConvertLosslessImports)
        #expect(store.savedValues.count == 2)
    }

    @Test("VoiceOver slider adjustments use the configured step and persist without a touch-up")
    func sliderAccessibilityPersists() throws {
        var saved: [Double] = []
        let cell = SettingsNativeCell(style: .default, reuseIdentifier: nil)
        let makeRow: (Bool) -> SettingsNativeRow = { enabled in
            .init(id: "accessible.slider", title: "Rate", enabled: enabled,
                control: .slider(1, 0.25...3, 0.25, { String($0) }, { saved.append($0) }))
        }
        cell.configure(makeRow(true))
        let slider = try #require(nativeSliders(in: cell).first)
        slider.accessibilityIncrement()
        #expect(saved == [1.25])
        slider.accessibilityDecrement()
        #expect(saved == [1.25, 1])
        cell.configure(makeRow(false))
        slider.accessibilityIncrement()
        #expect(saved == [1.25, 1])
    }

    @Test("Vertical equalizer bands preserve identity and commit once after dragging")
    func verticalBandsPersistWithoutReplacingControl() async throws {
        let band = EqualizerBandDescriptor(centerFrequencyHz: 1_000, minimumGainDecibels: -12, maximumGainDecibels: 12)
        let store = SettingsFeatureTestStore(playbackCapabilities: [.equalizer], equalizerDescriptor: .init(bands: [band], minimumPreampDecibels: -12, maximumPreampDecibels: 12))
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { model.viewModel.stopObservingChanges() }
        model.viewModel.setEqualizerEnabled(true)
        await model.viewModel.waitForPendingWork()
        let controller = EqualizerPluginSettingsViewController(context: .init(model: model))
        controller.loadViewIfNeeded()
        let slider = try #require(nativeSliders(in: controller.equalizerBank).first)
        let before = store.savedValues.count
        slider.value = 4.25
        dispatchRegisteredActions(slider, event: .valueChanged)
        controller.render()
        #expect(slider.value == 4.25)
        #expect(store.savedValues.count == before)
        dispatchRegisteredActions(slider, event: .touchUpInside)
        // iOS can send the snapped value once more after the gesture ends.
        dispatchRegisteredActions(slider, event: .valueChanged)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(store.current.playbackPreferences.equalizer.bands.first?.gain.decibels == 4.5)
        #expect(store.savedValues.count == before + 1)
        #expect(nativeSliders(in: controller.equalizerBank).first === slider)
        controller.rows["settings.playback.equalizer.reset"]?.action?()
        await model.viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.equalizer.bands.first?.gain == .zero)
        #expect(store.current.playbackPreferences.equalizer.isEnabled)
        controller.render()
        #expect(slider.value == 0)
    }

    @Test("The plugin equalizer page recovers failed loading and retries a rolled-back save")
    func equalizerPageFailureRecovery() async throws {
        let store = SettingsFeatureTestStore(playbackCapabilities: [.equalizer],
            equalizerDescriptor: .init(bands: [.init(centerFrequencyHz: 1_000, minimumGainDecibels: -12, maximumGainDecibels: 12)]))
        store.nextLoadError = SettingsError.decoding
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        let controller = EqualizerPluginSettingsViewController(context: .init(model: model))
        controller.loadViewIfNeeded()
        #expect(controller.rows["settings.equalizer.retryLoad"] != nil)
        controller.rows["settings.equalizer.retryLoad"]?.action?()
        for _ in 0..<200 where !model.viewModel.canEditPlayback { await Task.yield() }
        #expect(model.viewModel.canEditPlayback)
        store.nextSaveError = SettingsError.writeFailed
        model.viewModel.setEqualizerEnabled(true)
        await model.viewModel.waitForPendingWork()
        controller.render()
        #expect(!store.current.playbackPreferences.equalizer.isEnabled)
        #expect(controller.rows["settings.equalizer.retrySave"] != nil)
        controller.rows["settings.equalizer.retrySave"]?.action?()
        await model.viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.equalizer.isEnabled)
        model.viewModel.stopObservingChanges()
    }

    @Test("Custom equalizer edits retain the complete preset menu and allow selecting a preset during saving")
    func customEqualizerRetainsPresets() async throws {
        let band = EqualizerBandDescriptor(centerFrequencyHz: 1_000, minimumGainDecibels: -12, maximumGainDecibels: 12)
        let names = ["Flat", "Bass Boost", "Treble Boost", "Vocal", "Rock"]
        let gains: [Float] = [0, 6, -6, 3, 4]
        let presets = names.enumerated().map { index, name in
            EqualizerPresetDescriptor(id: UInt32(index), name: name, configuration: .init(bandGains: [
                .init(centerFrequencyHz: 1_000, gainDecibels: gains[index])]))
        }
        let initial = AppSettings(playbackPreferences: .init(equalizer: try .init(isEnabled: true,
            bands: [try .init(frequencyHz: 1_000, gain: .init(decibels: 2))])))
        let store = SettingsFeatureTestStore(settings: initial, playbackCapabilities: [.equalizer],
            equalizerDescriptor: .init(bands: [band], presets: presets))
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        defer { store.resumeSave(); model.viewModel.stopObservingChanges() }
        let controller = EqualizerPluginSettingsViewController(context: .init(model: model))
        controller.loadViewIfNeeded()
        func presetMenu() throws -> (String, UIMenu) {
            guard case .menu(let title, let menu) = controller.rows["settings.playback.equalizer.preset"]?.control else {
                throw NSError(domain: "Missing preset menu", code: 1)
            }
            return (title, menu)
        }
        let (title, menu) = try presetMenu()
        #expect(title == L("自定义"))
        #expect(menu.children.count == 5)
        let gridRows = controller.equalizerPresets.arrangedSubviews.compactMap { $0 as? UIStackView }
        #expect(gridRows.count == 3)
        #expect(gridRows.allSatisfy { $0.arrangedSubviews.count == 2 })
        let gridButtons = gridRows.flatMap(\.arrangedSubviews).compactMap { $0 as? UIButton }
        #expect(gridButtons.count == presets.count)
        #expect(gridButtons.last?.accessibilityIdentifier == "settings.playback.equalizer.preset.4")
        #expect(menu.children.compactMap { $0 as? UIAction }.allSatisfy { $0.state == .off })
        let slider = try #require(nativeSliders(in: controller.equalizerBank).first)
        store.suspendNextSave = true
        model.viewModel.setEqualizerGain(5, for: band)
        for _ in 0..<50 where !store.isSaveSuspended { await Task.yield() }
        #expect(store.isSaveSuspended)
        controller.render()
        #expect(controller.rows["settings.playback.equalizer.preset"]?.enabled == true)
        let button = try #require(controller.equalizerPresets.arrangedSubviews
            .flatMap(\.subviews).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "settings.playback.equalizer.preset.1" })
        #expect(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        store.resumeSave()
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(store.current.playbackPreferences.equalizer.bands.first?.gain.decibels == 6)
        controller.render()
        #expect(try presetMenu().0 == L("低音增强"))
        #expect(nativeSliders(in: controller.equalizerBank).first === slider)
        model.viewModel.setEqualizerGain(2, for: band)
        await model.viewModel.waitForPendingWork()
        controller.render()
        #expect(try presetMenu().0 == L("自定义"))
        #expect(try presetMenu().1.children.count == 5)
        model.viewModel.applyEqualizerPreset(id: 4)
        await model.viewModel.waitForPendingWork()
        controller.render()
        #expect(try presetMenu().0 == controller.presetTitle("Rock"))
        #expect(model.viewModel.selectedEqualizerPresetID == 4)
        #expect(store.current.playbackPreferences.equalizer.bands.first?.gain.decibels == 4)
    }

    @Test("Shared native settings surfaces load once and retain the loaded model on return")
    func sharedModelLoadsOnce() async {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        async let first: Void = model.loadIfNeeded()
        async let second: Void = model.loadIfNeeded()
        _ = await (first, second)
        await model.loadIfNeeded()
        #expect(store.loadCount == 1)
        #expect(model.viewModel.loadState == .loaded)
        model.viewModel.stopObservingChanges()
    }

    @Test("Saving and external settings updates preserve native slider identity and scroll position")
    func updatesPreserveControls() async throws {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        let controller = SettingsViewController(model: model, layout: .detail(.playback))
        controller.isPlaybackRateExpanded = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.viewModel.stopObservingChanges() }
        controller.view.layoutIfNeeded()
        await settleSettingsFeature()
        let table = controller.tableView!
        table.layoutIfNeeded()
        let path = IndexPath(row: 1, section: 0)
        let cell = try #require(table.cellForRow(at: path))
        let slider = try #require(nativeSliders(in: cell).first)
        #expect(cell.accessibilityIdentifier == "settings.playback.rate")
        #expect(!slider.isHidden)
        #expect(slider.isEnabled)
        #expect(!slider.allTargets.isEmpty)
        let offset = table.contentOffset
        slider.value = 1.5
        dispatchRegisteredActions(slider, event: .valueChanged)
        slider.value = 1.75
        dispatchRegisteredActions(slider, event: .valueChanged)
        #expect(store.savedValues.isEmpty)
        dispatchRegisteredActions(slider, event: .touchUpInside)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(store.savedValues.count == 1)
        #expect(store.current.playbackPreferences.rate.value == 1.75)
        #expect(table.cellForRow(at: path) === cell)
        #expect(nativeSliders(in: cell).first === slider)
        #expect(table.contentOffset == offset)

        store.publishExternal(.defaults)
        await settleSettingsFeature()
        #expect(slider.value == 1)
        #expect(table.cellForRow(at: path) === cell)
        #expect(table.contentOffset == offset)
    }

    @Test("Category changes reuse the native settings controller and pop nested pages")
    func categorySwitchPreservesController() async {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        let controller = SettingsViewController(model: model, layout: .detail(.playback))
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let table = controller.tableView
        navigation.pushViewController(UIViewController(), animated: false)
        controller.updateNavigationDestination(.storage)
        #expect(navigation.viewControllers.count == 1)
        #expect(navigation.topViewController === controller)
        #expect(controller.tableView === table)
        #expect(table?.accessibilityIdentifier == "settings.detail.storage")
        #expect(store.loadCount == 1)
        model.viewModel.stopObservingChanges()
    }

    @Test("Nested UIKit equalizer saves once at gesture end and retains the same control")
    func nestedEqualizerPreservesSliderAndSaves() async throws {
        let descriptor = EqualizerDescriptor(bands: [.init(centerFrequencyHz: 1_000, minimumGainDecibels: -12, maximumGainDecibels: 12)], minimumPreampDecibels: -12, maximumPreampDecibels: 12)
        let store = SettingsFeatureTestStore(playbackCapabilities: [.equalizer], equalizerDescriptor: descriptor)
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        model.viewModel.setEqualizerEnabled(true)
        await model.viewModel.waitForPendingWork()
        let savedCount = store.savedValues.count
        let controller = EqualizerPluginSettingsViewController(context: .init(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.viewModel.stopObservingChanges() }
        controller.view.layoutIfNeeded()
        await settleSettingsFeature()
        let table = controller.tableView!
        table.layoutIfNeeded()
        let path = IndexPath(row: 0, section: 1)
        let cell = try #require(table.cellForRow(at: path))
        let slider = try #require(nativeSliders(in: cell).first)
        #expect(slider.accessibilityIdentifier == "settings.playback.equalizer.preamp")
        slider.value = 2
        dispatchRegisteredActions(slider, event: .valueChanged)
        slider.value = 4.5
        dispatchRegisteredActions(slider, event: .valueChanged)
        #expect(store.savedValues.count == savedCount)
        dispatchRegisteredActions(slider, event: .touchUpInside)
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        #expect(store.savedValues.count == savedCount + 1)
        #expect(store.current.playbackPreferences.equalizer.preamp.decibels == 4.5)
        #expect(table.cellForRow(at: path) === cell)
        #expect(nativeSliders(in: cell).first === slider)
    }

    @Test("Sleep schedule controls edit persisted values and survive returning to the page")
    func nativeSleepSchedulePersists() async throws {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        let controller = SettingsViewController(model: model).child(.sleepTimer)
        controller.loadViewIfNeeded()
        controller.rows["settings.sleepTimer.schedule.add"]?.action?()
        await model.viewModel.waitForPendingWork()
        await settleSettingsFeature()
        let schedule = try #require(store.current.playbackPreferences.sleepTimer.schedules.first)
        let id = "settings.sleepTimer.schedule.\(schedule.id)"
        guard case .stepper(_, _, let change) = controller.rows[id + ".duration"]?.control else { Issue.record("Missing native schedule duration control"); return }
        change(35)
        await model.viewModel.waitForPendingWork()
        #expect(store.current.playbackPreferences.sleepTimer.schedules.first?.durationMinutes == 35)
        let reopened = SettingsViewController(model: model).child(.sleepTimer)
        reopened.loadViewIfNeeded()
        guard case .stepper(let value, _, _) = reopened.rows[id + ".duration"]?.control else { Issue.record("Missing reopened schedule"); return }
        #expect(value == 35)
        #expect(store.loadCount == 1)
        model.viewModel.stopObservingChanges()
    }

    @Test("Provider revocation from native details disables both metadata and lyrics")
    func nativeProviderRevocation() async {
        let store = SettingsFeatureTestStore()
        let model = SettingsSceneModel(store: store)
        await model.loadIfNeeded()
        model.viewModel.acceptPrivacyPolicy()
        model.viewModel.acceptProviderPrivacy(for: LyricsProviderID.lrclib.rawValue)
        await model.viewModel.waitForPendingWork()
        model.viewModel.setLyricsProviderEnabled(.lrclib, true)
        await model.viewModel.waitForPendingWork()
        let descriptor = PrivacyProviderCatalog.descriptor(for: LyricsProviderID.lrclib.rawValue)
        let controller = SettingsViewController(model: model).child(.providerPrivacy(descriptor))
        controller.loadViewIfNeeded()
        controller.rows["settings.privacy.provider.lrclib.revoke"]?.action?()
        await model.viewModel.waitForPendingWork()
        #expect(!store.current.importPreferences.privacyPreferences.isProviderPolicyAccepted(LyricsProviderID.lrclib.rawValue))
        #expect(!store.current.importPreferences.runtimeLyricsProviders.contains { $0.provider == .lrclib && $0.isEnabled })
        model.viewModel.stopObservingChanges()
    }

    @Test("Metadata cancellation ignores queued progress and keeps its terminal summary")
    func nativeMetadataCancellationIgnoresQueuedProgress() {
        let state = SettingsDetailState()
        state.scanIntent = .cancelling
        state.metadata = MetadataEnrichmentSnapshot(scan: .init(status: .cancelled))
        state.apply(MetadataEnrichmentSnapshot(scan: .init(status: .scanning)))
        #expect(state.metadata.scan.status == .cancelled)
        state.apply(MetadataEnrichmentSnapshot(scan: .init(status: .cancelled)))
        #expect(state.scanIntent == .idle)
        state.lyricsIntent = .starting
        state.lyrics = LyricsPreloadSnapshot(status: .downloading)
        state.apply(LyricsPreloadSnapshot(status: .idle))
        #expect(state.lyrics.status == .downloading)
    }

    // SwiftPM UI tests have no UIApplication; invoke the registered target
    // actions directly. The app UI test covers actual UIKit event dispatch.
    private func dispatchRegisteredActions(_ control: UIControl, event: UIControl.Event) {
        for target in control.allTargets {
            for action in control.actions(forTarget: target, forControlEvent: event) ?? [] {
                (target as? NSObject)?.perform(NSSelectorFromString(action), with: control)
            }
        }
    }

    private func nativeSliders(in view: UIView) -> [UISlider] {
        (view as? UISlider).map { [$0] } ?? view.subviews.flatMap { nativeSliders(in: $0) }
    }
}
