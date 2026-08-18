import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import Observation
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

@MainActor
@Observable
final class SettingsViewModel {
    private enum SettingsOperation: Sendable {
        case save(id: UInt64, settings: AppSettings)
        case reset(id: UInt64)
    }

    let store: any SettingsFeatureStore
    private let metadataEnrichment: (any MetadataEnrichmentServing)?

    private(set) var settings: AppSettings = .defaults
    private(set) var playbackCapabilities: PlaybackCapabilities = []
    private(set) var equalizerDescriptor: EqualizerDescriptor?
    private(set) var systemCapabilities = SystemIntegrationCapabilitySnapshot()
    private(set) var loadState: SettingsFeatureLoadState = .idle
    private(set) var mutationState: SettingsFeatureMutationState = .idle
    private(set) var storageUsage: StorageUsageSnapshot?
    private(set) var maintenanceState: SettingsMaintenanceState = .idle
    private(set) var lastFailure: SettingsFeatureFailure?
    private(set) var isRefreshingStorage = false
    private(set) var metadataEnrichmentSnapshot = MetadataEnrichmentSnapshot()
    private(set) var playbackRateDraft: Double?
    private(set) var equalizerPreampDraft: Double?
    var isResetConfirmationPresented = false
    var isMaintenanceConfirmationPresented = false
    private(set) var requestedMaintenanceAction: StorageMaintenanceAction?

    private var changeObservationTask: Task<Void, Never>?
    private var metadataObservationTask: Task<Void, Never>?
    private var metadataActionTask: Task<Void, Never>?
    private var metadataRuntimeTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var pendingOperation: SettingsOperation?
    private var inFlightOperation: SettingsOperation?
    private var operationSequence: UInt64 = 0
    private var committedSettings: AppSettings?
    private var recentlyWrittenSettings: Set<AppSettings> = []
    private var failedSaveSettings: AppSettings?
    private var equalizerBandGainDrafts: [Int: Double] = [:]
    private var storageRefreshTask: Task<Void, Never>?
    private var storageRefreshGeneration: UInt64 = 0
    private var metadataIntentGeneration: UInt64 = 0
    private var metadataRuntimeGeneration: UInt64 = 0

    init(
        store: any SettingsFeatureStore,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil
    ) {
        self.store = store
        self.metadataEnrichment = metadataEnrichment
    }

    var isLoading: Bool {
        if case .loading = loadState {
            return true
        }
        return false
    }

    var isSaving: Bool {
        mutationState.isSaving || pendingOperation != nil || operationTask != nil
    }

    var isMaintainingStorage: Bool {
        maintenanceState.isRunning
    }

    var canRetryFailedSave: Bool {
        failedSaveSettings != nil && lastFailure?.isRetryable == true
    }

    var canEditPlayback: Bool {
        loadState == .loaded && !isLoading
    }

    var supportsVariableRate: Bool {
        playbackCapabilities.contains(.variableRate)
    }

    var displayedPlaybackRate: Double {
        playbackRateDraft ?? settings.playbackPreferences.rate.value
    }

    var supportsReplayGain: Bool {
        playbackCapabilities.contains(.replayGain)
    }

    var supportsEqualizer: Bool {
        playbackCapabilities.contains(.equalizer) && equalizerDescriptor != nil
    }

    var equalizerBands: [EqualizerBandDescriptor] {
        equalizerDescriptor?.bands ?? []
    }

    var equalizerPresets: [EqualizerPresetDescriptor] {
        guard let equalizerDescriptor else { return [] }
        return equalizerDescriptor.presets.filter {
            (try? equalizerPreferences(
                from: $0.configuration,
                isEnabled: true,
                descriptor: equalizerDescriptor
            )) != nil
        }
    }

    var selectedEqualizerPresetID: UInt32? {
        equalizerPresets.first {
            equalizerPreferencesMatch($0.configuration)
        }?.id
    }

    var displayedEqualizerPreamp: Double {
        equalizerPreampDraft ?? settings.playbackPreferences.equalizer.preamp.decibels
    }

    var supportsGapless: Bool {
        playbackCapabilities.contains(.gapless)
    }

    var supportsCrossfade: Bool {
        playbackCapabilities.contains(.crossfade)
    }

    func load() async {
        await cancelStorageRefresh()
        changeObservationTask?.cancel()
        changeObservationTask = nil
        metadataObservationTask?.cancel()
        metadataObservationTask = nil
        invalidateMetadataTasks()
        await cancelOperations()
        await waitForMetadataWork()

        loadState = .loading
        mutationState = .idle
        lastFailure = nil
        failedSaveSettings = nil

        let stream = await store.makeChangeStream()
        changeObservationTask = Task { @MainActor [weak self] in
            for await value in stream {
                guard !Task.isCancelled else { return }
                self?.receiveExternal(value)
            }
        }

        if let metadataEnrichment {
            metadataEnrichmentSnapshot = await metadataEnrichment.snapshot()
            let metadataStream = await metadataEnrichment.makeSnapshotStream()
            metadataObservationTask = Task { @MainActor [weak self] in
                for await value in metadataStream {
                    guard !Task.isCancelled else { return }
                    self?.metadataEnrichmentSnapshot = value
                }
            }
        } else {
            metadataEnrichmentSnapshot = MetadataEnrichmentSnapshot()
        }

        do {
            let loaded = try await store.load().validated()
            try Task.checkCancellation()
            let effective = try await store.effective()
            try Task.checkCancellation()

            settings = loaded
            committedSettings = loaded
            playbackCapabilities = effective.playbackCapabilities
            equalizerDescriptor = effective.equalizerDescriptor
            systemCapabilities = effective.systemCapabilities
            loadState = .loaded
            syncMetadataRuntime(for: loaded)
            await refreshStorageUsage()
        } catch is CancellationError {
            changeObservationTask?.cancel()
            changeObservationTask = nil
            if loadState == .loading {
                loadState = .idle
            }
        } catch {
            changeObservationTask?.cancel()
            changeObservationTask = nil
            loadState = .failed(makeFailure(from: error))
        }
    }

    func retry() async {
        await load()
    }

    func refreshStorageUsage() async {
        guard loadState == .loaded, !isMaintainingStorage else { return }
        if let storageRefreshTask {
            await storageRefreshTask.value
            return
        }

        storageRefreshGeneration = nextGeneration(after: storageRefreshGeneration)
        let generation = storageRefreshGeneration
        isRefreshingStorage = true
        let store = self.store
        let task = Task { @MainActor [weak self] in
            do {
                let usage = try await store.storageUsage()
                guard !Task.isCancelled,
                      let self,
                      self.storageRefreshGeneration == generation
                else { return }
                self.storageUsage = usage
                if case .failed = self.maintenanceState {
                    self.maintenanceState = .idle
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.storageRefreshGeneration == generation
                else { return }
                self.storageUsage = nil
            }
        }
        storageRefreshTask = task
        await task.value
        guard storageRefreshGeneration == generation else { return }
        storageRefreshTask = nil
        isRefreshingStorage = false
    }

    func performStorageMaintenance(_ actions: Set<StorageMaintenanceAction>) async {
        guard loadState == .loaded, !actions.isEmpty, !isMaintainingStorage else { return }
        await cancelStorageRefresh()
        guard loadState == .loaded, !isMaintainingStorage else { return }
        maintenanceState = .loading
        do {
            let result = try await store.performStorageMaintenance(actions)
            storageUsage = result.usageAfter
            maintenanceState = .completed(result)
        } catch {
            maintenanceState = .failed(makeFailure(from: error).message)
        }
    }

    func requestStorageMaintenance(_ action: StorageMaintenanceAction) {
        guard loadState == .loaded, !isMaintainingStorage else { return }
        requestedMaintenanceAction = action
        isMaintenanceConfirmationPresented = true
    }

    func cancelStorageMaintenance() {
        requestedMaintenanceAction = nil
        isMaintenanceConfirmationPresented = false
    }

    func confirmStorageMaintenance() async {
        guard let action = requestedMaintenanceAction else { return }
        requestedMaintenanceAction = nil
        isMaintenanceConfirmationPresented = false
        await performStorageMaintenance([action])
    }

    func stopObservingChanges() {
        changeObservationTask?.cancel()
        changeObservationTask = nil
        metadataObservationTask?.cancel()
        metadataObservationTask = nil
        invalidateMetadataTasks()
    }

    /// Waits for the current serialized save/reset worker. Tests and previews
    /// can use this to observe a deterministic post-mutation state.
    func waitForPendingWork() async {
        await operationTask?.value
    }

    /// Waits for authorization and runtime synchronization started by the
    /// settings feature. This keeps async toggle behavior deterministic in
    /// tests and when a settings scene is recreated.
    func waitForMetadataWork() async {
        await metadataActionTask?.value
        await metadataRuntimeTask?.value
    }

    /// Cancels pending work and restores the last value acknowledged by the
    /// store. A repository that cannot cancel internally is still prevented
    /// from updating the UI with a stale result.
    func cancelPendingOperations() async {
        pendingOperation = nil
        let task = operationTask
        task?.cancel()
        await task?.value
        operationTask = nil
        inFlightOperation = nil
        rollbackToCommitted()
        mutationState = .cancelled
    }

    func setPlaybackRate(_ value: Double) {
        do {
            let rate = try PlaybackRate(value: value)
            applyEdit { current in
                AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: PlaybackPreferences(
                        rate: rate,
                        equalizer: current.playbackPreferences.equalizer,
                        replayGain: current.playbackPreferences.replayGain,
                        transition: current.playbackPreferences.transition,
                        sleepTimer: current.playbackPreferences.sleepTimer
                    ),
                    storagePreferences: current.storagePreferences
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    func beginPlaybackRateEditing() {
        guard canEditPlayback else { return }
        playbackRateDraft = settings.playbackPreferences.rate.value
    }

    func updatePlaybackRateDraft(_ value: Double) {
        guard canEditPlayback else { return }

        do {
            playbackRateDraft = try PlaybackRate(value: value).value
        } catch {
            recordValidationFailure(error)
        }
    }

    func endPlaybackRateEditing() {
        guard let playbackRateDraft else { return }
        self.playbackRateDraft = nil
        setPlaybackRate(playbackRateDraft)
    }

    func setReplayGain(_ mode: SettingsAPI.ReplayGainMode) {
        applyEdit { current in
            AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: PlaybackPreferences(
                    rate: current.playbackPreferences.rate,
                    equalizer: current.playbackPreferences.equalizer,
                    replayGain: mode,
                    transition: current.playbackPreferences.transition,
                    sleepTimer: current.playbackPreferences.sleepTimer
                ),
                storagePreferences: current.storagePreferences
            )
        }
    }

    func setEqualizerEnabled(_ isEnabled: Bool) {
        applyEdit { current in
            let equalizer = try EqualizerPreferences(
                isEnabled: isEnabled,
                preamp: current.playbackPreferences.equalizer.preamp,
                bands: current.playbackPreferences.equalizer.bands
            )
            return AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: PlaybackPreferences(
                    rate: current.playbackPreferences.rate,
                    equalizer: equalizer,
                    replayGain: current.playbackPreferences.replayGain,
                    transition: current.playbackPreferences.transition,
                    sleepTimer: current.playbackPreferences.sleepTimer
                ),
                storagePreferences: current.storagePreferences
            )
        }
    }

    func setEqualizerPreamp(_ decibels: Double) {
        do {
            let gain = try EqualizerGain(decibels: decibels)
            applyEdit { current in
                let equalizer = try EqualizerPreferences(
                    isEnabled: current.playbackPreferences.equalizer.isEnabled,
                    preamp: gain,
                    bands: current.playbackPreferences.equalizer.bands
                )
                return AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: PlaybackPreferences(
                        rate: current.playbackPreferences.rate,
                        equalizer: equalizer,
                        replayGain: current.playbackPreferences.replayGain,
                        transition: current.playbackPreferences.transition,
                        sleepTimer: current.playbackPreferences.sleepTimer
                    ),
                    storagePreferences: current.storagePreferences
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    func beginEqualizerPreampEditing() {
        guard canEditPlayback else { return }
        equalizerPreampDraft = settings.playbackPreferences.equalizer.preamp.decibels
    }

    func updateEqualizerPreampDraft(_ decibels: Double) {
        guard canEditPlayback else { return }

        do {
            equalizerPreampDraft = try EqualizerGain(decibels: decibels).decibels
        } catch {
            recordValidationFailure(error)
        }
    }

    func endEqualizerPreampEditing() {
        guard let equalizerPreampDraft else { return }
        self.equalizerPreampDraft = nil
        setEqualizerPreamp(equalizerPreampDraft)
    }

    func equalizerGain(for descriptor: EqualizerBandDescriptor) -> Double {
        let frequency = Int(descriptor.centerFrequencyHz.rounded())
        if let draft = equalizerBandGainDrafts[frequency] {
            return draft
        }
        return settings.playbackPreferences.equalizer.bands.first {
            $0.frequencyHz == frequency
        }?.gain.decibels ?? 0
    }

    func beginEqualizerGainEditing(for descriptor: EqualizerBandDescriptor) {
        guard canEditPlayback else { return }
        let frequency = Int(descriptor.centerFrequencyHz.rounded())
        equalizerBandGainDrafts[frequency] = equalizerGain(for: descriptor)
    }

    func updateEqualizerGainDraft(
        _ decibels: Double,
        for descriptor: EqualizerBandDescriptor
    ) {
        guard canEditPlayback else { return }

        do {
            let frequency = Int(descriptor.centerFrequencyHz.rounded())
            equalizerBandGainDrafts[frequency] = try EqualizerGain(
                decibels: decibels
            ).decibels
        } catch {
            recordValidationFailure(error)
        }
    }

    func endEqualizerGainEditing(for descriptor: EqualizerBandDescriptor) {
        let frequency = Int(descriptor.centerFrequencyHz.rounded())
        guard let draft = equalizerBandGainDrafts.removeValue(forKey: frequency) else { return }
        setEqualizerGain(draft, for: descriptor)
    }

    func setEqualizerGain(_ decibels: Double, for descriptor: EqualizerBandDescriptor) {
        do {
            let selectedFrequency = Int(descriptor.centerFrequencyHz.rounded())
            let selectedGain = try EqualizerGain(decibels: decibels)
            applyEdit { current in
                let savedGains = Dictionary(
                    uniqueKeysWithValues: current.playbackPreferences.equalizer.bands.map {
                        ($0.frequencyHz, $0.gain)
                    }
                )
                let bands = try self.equalizerBands.map { runtimeBand in
                    let frequency = Int(runtimeBand.centerFrequencyHz.rounded())
                    return try EqualizerBand(
                        frequencyHz: frequency,
                        gain: frequency == selectedFrequency
                            ? selectedGain
                            : savedGains[frequency] ?? .zero
                    )
                }
                let equalizer = try EqualizerPreferences(
                    isEnabled: current.playbackPreferences.equalizer.isEnabled,
                    preamp: current.playbackPreferences.equalizer.preamp,
                    bands: bands
                )
                return AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: PlaybackPreferences(
                        rate: current.playbackPreferences.rate,
                        equalizer: equalizer,
                        replayGain: current.playbackPreferences.replayGain,
                        transition: current.playbackPreferences.transition,
                        sleepTimer: current.playbackPreferences.sleepTimer
                    ),
                    storagePreferences: current.storagePreferences
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    func applyEqualizerPreset(id: UInt32) {
        guard let descriptor = equalizerDescriptor,
              let preset = equalizerPresets.first(where: { $0.id == id })
        else { return }

        do {
            try preset.configuration.validated(against: descriptor)
            applyEdit { current in
                let equalizer = try self.equalizerPreferences(
                    from: preset.configuration,
                    isEnabled: current.playbackPreferences.equalizer.isEnabled,
                    descriptor: descriptor
                )
                return AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: PlaybackPreferences(
                        rate: current.playbackPreferences.rate,
                        equalizer: equalizer,
                        replayGain: current.playbackPreferences.replayGain,
                        transition: current.playbackPreferences.transition,
                        sleepTimer: current.playbackPreferences.sleepTimer
                    ),
                    storagePreferences: current.storagePreferences
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    private func equalizerPreferences(
        from configuration: EqualizerConfiguration,
        isEnabled: Bool,
        descriptor: EqualizerDescriptor
    ) throws -> EqualizerPreferences {
        try configuration.validated(against: descriptor)
        return try EqualizerPreferences(
            isEnabled: isEnabled,
            preamp: EqualizerGain(decibels: Double(configuration.preampDecibels)),
            bands: configuration.bandGains.map {
                try EqualizerBand(
                    frequencyHz: Int($0.centerFrequencyHz.rounded()),
                    gain: EqualizerGain(decibels: Double($0.gainDecibels))
                )
            }
        )
    }

    private func equalizerPreferencesMatch(_ configuration: EqualizerConfiguration) -> Bool {
        let preferences = settings.playbackPreferences.equalizer
        guard approximatelyEqual(
            preferences.preamp.decibels,
            Double(configuration.preampDecibels)
        ) else { return false }

        let savedGains = Dictionary(
            uniqueKeysWithValues: preferences.bands.map {
                ($0.frequencyHz, $0.gain.decibels)
            }
        )
        return configuration.bandGains.allSatisfy {
            let frequency = Int($0.centerFrequencyHz.rounded())
            return approximatelyEqual(
                savedGains[frequency] ?? 0,
                Double($0.gainDecibels)
            )
        }
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    func setGaplessPlaybackEnabled(_ isEnabled: Bool) {
        applyEdit { current in
            let transition = try TransitionPreferences(
                gaplessPlaybackEnabled: isEnabled,
                crossfadeDuration: current.playbackPreferences.transition.crossfadeDuration
            )
            return AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: PlaybackPreferences(
                    rate: current.playbackPreferences.rate,
                    equalizer: current.playbackPreferences.equalizer,
                    replayGain: current.playbackPreferences.replayGain,
                    transition: transition,
                    sleepTimer: current.playbackPreferences.sleepTimer
                ),
                storagePreferences: current.storagePreferences
            )
        }
    }

    func setCrossfadeDuration(_ duration: Duration) {
        applyEdit { current in
            let transition = try TransitionPreferences(
                gaplessPlaybackEnabled: current.playbackPreferences.transition.gaplessPlaybackEnabled,
                crossfadeDuration: duration
            )
            return AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: PlaybackPreferences(
                    rate: current.playbackPreferences.rate,
                    equalizer: current.playbackPreferences.equalizer,
                    replayGain: current.playbackPreferences.replayGain,
                    transition: transition,
                    sleepTimer: current.playbackPreferences.sleepTimer
                ),
                storagePreferences: current.storagePreferences
            )
        }
    }

    func addSleepTimerSchedule(id: UUID = UUID()) {
        do {
            let schedule = try SleepTimerSchedule(
                id: id,
                startMinute: 23 * 60,
                endMinute: 5 * 60,
                durationMinutes: 20
            )
            try setSleepTimerSchedules(
                settings.playbackPreferences.sleepTimer.schedules + [schedule]
            )
        } catch {
            recordValidationFailure(error)
        }
    }

    func setSleepTimerScheduleEnabled(_ isEnabled: Bool, id: UUID) {
        updateSleepTimerSchedule(id: id) { schedule in
            try SleepTimerSchedule(
                id: schedule.id,
                isEnabled: isEnabled,
                startMinute: schedule.startMinute,
                endMinute: schedule.endMinute,
                durationMinutes: schedule.durationMinutes
            )
        }
    }

    func setSleepTimerScheduleStartMinute(_ startMinute: Int, id: UUID) {
        updateSleepTimerSchedule(id: id) { schedule in
            try SleepTimerSchedule(
                id: schedule.id,
                isEnabled: schedule.isEnabled,
                startMinute: startMinute,
                endMinute: schedule.endMinute,
                durationMinutes: schedule.durationMinutes
            )
        }
    }

    func setSleepTimerScheduleEndMinute(_ endMinute: Int, id: UUID) {
        updateSleepTimerSchedule(id: id) { schedule in
            try SleepTimerSchedule(
                id: schedule.id,
                isEnabled: schedule.isEnabled,
                startMinute: schedule.startMinute,
                endMinute: endMinute,
                durationMinutes: schedule.durationMinutes
            )
        }
    }

    func setSleepTimerScheduleDuration(_ durationMinutes: Int, id: UUID) {
        updateSleepTimerSchedule(id: id) { schedule in
            try SleepTimerSchedule(
                id: schedule.id,
                isEnabled: schedule.isEnabled,
                startMinute: schedule.startMinute,
                endMinute: schedule.endMinute,
                durationMinutes: durationMinutes
            )
        }
    }

    func deleteSleepTimerSchedule(id: UUID) {
        do {
            try setSleepTimerSchedules(
                settings.playbackPreferences.sleepTimer.schedules.filter { $0.id != id }
            )
        } catch {
            recordValidationFailure(error)
        }
    }

    private func updateSleepTimerSchedule(
        id: UUID,
        transform: (SleepTimerSchedule) throws -> SleepTimerSchedule
    ) {
        do {
            var schedules = settings.playbackPreferences.sleepTimer.schedules
            guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
            schedules[index] = try transform(schedules[index])
            try setSleepTimerSchedules(schedules)
        } catch {
            recordValidationFailure(error)
        }
    }

    private func setSleepTimerSchedules(_ schedules: [SleepTimerSchedule]) throws {
        let sleepTimer = try SleepTimerPreferences(schedules: schedules)
        applyEdit { current in
            AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: PlaybackPreferences(
                    rate: current.playbackPreferences.rate,
                    equalizer: current.playbackPreferences.equalizer,
                    replayGain: current.playbackPreferences.replayGain,
                    transition: current.playbackPreferences.transition,
                    sleepTimer: sleepTimer
                ),
                storagePreferences: current.storagePreferences
            )
        }
    }

    func setDuplicateImportPolicy(_ policy: DuplicateImportPolicy) {
        applyEdit { current in
            AppSettings(
                importPreferences: ImportPreferences(
                    duplicatePolicy: policy,
                    useMusicKitMetadataEnrichment: current.importPreferences.useMusicKitMetadataEnrichment
                ),
                playbackPreferences: current.playbackPreferences,
                storagePreferences: current.storagePreferences
            )
        }
    }

    func setMusicKitMetadataEnrichmentEnabled(_ isEnabled: Bool) {
        guard canEditPlayback else { return }
        metadataIntentGeneration = nextGeneration(after: metadataIntentGeneration)
        let generation = metadataIntentGeneration
        metadataActionTask?.cancel()
        metadataRuntimeTask?.cancel()
        metadataRuntimeGeneration = nextGeneration(after: metadataRuntimeGeneration)

        guard let metadataEnrichment else {
            return
        }

        if !isEnabled {
            applyMusicKitMetadataSetting(false)
            let service = metadataEnrichment
            metadataActionTask = Task { @MainActor [weak self] in
                await service.setEnabled(false)
                guard let self,
                      self.metadataIntentGeneration == generation
                else { return }
                self.metadataEnrichmentSnapshot = await service.snapshot()
            }
            return
        }

        metadataActionTask = Task { @MainActor [weak self] in
            let authorization = await metadataEnrichment.requestAuthorization()
            guard !Task.isCancelled,
                  let self,
                  self.metadataIntentGeneration == generation
            else { return }
            guard authorization == .authorized else {
                await metadataEnrichment.setEnabled(false)
                return
            }

            self.applyMusicKitMetadataSetting(true)
            await self.waitForPendingWork()
            guard !Task.isCancelled,
                  self.metadataIntentGeneration == generation,
                  self.settings.importPreferences.useMusicKitMetadataEnrichment,
                  self.mutationState == .saved
            else {
                await metadataEnrichment.setEnabled(false)
                return
            }
            await metadataEnrichment.setEnabled(true)
            self.metadataEnrichmentSnapshot = await metadataEnrichment.snapshot()
        }
    }

    func startMusicKitMetadataScan() {
        guard metadataEnrichmentSnapshot.isEnabled,
              metadataEnrichmentSnapshot.authorization == .authorized,
              metadataEnrichmentSnapshot.scan.status != .scanning
        else { return }
        Task { [metadataEnrichment] in
            await metadataEnrichment?.startScan()
        }
    }

    func cancelMusicKitMetadataScan() {
        Task { [metadataEnrichment] in
            await metadataEnrichment?.cancelScan()
        }
    }

    func requestMusicKitAuthorization() {
        metadataActionTask?.cancel()
        guard let metadataEnrichment else { return }
        metadataActionTask = Task { @MainActor [weak self] in
            _ = await metadataEnrichment.requestAuthorization()
            guard let self, !Task.isCancelled else { return }
            self.metadataEnrichmentSnapshot = await metadataEnrichment.snapshot()
        }
    }

    private func applyMusicKitMetadataSetting(_ isEnabled: Bool) {
        applyEdit { current in
            AppSettings(
                importPreferences: current.importPreferences.settingMusicKitMetadataEnrichment(isEnabled),
                playbackPreferences: current.playbackPreferences,
                storagePreferences: current.storagePreferences
            )
        }
    }

    private func syncMetadataRuntime(for settings: AppSettings) {
        metadataActionTask?.cancel()
        metadataActionTask = nil
        metadataRuntimeTask?.cancel()
        metadataRuntimeGeneration = nextGeneration(after: metadataRuntimeGeneration)
        let generation = metadataRuntimeGeneration
        let requestedValue = settings.importPreferences.useMusicKitMetadataEnrichment
        guard let metadataEnrichment else { return }
        let previousTask = metadataRuntimeTask
        metadataRuntimeTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await metadataEnrichment.setEnabled(requestedValue)
            guard !Task.isCancelled,
                  let self,
                  self.metadataRuntimeGeneration == generation
            else { return }
            let snapshot = await metadataEnrichment.snapshot()
            self.metadataEnrichmentSnapshot = snapshot
            if requestedValue,
               !snapshot.isEnabled,
               self.settings.importPreferences.useMusicKitMetadataEnrichment
            {
                self.applyMusicKitMetadataSetting(false)
            }
        }
    }

    private func invalidateMetadataTasks() {
        metadataIntentGeneration = nextGeneration(after: metadataIntentGeneration)
        metadataRuntimeGeneration = nextGeneration(after: metadataRuntimeGeneration)
        metadataActionTask?.cancel()
        metadataRuntimeTask?.cancel()
    }

    func setAutomaticallyPruneCache(_ isEnabled: Bool) {
        applyEdit { current in
            let storage = try StoragePreferences(
                cacheLimit: current.storagePreferences.cacheLimit,
                automaticallyPruneCache: isEnabled,
                stagingRetention: current.storagePreferences.stagingRetention
            )
            return AppSettings(
                importPreferences: current.importPreferences,
                playbackPreferences: current.playbackPreferences,
                storagePreferences: storage
            )
        }
    }

    func setCacheLimit(bytes: Int64) {
        do {
            let limit = try StorageByteLimit(bytes: bytes)
            let storage = try StoragePreferences(
                cacheLimit: limit,
                automaticallyPruneCache: settings.storagePreferences.automaticallyPruneCache,
                stagingRetention: settings.storagePreferences.stagingRetention
            )
            applyEdit { current in
                AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: current.playbackPreferences,
                    storagePreferences: storage
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    func setStagingRetention(_ duration: Duration) {
        do {
            let storage = try StoragePreferences(
                cacheLimit: settings.storagePreferences.cacheLimit,
                automaticallyPruneCache: settings.storagePreferences.automaticallyPruneCache,
                stagingRetention: duration
            )
            applyEdit { current in
                AppSettings(
                    importPreferences: current.importPreferences,
                    playbackPreferences: current.playbackPreferences,
                    storagePreferences: storage
                )
            }
        } catch {
            recordValidationFailure(error)
        }
    }

    func requestReset() {
        guard loadState == .loaded || loadState.failure != nil else { return }
        isResetConfirmationPresented = true
    }

    func cancelReset() {
        isResetConfirmationPresented = false
    }

    func confirmReset() async {
        let loadFailure = loadState.failure
        guard loadState == .loaded || loadFailure != nil else { return }
        isResetConfirmationPresented = false
        failedSaveSettings = nil

        if let loadFailure {
            loadState = .loading
            lastFailure = nil
            do {
                try await store.reset()
                try Task.checkCancellation()
                await load()
            } catch is CancellationError {
                loadState = .failed(loadFailure)
            } catch {
                loadState = .failed(makeFailure(from: error))
            }
            return
        }

        settings = .defaults
        mutationState = .saving
        lastFailure = nil
        syncMetadataRuntime(for: .defaults)
        enqueue(.reset(id: nextOperationID()))
    }

    private func applyEdit(_ edit: (AppSettings) throws -> AppSettings) {
        guard canEditPlayback else { return }

        do {
            let next = try edit(settings).validated()
            guard next != settings else { return }
            failedSaveSettings = nil
            settings = next
            mutationState = .saving
            lastFailure = nil
            enqueue(.save(id: nextOperationID(), settings: next))
        } catch {
            recordValidationFailure(error)
        }
    }

    private func recordValidationFailure(_ error: Error) {
        let failure = makeFailure(from: error)
        failedSaveSettings = nil
        lastFailure = failure
        mutationState = .failed(failure)
    }

    func retryFailedSave() {
        guard loadState == .loaded,
              !isSaving,
              canRetryFailedSave,
              let failedSaveSettings
        else { return }

        self.failedSaveSettings = nil
        settings = failedSaveSettings
        mutationState = .saving
        lastFailure = nil
        enqueue(.save(id: nextOperationID(), settings: failedSaveSettings))
    }

    private func nextOperationID() -> UInt64 {
        operationSequence = operationSequence == UInt64.max ? 0 : operationSequence + 1
        return operationSequence
    }

    private func enqueue(_ operation: SettingsOperation) {
        switch operation {
        case .save:
            pendingOperation = operation
        case .reset:
            // Reset is the latest user intent. It supersedes a queued save but
            // waits behind an already running operation in the same worker.
            pendingOperation = operation
        }
        startOperationWorkerIfNeeded()
    }

    private func startOperationWorkerIfNeeded() {
        guard operationTask == nil else { return }
        operationTask = Task { @MainActor [weak self] in
            await self?.drainOperations()
        }
    }

    private func drainOperations() async {
        while !Task.isCancelled {
            guard let operation = pendingOperation else { break }
            pendingOperation = nil
            inFlightOperation = operation

            do {
                switch operation {
                case .save(_, let value):
                    try await store.save(value)
                    try Task.checkCancellation()
                    committedSettings = value
                    failedSaveSettings = nil
                    rememberLocalWrite(value)
                    if pendingOperation == nil, settings == value {
                        mutationState = .saved
                        lastFailure = nil
                    }
                case .reset:
                    try await store.reset()
                    try Task.checkCancellation()
                    committedSettings = .defaults
                    rememberLocalWrite(.defaults)
                    if pendingOperation == nil, settings == .defaults {
                        mutationState = .saved
                        lastFailure = nil
                    }
                }
            } catch is CancellationError {
                pendingOperation = nil
                inFlightOperation = nil
                rollbackToCommitted()
                mutationState = .cancelled
                break
            } catch {
                let failure = makeFailure(from: error)
                lastFailure = failure
                if pendingOperation == nil {
                    if case .save(_, let value) = operation {
                        failedSaveSettings = value
                    } else {
                        failedSaveSettings = nil
                    }
                    rollbackToCommitted()
                    mutationState = .failed(failure)
                    syncMetadataRuntime(for: settings)
                }
            }

            inFlightOperation = nil
        }

        operationTask = nil
    }

    private func cancelOperations() async {
        guard operationTask != nil || pendingOperation != nil else { return }
        pendingOperation = nil
        let task = operationTask
        task?.cancel()
        await task?.value
        operationTask = nil
        inFlightOperation = nil
        failedSaveSettings = nil
        rollbackToCommitted()
        syncMetadataRuntime(for: settings)
    }

    private func cancelStorageRefresh() async {
        guard let storageRefreshTask else { return }
        storageRefreshGeneration = nextGeneration(after: storageRefreshGeneration)
        storageRefreshTask.cancel()
        await storageRefreshTask.value
        self.storageRefreshTask = nil
        isRefreshingStorage = false
    }

    private func nextGeneration(after value: UInt64) -> UInt64 {
        value == UInt64.max ? 0 : value + 1
    }

    private func rollbackToCommitted() {
        guard let committedSettings else { return }
        settings = committedSettings
    }

    private func rememberLocalWrite(_ value: AppSettings) {
        recentlyWrittenSettings.insert(value)
        if recentlyWrittenSettings.count > 8 {
            recentlyWrittenSettings.remove(recentlyWrittenSettings.first!)
        }
    }

    private func receiveExternal(_ value: AppSettings) {
        do {
            let validated = try value.validated()
            if recentlyWrittenSettings.remove(validated) != nil {
                committedSettings = validated
                if pendingOperation == nil, inFlightOperation == nil, settings == validated {
                    mutationState = .saved
                }
                return
            }

            guard validated != settings else { return }

            // An external commit wins over a queued local edit. A running
            // repository operation is cancelled so its stale result cannot
            // update the feature state after this point.
            pendingOperation = nil
            operationTask?.cancel()
            settings = validated
            committedSettings = validated
            failedSaveSettings = nil
            mutationState = .saved
            lastFailure = nil
            loadState = .loaded
            syncMetadataRuntime(for: validated)
        } catch {
            lastFailure = makeFailure(from: error)
        }
    }

    private func makeFailure(from error: Error) -> SettingsFeatureFailure {
        if let failure = error as? SettingsFeatureFailure {
            return failure
        }
        if let error = error as? AppServiceError {
            return SettingsFeatureFailure(
                diagnosticCode: error.diagnosticCode,
                message: error.failureReason,
                isRetryable: error.isRetryable
            )
        }
        if let error = error as? SettingsError {
            let message: String
            switch error {
            case .decoding:
                message = L("设置数据无法读取。")
            case .unsupportedSchemaVersion:
                message = L("设置数据版本与当前应用不兼容。")
            case .invalidValue:
                message = L("设置值不符合允许范围。")
            case .migrationFailed:
                message = L("设置数据无法升级。")
            case .readFailed:
                message = L("设置读取失败。")
            case .writeFailed:
                message = L("设置保存失败。")
            case .resetFailed:
                message = L("设置重置失败。")
            }
            return SettingsFeatureFailure(
                diagnosticCode: error.description,
                message: message,
                isRetryable: error.isRetryable
            )
        }
        if error is CancellationError {
            return SettingsFeatureFailure(
                diagnosticCode: "settings.cancelled",
                message: L("设置操作已取消。"),
                isRetryable: false
            )
        }
        return SettingsFeatureFailure(
            diagnosticCode: "settings.unknown",
            message: L("设置操作无法完成。"),
            isRetryable: true
        )
    }
}
