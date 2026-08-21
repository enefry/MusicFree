import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SystemIntegrationAPI

private struct SupersededPlaybackIntent: Error {}

@available(macOS 13.0, iOS 16.0, *)
@MainActor
internal final class PlaybackCoordinator: PlaybackServing, PlaybackAudioServing {
    private let libraryRepository: (any LibraryRepository)?
    private let sourceResolver: any MediaSourceResolving
    private let queueRepository: (any PlaybackQueueRepository)?
    private let historyRepository: (any PlaybackHistoryRepository)?
    private let engine: (any PlaybackEngine)?
    private let audioSession: (any AudioSessionManaging)?
    private let nowPlaying: (any NowPlayingPublishing)?
    private let remoteCommands: (any RemoteCommandReceiving)?
    private let systemCapabilities: SystemIntegrationCapabilitySnapshot
    private let clock: any AppClock
    private let idGenerator: any AppIDGenerating
    private let randomSource: any AppRandomSource

    private var queue = PlaybackQueueSnapshot.empty
    private var snapshotValue: PlaybackSessionSnapshot
    private var outputVolume: Float
    private var outputMuted: Bool
    private var activeGeneration = PlaybackGeneration.initial
    private var playbackIntentVersion: UInt64 = 0
    private var isMutatingQueue = false
    private var queueMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var isPreparingEngine = false
    private var enginePreparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionID: UUID?
    private var started = false
    private var startTask: (id: UUID, task: Task<Void, Error>)?
    private var shutdownTask: (id: UUID, task: Task<Void, Never>)?
    private var isShutdown = false
    private var wasPlayingBeforeInterruption = false
    private var eventTask: Task<Void, Never>?
    private var audioEventTask: Task<Void, Never>?
    private var remoteCommandTask: Task<Void, Never>?
    private var displayEnrichmentTask: (id: UUID, task: Task<Void, Never>)?
    private var snapshotContinuations: [UUID: AsyncStream<PlaybackSessionSnapshot>.Continuation] = [:]
    private var nowPlayingArtworkKey: String?
    private var nowPlayingArtworkProvider: SourceNowPlayingArtworkProvider?

    init(
        libraryRepository: (any LibraryRepository)?,
        sourceResolver: any MediaSourceResolving,
        queueRepository: (any PlaybackQueueRepository)?,
        historyRepository: (any PlaybackHistoryRepository)?,
        engine: (any PlaybackEngine)?,
        audioSession: (any AudioSessionManaging)?,
        nowPlaying: (any NowPlayingPublishing)?,
        remoteCommands: (any RemoteCommandReceiving)?,
        playbackCapabilities: PlaybackCapabilities,
        systemCapabilities: SystemIntegrationCapabilitySnapshot,
        effects: AudioEffectConfiguration = .neutral,
        clock: any AppClock,
        idGenerator: any AppIDGenerating,
        randomSource: any AppRandomSource
    ) {
        self.libraryRepository = libraryRepository
        self.sourceResolver = sourceResolver
        self.queueRepository = queueRepository
        self.historyRepository = historyRepository
        self.engine = engine
        self.audioSession = audioSession
        self.nowPlaying = nowPlaying
        self.remoteCommands = remoteCommands
        self.systemCapabilities = systemCapabilities
        self.clock = clock
        self.idGenerator = idGenerator
        self.randomSource = randomSource
        let audioController = engine as? any PlaybackAudioControlling
        self.outputVolume = audioController?.volume ?? 1
        self.outputMuted = audioController?.isMuted ?? false
        snapshotValue = PlaybackSessionSnapshot(
            capabilities: playbackCapabilities,
            effectiveEffects: effects,
            systemCapabilities: systemCapabilities
        )
    }

    var snapshot: PlaybackSessionSnapshot {
        snapshotValue
    }

    func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
        let subscriptionID = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.snapshotContinuations[subscriptionID] = continuation
            // Deliver the current restored state immediately. Without this
            // first value a subscriber created after startup could remain on
            // the empty snapshot until the next playback event.
            continuation.yield(self.snapshotValue)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.snapshotContinuations.removeValue(forKey: subscriptionID)
                }
            }
        }
    }

    func start() async throws {
        if let shutdownTask {
            await shutdownTask.task.value
            try Task.checkCancellation()
        }
        guard !isShutdown else {
            throw AppServiceError.invalidRequest(operation: "playback.startAfterShutdown")
        }
        guard !started else { return }

        let attempt: (id: UUID, task: Task<Void, Error>)
        if let startTask {
            attempt = startTask
        } else {
            let attemptID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                var restoredTrack: Track?
                var restoredState = self.snapshotValue.state

                if let queueRepository = self.queueRepository {
                    do {
                        let loadedQueue = try await queueRepository.load()
                        let canonicalQueue = try await self.canonicalizeQueue(loadedQueue)
                        if canonicalQueue != loadedQueue {
                            try await self.saveQueue(canonicalQueue)
                        }
                        self.queue = canonicalQueue
                    } catch {
                        throw AppServiceError.mapped(
                            error,
                            operation: "playback.restoreQueue"
                        )
                    }
                    try Task.checkCancellation()
                }

                if let currentItemID = self.queue.currentItemID,
                   let track = try await self.loadTrack(currentItemID) {
                    self.setCurrentDisplay(Self.display(for: track))
                    restoredTrack = track
                    restoredState = PlaybackState(
                        phase: .paused,
                        generation: self.activeGeneration,
                        itemID: currentItemID,
                        position: self.queue.resumePosition ?? .zero,
                        duration: track.duration
                    )
                }
                try Task.checkCancellation()
                self.updateSnapshot(state: restoredState)
                await self.publishSnapshot()
                try Task.checkCancellation()

                guard self.startTask?.id == attemptID,
                      self.shutdownTask == nil,
                      !self.isShutdown
                else {
                    throw CancellationError()
                }

                self.installSubscriptions()
                self.started = true
                if let restoredTrack {
                    self.scheduleDisplayEnrichment(for: restoredTrack)
                }
            }
            attempt = (attemptID, task)
            startTask = attempt
        }

        do {
            try await attempt.task.value
            if startTask?.id == attempt.id {
                startTask = nil
            }
            try Task.checkCancellation()
            guard started, !isShutdown, shutdownTask == nil else {
                throw CancellationError()
            }
        } catch {
            if startTask?.id == attempt.id {
                startTask = nil
            }
            throw error
        }
    }

    /// Stops subscriptions and releases framework-owned playback resources.
    /// This is intentionally separate from scene backgrounding so background
    /// audio can continue until the app is actually torn down.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.task.value
            return
        }
        guard !isShutdown else { return }

        isShutdown = true
        let shutdownID = UUID()
        let startAttempt = startTask
        let task = Task { @MainActor [weak self] in
            startAttempt?.task.cancel()
            if let startAttempt {
                _ = await startAttempt.task.result
            }

            guard let self else { return }
            if self.startTask?.id == startAttempt?.id {
                self.startTask = nil
            }
            _ = self.beginPlaybackIntent()
            self.eventTask?.cancel()
            self.audioEventTask?.cancel()
            self.remoteCommandTask?.cancel()
            self.displayEnrichmentTask?.task.cancel()
            self.eventTask = nil
            self.audioEventTask = nil
            self.remoteCommandTask = nil
            self.displayEnrichmentTask = nil

            await self.acquireEnginePreparation()
            defer { self.releaseEnginePreparation() }

            if let engine = self.engine {
                engine.stop()
                engine.dispose()
            }
            self.nowPlayingArtworkKey = nil
            self.nowPlayingArtworkProvider = nil
            self.nowPlaying?.clear()
            self.remoteCommands?.setEnabledCommands([])
            await self.audioSession?.deactivate()

            for continuation in self.snapshotContinuations.values {
                continuation.finish()
            }
            self.snapshotContinuations.removeAll()
            self.wasPlayingBeforeInterruption = false
            self.sessionID = nil
            self.started = false
            if self.shutdownTask?.id == shutdownID {
                self.shutdownTask = nil
            }
        }
        shutdownTask = (shutdownID, task)
        await task.value
    }

    func send(_ command: PlaybackSessionCommand) async {
        do {
            try await execute(command)
        } catch is SupersededPlaybackIntent {
            return
        } catch is CancellationError {
            return
        } catch {
            await record(
                error: AppServiceError.mapped(error, operation: "playback.command")
            )
        }
    }

    func execute(_ command: PlaybackSessionCommand) async throws {
        try await sendThrowing(command)
    }

    var volume: Float { outputVolume }

    var isMuted: Bool { outputMuted }

    func setVolume(_ volume: Float) async {
        let normalized = min(max(volume, 0), 1)
        guard normalized.isFinite else { return }
        outputVolume = normalized
        do {
            try (engine as? any PlaybackAudioControlling)?.setVolume(normalized)
        } catch {
            await record(error: AppServiceError.mapped(error, operation: "playback.volume"))
        }
    }

    func setMuted(_ isMuted: Bool) async {
        outputMuted = isMuted
        do {
            try (engine as? any PlaybackAudioControlling)?.setMuted(isMuted)
        } catch {
            await record(error: AppServiceError.mapped(error, operation: "playback.mute"))
        }
    }

    /// A throwing variant is useful to composition-root tests while the
    /// Feature-facing protocol keeps command delivery non-throwing.
    func sendThrowing(_ command: PlaybackSessionCommand) async throws {
        try Task.checkCancellation()
        switch command {
        case .play(let itemID):
            let intent = beginPlaybackIntent()
            try await play(itemID: itemID, intent: intent)
        case .playItems(let itemIDs, let shuffle):
            let intent = beginPlaybackIntent()
            try await replaceQueueAndPlay(
                itemIDs: itemIDs,
                shuffle: shuffle,
                intent: intent
            )
        case .resume:
            let intent = beginPlaybackIntent()
            try await resume(intent: intent)
        case .pause:
            wasPlayingBeforeInterruption = false
            _ = beginPlaybackIntent()
            try await pause()
        case .toggle:
            let intent = beginPlaybackIntent()
            try await toggle(intent: intent)
        case .stop:
            wasPlayingBeforeInterruption = false
            let intent = beginPlaybackIntent()
            try await stop(intent: intent)
        case .next:
            try await advanceFromUser(direction: 1)
        case .previous:
            try await advanceFromUser(direction: -1)
        case .seek(let position):
            try await seek(to: position)
        case .setRate(let rate):
            try setRate(rate)
        case .setEffects(let effects):
            try applyEffects(effects)
        case .enqueue(let itemID, let position):
            try await enqueue(itemID: itemID, at: position)
        case .enqueueItems(let itemIDs):
            try await enqueue(itemIDs: itemIDs, afterCurrent: false)
        case .enqueueNext(let itemIDs):
            try await enqueue(itemIDs: itemIDs, afterCurrent: true)
        case .editQueue(let edit):
            try await applyQueueEdit(edit)
        }
    }

    func apply(_ settings: EffectivePlaybackSettings) async {
        snapshotValue = PlaybackSessionSnapshot(
            state: snapshotValue.state,
            currentItem: snapshotValue.currentItem,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: settings.playbackCapabilities,
            effectiveEffects: settings.effects,
            systemCapabilities: settings.systemCapabilities
        )
        if let engine, snapshotValue.state.phase != .idle {
            do {
                try engine.apply(settings.effects)
            } catch {
                await record(error: AppServiceError.mapped(error, operation: "playback.applySettings"))
                return
            }
        }
        await publishSnapshot()
    }

    func updateCapabilities(_ capabilities: PlaybackCapabilities) async {
        snapshotValue = PlaybackSessionSnapshot(
            state: snapshotValue.state,
            currentItem: snapshotValue.currentItem,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: capabilities,
            effectiveEffects: snapshotValue.effectiveEffects,
            systemCapabilities: snapshotValue.systemCapabilities
        )
        updateRemoteCommandAvailability()
        await publishSnapshot()
    }

    /// Prunes durable and live queue state as one serialized queue mutation.
    func handleLibraryDeletion(_ itemIDs: Set<MediaItemID>) async throws {
        guard !itemIDs.isEmpty else { return }

        if let currentItemID = snapshotValue.currentItemID,
           itemIDs.contains(currentItemID) {
            _ = beginPlaybackIntent()
        }

        try await withQueueMutation {
            let durableQueue: PlaybackQueueSnapshot
            if queueRepository != nil {
                durableQueue = try await loadQueue()
            } else {
                durableQueue = queue
            }

            var updatedQueue = durableQueue
            for entry in durableQueue.entries where itemIDs.contains(entry.itemID) {
                updatedQueue = try updatedQueue.applying(.remove(entry.id))
            }
            if updatedQueue != durableQueue, queueRepository != nil {
                try await saveQueue(updatedQueue)
            }
            queue = updatedQueue

            guard let currentItemID = snapshotValue.currentItemID,
                  itemIDs.contains(currentItemID)
            else {
                updateSnapshot(state: snapshotValue.state)
                return
            }

            engine?.stop()
            setCurrentDisplay(nil)
            updateSnapshot(state: PlaybackState(
                phase: .stopped,
                generation: activeGeneration,
                itemID: nil,
                position: .zero,
                duration: nil
            ))
            nowPlaying?.clear()
        }
        await publishSnapshot()
    }

    private func play(itemID: MediaItemID, intent: UInt64) async throws {
        try requireCurrentIntent(intent)
        let entry = try await withQueueMutation {
            let entry: PlaybackQueueEntry
            if let existing = queue.entries.first(where: { $0.itemID == itemID }) {
                entry = existing
            } else {
                let entryID = try await valueForCurrentIntent(intent) {
                    await self.idGenerator.nextUUID()
                }
                entry = try await makeQueueEntry(
                    id: entryID,
                    itemID: itemID,
                    intent: intent
                )
                try await persistQueue(
                    try queue.applying(.append(entry)),
                    intent: intent
                )
            }

            let selected = try queue.applying(.setCurrent(entry.id))
            try await persistQueue(selected, intent: intent)
            return entry
        }
        try await prepareAndPlay(entry: entry, intent: intent)
    }

    private func resume(
        intent: UInt64,
        audioSessionAlreadyActive: Bool = false
    ) async throws {
        try requireCurrentIntent(intent)
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        guard let currentEntry = queue.currentEntry else {
            throw PlaybackError.noCurrentItem
        }

        if snapshotValue.phase == .preparing
            || engine.state.itemID != currentEntry.itemID {
            try await prepareAndPlay(entry: currentEntry, intent: intent)
            return
        }

        switch engine.state.phase {
        case .paused, .stopped, .buffering, .preparing:
            if engine.state.itemID != nil {
                if !audioSessionAlreadyActive {
                    try await activateAudioSession(intent: intent)
                }
                try requireCurrentIntent(intent)
                try engine.play()
                updateSnapshot(state: engine.state)
                await publishSnapshot()
            } else {
                try await prepareAndPlay(entry: currentEntry, intent: intent)
            }
        case .playing:
            return
        case .idle, .failed:
            try await prepareAndPlay(entry: currentEntry, intent: intent)
        }
    }

    private func pause() async throws {
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        guard let currentItemID = snapshotValue.currentItemID else {
            throw PlaybackError.noCurrentItem
        }

        if snapshotValue.phase == .preparing || engine.state.itemID != currentItemID {
            if engine.state.itemID != nil {
                engine.stop()
            }
            updateSnapshot(state: PlaybackState(
                phase: .paused,
                generation: activeGeneration,
                itemID: currentItemID,
                position: snapshotValue.position,
                duration: snapshotValue.duration
            ))
            await publishSnapshot()
            return
        }

        engine.pause()
        updateSnapshot(state: engine.state)
        await publishSnapshot()
    }

    private func prepareEngine(
        _ engine: any PlaybackEngine,
        item: PlaybackItem,
        startAt: Duration?,
        intent: UInt64
    ) async throws {
        await acquireEnginePreparation()
        defer { releaseEnginePreparation() }

        do {
            try requireCurrentIntent(intent)
            try await activateAudioSession(intent: intent)
            try await valueForCurrentIntent(intent) {
                try await engine.prepare(item, startAt: startAt)
            }
            activeGeneration = engine.state.generation
            try requireCurrentIntent(intent)
            try engine.apply(snapshotValue.effectiveEffects)
            try engine.play()
        } catch {
            try requireCurrentIntent(intent)
            throw AppServiceError.mapped(error, operation: "playback.prepare")
        }
    }

    private func activateAudioSession(intent: UInt64) async throws {
        try requireCurrentIntent(intent)
        guard let audioSession else { return }
        try audioSession.configureForPlayback()
        try await valueForCurrentIntent(intent) {
            try await audioSession.activate()
        }
    }

    private func toggle(intent: UInt64) async throws {
        if snapshotValue.phase == .playing {
            try await pause()
        } else {
            try await resume(intent: intent)
        }
    }

    private func stop(intent: UInt64) async throws {
        try requireCurrentIntent(intent)
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        guard let currentItemID = snapshotValue.currentItemID else { return }
        if engine.state.itemID != nil {
            engine.stop()
        }
        if let currentEntryID = queue.currentEntryID {
            try await withQueueMutation {
                let updated = try queue.applying(.setResumePosition(snapshotValue.position))
                try await persistQueue(updated, intent: intent)
            }
            _ = currentEntryID
        }
        updateSnapshot(state: PlaybackState(
            phase: .stopped,
            generation: activeGeneration,
            itemID: currentItemID,
            position: snapshotValue.position,
            duration: snapshotValue.duration,
            error: nil
        ))
        nowPlaying?.clear()
        await publishSnapshot()
    }

    private func seek(to position: Duration) async throws {
        guard position >= .zero else { throw PlaybackError.invalidPosition }
        guard snapshotValue.capabilities.contains(.seeking) else {
            throw PlaybackError.unsupportedCapability(.seeking)
        }
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        try await engine.seek(to: position)
        try await withQueueMutation {
            let updated = try queue.applying(.setResumePosition(position))
            try await persistQueue(updated)
        }
        updateSnapshot(state: engine.state)
        await publishSnapshot()
    }

    private func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate > 0 else { throw PlaybackError.invalidRate }
        guard snapshotValue.capabilities.contains(.variableRate) else {
            throw PlaybackError.unsupportedCapability(.variableRate)
        }
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        try engine.setRate(rate)
        let current = snapshotValue.effectiveEffects
        snapshotValue = PlaybackSessionSnapshot(
            state: snapshotValue.state,
            currentItem: snapshotValue.currentItem,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: snapshotValue.capabilities,
            effectiveEffects: AudioEffectConfiguration(
                equalizer: current.equalizer,
                replayGain: current.replayGain,
                transition: current.transition,
                rate: rate
            ),
            systemCapabilities: snapshotValue.systemCapabilities
        )
        Task { await publishSnapshot() }
    }

    private func applyEffects(_ requested: AudioEffectConfiguration) throws {
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }
        let effective = clipped(requested)
        try engine.apply(effective)
        snapshotValue = PlaybackSessionSnapshot(
            state: snapshotValue.state,
            currentItem: snapshotValue.currentItem,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: snapshotValue.capabilities,
            effectiveEffects: effective,
            systemCapabilities: snapshotValue.systemCapabilities
        )
        Task { await publishSnapshot() }
    }

    private func enqueue(itemID: MediaItemID, at position: Int?) async throws {
        let entry = try await makeQueueEntry(
            id: await idGenerator.nextUUID(),
            itemID: itemID
        )
        try await withQueueMutation {
            var updated = try queue.applying(.enqueue(entry, at: position))
            if queue.isEmpty {
                updated = try updated.applying(.setCurrent(entry.id))
            }
            try await persistQueue(updated)
            updateSnapshot(state: snapshotValue.state)
        }
        await publishSnapshot()
    }

    private func enqueue(
        itemIDs: [MediaItemID],
        afterCurrent: Bool
    ) async throws {
        guard !itemIDs.isEmpty else {
            throw AppServiceError.invalidRequest(operation: "playback.enqueueItems")
        }

        var newEntries: [PlaybackQueueEntry] = []
        newEntries.reserveCapacity(itemIDs.count)
        for itemID in itemIDs {
            try Task.checkCancellation()
            let entryID = await idGenerator.nextUUID()
            newEntries.append(
                try await makeQueueEntry(id: entryID, itemID: itemID)
            )
        }

        try await withQueueMutation {
            var updated = queue
            let wasEmpty = updated.isEmpty
            if afterCurrent,
               let currentEntryID = updated.currentEntryID,
               let currentIndex = updated.entries.firstIndex(where: { $0.id == currentEntryID }) {
                for (offset, entry) in newEntries.enumerated() {
                    updated = try updated.applying(
                        .insert(entry, at: currentIndex + 1 + offset)
                    )
                }

                if updated.shuffleMode == .on, !updated.shuffleOrder.isEmpty {
                    let newEntryIDs = newEntries.map(\.id)
                    let newEntryIDSet = Set(newEntryIDs)
                    var order = updated.shuffleOrder.filter { !newEntryIDSet.contains($0) }
                    let insertionIndex = order.firstIndex(of: currentEntryID).map { $0 + 1 }
                        ?? order.endIndex
                    order.insert(contentsOf: newEntryIDs, at: insertionIndex)
                    updated = PlaybackQueueSnapshot(
                        entries: updated.entries,
                        currentEntryID: updated.currentEntryID,
                        repeatMode: updated.repeatMode,
                        shuffleMode: updated.shuffleMode,
                        shuffleSeed: updated.shuffleSeed,
                        shuffleOrder: order,
                        resumePosition: updated.resumePosition
                    )
                }
            } else {
                for entry in newEntries {
                    updated = try updated.applying(.append(entry))
                }
            }

            if wasEmpty, let firstEntry = newEntries.first {
                updated = try updated.applying(.setCurrent(firstEntry.id))
            }
            try await persistQueue(updated)
            updateSnapshot(state: snapshotValue.state)
        }
        await publishSnapshot()
    }

    private func replaceQueueAndPlay(
        itemIDs: [MediaItemID],
        shuffle: Bool,
        intent: UInt64
    ) async throws {
        guard !itemIDs.isEmpty else {
            throw AppServiceError.invalidRequest(operation: "playback.playItems")
        }

        var entries: [PlaybackQueueEntry] = []
        entries.reserveCapacity(itemIDs.count)
        for itemID in itemIDs {
            let entryID = try await valueForCurrentIntent(intent) {
                await self.idGenerator.nextUUID()
            }
            entries.append(try await makeQueueEntry(
                id: entryID,
                itemID: itemID,
                intent: intent
            ))
        }
        guard let firstEntry = entries.first else {
            throw AppServiceError.invalidRequest(operation: "playback.playItems")
        }

        let seed: UInt64?
        let order: [UUID]
        if shuffle {
            let generatedSeed = try await valueForCurrentIntent(intent) {
                await self.randomSource.nextUInt64()
            }
            seed = generatedSeed
            var generatedOrder = Self.shuffledIDs(entries.map(\.id), seed: generatedSeed)
            if let firstIndex = generatedOrder.firstIndex(of: firstEntry.id) {
                generatedOrder = Array(generatedOrder[firstIndex...])
                    + Array(generatedOrder[..<firstIndex])
            }
            order = generatedOrder
        } else {
            seed = nil
            order = []
        }

        let replacement = PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: firstEntry.id,
            repeatMode: .off,
            shuffleMode: shuffle ? .on : .off,
            shuffleSeed: seed,
            shuffleOrder: order
        )
        try await withQueueMutation {
            try await persistQueue(replacement, intent: intent)
        }
        try await prepareAndPlay(entry: firstEntry, intent: intent)
    }

    private func applyQueueEdit(_ edit: PlaybackQueueEdit) async throws {
        try await withQueueMutation {
            let previousCurrentEntryID = queue.currentEntryID
            var updated = try queue.applying(edit)

            // An empty order is the API's request to create a fresh shuffle order.
            // Generate it here so Feature modules do not own queue policy or
            // nondeterministic state, and persist the result for restart recovery.
            if case .setShuffle(let mode, let requestedSeed, let requestedOrder) = edit,
               mode == .on,
               requestedOrder.isEmpty,
               !updated.entries.isEmpty
            {
                let seed: UInt64
                if let requestedSeed {
                    seed = requestedSeed
                } else {
                    seed = await randomSource.nextUInt64()
                }
                var order = Self.shuffledIDs(
                    updated.entries.map(\.id),
                    seed: seed
                )
                if let currentEntryID = updated.currentEntryID,
                   let currentIndex = order.firstIndex(of: currentEntryID)
                {
                    order = Array(order[currentIndex...]) + Array(order[..<currentIndex])
                }
                updated = try updated.applying(
                    .setShuffle(mode: .on, seed: seed, order: order)
                )
            }

            let changesCurrentEntry = previousCurrentEntryID != updated.currentEntryID
            if changesCurrentEntry {
                _ = beginPlaybackIntent()
            }
            try await persistQueue(updated)
            let removedCurrent = previousCurrentEntryID != updated.currentEntryID
                && previousCurrentEntryID != nil
                && updated.currentEntryID == nil

            if removedCurrent, let engine, engine.state.itemID != nil {
                engine.stop()
                nowPlaying?.clear()
                updateSnapshot(state: PlaybackState(
                    phase: .stopped,
                    generation: activeGeneration,
                    itemID: nil
                ))
            } else {
                updateSnapshot(state: snapshotValue.state)
            }
        }
        await publishSnapshot()
    }

    private func advanceFromUser(direction: Int) async throws {
        let selection: (entry: PlaybackQueueEntry, intent: UInt64)? = try await withQueueMutation {
            guard !queue.isEmpty else { return nil }
            guard let entry = adjacentOrWrappedEntry(direction: direction) else { return nil }
            let intent = beginPlaybackIntent()
            let selected = try queue.applying(.setCurrent(entry.id))
            try await persistQueue(selected, intent: intent)
            return (entry, intent)
        }
        guard let selection else { return }
        try await prepareAndPlay(entry: selection.entry, intent: selection.intent)
    }

    private func advance(direction: Int, intent: UInt64) async throws {
        let entry = try await withQueueMutation {
            try requireCurrentIntent(intent)
            guard !queue.isEmpty else { throw PlaybackError.noCurrentItem }
            guard let entry = adjacentOrWrappedEntry(direction: direction) else {
                throw PlaybackError.noCurrentItem
            }
            let selected = try queue.applying(.setCurrent(entry.id))
            try await persistQueue(selected, intent: intent)
            return entry
        }
        try await prepareAndPlay(entry: entry, intent: intent)
    }

    private func prepareAndPlay(
        entry: PlaybackQueueEntry,
        intent: UInt64,
        startAt overrideStartAt: Duration? = nil
    ) async throws {
        try requireCurrentIntent(intent)
        guard let engine else {
            throw AppServiceError.missingDependency("playbackEngine")
        }

        let startAt = overrideStartAt ?? queue.resumePosition
        // Publish the new intent before asynchronous lookup so a failed
        // resolve/probe is associated with the selected item, not the prior
        // song left in the mini-player.
        setCurrentDisplay(nil)
        updateSnapshot(state: PlaybackState(
            phase: .preparing,
            generation: activeGeneration,
            itemID: entry.itemID,
            position: startAt ?? .zero
        ))
        await publishSnapshot()
        try requireCurrentIntent(intent)
        if engine.state.itemID != nil, engine.state.itemID != entry.itemID {
            engine.stop()
        }

        guard let track = try await valueForCurrentIntent(intent, operation: {
            try await self.loadTrack(entry.itemID)
        }) else {
            throw PlaybackError.resourceUnavailable
        }

        // Relationship names are optional enrichment; audio preparation uses
        // the track-local display immediately and never waits for library scans.
        let display = Self.display(for: track)
        setCurrentDisplay(display)
        updateSnapshot(state: PlaybackState(
            phase: .preparing,
            generation: activeGeneration,
            itemID: entry.itemID,
            position: startAt ?? .zero,
            duration: track.duration
        ))
        await publishSnapshot()
        try requireCurrentIntent(intent)

        let source: any MediaSource
        source = try await valueForCurrentIntent(intent) {
            do {
                return try await self.sourceResolver.source(for: track.assetID.sourceID)
            } catch {
                throw AppServiceError.mapped(error, operation: "playback.source")
            }
        }

        let resource: PlaybackResource
        resource = try await valueForCurrentIntent(intent) {
            do {
                return try await source.resolve(track.assetID.mediaItemID)
            } catch {
                throw AppServiceError.mapped(error, operation: "playback.resolve")
            }
        }

        try await prepareEngine(
            engine,
            item: PlaybackItem(
                itemID: entry.itemID,
                resource: resource,
                selection: track.playbackSelection,
                displaySnapshot: display
            ),
            startAt: startAt,
            intent: intent
        )
        scheduleDisplayEnrichment(for: track)

        try requireCurrentIntent(intent)
        let queueWithoutResumePosition = try queue.applying(.setResumePosition(nil))
        if queueWithoutResumePosition != queue {
            try await withQueueMutation {
                let updated = try queue.applying(.setResumePosition(nil))
                if updated != queue {
                    try await persistQueue(updated, intent: intent)
                }
            }
        }
        sessionID = try await valueForCurrentIntent(intent) {
            await self.idGenerator.nextUUID()
        }
        if let historyRepository, let sessionID {
            let startedAt = try await valueForCurrentIntent(intent) {
                await self.clock.now()
            }
            try? await historyRepository.recordPlaybackStarted(
                PlaybackStart(sessionID: sessionID, itemID: entry.itemID, startedAt: startedAt)
            )
            try requireCurrentIntent(intent)
        }
        updateSnapshot(state: engine.state)
        await publishSnapshot()
    }

    private func handle(_ event: PlaybackEvent) async {
        guard event.generation == activeGeneration else { return }
        if let itemID = event.itemID, itemID != snapshotValue.currentItemID {
            return
        }

        switch event {
        case .phaseChanged(_, let itemID, let phase):
            updateSnapshot(state: PlaybackState(
                phase: phase,
                generation: event.generation,
                itemID: itemID,
                position: snapshotValue.position,
                duration: snapshotValue.duration
            ))
            await publishSnapshot()
        case .positionChanged(_, _, let position, let duration):
            updateSnapshot(state: PlaybackState(
                phase: snapshotValue.phase,
                generation: event.generation,
                itemID: snapshotValue.currentItemID,
                position: position,
                duration: duration ?? snapshotValue.duration
            ))
            if queue.currentEntryID != nil {
                try? await withQueueMutation {
                    let updatedQueue = try queue.applying(.setResumePosition(position))
                    try await persistQueue(updatedQueue)
                }
            }
            await publishSnapshot()
        case .ended(_, let itemID, let reason):
            let intent = beginPlaybackIntent()
            await recordCompletion(itemID: itemID, reason: reason)
            guard playbackIntentVersion == intent else { return }
            await advanceAfterEnd(intent: intent)
        case .failed(_, let itemID, let error):
            updateSnapshot(state: PlaybackState(
                phase: .failed,
                generation: event.generation,
                itemID: itemID,
                position: snapshotValue.position,
                duration: snapshotValue.duration,
                error: error
            ))
            nowPlaying?.clear()
            await publishSnapshot()
        }
    }

    private func advanceAfterEnd(intent: UInt64) async {
        switch queue.repeatMode {
        case .one:
            guard let currentEntry = queue.currentEntry else { return }
            // A completed item may have just persisted its final position. A
            // repeat is a new playback pass and must not resume from EOF.
            do {
                try await prepareAndPlay(
                    entry: currentEntry,
                    intent: intent,
                    startAt: .zero
                )
            } catch {
                guard playbackIntentVersion == intent else { return }
                await record(
                    error: AppServiceError.mapped(error, operation: "playback.repeat")
                )
            }
        case .off, .all:
            do {
                try await advance(direction: 1, intent: intent)
            } catch {
                guard playbackIntentVersion == intent else { return }
                if let engine {
                    engine.stop()
                }
                updateSnapshot(state: PlaybackState(
                    phase: .stopped,
                    generation: activeGeneration,
                    itemID: queue.currentItemID,
                    position: .zero,
                    duration: snapshotValue.duration
                ))
                nowPlaying?.clear()
                await publishSnapshot()
            }
        }
    }

    private func recordCompletion(itemID: MediaItemID, reason: PlaybackCompletionReason) async {
        guard let historyRepository, let sessionID else { return }
        let occurredAt = await clock.now()
        try? await historyRepository.recordCompleted(
            PlaybackCompletion(
                sessionID: sessionID,
                itemID: itemID,
                occurredAt: occurredAt,
                reason: reason
            )
        )
    }

    private func installSubscriptions() {
        if let engine {
            let engineStream = engine.makeEventStream()
            eventTask = Task { [weak self] in
                for await event in engineStream {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event)
                }
            }
        }

        if let audioSession {
            let stream = audioSession.makeEventStream()
            audioEventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event)
                }
            }
        }

        if let remoteCommands {
            let enabled = enabledRemoteCommands()
            remoteCommands.setEnabledCommands(enabled)
            let stream = remoteCommands.makeCommandStream()
            remoteCommandTask = Task { [weak self] in
                for await command in stream {
                    guard !Task.isCancelled else { return }
                    guard command.isValid else { continue }
                    await self?.handleRemote(command)
                }
            }
        }
    }

    private func updateRemoteCommandAvailability() {
        guard started else { return }
        remoteCommands?.setEnabledCommands(enabledRemoteCommands())
    }

    private func handle(_ event: AudioSessionEvent) async {
        switch event {
        case .interruption(.began):
            wasPlayingBeforeInterruption = snapshotValue.phase == .playing
            if wasPlayingBeforeInterruption {
                _ = beginPlaybackIntent()
                try? await pause()
            }
        case .interruption(.ended(let shouldResume)):
            if shouldResume && wasPlayingBeforeInterruption {
                await send(.resume)
            }
            wasPlayingBeforeInterruption = false
        case .routeChanged(let change):
            if change.isOldDeviceUnavailable {
                await send(.pause)
            }
        case .mediaServicesReset:
            await recoverFromMediaServicesReset()
        }
    }

    private func recoverFromMediaServicesReset() async {
        guard snapshotValue.phase == .playing else { return }
        let intent = beginPlaybackIntent()
        do {
            try await activateAudioSession(intent: intent)
            try await resume(intent: intent, audioSessionAlreadyActive: true)
        } catch is SupersededPlaybackIntent {
            return
        } catch is CancellationError {
            return
        } catch {
            await record(
                error: AppServiceError.mapped(
                    error,
                    operation: "playback.mediaServicesReset"
                )
            )
        }
    }

    private func handleRemote(_ command: RemotePlaybackCommand) async {
        guard snapshotValue.currentItemID != nil else { return }
        let sessionCommand: PlaybackSessionCommand
        switch command {
        case .play:
            sessionCommand = .resume
        case .pause:
            sessionCommand = .pause
        case .togglePlayPause:
            sessionCommand = .toggle
        case .next:
            sessionCommand = .next
        case .previous:
            sessionCommand = .previous
        case .seek(let position):
            sessionCommand = .seek(to: position)
        case .changeRate(let rate):
            sessionCommand = .setRate(rate)
        }
        await send(sessionCommand)
    }

    private func enabledRemoteCommands() -> Set<RemoteCommandKind> {
        var result: Set<RemoteCommandKind> = [.play, .pause, .togglePlayPause, .next, .previous]
        if snapshotValue.capabilities.contains(.seeking) {
            result.insert(.seek)
        }
        if snapshotValue.capabilities.contains(.variableRate) {
            result.insert(.changeRate)
        }
        return result
    }

    private func loadTrack(_ itemID: MediaItemID) async throws -> Track? {
        guard let libraryRepository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            return try await libraryRepository.track(id: itemID)
        } catch {
            throw AppServiceError.mapped(error, operation: "playback.track")
        }
    }

    /// Upgrades legacy queue entries while preserving queue intent and entry
    /// identity. Missing variants remain readable so a transiently unavailable
    /// library record cannot silently remove a user's queue item.
    private func canonicalizeQueue(
        _ snapshot: PlaybackQueueSnapshot
    ) async throws -> PlaybackQueueSnapshot {
        guard libraryRepository != nil else { return snapshot }

        var entries: [PlaybackQueueEntry] = []
        entries.reserveCapacity(snapshot.entries.count)
        var didChange = false

        for entry in snapshot.entries {
            guard let preferredVariantID = entry.preferredVariantID,
                  let track = try await loadTrack(preferredVariantID)
            else {
                entries.append(entry)
                continue
            }

            let canonicalEntry = PlaybackQueueEntry(id: entry.id, track: track)
            didChange = didChange || canonicalEntry != entry
            entries.append(canonicalEntry)
        }

        guard didChange else { return snapshot }
        return PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: snapshot.currentEntryID,
            repeatMode: snapshot.repeatMode,
            shuffleMode: snapshot.shuffleMode,
            shuffleSeed: snapshot.shuffleSeed,
            shuffleOrder: snapshot.shuffleOrder,
            resumePosition: snapshot.resumePosition
        )
    }

    /// Builds queue identity from the current library model. The legacy
    /// fallback keeps queue-only callers and old unavailable items readable;
    /// every track that can be resolved is persisted with its real logical
    /// identity and selected variant.
    private func makeQueueEntry(
        id: UUID,
        itemID: MediaItemID,
        intent: UInt64? = nil
    ) async throws -> PlaybackQueueEntry {
        guard libraryRepository != nil else {
            return PlaybackQueueEntry(id: id, itemID: itemID)
        }

        let track: Track?
        if let intent {
            track = try await valueForCurrentIntent(intent) {
                try await self.loadTrack(itemID)
            }
        } else {
            track = try await loadTrack(itemID)
        }
        guard let track else {
            return PlaybackQueueEntry(id: id, itemID: itemID)
        }
        return PlaybackQueueEntry(id: id, track: track)
    }

    private func persistQueue(_ updated: PlaybackQueueSnapshot) async throws {
        try await saveQueue(updated)
        queue = updated
    }

    private func persistQueue(
        _ updated: PlaybackQueueSnapshot,
        intent: UInt64
    ) async throws {
        try await valueForCurrentIntent(intent) {
            try await self.saveQueue(updated)
        }
        queue = updated
    }

    private func loadQueue() async throws -> PlaybackQueueSnapshot {
        guard let queueRepository else {
            throw AppServiceError.missingDependency("playbackQueueRepository")
        }
        do {
            return try await queueRepository.load()
        } catch {
            throw AppServiceError.mapped(error, operation: "playback.loadQueue")
        }
    }

    private func saveQueue(_ value: PlaybackQueueSnapshot) async throws {
        guard let queueRepository else {
            throw AppServiceError.missingDependency("playbackQueueRepository")
        }
        do {
            try await queueRepository.save(value)
        } catch {
            throw AppServiceError.mapped(error, operation: "playback.saveQueue")
        }
    }

    private func adjacentEntry(direction: Int) -> PlaybackQueueEntry? {
        let ordered = orderedEntries()
        guard let current = queue.currentEntry,
              let index = ordered.firstIndex(of: current)
        else {
            return direction > 0 ? ordered.first : ordered.last
        }
        let nextIndex = index + direction
        guard ordered.indices.contains(nextIndex) else { return nil }
        return ordered[nextIndex]
    }

    private func adjacentOrWrappedEntry(direction: Int) -> PlaybackQueueEntry? {
        if let adjacent = adjacentEntry(direction: direction) {
            return adjacent
        }
        guard queue.repeatMode == .all else { return nil }
        return direction > 0 ? orderedEntries().first : orderedEntries().last
    }

    private func orderedEntries() -> [PlaybackQueueEntry] {
        guard queue.shuffleMode == .on, !queue.shuffleOrder.isEmpty else {
            return queue.entries
        }
        let byID = Dictionary(uniqueKeysWithValues: queue.entries.map { ($0.id, $0) })
        return queue.shuffleOrder.compactMap { byID[$0] }
    }

    /// A small local SplitMix64 shuffle keeps the persisted order reproducible
    /// for a given seed without importing test-support or UI code into Core.
    private static func shuffledIDs(_ ids: [UUID], seed: UInt64) -> [UUID] {
        guard ids.count > 1 else { return ids }

        var state = seed
        func nextUInt64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        var result = ids
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let other = Int(nextUInt64() % UInt64(index + 1))
            result.swapAt(index, other)
        }
        return result
    }

    private func clipped(_ requested: AudioEffectConfiguration) -> AudioEffectConfiguration {
        let capabilities = snapshotValue.capabilities
        let equalizer = capabilities.contains(.equalizer) ? requested.equalizer : nil
        let replayGain = capabilities.contains(.replayGain)
            ? requested.replayGain
            : .disabled
        let transition: AudioTransitionConfiguration
        switch requested.transition.mode {
        case .crossfade where capabilities.contains(.crossfade):
            transition = requested.transition
        case .gapless where capabilities.contains(.gapless):
            transition = requested.transition
        default:
            transition = .disabled
        }
        let rate = capabilities.contains(.variableRate) ? requested.rate : 1
        return AudioEffectConfiguration(
            equalizer: equalizer,
            replayGain: replayGain,
            transition: transition,
            rate: rate
        )
    }

    private func setCurrentDisplay(_ display: PlaybackDisplaySnapshot?) {
        if display == nil {
            displayEnrichmentTask?.task.cancel()
            displayEnrichmentTask = nil
        }
        snapshotValue = PlaybackSessionSnapshot(
            state: snapshotValue.state,
            currentItem: display,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: snapshotValue.capabilities,
            effectiveEffects: snapshotValue.effectiveEffects,
            systemCapabilities: snapshotValue.systemCapabilities
        )
    }

    private func updateSnapshot(state: PlaybackState) {
        snapshotValue = PlaybackSessionSnapshot(
            state: state,
            currentItem: snapshotValue.currentItem,
            queue: PlaybackQueueSummary(snapshot: queue),
            capabilities: snapshotValue.capabilities,
            effectiveEffects: snapshotValue.effectiveEffects,
            systemCapabilities: snapshotValue.systemCapabilities
        )
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshotValue)
        }
    }

    private func record(error: AppServiceError) async {
        let playbackError: PlaybackError?
        if case .playback(let value) = error {
            playbackError = value
        } else if error.isCancellation {
            playbackError = .cancelled
        } else {
            playbackError = .unknown(code: error.diagnosticCode)
        }
        guard let playbackError else { return }
        let state = PlaybackState(
            phase: playbackError.isCancellation ? snapshotValue.phase : .failed,
            generation: activeGeneration,
            itemID: snapshotValue.currentItemID,
            position: snapshotValue.position,
            duration: snapshotValue.duration,
            error: playbackError
        )
        updateSnapshot(state: state)
        if state.phase == .failed {
            nowPlaying?.clear()
        }
        await publishSnapshot()
    }

    private func publishSnapshot() async {
        guard let nowPlaying else { return }
        let snapshot = snapshotValue
        guard let itemID = snapshot.currentItemID,
              let display = snapshot.currentItem
        else {
            nowPlayingArtworkKey = nil
            nowPlayingArtworkProvider = nil
            nowPlaying.clear()
            return
        }
        let date = await clock.now()
        guard snapshot == snapshotValue else { return }
        let queueIndex = snapshot.queue.entries.firstIndex {
            $0.id == snapshot.queue.currentEntryID
        }
        let artwork: NowPlayingArtworkReference?
        if let artworkID = display.artworkID {
            let key = "\(itemID.sourceID.rawValue):\(artworkID.rawValue)"
            if nowPlayingArtworkKey != key {
                nowPlayingArtworkKey = key
                nowPlayingArtworkProvider = SourceNowPlayingArtworkProvider(
                    sourceResolver: sourceResolver,
                    sourceID: itemID.sourceID,
                    artworkID: artworkID
                )
            }
            artwork = NowPlayingArtworkReference(
                id: artworkID,
                provider: nowPlayingArtworkProvider
            )
        } else {
            nowPlayingArtworkKey = nil
            nowPlayingArtworkProvider = nil
            artwork = nil
        }
        let systemSnapshot = NowPlayingSnapshot(
            itemID: itemID,
            title: display.title,
            artist: display.artist,
            album: display.album,
            duration: display.duration,
            elapsed: snapshot.position,
            isPlaying: snapshot.phase == .playing,
            rate: snapshot.effectiveEffects.rate,
            queuePosition: queueIndex,
            queueCount: snapshot.queue.entries.isEmpty ? nil : snapshot.queue.entries.count,
            artwork: artwork,
            updatedAt: date
        )
        nowPlaying.publish(systemSnapshot)
    }

    @discardableResult
    private func beginPlaybackIntent() -> UInt64 {
        playbackIntentVersion &+= 1
        return playbackIntentVersion
    }

    private func requireCurrentIntent(_ intent: UInt64) throws {
        try Task.checkCancellation()
        guard intent == playbackIntentVersion else {
            throw SupersededPlaybackIntent()
        }
    }

    private func valueForCurrentIntent<Value>(
        _ intent: UInt64,
        operation: () async throws -> Value
    ) async throws -> Value {
        try requireCurrentIntent(intent)
        do {
            let value = try await operation()
            try requireCurrentIntent(intent)
            return value
        } catch {
            try requireCurrentIntent(intent)
            throw error
        }
    }

    /// Keeps queue read-modify-save operations linear across repository actor hops.
    private func withQueueMutation<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await acquireQueueMutation()
        defer { releaseQueueMutation() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireQueueMutation() async {
        if !isMutatingQueue {
            isMutatingQueue = true
            return
        }
        await withCheckedContinuation { continuation in
            queueMutationWaiters.append(continuation)
        }
    }

    private func releaseQueueMutation() {
        if queueMutationWaiters.isEmpty {
            isMutatingQueue = false
        } else {
            queueMutationWaiters.removeFirst().resume()
        }
    }

    private func acquireEnginePreparation() async {
        if !isPreparingEngine {
            isPreparingEngine = true
            return
        }
        await withCheckedContinuation { continuation in
            enginePreparationWaiters.append(continuation)
        }
    }

    private func releaseEnginePreparation() {
        if enginePreparationWaiters.isEmpty {
            isPreparingEngine = false
        } else {
            enginePreparationWaiters.removeFirst().resume()
        }
    }

    private static func display(for track: Track) -> PlaybackDisplaySnapshot {
        PlaybackDisplaySnapshot(
            title: track.title,
            artworkID: track.artworkID,
            duration: track.duration
        )
    }

    private func scheduleDisplayEnrichment(for track: Track) {
        displayEnrichmentTask?.task.cancel()
        guard let libraryRepository,
              !track.artistIDs.isEmpty || track.albumID != nil
        else {
            displayEnrichmentTask = nil
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            let display = await Self.enrichedDisplay(
                for: track,
                using: libraryRepository
            )
            guard let self, self.displayEnrichmentTask?.id == taskID else {
                return
            }
            defer {
                if self.displayEnrichmentTask?.id == taskID {
                    self.displayEnrichmentTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.snapshotValue.currentItemID == track.id
            else {
                return
            }

            self.setCurrentDisplay(display)
            self.updateSnapshot(state: self.snapshotValue.state)
            await self.publishSnapshot()
        }
        displayEnrichmentTask = (taskID, task)
    }

    private static func enrichedDisplay(
        for track: Track,
        using libraryRepository: any LibraryRepository
    ) async -> PlaybackDisplaySnapshot {
        var artist: String?
        var album: String?

        if !track.artistIDs.isEmpty {
            var names: [String] = []
            for artistID in track.artistIDs {
                guard !Task.isCancelled else {
                    return display(for: track)
                }
                if let value = try? await libraryRepository.artist(id: artistID) {
                    names.append(value.name)
                }
            }
            artist = names.isEmpty ? nil : names.joined(separator: "、")
        }

        guard !Task.isCancelled else {
            return display(for: track)
        }
        if let albumID = track.albumID,
           let value = try? await libraryRepository.album(id: albumID) {
            album = value.title
        }

        return PlaybackDisplaySnapshot(
            title: track.title,
            artist: artist,
            album: album,
            artworkID: track.artworkID,
            duration: track.duration
        )
    }

    deinit {
        eventTask?.cancel()
        audioEventTask?.cancel()
        remoteCommandTask?.cancel()
        displayEnrichmentTask?.task.cancel()
    }
}
