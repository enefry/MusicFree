@testable import SettingsFeature
import AppServices
import Foundation
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
