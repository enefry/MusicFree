import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing

@MainActor
@Suite struct PlaybackTransitionCoordinatorTests {
    @Test func commitAndRetirementAreExactlyOnce() async throws {
        let (container, engine, library, publisher, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let prepared = try #require(engine.prepared.first)
        let oldGeneration = engine.state.generation
        let commit = engine.commit(prepared)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        engine.replay(commit)
        engine.base.emit(.positionChanged(generation: oldGeneration, itemID: ids[0], position: .seconds(99), duration: .seconds(100)))
        engine.base.emit(.ended(generation: oldGeneration, itemID: ids[0], reason: .ended))
        let retirement = PlaybackTransitionRetirement(ticket: prepared.ticket, renderFrame: 480000, playedDuration: .seconds(10))
        engine.retire(retirement); engine.retire(retirement)
        try await wait { engine.prepared.count == 2 }
        #expect(container.playback.snapshot.currentItemID == ids[1])
        #expect(container.playback.snapshot.position < .seconds(99))
        #expect(publisher.currentSnapshot?.itemID == ids[1])
        let events = await library.historyEvents
        #expect(events.filter { if case .started(let e) = $0 { return e.itemID == ids[1] }; return false }.count == 1)
        #expect(events.filter { if case .completed(let e) = $0 { return e.itemID == ids[0] }; return false }.count == 1)
        #expect(events.filter { if case .validPlayback(let e) = $0 { return e.itemID == ids[0] && e.playedDuration == .seconds(10) }; return false }.count == 1)
        await container.stop()
    }

    @Test(arguments: ["pause", "stop", "seek", "queue", "effects"])
    func cancellationRejectsLateCommit(_ operation: String) async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let old = try #require(engine.prepared.first)
        switch operation {
        case "pause": try await container.playback.execute(.pause)
        case "stop": try await container.playback.execute(.stop)
        case "seek": try await container.playback.execute(.seek(to: .seconds(1)))
        case "queue": try await container.playback.execute(.enqueueNext(itemIDs: [ids[2]]))
        default: try await container.playback.execute(.setEffects(.neutral))
        }
        engine.replay(LogicalPlaybackCommit(ticket: old.ticket, item: old.item, renderFrame: 1, sampleRate: 48000))
        try await Task.sleep(for: .milliseconds(50))
        #expect(container.playback.snapshot.currentItemID == ids[0])
        #expect(engine.cancelCount > 0)
        await container.stop()
    }

    @Test(arguments: [false, true])
    func seekPreparesSuccessorOnlyWhilePlaying(_ paused: Bool) async throws {
        let (container, engine, _, publisher, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let old = try #require(engine.prepared.first)
        if paused { try await container.playback.execute(.pause) }

        try await container.playback.execute(.seek(to: .seconds(8)))
        if paused {
            #expect(engine.prepared.count == 1)
            #expect(container.playback.snapshot.phase == .paused)
            try await container.playback.execute(.resume)
        }
        try await wait { engine.prepared.count == 2 }
        let refreshed = try #require(engine.prepared.last)
        #expect(refreshed.item.itemID == ids[1])
        #expect(refreshed.ticket.id != old.ticket.id)
        #expect(refreshed.ticket.intent != old.ticket.intent)

        engine.replay(LogicalPlaybackCommit(ticket: old.ticket, item: old.item, renderFrame: 1, sampleRate: 48000))
        #expect(container.playback.snapshot.currentItemID == ids[0])
        _ = engine.commit(refreshed)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        try await wait { publisher.currentSnapshot?.itemID == ids[1] }
        await container.stop()
    }

    @Test func handoffDuringPositionSaveCannotRestoreOutgoingItem() async throws {
        let repository = SuspendedQueueRepository()
        let (container, engine, _, _, ids) = try await setup(queueRepository: repository)
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        await repository.suspendNextSave()
        engine.base.emit(.positionChanged(generation: engine.state.generation, itemID: ids[0], position: .seconds(9), duration: .seconds(10)))
        for _ in 0..<100 {
            if await repository.isSuspended { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await repository.isSuspended)
        let prepared = try #require(engine.prepared.first)
        _ = engine.commit(prepared)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        await repository.resumeSave()
        try await wait { engine.prepared.count == 2 }
        let persisted = await repository.load()
        #expect(persisted.currentEntry?.itemID == ids[1])
        #expect(persisted.resumePosition == nil)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        await container.stop()
    }

    @Test(arguments: ["repeat-one", "repeat-all", "shuffle"])
    func successorUsesQueuePolicy(_ policy: String) async throws {
        let repository = InMemoryPlaybackQueueRepository()
        let (container, engine, _, _, ids) = try await setup(queueRepository: repository)
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let initial = await repository.currentSnapshot()
        switch policy {
        case "repeat-one": try await container.playback.execute(.editQueue(.setRepeatMode(.one)))
        case "repeat-all":
            try await container.playback.execute(.editQueue(.setRepeatMode(.all)))
            try await container.playback.execute(.play(ids[2]))
        default:
            let order = [initial.entries[0].id, initial.entries[2].id, initial.entries[1].id]
            try await container.playback.execute(.editQueue(.setShuffle(mode: .on, seed: 1, order: order)))
        }
        let expected = policy == "shuffle" ? ids[2] : ids[0]
        try await wait { engine.prepared.last?.item.itemID == expected }
        let prepared = try #require(engine.prepared.last)
        #expect(prepared.item.itemID == expected)
        _ = engine.commit(prepared)
        #expect(container.playback.snapshot.currentItemID == expected)
        await container.stop()
    }

    @Test func redundantResumePreservesNextPreparation() async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let cancelled = engine.cancelCount
        try await container.playback.execute(.resume)
        #expect(engine.cancelCount == cancelled)
        let prepared = try #require(engine.prepared.first)
        _ = engine.commit(prepared)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        await container.stop()
    }

    @Test func shutdownRecordsInterruptedOutgoingOverlap() async throws {
        let (container, engine, library, _, ids) = try await setup()
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let prepared = try #require(engine.prepared.first)
        _ = engine.commit(prepared)
        engine.retirementOnStop = PlaybackTransitionRetirement(ticket: prepared.ticket,
            renderFrame: 49000, playedDuration: .seconds(9), reason: .interrupted)
        await container.stop()
        let events = await library.historyEvents
        #expect(events.filter { if case .completed(let e) = $0 { return e.itemID == ids[0] && e.reason == .interrupted }; return false }.count == 1)
        #expect(events.filter { if case .validPlayback(let e) = $0 { return e.itemID == ids[0] && e.playedDuration == .seconds(9) }; return false }.count == 1)
    }

    @Test(arguments: [false, true])
    func unrelatedEffectUpdatesKeepPreparedSuccessor(_ rateOnly: Bool) async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let cancelled = engine.cancelCount
        let effects = container.playback.snapshot.effectiveEffects
        try await container.playback.execute(rateOnly ? .setRate(effects.rate) : .setEffects(effects))
        #expect(engine.cancelCount == cancelled)
        _ = engine.commit(try #require(engine.prepared.first))
        #expect(container.playback.snapshot.currentItemID == ids[1])
        await container.stop()
    }

    @Test(arguments: [PlaybackTransitionInvalidationReason.outputRebuilt, .preparationFailed])
    func engineInvalidationRetriesOnlyRebuiltOutput(_ reason: PlaybackTransitionInvalidationReason) async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let old = try #require(engine.prepared.first)
        engine.invalidate(old.ticket, reason: reason)
        if reason == .outputRebuilt {
            try await wait { engine.prepared.count == 2 }
            // Repeated notifications for an old graph cannot cancel its replacement.
            engine.invalidate(old.ticket, reason: reason)
            let replacement = try #require(engine.prepared.last)
            #expect(replacement.ticket.id != old.ticket.id)
            _ = engine.commit(replacement)
            #expect(container.playback.snapshot.currentItemID == ids[1])
        } else {
            try await Task.sleep(for: .milliseconds(60))
            #expect(engine.prepared.count == 1)
            engine.replay(LogicalPlaybackCommit(ticket: old.ticket, item: old.item, renderFrame: 1, sampleRate: 48000))
            #expect(container.playback.snapshot.currentItemID == ids[0])
        }
        await container.stop()
    }

    @Test func restoringRateThroughEffectsRetainsTransitionPreferences() async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let original = container.playback.snapshot.effectiveEffects
        try await container.playback.execute(.setRate(1.5))
        #expect(!container.playback.snapshot.capabilities.contains(.gapless))
        try await container.playback.execute(.setEffects(original))
        #expect(engine.base.lastEffects?.transition == original.transition)
        #expect(container.playback.snapshot.effectiveEffects.transition == original.transition)
        #expect(container.playback.snapshot.capabilities.contains(.gapless))
        try await wait { engine.prepared.count == 2 }
        await container.stop()
    }

    @Test func tailQueueEditKeepsTicketAndCommitsAcrossRevision() async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        let prepared = try #require(engine.prepared.first)
        let cancelled = engine.cancelCount
        try await container.playback.execute(.enqueueItems(itemIDs: [ids[2]]))
        #expect(engine.cancelCount == cancelled)
        _ = engine.commit(prepared)
        #expect(container.playback.snapshot.currentItemID == ids[1])
        await container.stop()
    }

    @Test func seekAtPendingHandoffUsesIncomingIdentity() async throws {
        let (container, engine, _, _, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        engine.commitOnCancel = try #require(engine.prepared.first)
        try await container.playback.execute(.seek(to: .seconds(1)))
        #expect(engine.soughtItems == [ids[1]])
        #expect(container.playback.snapshot.currentItemID == ids[1])
        #expect(container.playback.snapshot.position == .seconds(1))
        await container.stop()
    }

    @Test(arguments: [false, true])
    func unauthorizedAudibleCommitStopsInsteadOfDiverging(_ repeatsSameItem: Bool) async throws {
        let (container, engine, library, publisher, ids) = try await setup()
        defer { Task { await container.stop() } }
        try await container.playback.execute(.playItems(itemIDs: ids, shuffle: false))
        try await wait { engine.prepared.count == 1 }
        if repeatsSameItem {
            try await container.playback.execute(.editQueue(.setRepeatMode(.one)))
            try await wait { engine.prepared.count == 2 }
        }
        let old = try #require(engine.prepared.last)
        if repeatsSameItem { try await container.playback.execute(.editQueue(.setRepeatMode(.off))) }
        else { try await container.playback.execute(.enqueueNext(itemIDs: [ids[2]])) }
        _ = engine.commit(old)
        #expect(container.playback.snapshot.phase != .playing)
        try await wait { publisher.currentSnapshot == nil }
        await container.stop()
        let events = await library.historyEvents
        #expect(events.filter { if case .completed(let event) = $0 {
            return event.itemID == ids[0] && event.reason == .failed
        }; return false }.count == 1)
    }

    private func setup(queueRepository: any PlaybackQueueRepository = InMemoryPlaybackQueueRepository()) async throws -> (AppServiceContainer, TransitionEngine, InMemoryLibraryRepository, FakeNowPlayingPublisher, [MediaItemID]) {
        let ids = ["a", "b", "c"].map { MediaItemID(sourceID: .local, externalID: "transition-\($0)") }
        let library = InMemoryLibraryRepository(tracks: ids.map { Track(id: $0, title: $0.externalID, duration: .seconds(10)) })
        let source = FakeMediaSource(descriptor: FixtureFactory.sourceDescriptor(sourceID: .local),
            resolveResults: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, FakeMediaSourceResolveResult.resource(.localFile(URL(fileURLWithPath: "/fixture/\($0.externalID).wav"))))
        }))
        let engine = TransitionEngine()
        let publisher = FakeNowPlayingPublisher()
        let container = try AppServiceContainer(dependencies: AppDependencies(
            mediaSources: [source], libraryRepository: library,
            playbackQueueRepository: queueRepository, playbackHistoryRepository: library,
            settingsRepository: InMemorySettingsRepository(),
            playbackEngine: engine, nowPlaying: publisher,
            systemCapabilities: SystemIntegrationCapabilitySnapshot(capabilities: [.nowPlaying])))
        _ = try await container.start()
        return (container, engine, library, publisher, ids)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
}

private actor SuspendedQueueRepository: PlaybackQueueRepository {
    private var snapshot = PlaybackQueueSnapshot.empty
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    func load() -> PlaybackQueueSnapshot { snapshot }
    func suspendNextSave() { shouldSuspend = true }
    func resumeSave() { continuation?.resume(); continuation = nil }
    func save(_ value: PlaybackQueueSnapshot) async {
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        snapshot = value
    }
}

@MainActor private final class TransitionEngine: PlaybackEngine, PlaybackTransitionControlling {
    let base = FakePlaybackEngine(capabilities: [.seeking, .variableRate, .fade, .gapless, .crossfade])
    private var rate: Float = 1
    var capabilities: PlaybackCapabilities {
        rate == 1 ? base.capabilities : base.capabilities.subtracting([.fade, .gapless, .crossfade])
    }
    var state: PlaybackState { override ?? base.state }
    private var override: PlaybackState?
    struct Prepared { let item: PlaybackItem; let ticket: PlaybackTransitionTicket }
    var prepared: [Prepared] = []
    var cancelCount = 0
    var retirementOnStop: PlaybackTransitionRetirement?
    var commitOnCancel: Prepared?
    var soughtItems: [MediaItemID] = []
    private var continuation: AsyncStream<LogicalPlaybackCommit>.Continuation?
    private var commitHandler: (@MainActor (LogicalPlaybackCommit) -> Void)?
    private var retirementHandler: (@MainActor (PlaybackTransitionRetirement) -> Void)?
    private var invalidationHandler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?
    func makeEventStream() -> AsyncStream<PlaybackEvent> { base.makeEventStream() }
    func prepare(_ item: PlaybackItem, startAt: Duration?) async throws { override = nil; try await base.prepare(item, startAt: startAt) }
    func play() throws { try base.play() }
    func pause() { base.pause() }
    func stop() {
        if let retirementOnStop { retirementHandler?(retirementOnStop); self.retirementOnStop = nil }
        override = nil; base.stop()
    }
    func seek(to position: Duration) async throws {
        if let itemID = state.itemID { soughtItems.append(itemID) }
        try await base.seek(to: position)
        if let override {
            self.override = PlaybackState(phase: override.phase, generation: override.generation,
                itemID: override.itemID, position: position, duration: override.duration)
        }
    }
    func setRate(_ rate: Float) throws { try base.setRate(rate); self.rate = rate }
    func apply(_ effects: AudioEffectConfiguration) throws { try base.apply(effects); rate = effects.rate }
    func dispose() { base.dispose(); continuation?.finish() }
    func makeTransitionStream() -> AsyncStream<LogicalPlaybackCommit> { AsyncStream { continuation = $0 } }
    func prepareNext(_ item: PlaybackItem, ticket: PlaybackTransitionTicket) async throws {
        guard capabilities.contains(.gapless) else { throw PlaybackError.unsupportedCapability(.gapless) }
        prepared.append(Prepared(item: item, ticket: ticket))
    }
    func cancelNext() {
        cancelCount += 1
        if let commitOnCancel { self.commitOnCancel = nil; _ = commit(commitOnCancel) }
    }
    func hardPause() { pause() }
    func hardStop() { stop() }
    func setTransitionCommitHandler(_ handler: (@MainActor (LogicalPlaybackCommit) -> Void)?) { commitHandler = handler }
    func setTransitionRetirementHandler(_ handler: (@MainActor (PlaybackTransitionRetirement) -> Void)?) { retirementHandler = handler }
    func setTransitionInvalidationHandler(_ handler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?) { invalidationHandler = handler }
    func invalidate(_ ticket: PlaybackTransitionTicket, reason: PlaybackTransitionInvalidationReason) { invalidationHandler?(ticket, reason) }
    func commit(_ value: Prepared) -> LogicalPlaybackCommit {
        override = PlaybackState(phase: .playing, generation: state.generation.advanced(), itemID: value.item.itemID, duration: .seconds(10))
        let commit = LogicalPlaybackCommit(ticket: value.ticket, item: value.item, renderFrame: 48000, sampleRate: 48000)
        replay(commit); return commit
    }
    func replay(_ commit: LogicalPlaybackCommit) { commitHandler?(commit); continuation?.yield(commit) }
    func retire(_ event: PlaybackTransitionRetirement) { retirementHandler?(event) }
}
