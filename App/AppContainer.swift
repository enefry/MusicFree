import AppServices
import AppleSystemAdapter
import Combine
import Foundation
import LibraryPersistenceAdapter
import LibraryAPI
import LocalMediaAdapter
import MediaSourceAPI
import MusicDomain
import PreferencesPersistenceAdapter
import SettingsAPI
import VLCKitPlaybackAdapter

@MainActor
final class AppContainer: ObservableObject {
    typealias CompositionFactory = @MainActor @Sendable () async throws -> Composition

    struct Composition: Sendable {
        let services: AppServiceContainer
        let scanner: AppDocumentsScanner?
        let importAvailable: Bool
        let startupIssues: [AppStartupIssue]
        let diagnostics: [CompositionDiagnostic]

        init(
            services: AppServiceContainer,
            scanner: AppDocumentsScanner? = nil,
            importAvailable: Bool = false,
            startupIssues: [AppStartupIssue] = [],
            diagnostics: [CompositionDiagnostic] = []
        ) {
            self.services = services
            self.scanner = scanner
            self.importAvailable = importAvailable
            self.startupIssues = startupIssues
            self.diagnostics = diagnostics
        }
    }

    struct CompositionDiagnostic: Sendable {
        let code: String
        let message: String
    }

    let router: AppRouter
    let lifecycleCoordinator: AppLifecycleCoordinator
    let diagnosticsExporter: AppDiagnosticsExporter
    private(set) var serviceContainer: AppServiceContainer?
    private(set) var documentsScanner: AppDocumentsScanner?
    private(set) var importAvailable: Bool
    private(set) var compositionIssues: [AppStartupIssue]

    private let compositionFactory: CompositionFactory
    private var compositionTask: (id: UUID, task: Task<Bool, Never>)?
    private var teardownTask: (id: UUID, task: Task<Void, Never>)?
    private var activeSceneIDs: Set<UUID> = []
    private var serviceStartupIssues: [AppStartupIssue] = []

    @Published private(set) var startupState: AppStartupState

    init(
        router: AppRouter = AppRouter(),
        lifecycleCoordinator: AppLifecycleCoordinator? = nil,
        diagnosticsExporter: AppDiagnosticsExporter? = nil,
        startupState: AppStartupState = .loading,
        serviceContainer: AppServiceContainer? = nil,
        documentsScanner: AppDocumentsScanner? = nil,
        importAvailable: Bool = false,
        compositionIssues: [AppStartupIssue]? = nil,
        compositionFactory: CompositionFactory? = nil
    ) {
        self.router = router
        self.lifecycleCoordinator = lifecycleCoordinator ?? AppLifecycleCoordinator()
        self.diagnosticsExporter = diagnosticsExporter ?? AppDiagnosticsExporter()
        let resolvedCompositionFactory = compositionFactory ?? Self.makeDefaultComposition
        self.compositionFactory = resolvedCompositionFactory

        if let serviceContainer {
            self.serviceContainer = serviceContainer
            self.documentsScanner = documentsScanner
            self.importAvailable = importAvailable
            self.compositionIssues = compositionIssues ?? startupState.issues
        } else {
            self.serviceContainer = nil
            self.documentsScanner = nil
            self.importAvailable = false
            self.compositionIssues = compositionIssues ?? []
        }
        self.startupState = startupState

        _ = AppServicesModule.self
        _ = LocalMediaAdapterModule.self
        _ = LibraryPersistenceAdapterModule.self
        _ = AppleSystemAdapterModule.self
        _ = PreferencesPersistenceAdapterModule.self
        _ = VLCKitPlaybackAdapterModule.self

        self.diagnosticsExporter.record(startupState: startupState)
    }

    static func makeForTesting(
        startupState: AppStartupState = .ready,
        diagnosticsExporter: AppDiagnosticsExporter? = nil,
        compositionIssues: [AppStartupIssue] = [],
        mediaImporter: (any MediaImporting)? = nil,
        storageMaintenance: (any StorageMaintenanceServing)? = nil
    ) async throws -> AppContainer {
        let settingsSuitePrefix = "win.tools4me.musicplayer.tests.\(UUID().uuidString)"
        let factory: CompositionFactory = {
            let services = try await makeTestingServices(
                settingsSuiteName: "\(settingsSuitePrefix).\(UUID().uuidString)",
                mediaImporter: mediaImporter,
                storageMaintenance: storageMaintenance
            )
            return Composition(
                services: services,
                importAvailable: mediaImporter != nil,
                startupIssues: compositionIssues
            )
        }
        let composition = try await factory()
        return AppContainer(
            diagnosticsExporter: diagnosticsExporter,
            startupState: startupState,
            serviceContainer: composition.services,
            importAvailable: composition.importAvailable,
            compositionIssues: composition.startupIssues,
            compositionFactory: factory
        )
    }

    func updateStartupState(_ state: AppStartupState) {
        guard startupState != state else { return }

        startupState = state
        diagnosticsExporter.record(startupState: state)
    }

    /// Marks a composed and started graph usable without erasing adapter-level
    /// degradation discovered while the graph was built.
    func completeStartup(_ report: AppStartupReport? = nil) {
        serviceStartupIssues = report?.fallbacks.compactMap { fallback in
            switch fallback {
            case .settingsCorrupted:
                .settingsCorrupted
            case .storagePruningFailed:
                .cacheUnavailable
            }
        } ?? []
        updateStartupStateForCurrentIssues()
    }

    var activeSceneCount: Int {
        activeSceneIDs.count
    }

    /// The service graph is app-owned so closing one window cannot dispose the
    /// adapters used by another window or by background audio.
    func sceneDidAppear(_ sceneID: UUID) {
        let inserted = activeSceneIDs.insert(sceneID).inserted
        guard inserted, activeSceneIDs.count == 1 else { return }
        lifecycleCoordinator.start()
    }

    func sceneDidDisappear(_ sceneID: UUID) {
        guard activeSceneIDs.remove(sceneID) != nil else { return }
        if activeSceneIDs.isEmpty {
            lifecycleCoordinator.stop()
        }
    }

    @discardableResult
    func resetCorruptedSettings() async -> Bool {
        guard serviceStartupIssues.contains(.settingsCorrupted),
              let services = serviceContainer
        else {
            return false
        }

        do {
            try await services.settingsServing.reset()
            guard serviceContainer === services else {
                diagnosticsExporter.record(
                    code: "startup.settings.reset-obsolete",
                    message: "The reset completed for a retired service graph."
                )
                return false
            }
            serviceStartupIssues.removeAll { $0 == .settingsCorrupted }
            updateStartupStateForCurrentIssues()
            diagnosticsExporter.record(
                code: "startup.settings.reset-succeeded",
                message: "The user explicitly reset unreadable settings."
            )
            return true
        } catch {
            diagnosticsExporter.record(
                code: "startup.settings.reset-failed",
                message: String(describing: error)
            )
            return false
        }
    }

    /// `AppServiceContainer.stop()` is a terminal teardown because it disposes
    /// the playback engine. Remove that graph so every later start is composed
    /// from fresh adapter instances.
    func stopServicesAndDiscardComposition(
        _ servicesToStop: AppServiceContainer? = nil
    ) async {
        if let servicesToStop, serviceContainer !== servicesToStop {
            await servicesToStop.stop()
            return
        }

        if let teardownTask {
            await teardownTask.task.value
            return
        }

        let teardownID = UUID()
        let compositionAttempt = compositionTask
        let task = Task { @MainActor [weak self] in
            compositionAttempt?.task.cancel()
            if let compositionAttempt {
                _ = await compositionAttempt.task.value
            }

            guard let self else { return }
            if self.compositionTask?.id == compositionAttempt?.id {
                self.compositionTask = nil
            }

            let services = servicesToStop ?? self.serviceContainer
            if let services {
                await services.stop()
            }
            if let services, self.serviceContainer === services {
                self.serviceContainer = nil
                self.documentsScanner = nil
                self.importAvailable = false
                self.compositionIssues = []
                self.serviceStartupIssues = []
            }
            if self.teardownTask?.id == teardownID {
                self.teardownTask = nil
            }
        }
        teardownTask = (teardownID, task)
        await task.value
    }

    /// Records an error only while the failed graph is still the active graph.
    /// A newer retry can be installed while an older start is suspended.
    func handleFailedServiceStart(_ services: AppServiceContainer, error: Error) async {
        await stopServicesAndDiscardComposition(services)
        guard serviceContainer == nil, compositionTask == nil else { return }

        updateStartupState(startupState(for: error))
        diagnosticsExporter.record(
            code: "startup.services.start-failed",
            message: String(describing: error)
        )
    }

    /// Rebuilds a discarded composition after a dependency or store failure.
    /// Tests inject a factory that follows the same fresh-instance contract.
    @discardableResult
    func retryComposition() async -> Bool {
        if let teardownTask {
            await teardownTask.task.value
            guard !Task.isCancelled else { return false }
        }
        guard serviceContainer == nil else { return true }

        let attempt: (id: UUID, task: Task<Bool, Never>)
        if let compositionTask {
            attempt = compositionTask
        } else {
            let attemptID = UUID()
            let factory = compositionFactory
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                do {
                    let composition = try await factory()
                    guard !Task.isCancelled else {
                        await composition.services.stop()
                        return false
                    }
                    guard self.compositionTask?.id == attemptID,
                          self.teardownTask == nil
                    else {
                        await composition.services.stop()
                        return false
                    }
                    guard self.serviceContainer == nil else {
                        await composition.services.stop()
                        return true
                    }

                    self.serviceContainer = composition.services
                    self.documentsScanner = composition.scanner
                    self.importAvailable = composition.importAvailable
                    self.compositionIssues = composition.startupIssues
                    self.serviceStartupIssues = []
                    self.updateStartupState(.loading)
                    self.record(composition.diagnostics)
                    self.diagnosticsExporter.record(
                        code: "startup.composition.retry-succeeded",
                        message: "Application services were composed again."
                    )
                    return true
                } catch is CancellationError {
                    return false
                } catch {
                    guard self.compositionTask?.id == attemptID,
                          self.teardownTask == nil
                    else {
                        return false
                    }
                    let state = self.startupState(for: error)
                    self.updateStartupState(state)
                    self.diagnosticsExporter.record(
                        code: "startup.composition.retry-failed",
                        message: String(describing: error)
                    )
                    return false
                }
            }
            attempt = (attemptID, task)
            compositionTask = attempt
        }

        let succeeded = await attempt.task.value
        if compositionTask?.id == attempt.id, teardownTask == nil {
            compositionTask = nil
        }
        return !Task.isCancelled && succeeded && serviceContainer != nil
    }

    /// Maps service failures to the narrowest user-facing startup state without
    /// exposing adapter paths, framework errors, or credentials.
    func startupState(for error: Error) -> AppStartupState {
        let appError: AppServiceError
        if let error = error as? AppServiceError {
            appError = error
        } else {
            return .recoveryRequired(.dependencyUnavailable)
        }

        switch appError {
        case .library:
            return .recoveryRequired(.libraryStoreUnavailable)
        case .settings:
            return .degraded(.settingsCorrupted)
        case .playback, .systemIntegration:
            return .degraded(.playbackUnavailable)
        case .missingDependency(let dependency), .incompatibleDependency(let dependency):
            let normalized = dependency.lowercased()
            if normalized.contains("library") || normalized.contains("store") {
                return .recoveryRequired(.libraryStoreUnavailable)
            }
            if normalized.contains("settings") {
                return .degraded(.settingsCorrupted)
            }
            if normalized.contains("playback")
                || normalized.contains("audio")
                || normalized.contains("nowplaying")
                || normalized.contains("remote") {
                return .degraded(.playbackUnavailable)
            }
            return .recoveryRequired(.dependencyUnavailable)
        case .mediaSource, .importFailed, .removalFailed:
            return .degraded(.dependencyUnavailable)
        case .cancelled:
            return .loading
        case .invalidRequest, .invalidCommand, .duplicateSource, .sourceNotFound,
             .operationInProgress, .pendingRemoval, .unknown:
            return .recoveryRequired(.dependencyUnavailable)
        }
    }

    private static func makeDefaultComposition() async throws -> Composition {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appSupportRoot = applicationSupport.appendingPathComponent(
            "MusicFree",
            isDirectory: true
        )
        let cacheRoot = caches.appendingPathComponent("MusicFree", isDirectory: true)

        let persistenceConfiguration = try LibraryPersistenceConfiguration(
            storeURL: appSupportRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("MusicFree.store", isDirectory: false)
        )
        let store = try await makePersistenceStore(configuration: persistenceConfiguration)
        try Task.checkCancellation()
        let libraryRepository = SwiftDataLibraryRepository(store: store)
        let playlistRepository = SwiftDataPlaylistRepository(store: store)
        let queueRepository = SwiftDataPlaybackQueueRepository(store: store)
        let historyRepository = SwiftDataPlaybackHistoryRepository(store: store)
        let metadataEnrichmentRecordRepository = FileMetadataEnrichmentRecordRepository(
            fileURL: appSupportRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("metadata-enrichment.json", isDirectory: false)
        )
#if !METADATA_SERVER_DISABLED
        let metadataServerConfiguration = MetadataServerConfiguration.from()
#endif
        let musicBrainzAPIConfiguration = MusicBrainzAPIConfiguration.from()
        let discogsAPIConfiguration = DiscogsAPIConfiguration.from()
#if !LYRICS_DISABLED
        let lrclibAPIConfiguration = LRCLIBAPIConfiguration.from()
#endif

        let localMediaConfiguration = try LocalMediaConfiguration(
            managedRoot: appSupportRoot.appendingPathComponent("Media", isDirectory: true),
            stagingRoot: cacheRoot.appendingPathComponent("ImportStaging", isDirectory: true),
            quarantineRoot: appSupportRoot.appendingPathComponent("Quarantine", isDirectory: true)
        )
        let vlcConfiguration = try VLCKitAdapterConfiguration(
            applicationIdentifier: Bundle.main.bundleIdentifier ?? "win.tools4me.musicplayer",
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0",
            applicationName: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String ?? "MyMusic",
            capabilityPolicy: VLCKitCapabilityPolicy(
                enabledCapabilities: [.seeking, .variableRate, .equalizer]
            )
        )
        var startupIssues: [AppStartupIssue] = []
        var diagnostics: [CompositionDiagnostic] = []
        let playbackEngine: VLCPlaybackEngine?
        do {
            playbackEngine = try VLCPlaybackEngine(configuration: vlcConfiguration)
        } catch {
            playbackEngine = nil
            startupIssues.append(.playbackUnavailable)
            diagnostics.append(.init(
                code: "startup.vlckit.playback-unavailable",
                message: String(describing: error)
            ))
        }

        let probe: VLCMediaProbe?
        do {
            probe = try VLCMediaProbe(configuration: vlcConfiguration)
        } catch {
            probe = nil
            diagnostics.append(.init(
                code: "startup.vlckit.probe-unavailable",
                message: String(describing: error)
            ))
        }

        let metadataReader: VLCMetadataReader?
        do {
            metadataReader = try VLCMetadataReader(configuration: vlcConfiguration)
        } catch {
            metadataReader = nil
            diagnostics.append(.init(
                code: "startup.vlckit.metadata-unavailable",
                message: String(describing: error)
            ))
        }

        let localSource: LocalMediaSource?
        let importer: LocalMediaImporter?
        if let probe, let metadataReader {
            localSource = try LocalMediaSource(
                configuration: localMediaConfiguration,
                probe: probe,
                metadataReader: metadataReader
            )
            importer = try LocalMediaImporter(
                configuration: localMediaConfiguration,
                probe: probe,
                metadataReader: metadataReader,
                libraryRepository: libraryRepository
            )
        } else {
            // Probe and metadata parsing are required by both the managed local
            // source and importer. Omitting both ports makes the loss explicit:
            // the durable library remains browseable, but local playback and
            // import are not advertised through half-functional adapters.
            localSource = nil
            importer = nil
            if !startupIssues.contains(.playbackUnavailable) {
                startupIssues.append(.playbackUnavailable)
            }
            startupIssues.append(.dependencyUnavailable)
        }
        let metadataEnrichmentProvider = MusicKitMetadataProvider()
        var metadataEnrichmentProviders: [any MetadataEnrichmentProviding] = [
            metadataEnrichmentProvider
        ]
        if let musicBrainzAPIConfiguration {
            metadataEnrichmentProviders.append(
                MusicBrainzMetadataProvider(configuration: musicBrainzAPIConfiguration)
            )
        }
#if !METADATA_SERVER_DISABLED
        if let metadataServerConfiguration {
            let durationProvider: MetadataServerMetadataProvider.DurationProvider?
            if let localSource {
                durationProvider = { [localSource] itemID in
                    guard let duration = try? await localSource.probe(itemID).duration else {
                        return nil
                    }
                    let components = duration.components
                    return Double(components.seconds)
                        + Double(components.attoseconds) / 1_000_000_000_000_000_000
                }
            } else {
                durationProvider = nil
            }
            metadataEnrichmentProviders.append(
                MetadataServerMetadataProvider(
                    configuration: metadataServerConfiguration,
                    durationProvider: durationProvider
                )
            )
        }
#endif
        if let discogsAPIConfiguration {
            metadataEnrichmentProviders.append(
                DiscogsMetadataProvider(configuration: discogsAPIConfiguration)
            )
        }
#if LYRICS_DISABLED
        let lyricsProviders: [any LyricsProviding] = []
#else
        var lyricsProviders: [any LyricsProviding] = []
#if !METADATA_SERVER_DISABLED
        if let metadataServerConfiguration,
           let lyricsConfiguration = MetadataServerLyricsConfiguration(
               metadataServerConfiguration: metadataServerConfiguration
           ) {
            lyricsProviders.append(
                MetadataServerLyricsProvider(configuration: lyricsConfiguration)
            )
        }
#endif
        if let lrclibAPIConfiguration {
            lyricsProviders.append(LRCLIBLyricsProvider(configuration: lrclibAPIConfiguration))
        }
#endif
        let remover = try ManagedMediaRemover(
            configuration: localMediaConfiguration,
            libraryRepository: libraryRepository
        )
        let storageMaintenance = try LocalMediaStorageMaintenance(
            configuration: localMediaConfiguration,
            libraryRepository: libraryRepository
        )
        let settingsRepository = try UserDefaultsSettingsRepository(
            suiteName: PreferencesConfiguration.defaultSuiteName
        )
        let appleSystemConfiguration = AppleSystemConfiguration.standard
        let audioSession = try AppleAudioSessionManager(
            configuration: appleSystemConfiguration
        )
        let nowPlaying = AppleNowPlayingPublisher()
        let remoteCommands = AppleRemoteCommandReceiver(
            configuration: appleSystemConfiguration
        )
        let systemCapabilities = AppleSystemCapabilityDetector.current
        let mediaSources: [any MediaSource] = localSource.map { [$0] } ?? []
        let artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)?
        if let localSource {
            artworkWriter = { [localSource] data, artworkID in
                try await localSource.beginArtworkWrite(data, artworkID: artworkID)
            }
        } else {
            artworkWriter = nil
        }
        let dependencies = try AppDependencies(
            mediaSources: mediaSources,
            mediaImporter: importer,
            managedMediaRemover: remover,
            artworkWriter: artworkWriter,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            playbackQueueRepository: queueRepository,
            playbackHistoryRepository: historyRepository,
            settingsRepository: settingsRepository,
            metadataEnrichmentProviders: metadataEnrichmentProviders,
            lyricsProviders: lyricsProviders,
            metadataEnrichmentRecordRepository: metadataEnrichmentRecordRepository,
            storageMaintenance: storageMaintenance,
            playbackEngine: playbackEngine,
            audioSession: audioSession,
            nowPlaying: nowPlaying,
            remoteCommands: remoteCommands,
            systemCapabilities: systemCapabilities
        )
        let services = try AppServiceContainer(dependencies: dependencies)
        return Composition(
            services: services,
            scanner: importer.map { _ in
                AppDocumentsScanner(
                    documentsURL: documents,
                    snapshotURL: appSupportRoot
                        .appendingPathComponent("DocumentsScan", isDirectory: true)
                        .appendingPathComponent("snapshot.json", isDirectory: false),
                    importer: services.importServing
                )
            },
            importAvailable: importer != nil,
            startupIssues: startupIssues,
            diagnostics: diagnostics
        )
    }

    private func record(_ diagnostics: [CompositionDiagnostic]) {
        for diagnostic in diagnostics {
            diagnosticsExporter.record(
                code: diagnostic.code,
                message: diagnostic.message
            )
        }
    }

    private static func makeTestingServices(
        settingsSuiteName: String,
        mediaImporter: (any MediaImporting)? = nil,
        storageMaintenance: (any StorageMaintenanceServing)? = nil
    ) async throws -> AppServiceContainer {
        let store = try await makePersistenceStore(configuration: .inMemory)
        try Task.checkCancellation()
        let libraryRepository = SwiftDataLibraryRepository(store: store)
        let playlistRepository = SwiftDataPlaylistRepository(store: store)
        let queueRepository = SwiftDataPlaybackQueueRepository(store: store)
        let historyRepository = SwiftDataPlaybackHistoryRepository(store: store)
        let settingsRepository = try UserDefaultsSettingsRepository(
            suiteName: settingsSuiteName
        )
        let dependencies = try AppDependencies(
            mediaImporter: mediaImporter,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            playbackQueueRepository: queueRepository,
            playbackHistoryRepository: historyRepository,
            settingsRepository: settingsRepository,
            storageMaintenance: storageMaintenance
        )
        return try AppServiceContainer(dependencies: dependencies)
    }

    /// SwiftData binds a context created on the main thread to the main queue.
    /// Open it in a detached task because repository access is serialized by
    /// LibraryPersistenceStore's actor, not by the UI actor.
    private nonisolated static func makePersistenceStore(
        configuration: LibraryPersistenceConfiguration
    ) async throws -> LibraryPersistenceStore {
        let task = Task.detached(priority: .userInitiated) {
            try LibraryPersistenceStore(configuration: configuration)
        }
        return try await withTaskCancellationHandler {
            let store = try await task.value
            try Task.checkCancellation()
            return store
        } onCancel: {
            task.cancel()
        }
    }

    private func updateStartupStateForCurrentIssues() {
        let issues = Array(Set(compositionIssues + serviceStartupIssues)).sorted {
            $0.rawValue < $1.rawValue
        }
        updateStartupState(issues.isEmpty ? .ready : .degraded(issues))
    }
}
