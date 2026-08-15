import Foundation
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

public enum AppStartupFallback: String, Codable, Equatable, Hashable, Sendable {
    case settingsCorrupted
    case storagePruningFailed
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
    public let playlists: any PlaylistServing
    public let playback: any PlaybackServing
    public let sleepTimer: any SleepTimerServing
    public let settings: any SettingsServing
    public let storageMaintenance: any StorageMaintenanceServing

    private let libraryCoordinator: LibraryCoordinator
    private let artworkCoordinator: ArtworkCoordinator
    private let importCoordinator: ImportCoordinator
    private let playlistCoordinator: PlaylistCoordinator
    private let playbackCoordinator: PlaybackCoordinator
    private let sleepTimerCoordinator: SleepTimerCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let storageMaintenanceCoordinator: StorageMaintenanceCoordinator
    private var settingsTask: Task<Void, Never>?
    private var startupReport: AppStartupReport?
    private var startTask: (id: UUID, task: Task<AppStartupReport, Error>)?
    private var stopTask: (id: UUID, task: Task<Void, Never>)?
    private var isStopped = false

    public init(dependencies: AppDependencies) throws {
        let sourceRegistry = try MediaSourceRegistry(sources: dependencies.mediaSources)
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

        self.playbackCoordinator = playbackService
        self.sleepTimerCoordinator = sleepTimerService
        self.libraryCoordinator = libraryService
        self.artworkCoordinator = ArtworkCoordinator(sourceResolver: sourceRegistry)
        self.importCoordinator = ImportCoordinator(importer: dependencies.mediaImporter)
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

        library = libraryCoordinator
        artwork = artworkCoordinator
        importer = importCoordinator
        playlists = playlistCoordinator
        playback = playbackCoordinator
        sleepTimer = sleepTimerCoordinator
        settings = settingsCoordinator
        storageMaintenance = storageMaintenanceCoordinator
    }

    public var libraryServing: any LibraryServing { library }
    public var artworkServing: any ArtworkServing { artwork }
    public var importServing: any ImportServing { importer }
    public var playlistServing: any PlaylistServing { playlists }
    public var playbackServing: any PlaybackServing { playback }
    public var playbackAudioServing: any PlaybackAudioServing { playbackCoordinator }
    public var sleepTimerServing: any SleepTimerServing { sleepTimer }
    public var settingsServing: any SettingsServing { settings }
    public var storageMaintenanceServing: any StorageMaintenanceServing { storageMaintenance }

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
                var fallbacks = settingsResult.fallbacks
                do {
                    try await self.storageMaintenanceCoordinator.enforceAutomaticPruning(
                        settingsResult.effective.settings.storagePreferences
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    fallbacks.insert(.storagePruningFailed)
                }
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
                    fallbacks: fallbacks
                )
                self.startupReport = report
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
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            startAttempt?.task.cancel()
            self.settingsTask?.cancel()
            self.settingsTask = nil
            self.sleepTimerCoordinator.stop()
            await self.playbackCoordinator.shutdown()
            if let startAttempt {
                _ = await startAttempt.task.result
            }

            if self.startTask?.id == startAttempt?.id {
                self.startTask = nil
            }
            self.startupReport = nil
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
            }
        }
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
