import Foundation
import MediaSourceAPI
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

public enum AppStartupFallback: String, Codable, Equatable, Hashable, Sendable {
    case settingsCorrupted
    case storagePruningFailed
    case metadataRepairFailed
}

@available(macOS 13.0, iOS 16.0, *)
public struct AppStartupReport: Codable, Equatable, Sendable {
    public let recovery: LibraryRecoveryResult
    public let effectiveSettings: EffectivePlaybackSettings
    public let fallbacks: Set<AppStartupFallback>

    public init(
        recovery: LibraryRecoveryResult,
        effectiveSettings: EffectivePlaybackSettings,
        fallbacks: Set<AppStartupFallback> = []
    ) {
        self.recovery = recovery
        self.effectiveSettings = effectiveSettings
        self.fallbacks = fallbacks
    }
}

/// The composition-root factory. It exposes only Feature façades and owns the
/// lifetime of cross-service subscriptions.
@available(macOS 13.0, iOS 16.0, *)
@MainActor
public final class AppServiceContainer {
    public let library: any LibraryServing
    public let artwork: any ArtworkServing
    public let importer: any ImportServing
    public let metadataEnrichment: any MetadataEnrichmentServing
    public let lyrics: any LyricsServing
    public let playlists: any PlaylistServing
    public let playback: any PlaybackServing
    public let sleepTimer: any SleepTimerServing
    public let settings: any SettingsServing
    public let storageMaintenance: any StorageMaintenanceServing
    public let onlineSources: any OnlineSourceServing
    public let onlineAudition: any OnlineAuditionServing
    public let onlineDownloadQueue: OnlineDownloadQueue
    public let mediaSourceResolver: any MediaSourceResolving

    private let libraryCoordinator: LibraryCoordinator
    private let artworkCoordinator: ArtworkCoordinator
    private let importCoordinator: ImportCoordinator
    private let metadataEnrichmentCoordinator: MetadataEnrichmentCoordinator
    private let lyricsCoordinator: LyricsCoordinator
    private let playlistCoordinator: PlaylistCoordinator
    private let playbackCoordinator: PlaybackCoordinator
    private let sleepTimerCoordinator: SleepTimerCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let storageMaintenanceCoordinator: StorageMaintenanceCoordinator
    private let onlineSourceCoordinator: OnlineSourceCoordinator
    private let onlineAuditionCoordinator: OnlineAuditionCoordinator
    private let onlineDownloadQueueCoordinator: OnlineDownloadQueue
    private var settingsTask: Task<Void, Never>?
    private var startupReport: AppStartupReport?
    private var startTask: (id: UUID, task: Task<AppStartupReport, Error>)?
    private var automaticMaintenanceTask: (
        id: UUID,
        task: Task<Set<AppStartupFallback>, Never>
    )?
    private var automaticMaintenanceFallbacks: Set<AppStartupFallback>?
    private var stopTask: (id: UUID, task: Task<Void, Never>)?
    private var isStopped = false

    public init(dependencies: AppDependencies) throws {
        let sourceRegistry = try MediaSourceRegistry(sources: dependencies.mediaSources)
        let onlineSourceService = try OnlineSourceCoordinator(
            sources: dependencies.onlineSources,
            factory: dependencies.onlineSourceFactory
        )
        let playbackService = PlaybackCoordinator(
            libraryRepository: dependencies.libraryRepository,
            sourceResolver: sourceRegistry,
            queueRepository: dependencies.playbackQueueRepository,
            historyRepository: dependencies.playbackHistoryRepository,
            engine: dependencies.playbackEngine,
            audioSession: dependencies.audioSession,
            nowPlaying: dependencies.nowPlaying,
            remoteCommands: dependencies.remoteCommands,
            playbackCapabilities: dependencies.playbackCapabilities,
            systemCapabilities: dependencies.systemCapabilities,
            clock: dependencies.clock,
            idGenerator: dependencies.idGenerator,
            randomSource: dependencies.randomSource
        )
        let onlineAuditionService = OnlineAuditionCoordinator(
            onlineSources: onlineSourceService,
            engine: dependencies.onlineAuditionEngine,
            audioSession: dependencies.audioSession,
            formalPlayback: playbackService
        )
        playbackService.setTransientPlaybackPreflight { [weak onlineAuditionService] in
            guard let onlineAuditionService,
                  onlineAuditionService.snapshot.hasRetainedSession
            else {
                return
            }
            await onlineAuditionService.close()
        }
        let artworkPruner: (@Sendable () async throws -> Void)?
        if let storageMaintenance = dependencies.storageMaintenance {
            artworkPruner = { [storageMaintenance] in
                _ = try await storageMaintenance.pruneOrphanedArtwork()
            }
        } else {
            artworkPruner = nil
        }
        let libraryService = LibraryCoordinator(
            repository: dependencies.libraryRepository,
            remover: dependencies.managedMediaRemover,
            artworkWriter: dependencies.artworkWriter,
            artworkPruner: artworkPruner,
            queueRepository: dependencies.playbackQueueRepository,
            historyRepository: dependencies.playbackHistoryRepository,
            deletionHandler: { [weak playbackService] itemIDs in
                guard let playbackService else { return }
                try await playbackService.handleLibraryDeletion(itemIDs)
            }
        )
        let sleepTimerService = SleepTimerCoordinator(
            playback: playbackService,
            clock: dependencies.clock,
            calendar: dependencies.calendar
        )
        let metadataEnrichmentService = MetadataEnrichmentCoordinator(
            providers: dependencies.metadataEnrichmentProviders,
            recordRepository: dependencies.metadataEnrichmentRecordRepository,
            libraryRepository: dependencies.libraryRepository,
            library: libraryService,
            clock: dependencies.clock
        )
        let lyricsService = LyricsCoordinator(
            providers: dependencies.lyricsProviders,
            library: libraryService
        )
        let importService = ImportCoordinator(
            importer: dependencies.mediaImporter,
            metadataEnrichment: metadataEnrichmentService
        )
        let onlineDownloadQueueService = OnlineDownloadQueue(
            onlineSources: onlineSourceService,
            importer: importService,
            persistence: dependencies.onlineDownloadQueueStore
        )

        self.playbackCoordinator = playbackService
        self.sleepTimerCoordinator = sleepTimerService
        self.libraryCoordinator = libraryService
        self.artworkCoordinator = ArtworkCoordinator(sourceResolver: sourceRegistry)
        self.metadataEnrichmentCoordinator = metadataEnrichmentService
        self.lyricsCoordinator = lyricsService
        self.importCoordinator = importService
        self.playlistCoordinator = PlaylistCoordinator(repository: dependencies.playlistRepository)
        self.settingsCoordinator = SettingsCoordinator(
            repository: dependencies.settingsRepository,
            playbackCapabilities: dependencies.playbackCapabilities,
            equalizerDescriptor: dependencies.playbackEngine?.equalizerDescriptor,
            systemCapabilities: dependencies.systemCapabilities
        )
        self.storageMaintenanceCoordinator = StorageMaintenanceCoordinator(
            adapter: dependencies.storageMaintenance,
            library: libraryService
        )
        self.onlineSourceCoordinator = onlineSourceService
        self.onlineAuditionCoordinator = onlineAuditionService
        self.onlineDownloadQueueCoordinator = onlineDownloadQueueService

        library = libraryCoordinator
        artwork = artworkCoordinator
        importer = importCoordinator
        metadataEnrichment = metadataEnrichmentCoordinator
        lyrics = lyricsCoordinator
        playlists = playlistCoordinator
        playback = playbackCoordinator
        sleepTimer = sleepTimerCoordinator
        settings = settingsCoordinator
        storageMaintenance = storageMaintenanceCoordinator
        onlineSources = onlineSourceCoordinator
        onlineAudition = onlineAuditionCoordinator
        onlineDownloadQueue = onlineDownloadQueueCoordinator
        mediaSourceResolver = sourceRegistry
    }

    public var libraryServing: any LibraryServing { library }
    public var artworkServing: any ArtworkServing { artwork }
    public var importServing: any ImportServing { importer }
    public var metadataEnrichmentServing: any MetadataEnrichmentServing {
        metadataEnrichment
    }
    public var playlistServing: any PlaylistServing { playlists }
    public var playbackServing: any PlaybackServing { playback }
    public var playbackAudioServing: any PlaybackAudioServing { playbackCoordinator }
    public var sleepTimerServing: any SleepTimerServing { sleepTimer }
    public var settingsServing: any SettingsServing { settings }
    public var storageMaintenanceServing: any StorageMaintenanceServing { storageMaintenance }
    public var onlineDownloadQueueServing: OnlineDownloadQueue {
        onlineDownloadQueueCoordinator
    }

    /// Starts recovery, loads user intent, applies capability clipping, and
    /// installs the settings-to-playback lifecycle subscription. Repeated
    /// and concurrent calls share one attempt and return the same report.
    public func start() async throws -> AppStartupReport {
        if let stopTask {
            await stopTask.task.value
            try Task.checkCancellation()
        }
        guard !isStopped else {
            throw AppServiceError.invalidRequest(operation: "services.startAfterStop")
        }
        if let startupReport { return startupReport }

        let attempt: (id: UUID, task: Task<AppStartupReport, Error>)
        if let startTask {
            attempt = startTask
        } else {
            let attemptID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                let recovery = try await self.libraryCoordinator.recoverPendingRemovals()
                try Task.checkCancellation()
                let settingsResult = try await self.effectiveSettingsOrDefault()
                try Task.checkCancellation()
                let importPreferences = settingsResult.effective.settings.importPreferences
                await self.applyOnlineSourcePreferences(importPreferences)
                await self.metadataEnrichmentCoordinator.setPrivacyPreferences(
                    importPreferences.privacyPreferences
                )
                let metadataProviders = importPreferences.runtimeMetadataProviders
                await self.metadataEnrichmentCoordinator.setProviderPreferences(
                    metadataProviders
                )
                await self.metadataEnrichmentCoordinator.setEnabled(
                    metadataProviders.contains(where: \.isEnabled)
                )
                await self.lyricsCoordinator.setPrivacyPreferences(
                    importPreferences.privacyPreferences
                )
                await self.lyricsCoordinator.setProviderPreferences(
                    importPreferences.runtimeLyricsProviders
                )
                try Task.checkCancellation()
                await self.playbackCoordinator.apply(settingsResult.effective)
                try Task.checkCancellation()
                try await self.playbackCoordinator.start()
                try Task.checkCancellation()
                self.sleepTimerCoordinator.start(
                    preferences: settingsResult.effective.settings.playbackPreferences.sleepTimer
                )

                guard self.startTask?.id == attemptID,
                      self.stopTask == nil,
                      !self.isStopped
                else {
                    throw CancellationError()
                }

                self.installSettingsSubscription()
                let report = AppStartupReport(
                    recovery: recovery,
                    effectiveSettings: settingsResult.effective,
                    fallbacks: settingsResult.fallbacks
                )
                self.startupReport = report
                self.scheduleAutomaticMaintenance(
                    settingsResult.effective.settings.storagePreferences
                )
                return report
            }
            attempt = (attemptID, task)
            startTask = attempt
        }

        do {
            let report = try await attempt.task.value
            if startTask?.id == attempt.id {
                startTask = nil
            }
            try Task.checkCancellation()
            guard !isStopped, stopTask == nil, startupReport == report else {
                throw CancellationError()
            }
            return report
        } catch {
            if startTask?.id == attempt.id {
                startTask = nil
            }
            throw error
        }
    }

    public func updatePlaybackCapabilities(_ capabilities: PlaybackCapabilities) async {
        await settingsCoordinator.updatePlaybackCapabilities(capabilities)
        await playbackCoordinator.updateCapabilities(capabilities)
    }

    /// Automatic cache/artwork maintenance is deliberately outside the
    /// launch-critical path. Callers can observe its eventual fallback without
    /// delaying the first usable frame.
    public func waitForPostStartupMaintenance() async -> Set<AppStartupFallback> {
        if let automaticMaintenanceFallbacks {
            return automaticMaintenanceFallbacks
        }
        guard let attempt = automaticMaintenanceTask else { return [] }

        let fallbacks = await attempt.task.value
        if automaticMaintenanceTask?.id == attempt.id {
            automaticMaintenanceTask = nil
            automaticMaintenanceFallbacks = fallbacks
        }
        return fallbacks
    }

    public func updateSystemCapabilities(
        _ capabilities: SystemIntegrationCapabilitySnapshot
    ) async {
        await settingsCoordinator.updateSystemCapabilities(capabilities)
    }

    /// Tears down cross-service subscriptions and releases playback/system
    /// adapters. Stop is terminal because the playback engine is disposed.
    /// Calling it more than once is safe.
    public func stop() async {
        if let stopTask {
            await stopTask.task.value
            return
        }
        guard !isStopped else { return }

        isStopped = true
        let stopID = UUID()
        let startAttempt = startTask
        let maintenanceAttempt = automaticMaintenanceTask
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            startAttempt?.task.cancel()
            maintenanceAttempt?.task.cancel()
            self.settingsTask?.cancel()
            self.settingsTask = nil
            await self.metadataEnrichmentCoordinator.setEnabled(false)
            self.sleepTimerCoordinator.stop()
            await self.onlineDownloadQueueCoordinator.shutdown()
            await self.onlineAuditionCoordinator.shutdown()
            await self.playbackCoordinator.shutdown()
            if let startAttempt {
                _ = await startAttempt.task.result
            }
            if let maintenanceAttempt {
                _ = await maintenanceAttempt.task.value
            }

            if self.startTask?.id == startAttempt?.id {
                self.startTask = nil
            }
            self.startupReport = nil
            self.automaticMaintenanceTask = nil
            self.automaticMaintenanceFallbacks = nil
            if self.stopTask?.id == stopID {
                self.stopTask = nil
            }
        }
        stopTask = (stopID, task)
        await task.value
    }

    private func effectiveSettingsOrDefault() async throws -> (
        effective: EffectivePlaybackSettings,
        fallbacks: Set<AppStartupFallback>
    ) {
        do {
            return (try await settingsCoordinator.effective(), [])
        } catch let error as AppServiceError {
            switch error {
            case .missingDependency:
                return (await defaultEffectiveSettings(), [])
            case .settings(let settingsError) where settingsError.isPersistedDataCorruption:
                return (await defaultEffectiveSettings(), [.settingsCorrupted])
            default:
                throw error
            }
        }
    }

    private func scheduleAutomaticMaintenance(_ preferences: StoragePreferences) {
        guard automaticMaintenanceTask == nil,
              automaticMaintenanceFallbacks == nil
        else {
            return
        }

        let attemptID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return Set<AppStartupFallback>() }
            var fallbacks = Set<AppStartupFallback>()
            do {
                _ = try await self.libraryCoordinator.repairMetadata()
            } catch is CancellationError {
                return fallbacks
            } catch {
                fallbacks.insert(.metadataRepairFailed)
            }
            do {
                try await self.storageMaintenanceCoordinator.enforceAutomaticPruning(preferences)
                return fallbacks
            } catch is CancellationError {
                return fallbacks
            } catch {
                fallbacks.insert(.storagePruningFailed)
                return fallbacks
            }
        }
        automaticMaintenanceTask = (attemptID, task)
    }

    private func defaultEffectiveSettings() async -> EffectivePlaybackSettings {
        EffectivePlaybackSettings(
            settings: .defaults,
            effects: .neutral,
            playbackCapabilities: await settingsCapabilities(),
            equalizerDescriptor: nil,
            systemCapabilities: await settingsSystemCapabilities()
        )
    }

    private func settingsCapabilities() async -> PlaybackCapabilities {
        await settingsCoordinator.currentPlaybackCapabilities()
    }

    private func settingsSystemCapabilities() async -> SystemIntegrationCapabilitySnapshot {
        await settingsCoordinator.currentSystemCapabilities()
    }

    private func installSettingsSubscription() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.settingsCoordinator.makeEffectiveChangeStream()
            for await effective in stream {
                guard !Task.isCancelled else { return }
                await self.playbackCoordinator.apply(effective)
                await self.sleepTimerCoordinator.update(
                    preferences: effective.settings.playbackPreferences.sleepTimer
                )
                let importPreferences = effective.settings.importPreferences
                await self.applyOnlineSourcePreferences(importPreferences)
                await self.metadataEnrichmentCoordinator.setPrivacyPreferences(
                    importPreferences.privacyPreferences
                )
                await self.lyricsCoordinator.setPrivacyPreferences(
                    importPreferences.privacyPreferences
                )
                let metadataProviders = importPreferences.runtimeMetadataProviders
                await self.metadataEnrichmentCoordinator.setProviderPreferences(
                    metadataProviders
                )
                await self.metadataEnrichmentCoordinator.setEnabled(
                    metadataProviders.contains(where: \.isEnabled)
                )
                await self.lyricsCoordinator.setProviderPreferences(
                    importPreferences.runtimeLyricsProviders
                )
            }
        }
    }

    /// Applies the persisted online-source gate and stops a transient audition
    /// in the same turn when settings revoke its runtime availability. Without
    /// this boundary, the source list could correctly show a disabled source
    /// while the dedicated audition engine kept playing its already-resolved
    /// HTTP resource.
    private func applyOnlineSourcePreferences(
        _ importPreferences: ImportPreferences
    ) async {
        onlineSourceCoordinator.apply(importPreferences)
        let onlineSnapshot = await onlineSourceCoordinator.snapshot()
        onlineDownloadQueueCoordinator.restore(using: onlineSnapshot)
        await onlineDownloadQueueCoordinator.stopUnavailable(using: onlineSnapshot)
        let auditionSnapshot = onlineAuditionCoordinator.snapshot
        guard auditionSnapshot.hasRetainedSession,
              let sourceID = auditionSnapshot.sourceID,
              onlineSnapshot.sources.first(where: { $0.sourceID == sourceID })?.isRuntimeEnabled != true
        else {
            return
        }
        await onlineAuditionCoordinator.close()
    }

    deinit {
        settingsTask?.cancel()
    }
}

private extension SettingsError {
    var isPersistedDataCorruption: Bool {
        switch self {
        case .decoding, .unsupportedSchemaVersion, .invalidValue, .migrationFailed:
            true
        case .readFailed, .writeFailed, .resetFailed:
            false
        }
    }
}
