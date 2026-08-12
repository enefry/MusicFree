import Foundation
import AppServices
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing
import UIKit

@testable import MusicFree

@MainActor
private final class LifecycleEventRecorder {
    var events: [AppLifecycleEvent] = []
}

private enum CompositionFactoryTestError: Error, Sendable {
    case failed
}

@MainActor
private final class CompositionFactoryHarness {
    enum Outcome {
        case success(AppContainer.Composition)
        case failure
    }

    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var outcomes: [Outcome]
    private let suspendsFactory: Bool
    private var invocationWaiters: [Waiter] = []
    private var retryCallerWaiters: [Waiter] = []
    private var factoryRelease: CheckedContinuation<Void, Never>?

    private(set) var invocationCount = 0
    private(set) var retryCallerCount = 0

    init(outcomes: [Outcome], suspendsFactory: Bool = false) {
        self.outcomes = outcomes
        self.suspendsFactory = suspendsFactory
    }

    func makeComposition() async throws -> AppContainer.Composition {
        invocationCount += 1
        Self.resumeSatisfied(&invocationWaiters, currentCount: invocationCount)
        if suspendsFactory {
            await withCheckedContinuation { continuation in
                factoryRelease = continuation
            }
        }
        guard !outcomes.isEmpty else {
            throw CompositionFactoryTestError.failed
        }
        switch outcomes.removeFirst() {
        case .success(let composition):
            return composition
        case .failure:
            throw CompositionFactoryTestError.failed
        }
    }

    func noteRetryCaller() {
        retryCallerCount += 1
        Self.resumeSatisfied(&retryCallerWaiters, currentCount: retryCallerCount)
    }

    func waitForInvocation(count: Int = 1) async {
        guard invocationCount < count else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(Waiter(
                expectedCount: count,
                continuation: continuation
            ))
        }
    }

    func waitForRetryCallers(count: Int) async {
        guard retryCallerCount < count else { return }
        await withCheckedContinuation { continuation in
            retryCallerWaiters.append(Waiter(
                expectedCount: count,
                continuation: continuation
            ))
        }
    }

    func releaseFactory() {
        let continuation = factoryRelease
        factoryRelease = nil
        continuation?.resume()
    }

    private static func resumeSatisfied(
        _ waiters: inout [Waiter],
        currentCount: Int
    ) {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if currentCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

@MainActor
private final class AsyncOperationState {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = false
    private(set) var finished = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func markFinished() {
        finished = true
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private struct EmptyLibraryRepository: LibraryRepository {
    func track(id: MediaItemID) async throws -> Track? {
        nil
    }

    func album(id: AlbumID) async throws -> Album? {
        nil
    }

    func artist(id: ArtistID) async throws -> Artist? {
        nil
    }

    func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        LibraryPage(elements: [])
    }

    func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        LibraryPage(elements: [])
    }

    func apply(_ transaction: LibraryTransaction) async throws {}

    func remove(_ itemIDs: Set<MediaItemID>) async throws {}

    func changes() -> AsyncStream<LibraryChange> {
        AsyncStream { $0.finish() }
    }
}

private actor ControlledStartupRecovery: ManagedMediaRemoving {
    private var didStartPendingRemovals = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pendingRemovals() async throws -> [MediaRemovalTransaction] {
        didStartPendingRemovals = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return []
    }

    func waitUntilStarted() async {
        guard !didStartPendingRemovals else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func prepareRemoval(of itemIDs: Set<MediaItemID>) async throws
        -> MediaRemovalTransaction
    {
        MediaRemovalTransaction(transactionID: UUID(), itemIDs: itemIDs)
    }

    func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {}
    func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {}
}

private actor AppBlockingStorageMaintenance: StorageMaintenanceServing {
    private let failsPruning: Bool
    private var pruningStarted = false
    private var pruningReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(failsPruning: Bool = false) {
        self.failsPruning = failsPruning
    }

    func usage() async throws -> StorageUsageSnapshot {
        StorageUsageSnapshot()
    }

    func perform(
        _ actions: Set<StorageMaintenanceAction>
    ) async throws -> StorageMaintenanceResult {
        StorageMaintenanceResult(
            usageBefore: StorageUsageSnapshot(),
            usageAfter: StorageUsageSnapshot()
        )
    }

    func pruneCache(
        to limit: StorageByteLimit,
        retainingStagingFor retention: Duration
    ) async throws -> StorageMaintenanceResult {
        pruningStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if failsPruning {
            throw StorageMaintenanceError.failed
        }
        if !pruningReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return StorageMaintenanceResult(
            usageBefore: StorageUsageSnapshot(),
            usageAfter: StorageUsageSnapshot()
        )
    }

    func waitUntilPruningStarts() async {
        guard !pruningStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePruning() {
        pruningReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class CorruptedSettingsRepository: SettingsRepository, @unchecked Sendable {
    private actor State {
        private(set) var isCorrupted = true
        private(set) var resetCount = 0

        func load() throws -> AppSettings {
            guard !isCorrupted else { throw SettingsError.decoding }
            return .defaults
        }

        func reset() {
            isCorrupted = false
            resetCount += 1
        }
    }

    private let state = State()

    var isCorrupted: Bool {
        get async { await state.isCorrupted }
    }

    var resetCount: Int {
        get async { await state.resetCount }
    }

    func load() async throws -> AppSettings {
        try await state.load()
    }

    func save(_ settings: AppSettings) async throws {
        guard !(await state.isCorrupted) else { throw SettingsError.decoding }
    }

    func reset() async throws {
        await state.reset()
    }

    func changes() -> AsyncStream<AppSettings> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor SuspendedCorruptedSettingsRepository: SettingsRepository {
    private var isCorrupted = true
    private var resetStarted = false
    private var resetReleased = false
    private var resetStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var resetReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async throws -> AppSettings {
        guard !isCorrupted else { throw SettingsError.decoding }
        return .defaults
    }

    func save(_ settings: AppSettings) async throws {
        guard !isCorrupted else { throw SettingsError.decoding }
    }

    func reset() async throws {
        resetStarted = true
        let waiters = resetStartWaiters
        resetStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !resetReleased {
            await withCheckedContinuation { continuation in
                resetReleaseWaiters.append(continuation)
            }
        }
        isCorrupted = false
    }

    nonisolated func changes() -> AsyncStream<AppSettings> {
        AsyncStream { $0.finish() }
    }

    func waitUntilResetStarts() async {
        guard !resetStarted else { return }
        await withCheckedContinuation { continuation in
            resetStartWaiters.append(continuation)
        }
    }

    func releaseReset() {
        resetReleased = true
        let waiters = resetReleaseWaiters
        resetReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private func makeShellComposition() throws -> AppContainer.Composition {
    let dependencies = try AppDependencies()
    let services = try AppServiceContainer(dependencies: dependencies)
    return AppContainer.Composition(services: services)
}

@Suite(.serialized)
struct MusicFreeAppIntegrationSuite {

@MainActor
@Test("AppRouter keeps typed navigation and presentation state")
func appRouterKeepsTypedState() {
    var router = AppRouter()

    #expect(router.selectedRoute == .library)
    #expect(router.presented == nil)

    router.select(.playlists)
    router.present(.player)

    #expect(router.selectedRoute == .playlists)
    #expect(router.presented == .player)

    router.dismissPresentation()
    #expect(router.presented == nil)
}

@MainActor
@Test("AppLifecycleCoordinator forwards scene and application events")
func appLifecycleCoordinatorForwardsEvents() {
    let notificationCenter = NotificationCenter()
    let recorder = LifecycleEventRecorder()
    let coordinator = AppLifecycleCoordinator(
        notificationCenter: notificationCenter,
        eventHandler: { event in
            recorder.events.append(event)
        }
    )

    coordinator.start()
    #expect(coordinator.isObserving)

    coordinator.handle(.active)
    #expect(coordinator.phase == .active)
    #expect(coordinator.lastEvent == .scenePhaseChanged(.active))

    notificationCenter.post(
        name: UIApplication.didEnterBackgroundNotification,
        object: nil
    )
    #expect(coordinator.phase == .background)
    #expect(coordinator.lastEvent == .applicationDidEnterBackground)

    let eventCountBeforeStop = recorder.events.count
    coordinator.stop()
    #expect(!coordinator.isObserving)

    notificationCenter.post(
        name: UIApplication.didBecomeActiveNotification,
        object: nil
    )
    #expect(recorder.events.count == eventCountBeforeStop)
}

@MainActor
@Test("AppContainer keeps shared services and observers while another scene survives")
func appContainerKeepsAppOwnedServicesAcrossSceneChurn() throws {
    let notificationCenter = NotificationCenter()
    let lifecycle = AppLifecycleCoordinator(notificationCenter: notificationCenter)
    let composition = try makeShellComposition()
    let container = AppContainer(
        lifecycleCoordinator: lifecycle,
        startupState: .ready,
        serviceContainer: composition.services
    )
    let firstSceneID = UUID()
    let secondSceneID = UUID()

    container.sceneDidAppear(firstSceneID)
    container.sceneDidAppear(secondSceneID)
    #expect(container.activeSceneCount == 2)
    #expect(lifecycle.isObserving)

    container.sceneDidDisappear(firstSceneID)
    #expect(container.activeSceneCount == 1)
    #expect(lifecycle.isObserving)
    #expect(container.serviceContainer === composition.services)

    container.sceneDidDisappear(firstSceneID)
    #expect(container.activeSceneCount == 1)

    container.sceneDidDisappear(secondSceneID)
    #expect(container.activeSceneCount == 0)
    #expect(!lifecycle.isObserving)
    #expect(container.serviceContainer === composition.services)

    container.sceneDidAppear(firstSceneID)
    #expect(lifecycle.isObserving)
    #expect(container.serviceContainer === composition.services)
}

@MainActor
@Test("AppStartupState classifies recoverable and blocking issues")
func appStartupStateClassifiesIssues() {
    let degraded = AppStartupState.degraded(.playbackUnavailable)
    let recoveryRequired = AppStartupState.recoveryRequired(.libraryStoreUnavailable)

    #expect(degraded.isUsable)
    #expect(degraded.issues == [.playbackUnavailable])
    #expect(!recoveryRequired.isUsable)
    #expect(recoveryRequired.issues == [.libraryStoreUnavailable])
}

@MainActor
@Test("AppContainer classifies startup failures by service boundary")
func appContainerClassifiesStartupFailures() async throws {
    let container = try await AppContainer.makeForTesting()

    #expect(
        container.startupState(for: AppServiceError.library(.capacity(.storageUnavailable)))
            == .recoveryRequired([.libraryStoreUnavailable])
    )
    #expect(
        container.startupState(for: AppServiceError.settings(.decoding))
            == .degraded([.settingsCorrupted])
    )
    #expect(
        container.startupState(for: AppServiceError.playback(.noCurrentItem))
            == .degraded([.playbackUnavailable])
    )
    #expect(
        container.startupState(for: AppServiceError.missingDependency("libraryRepository"))
            == .recoveryRequired([.libraryStoreUnavailable])
    )
}

@MainActor
@Test("AppDiagnosticsExporter exports sanitized diagnostics on demand")
func appDiagnosticsExporterSanitizesBeforeExport() throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let exporter = AppDiagnosticsExporter(now: { timestamp })

    exporter.record(
        code: "startup/detail",
        message: "Authorization: fixture-header-value file:///private/fixture/music/song.m4a?token=fixture-query-value"
    )

    let exported = try exporter.exportData()
    let text = String(decoding: exported, as: UTF8.self)

    #expect(text.contains("startup-detail"))
    #expect(text.contains("<redacted"))
    #expect(!text.contains("fixture-header-value"))
    #expect(!text.contains("fixture-query-value"))
    #expect(!text.contains("/private/fixture"))
}

@MainActor
@Test("AppContainer exposes an injectable shell composition")
func appContainerExposesInjectableShellComposition() async throws {
    let exporter = AppDiagnosticsExporter(
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let container = try await AppContainer.makeForTesting(
        startupState: .degraded(.playbackUnavailable),
        diagnosticsExporter: exporter
    )

    #expect(container.router.selectedRoute == .library)
    #expect(container.startupState == .degraded([.playbackUnavailable]))
    #expect(exporter.entries.count == 1)

    container.updateStartupState(.ready)
    #expect(container.startupState == .ready)
}

@MainActor
@Test("AppContainer preserves composition degradation after services start")
func appContainerPreservesCompositionDegradation() async throws {
    let container = try await AppContainer.makeForTesting(
        startupState: .loading,
        compositionIssues: [.playbackUnavailable],
        mediaImporter: SuccessfulMediaImporter()
    )
    let services = try #require(container.serviceContainer)

    _ = try await services.start()
    container.completeStartup()

    #expect(container.startupState == .degraded([.playbackUnavailable]))
    #expect(container.importAvailable)
    let tracks = try await services.library.browseTracks(page: .init())
    let settings = try await services.settings.load()
    #expect(tracks.items.isEmpty)
    #expect(settings == .defaults)

    let importID = UUID()
    let stream = try await services.importer.start(.init(
        importID: importID,
        urls: [URL(fileURLWithPath: "/fixture/degraded-engine-test.wav")]
    ))
    var terminalResult: MediaImportResult?
    for try await event in stream {
        if case .completed(_, let result) = event {
            terminalResult = result
        }
    }
    #expect(terminalResult?.imported == 1)
}

@MainActor
@Test("AppContainer remains loading until startup storage pruning finishes")
func appContainerWaitsForStartupStoragePruning() async throws {
    let maintenance = AppBlockingStorageMaintenance()
    let container = try await AppContainer.makeForTesting(
        startupState: .loading,
        storageMaintenance: maintenance
    )
    let services = try #require(container.serviceContainer)
    let start = Task { @MainActor in
        let report = try await services.start()
        container.completeStartup(report)
    }
    await maintenance.waitUntilPruningStarts()

    #expect(container.startupState == .loading)

    await maintenance.releasePruning()
    try await start.value
    #expect(container.startupState == .ready)
}

@MainActor
@Test("AppContainer degrades instead of requiring recovery when pruning fails")
func appContainerMapsStoragePruningFailureToCacheDegradation() async throws {
    let maintenance = AppBlockingStorageMaintenance(failsPruning: true)
    let container = try await AppContainer.makeForTesting(
        startupState: .loading,
        storageMaintenance: maintenance
    )
    let services = try #require(container.serviceContainer)

    let report = try await services.start()
    container.completeStartup(report)

    #expect(report.fallbacks == [.storagePruningFailed])
    #expect(container.startupState == .degraded([.cacheUnavailable]))
}

@MainActor
@Test("Parser degradation does not advertise import as available")
func parserDegradationDisablesImportFacade() async throws {
    let container = try await AppContainer.makeForTesting(
        startupState: .loading,
        compositionIssues: [.playbackUnavailable, .dependencyUnavailable]
    )
    let services = try #require(container.serviceContainer)

    _ = try await services.start()
    container.completeStartup()

    #expect(
        container.startupState
            == .degraded([.dependencyUnavailable, .playbackUnavailable])
    )
    #expect(!container.importAvailable)
    do {
        _ = try await services.importer.start(.init(
            importID: UUID(),
            urls: [URL(fileURLWithPath: "/fixture/parser-unavailable.wav")]
        ))
        Issue.record("Import unexpectedly started without probe/metadata dependencies")
    } catch let error as AppServiceError {
        #expect(error == .missingDependency("mediaImporter"))
    }
}

@MainActor
@Test("AppContainer initialization does not invoke its composition factory")
func appContainerInitializationIsCompositionLazy() throws {
    let harness = CompositionFactoryHarness(outcomes: [
        .success(try makeShellComposition())
    ])
    let container = AppContainer(
        compositionFactory: { try await harness.makeComposition() }
    )

    #expect(harness.invocationCount == 0)
    #expect(container.serviceContainer == nil)
    #expect(container.startupState == .loading)
}

@MainActor
@Test("Concurrent composition retries share one factory invocation")
func concurrentCompositionRetriesShareFactoryInvocation() async throws {
    let harness = CompositionFactoryHarness(
        outcomes: [.success(try makeShellComposition())],
        suspendsFactory: true
    )
    let container = AppContainer(
        compositionFactory: { try await harness.makeComposition() }
    )
    let first = Task { @MainActor in
        harness.noteRetryCaller()
        return await container.retryComposition()
    }
    let second = Task { @MainActor in
        harness.noteRetryCaller()
        return await container.retryComposition()
    }

    await harness.waitForRetryCallers(count: 2)
    await harness.waitForInvocation()
    #expect(harness.invocationCount == 1)
    harness.releaseFactory()

    let firstResult = await first.value
    let secondResult = await second.value
    #expect(firstResult)
    #expect(secondResult)
    #expect(harness.invocationCount == 1)
    #expect(container.serviceContainer != nil)
}

@MainActor
@Test("Cancelling one retry waiter does not abort the shared composition")
func cancellingRetryWaiterDoesNotAbortSharedComposition() async throws {
    let harness = CompositionFactoryHarness(
        outcomes: [.success(try makeShellComposition())],
        suspendsFactory: true
    )
    let container = AppContainer(
        compositionFactory: { try await harness.makeComposition() }
    )
    let cancelledWaiter = Task { @MainActor in
        harness.noteRetryCaller()
        return await container.retryComposition()
    }
    let liveWaiter = Task { @MainActor in
        harness.noteRetryCaller()
        return await container.retryComposition()
    }

    await harness.waitForRetryCallers(count: 2)
    await harness.waitForInvocation()
    cancelledWaiter.cancel()
    harness.releaseFactory()

    let cancelledResult = await cancelledWaiter.value
    let liveResult = await liveWaiter.value
    #expect(!cancelledResult)
    #expect(liveResult)
    #expect(harness.invocationCount == 1)
    #expect(container.serviceContainer != nil)
    await container.stopServicesAndDiscardComposition()
}

@MainActor
@Test("Cancelling one service-start waiter preserves the shared started graph")
func cancellingServiceStartWaiterPreservesSharedGraph() async throws {
    let recovery = ControlledStartupRecovery()
    let services = try AppServiceContainer(dependencies: AppDependencies(
        managedMediaRemover: recovery,
        libraryRepository: EmptyLibraryRepository()
    ))
    let container = AppContainer(
        startupState: .loading,
        serviceContainer: services
    )
    let cancelledScene = RootScene(container: container)
    let liveScene = RootScene(container: container)

    let cancelledWaiter = Task { @MainActor in
        await cancelledScene.startServices()
    }
    await recovery.waitUntilStarted()
    let liveWaiterState = AsyncOperationState()
    let liveWaiter = Task { @MainActor in
        liveWaiterState.markStarted()
        await liveScene.startServices()
        liveWaiterState.markFinished()
    }
    await liveWaiterState.waitUntilStarted()

    cancelledWaiter.cancel()
    await recovery.release()
    await cancelledWaiter.value
    await liveWaiter.value

    #expect(container.serviceContainer === services)
    #expect(container.startupState == .ready)
    #expect(liveWaiterState.finished)
    await container.stopServicesAndDiscardComposition()
}

@MainActor
@Test("Corrupted settings preserve storage and start the app with explicit reset recovery")
func corruptedSettingsStartDegradedWithoutImplicitReset() async throws {
    let repository = CorruptedSettingsRepository()
    let services = try AppServiceContainer(dependencies: AppDependencies(
        settingsRepository: repository
    ))
    let container = AppContainer(
        startupState: .loading,
        serviceContainer: services
    )
    let scene = RootScene(container: container)

    await scene.startServices()

    #expect(container.serviceContainer === services)
    #expect(container.startupState == .degraded([.settingsCorrupted]))
    #expect(await repository.isCorrupted)
    #expect(await repository.resetCount == 0)

    #expect(await container.resetCorruptedSettings())
    #expect(!(await repository.isCorrupted))
    #expect(await repository.resetCount == 1)
    #expect(container.startupState == .ready)
    #expect(try await services.settingsServing.load() == .defaults)
}

@MainActor
@Test("Pruning failure preserves corrupted-settings degraded startup")
func pruningFailureDoesNotDefeatCorruptedSettingsFallback() async throws {
    let repository = CorruptedSettingsRepository()
    let maintenance = AppBlockingStorageMaintenance(failsPruning: true)
    let services = try AppServiceContainer(dependencies: AppDependencies(
        settingsRepository: repository,
        storageMaintenance: maintenance
    ))
    let container = AppContainer(
        startupState: .loading,
        serviceContainer: services
    )
    let scene = RootScene(container: container)

    await scene.startServices()

    #expect(container.serviceContainer === services)
    #expect(
        container.startupState
            == .degraded([.cacheUnavailable, .settingsCorrupted])
    )
    #expect(await repository.isCorrupted)
    #expect(await repository.resetCount == 0)
}

@MainActor
@Test("A stale settings reset cannot clear a replacement graph issue")
func staleSettingsResetDoesNotMutateReplacementComposition() async throws {
    let repository = SuspendedCorruptedSettingsRepository()
    let retiredServices = try AppServiceContainer(dependencies: AppDependencies(
        settingsRepository: repository
    ))
    let replacementServices = try AppServiceContainer(dependencies: AppDependencies())
    let container = AppContainer(
        startupState: .loading,
        serviceContainer: retiredServices,
        compositionFactory: {
            AppContainer.Composition(services: replacementServices)
        }
    )
    let scene = RootScene(container: container)
    await scene.startServices()
    #expect(container.startupState == .degraded([.settingsCorrupted]))

    let reset = Task { @MainActor in
        await container.resetCorruptedSettings()
    }
    await repository.waitUntilResetStarts()

    await container.stopServicesAndDiscardComposition()
    #expect(await container.retryComposition())
    container.completeStartup(AppStartupReport(
        recovery: LibraryRecoveryResult(),
        effectiveSettings: EffectivePlaybackSettings(
            settings: .defaults,
            effects: .neutral,
            playbackCapabilities: [],
            systemCapabilities: SystemIntegrationCapabilitySnapshot()
        ),
        fallbacks: [.settingsCorrupted]
    ))
    #expect(container.serviceContainer === replacementServices)
    #expect(container.startupState == .degraded([.settingsCorrupted]))

    await repository.releaseReset()
    #expect(!(await reset.value))
    #expect(container.serviceContainer === replacementServices)
    #expect(container.startupState == .degraded([.settingsCorrupted]))
}

@MainActor
@Test("Teardown fences an in-flight factory and prevents stale installation")
func teardownFencesCompositionAndPreventsInstallation() async throws {
    let harness = CompositionFactoryHarness(
        outcomes: [.success(try makeShellComposition())],
        suspendsFactory: true
    )
    let container = AppContainer(
        compositionFactory: { try await harness.makeComposition() }
    )
    let retry = Task { @MainActor in
        await container.retryComposition()
    }
    await harness.waitForInvocation()

    let teardownState = AsyncOperationState()
    let teardown = Task { @MainActor in
        teardownState.markStarted()
        await container.stopServicesAndDiscardComposition()
        teardownState.markFinished()
    }
    await teardownState.waitUntilStarted()
    await Task.yield()

    #expect(!teardownState.finished)
    #expect(container.serviceContainer == nil)
    harness.releaseFactory()

    await teardown.value
    let retryResult = await retry.value
    #expect(teardownState.finished)
    #expect(!retryResult)
    #expect(container.serviceContainer == nil)
    #expect(harness.invocationCount == 1)
}

@MainActor
@Test("A failed composition attempt allows a fresh retry")
func failedCompositionAllowsFreshRetry() async throws {
    let replacement = try makeShellComposition()
    let harness = CompositionFactoryHarness(outcomes: [
        .failure,
        .success(replacement)
    ])
    let container = AppContainer(
        compositionFactory: { try await harness.makeComposition() }
    )

    let firstResult = await container.retryComposition()
    #expect(!firstResult)
    #expect(harness.invocationCount == 1)
    #expect(container.serviceContainer == nil)
    #expect(container.startupState == .recoveryRequired([.dependencyUnavailable]))

    let secondResult = await container.retryComposition()
    #expect(secondResult)
    #expect(harness.invocationCount == 2)
    #expect(container.serviceContainer === replacement.services)
}

@MainActor
@Test("Terminal service stop discards composition and retry creates fresh services")
func terminalServiceStopRebuildsComposition() async throws {
    let container = try await AppContainer.makeForTesting()
    let firstServices = try #require(container.serviceContainer)

    await container.stopServicesAndDiscardComposition()
    #expect(container.serviceContainer == nil)

    let didRecompose = await container.retryComposition()
    #expect(didRecompose)
    let replacementServices = try #require(container.serviceContainer)
    #expect(firstServices !== replacementServices)
}

@MainActor
@Test("A stale service start failure cannot replace the newer composition state")
func staleServiceStartFailureDoesNotReplaceNewCompositionState() async throws {
    let container = try await AppContainer.makeForTesting()
    let retiredServices = try #require(container.serviceContainer)

    await container.stopServicesAndDiscardComposition(retiredServices)
    let didRecompose = await container.retryComposition()
    #expect(didRecompose)
    let activeServices = try #require(container.serviceContainer)
    container.updateStartupState(.ready)

    await container.handleFailedServiceStart(
        retiredServices,
        error: AppServiceError.playback(.noCurrentItem)
    )

    #expect(container.serviceContainer === activeServices)
    #expect(container.startupState == .ready)
}

@MainActor
@Test("Configured playlist service loads empty and supports mutations")
func configuredPlaylistServiceSupportsMutations() async throws {
    let container = try await AppContainer.makeForTesting()
    let services = try #require(container.serviceContainer)

    let initialPage = try await services.playlists.playlists(page: .init())
    #expect(initialPage.items.isEmpty)

    let created = try await services.playlists.create(.init(name: "通勤"))
    let renamed = try await services.playlists.update(.init(
        playlistID: created.id,
        change: .rename("收藏")
    ))
    #expect(renamed.name == "收藏")

    try await services.playlists.delete(created.id)
    let finalPage = try await services.playlists.playlists(page: .init())
    #expect(finalPage.items.isEmpty)
}

@MainActor
@Test("Configured library service loads from the shared persistent repository")
func configuredLibraryServiceLoadsEmpty() async throws {
    let container = try await AppContainer.makeForTesting()
    let services = try #require(container.serviceContainer)

    let tracks = try await services.library.browseTracks(page: .init())
    #expect(tracks.items.isEmpty)
}

@MainActor
@Test("Configured settings service loads defaults and supports update and reset")
func configuredSettingsServiceSupportsUpdateAndReset() async throws {
    let container = try await AppContainer.makeForTesting()
    let services = try #require(container.serviceContainer)

    let defaults = try await services.settings.load()
    #expect(defaults == .defaults)

    try await services.settings.update(defaults)
    let updatedSettings = try await services.settings.load()
    #expect(updatedSettings == defaults)

    try await services.settings.reset()
    let resetSettings = try await services.settings.load()
    #expect(resetSettings == .defaults)
}

@Test("Release manifest loads local license text and reproducible build evidence")
func releaseInfoProviderLoadsBundledLicenseMaterial() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeReleaseBundle-\(UUID().uuidString)", isDirectory: true)
        .appendingPathExtension("bundle")
    let notices = root.appendingPathComponent("ThirdPartyNotices", isDirectory: true)
    try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let info: NSDictionary = [
        "CFBundleIdentifier": "win.tools4me.musicplayer.tests",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "7"
    ]
    try info.write(to: root.appendingPathComponent("Info.plist"))

    let licenseFile = notices.appendingPathComponent("License.txt")
    try Data("Complete license text from the app bundle.".utf8).write(to: licenseFile)
    let manifest = """
    {
      "schemaVersion": 1,
      "dependencies": [{
        "id": "test-binary",
        "name": "Test binary",
        "version": "1.2.3",
        "license": "LGPL-2.1-or-later",
        "kind": "binary",
        "licenseFile": "License.txt",
        "revision": "revision-123",
        "checksum": "checksum-456"
      }]
    }
    """
    try Data(manifest.utf8).write(
        to: notices.appendingPathComponent("manifest.json")
    )

    let bundle = try #require(Bundle(url: root))
    let releaseInfo = try #require(
        await AppReleaseInfoProvider(bundle: bundle).releaseInfo()
    )
    let dependency = try #require(releaseInfo.dependencies.first)

    #expect(releaseInfo.appVersion == "0.1.0")
    #expect(releaseInfo.buildNumber == "7")
    #expect(dependency.licenseFile == "License.txt")
    #expect(dependency.licenseText == "Complete license text from the app bundle.")
    #expect(dependency.revision == "revision-123")
    #expect(dependency.checksum == "checksum-456")
}

@Test("Documents scanner imports only when the file snapshot changes")
func documentsScannerTracksSnapshotChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeScannerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let importer = RecordingImportService()
    let scanner = AppDocumentsScanner(documentsURL: root, importer: importer)

    let initialScan = try await scanner.scanIfNeeded()
    #expect(initialScan == nil)
    #expect(await importer.requestCount == 0)

    let firstFile = root.appendingPathComponent("first.wav")
    try Data("first".utf8).write(to: firstFile)
    let firstResult = try await scanner.scanIfNeeded()
    #expect(firstResult?.imported == 1)
    #expect(await importer.requestCount == 1)

    let unchangedScan = try await scanner.scanIfNeeded()
    #expect(unchangedScan == nil)
    #expect(await importer.requestCount == 1)

    let forcedResult = try await scanner.scanIfNeeded(force: true)
    #expect(forcedResult?.imported == 1)
    #expect(await importer.requestCount == 2)

    let secondFile = root.appendingPathComponent("second.flac")
    try Data("second".utf8).write(to: secondFile)
    let secondResult = try await scanner.scanIfNeeded()
    #expect(secondResult?.imported == 1)
    #expect(await importer.requestCount == 3)
}

@Test("Documents scanner retries a snapshot that had failed files")
func documentsScannerRetriesFailedSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeScannerFailureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let importer = RetryingImportService()
    let scanner = AppDocumentsScanner(documentsURL: root, importer: importer)
    try Data("unavailable-yet".utf8).write(to: root.appendingPathComponent("retry.flac"))

    let first = try await scanner.scanIfNeeded()
    #expect(first?.failed == 1)
    #expect(await importer.requestCount == 1)

    // The file did not change, but the failed item must remain eligible for a
    // refresh once the underlying import problem is gone.
    let second = try await scanner.scanIfNeeded()
    #expect(second?.failed == 0)
    #expect(second?.imported == 1)
    #expect(await importer.requestCount == 2)

    let completedScan = try await scanner.scanIfNeeded()
    #expect(completedScan == nil)
    #expect(await importer.requestCount == 2)
}

@Test("Documents scanner coalesces overlapping scans")
func documentsScannerCoalescesOverlappingScans() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeScannerOverlapTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("overlap".utf8).write(to: root.appendingPathComponent("overlap.flac"))

    let importer = BlockingImportService()
    let scanner = AppDocumentsScanner(documentsURL: root, importer: importer)
    let firstScan = Task {
        try await scanner.scanIfNeeded()
    }
    await importer.waitUntilStarted()

    let secondScan = Task {
        try await scanner.scanIfNeeded()
    }
    for _ in 0..<10 {
        await Task.yield()
    }

    #expect(await importer.requestCount == 1)
    await importer.complete()

    let firstResult = try await firstScan.value
    let secondResult = try await secondScan.value
    #expect(firstResult?.imported == 1)
    #expect(secondResult == firstResult)
    #expect(await importer.requestCount == 1)
}

@Test("Documents scanner restores its completed snapshot across launches")
func documentsScannerRestoresCompletedSnapshot() async throws {
    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeScannerRestoreTests-\(UUID().uuidString)", isDirectory: true)
    let documentsURL = testRoot.appendingPathComponent("Documents", isDirectory: true)
    let snapshotURL = testRoot.appendingPathComponent("State/snapshot.json")
    try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    try Data("persisted".utf8).write(to: documentsURL.appendingPathComponent("persisted.flac"))

    let firstImporter = RecordingImportService()
    let firstScanner = AppDocumentsScanner(
        documentsURL: documentsURL,
        snapshotURL: snapshotURL,
        importer: firstImporter
    )
    let firstResult = try await firstScanner.scanIfNeeded()
    #expect(firstResult?.imported == 1)
    #expect(await firstImporter.requestCount == 1)

    let relaunchedImporter = RecordingImportService()
    let relaunchedScanner = AppDocumentsScanner(
        documentsURL: documentsURL,
        snapshotURL: snapshotURL,
        importer: relaunchedImporter
    )
    let relaunchedResult = try await relaunchedScanner.scanIfNeeded()
    #expect(relaunchedResult == nil)
    #expect(await relaunchedImporter.requestCount == 0)
}

}

private actor RecordingImportService: ImportServing {
    private(set) var requestCount = 0

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .completed(
                    importID: request.importID,
                    result: MediaImportResult(
                        importID: request.importID,
                        imported: 1,
                        duplicate: 0,
                        skipped: 0,
                        failed: 0,
                        cancelled: 0
                    )
                )
            )
            continuation.finish()
        }
    }

    func cancel(_ importID: UUID) async {}

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        nil
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor RetryingImportService: ImportServing {
    private(set) var requestCount = 0

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requestCount += 1
        let attempt = requestCount
        return AsyncThrowingStream { continuation in
            let result = MediaImportResult(
                importID: request.importID,
                imported: attempt == 1 ? 0 : 1,
                duplicate: 0,
                skipped: 0,
                failed: attempt == 1 ? 1 : 0,
                cancelled: 0
            )
            continuation.yield(
                .completed(importID: request.importID, result: result)
            )
            continuation.finish()
        }
    }

    func cancel(_ importID: UUID) async {}

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        nil
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor BlockingImportService: ImportServing {
    private(set) var requestCount = 0
    private var importID: UUID?
    private var continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation?
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requestCount += 1
        importID = request.importID
        let stream = AsyncThrowingStream<MediaImportEvent, Error>.makeStream()
        continuation = stream.continuation
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return stream.stream
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete() {
        guard let importID, let continuation else { return }
        let result = MediaImportResult(
            importID: importID,
            imported: 1,
            duplicate: 0,
            skipped: 0,
            failed: 0,
            cancelled: 0
        )
        continuation.yield(.completed(importID: importID, result: result))
        continuation.finish()
        self.continuation = nil
    }

    func cancel(_ importID: UUID) async {}

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        nil
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private struct SuccessfulMediaImporter: MediaImporting {
    func importMedia(
        _ request: MediaImportRequest
    ) -> AsyncThrowingStream<MediaImportEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(
                importID: request.importID,
                result: MediaImportResult(
                    importID: request.importID,
                    imported: 1,
                    duplicate: 0,
                    skipped: 0,
                    failed: 0,
                    cancelled: 0
                )
            ))
            continuation.finish()
        }
    }

    func cancelImport(_ importID: UUID) async {}
}
