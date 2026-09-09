import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SystemIntegrationAPI

/// Owns a dedicated playback engine for short-lived online-source audition.
/// It intentionally does not participate in the persisted queue, playback
/// history, Now Playing, background progression, or remote commands.
@MainActor
public final class OnlineAuditionCoordinator: OnlineAuditionServing {
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-audition"
    )

    public private(set) var snapshot: OnlineAuditionSnapshot = .idle

    private let onlineSources: any OnlineSourceServing
    private let engine: (any PlaybackEngine)?
    private let audioSession: (any AudioSessionManaging)?
    private weak var formalPlayback: (any PlaybackServing)?

    /// This queue is deliberately in-memory and contains catalog metadata
    /// only. Resolved URLs and credentials never enter it.
    private var queue: [OnlineAuditionQueueItem] = []
    private var currentIndex: Int?
    private var sourceDisplayName: String?
    private var sessionID: UUID?
    private var currentOperationID: UUID?
    private var activeGeneration: PlaybackGeneration?
    /// Some engines report natural EOF as a stopped phase followed by an
    /// ended event. Keep that generation eligible for the terminal event even
    /// if another engine callback clears the active generation in between.
    private var pendingNaturalEndGeneration: PlaybackGeneration?
    private var hasStartedActiveGeneration = false
    private var isInterrupted = false

    private var isMutatingEngine = false
    private var engineMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventTask: Task<Void, Never>?
    private var formalPlaybackTask: Task<Void, Never>?
    private var audioSessionTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<OnlineAuditionSnapshot>.Continuation] = [:]

    public init(
        onlineSources: any OnlineSourceServing,
        engine: (any PlaybackEngine)?,
        audioSession: (any AudioSessionManaging)? = nil,
        formalPlayback: (any PlaybackServing)? = nil
    ) {
        self.onlineSources = onlineSources
        self.engine = engine
        self.audioSession = audioSession
        self.formalPlayback = formalPlayback
    }

    public func makeSnapshotStream() -> AsyncStream<OnlineAuditionSnapshot> {
        let continuationID = UUID()
        return AsyncStream { continuation in
            continuations[continuationID] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: continuationID)
                }
            }
        }
    }

    public func audition(
        sourceID: MediaSourceID,
        item: SourceCatalogItem
    ) async throws {
        try await start(
            sourceID: sourceID,
            items: [item],
            startingItemID: item.id
        )
    }

    public func start(
        sourceID: MediaSourceID,
        items: [SourceCatalogItem],
        startingItemID: SourceObjectID?
    ) async throws {
        guard engine != nil else {
            throw OnlineAuditionError.playbackUnavailable
        }
        guard items.allSatisfy({ $0.id.sourceID == sourceID }) else {
            throw OnlineSourceServingError.sourceNotConfigured(sourceID)
        }

        let frozenQueue = Self.freeze(items: items, sourceID: sourceID)
        guard !frozenQueue.isEmpty else {
            throw OnlineAuditionError.emptyQueue
        }
        guard let selectedIndex: Int = {
            if let startingItemID {
                return frozenQueue.firstIndex(where: { $0.itemID == startingItemID })
            }
            return frozenQueue.indices.first
        }() else {
            throw OnlineAuditionError.itemNotInQueue
        }

        let hadExistingSession = self.sessionID != nil
        let sessionID = UUID()
        let operationID = UUID()
        self.sessionID = sessionID
        currentOperationID = operationID
        queue = frozenQueue
        currentIndex = selectedIndex
        sourceDisplayName = nil
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        isInterrupted = false
        publishCurrent(phase: .preparing)

        // Stop the previous resource before resolving a new URL. The session
        // and operation guards ensure a newer start wins if calls overlap
        // while this mutation is waiting behind an older engine operation.
        await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.currentOperationID == operationID
            else { return }
            self.stopEngine(force: hadExistingSession)
        }
        try requireCurrent(operationID, sessionID: sessionID)

        sourceDisplayName = await onlineSourceDisplayName(for: sourceID)
        try requireCurrent(operationID, sessionID: sessionID)
        publishCurrent(phase: .preparing)

        ensureEventObservation()
        ensureFormalPlaybackObservation()
        await formalPlayback?.send(.pause)
        try requireCurrent(operationID, sessionID: sessionID)

        do {
            try await resolveAndPlay(
                operationID: operationID,
                sessionID: sessionID,
                startAt: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnlineAuditionError {
            throw error
        } catch let error as PlaybackError {
            throw OnlineAuditionError.playbackFailed(error.diagnosticCode)
        } catch {
            throw OnlineAuditionError.playbackFailed("engine_failure")
        }
    }

    public func pause() async {
        guard let sessionID, snapshot.isActive else { return }
        await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.activeGeneration != nil,
                  self.snapshot.phase != .preparing
            else { return }
            self.engine?.pause()
            guard self.sessionID == sessionID else { return }
            self.publishState(self.engine?.state, fallbackPhase: .paused)
        }
    }

    public func resume() async throws {
        guard let sessionID else { return }

        switch snapshot.phase {
        case .paused:
            if activeGeneration == nil {
                try await replayCurrent()
                return
            }
            var resumeError: OnlineAuditionError?
            var expectedGeneration: PlaybackGeneration?
            await withEngineMutation {
                guard self.sessionID == sessionID,
                      self.activeGeneration != nil,
                      let engine = self.engine
                else { return }
                do {
                    try engine.play()
                    self.hasStartedActiveGeneration = true
                    self.publishState(engine.state, fallbackPhase: .playing)
                } catch {
                    expectedGeneration = self.activeGeneration
                    resumeError = .playbackFailed(Self.diagnosticCode(for: error))
                }
            }
            if let resumeError {
                await publishFailureIfCurrent(
                    resumeError,
                    sessionID: sessionID,
                    operationID: nil,
                    expectedGeneration: expectedGeneration
                )
                throw resumeError
            }
        case .ended, .failed, .stopped:
            try await replayCurrent()
        case .idle, .preparing, .buffering, .playing:
            break
        }
    }

    public func seek(to position: Duration) async throws {
        guard position >= .zero else {
            throw PlaybackError.invalidPosition
        }
        guard snapshot.canSeek,
              let sessionID,
              let expectedGeneration = activeGeneration,
              let engine
        else {
            throw OnlineAuditionError.seekingUnavailable
        }

        try await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.activeGeneration == expectedGeneration,
                  self.snapshot.canSeek
            else { throw CancellationError() }
            try await engine.seek(to: position)
            guard self.sessionID == sessionID,
                  self.activeGeneration == expectedGeneration
            else { throw CancellationError() }
            self.publishState(engine.state, fallbackPhase: self.snapshot.phase)
        }
    }

    public func previous() async throws {
        try await switchToAdjacent(direction: -1)
    }

    public func next() async throws {
        try await switchToAdjacent(direction: 1)
    }

    public func select(itemID: SourceObjectID) async throws {
        guard let targetIndex = queue.firstIndex(where: { $0.itemID == itemID }) else {
            throw OnlineAuditionError.itemNotInQueue
        }
        try await switchTo(index: targetIndex)
    }

    public func retry() async throws {
        guard snapshot.canRetry else { return }
        try await replayCurrent()
    }

    /// Legacy stop keeps the queue and a terminal stopped snapshot so older
    /// catalog callers can still render their existing stop state.
    public func stop() async {
        guard let sessionID else { return }
        let operationID = UUID()
        currentOperationID = operationID
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        isInterrupted = false
        await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.currentOperationID == operationID
            else { return }
            self.stopEngine()
            self.publishCurrent(phase: .stopped, position: .zero)
        }
    }

    /// Explicit close clears the temporary queue and removes the global
    /// audition entry. It never resumes formal playback.
    public func close() async {
        currentOperationID = nil
        self.sessionID = nil
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        isInterrupted = false
        await withEngineMutation {
            guard self.sessionID == nil else { return }
            self.stopEngine()
            self.queue.removeAll()
            self.currentIndex = nil
            self.sourceDisplayName = nil
            self.publish(.idle)
        }
    }

    public func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
        switch event {
        case .interruption(.began):
            isInterrupted = true
            currentOperationID = nil
            activeGeneration = nil
            pendingNaturalEndGeneration = nil
            hasStartedActiveGeneration = false
            let sessionID = self.sessionID
            guard let sessionID, snapshot.phase != .idle else { return }
            await withEngineMutation {
                guard self.sessionID == sessionID else { return }
                let phase = self.snapshot.phase
                if phase == .preparing {
                    self.stopEngine()
                } else {
                    self.engine?.pause()
                }
                if phase == .preparing || phase == .buffering || phase == .playing {
                    self.publishCurrent(
                        phase: .paused,
                        position: self.engine?.state.position ?? self.snapshot.position,
                        duration: self.engine?.state.duration ?? self.snapshot.duration,
                        failureReason: nil
                    )
                }
            }
        case .interruption(.ended):
            // Deliberately do not resume. The next explicit resume/retry
            // clears this marker and resolves a fresh access value if needed.
            break
        case .routeChanged(let change):
            if change.isOldDeviceUnavailable {
                await handleAudioSessionEvent(.interruption(.began))
            }
        case .mediaServicesReset:
            if snapshot.isActive {
                await handleAudioSessionEvent(.interruption(.began))
            }
        }
    }

    public func shutdown() async {
        await close()
        eventTask?.cancel()
        eventTask = nil
        formalPlaybackTask?.cancel()
        formalPlaybackTask = nil
        audioSessionTask?.cancel()
        audioSessionTask = nil
        engine?.dispose()
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    private func replayCurrent() async throws {
        guard let sessionID,
              let currentIndex,
              queue.indices.contains(currentIndex)
        else { throw OnlineAuditionError.emptyQueue }

        let operationID = UUID()
        let replayPosition: Duration = snapshot.phase == .ended
            ? .zero
            : snapshot.position
        currentOperationID = operationID
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        isInterrupted = false
        publishCurrent(
            phase: .preparing,
            position: replayPosition,
            failureReason: nil
        )
        ensureEventObservation()
        ensureFormalPlaybackObservation()
        await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.currentOperationID == operationID
            else { return }
            self.stopEngine()
        }
        try requireCurrent(operationID, sessionID: sessionID)
        try await resolveAndPlay(
            operationID: operationID,
            sessionID: sessionID,
            startAt: replayPosition
        )
    }

    private func switchToAdjacent(direction: Int) async throws {
        guard let currentIndex,
              queue.indices.contains(currentIndex)
        else { return }
        let targetIndex = currentIndex + direction
        guard queue.indices.contains(targetIndex) else { return }
        try await switchTo(index: targetIndex)
    }

    private func switchTo(index: Int) async throws {
        guard let sessionID, queue.indices.contains(index) else {
            throw OnlineAuditionError.emptyQueue
        }
        let operationID = UUID()
        currentOperationID = operationID
        currentIndex = index
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        isInterrupted = false
        publishCurrent(phase: .preparing, position: .zero, failureReason: nil)
        await withEngineMutation {
            guard self.sessionID == sessionID,
                  self.currentOperationID == operationID
            else { return }
            self.stopEngine()
        }
        try requireCurrent(operationID, sessionID: sessionID)
        try await resolveAndPlay(
            operationID: operationID,
            sessionID: sessionID,
            startAt: nil
        )
    }

    private func resolveAndPlay(
        operationID: UUID,
        sessionID: UUID,
        startAt: Duration?
    ) async throws {
        guard let engine,
              let currentIndex,
              queue.indices.contains(currentIndex)
        else {
            let error = OnlineAuditionError.playbackUnavailable
            await publishFailureIfCurrent(
                error,
                sessionID: sessionID,
                operationID: operationID,
                expectedGeneration: nil
            )
            throw error
        }
        let queueItem = queue[currentIndex]
        let item = queueItem.item

        do {
            let access = try await onlineSources.playbackAccess(
                sourceID: item.id.sourceID,
                itemID: item.id,
                purpose: .audition
            )
            try requireCurrent(operationID, sessionID: sessionID)

            let request: RemotePlaybackRequest
            switch access {
            case .http(let value, let transcode):
                guard !value.isExpired(at: Date()) else {
                    throw OnlineAuditionError.accessExpired
                }
                request = value
                Self.logger.info(
                    "playback access resolved source=\(item.id.sourceID.rawValue) item=\(item.id.externalID) transcoded=\(transcode != nil)"
                )
            case .downloadRequired:
                throw OnlineAuditionError.downloadRequired
            }

            try await withEngineMutation {
                try self.requireCurrent(operationID, sessionID: sessionID)
                self.stopEngine()
                if let audioSession = self.audioSession {
                    try audioSession.configureForPlayback()
                    try await audioSession.activate()
                    try self.requireCurrent(operationID, sessionID: sessionID)
                }

                let mediaItemID = MediaItemID(
                    sourceID: item.id.sourceID,
                    externalID: item.id.externalID
                )
                try await engine.prepare(
                    PlaybackItem(
                        itemID: mediaItemID,
                        resource: .remote(request),
                        displaySnapshot: PlaybackDisplaySnapshot(
                            title: item.title ?? item.displayName,
                            artist: item.artist,
                            album: item.album,
                            duration: item.duration
                        )
                    ),
                    startAt: startAt
                )
                try self.requireCurrent(operationID, sessionID: sessionID)
                self.activeGeneration = engine.state.generation
                self.hasStartedActiveGeneration = false
                try engine.play()
                try self.requireCurrent(operationID, sessionID: sessionID)
                self.hasStartedActiveGeneration = true
                self.currentOperationID = nil
                self.publishState(engine.state, fallbackPhase: .playing)
                Self.logger.info(
                    "engine playback started source=\(item.id.sourceID.rawValue) item=\(item.id.externalID) phase=\(self.snapshot.phase.rawValue)"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnlineAuditionError {
            await publishFailureIfCurrent(
                error,
                sessionID: sessionID,
                operationID: operationID,
                expectedGeneration: activeGeneration
            )
            throw error
        } catch let error as PlaybackError {
            let mapped = OnlineAuditionError.playbackFailed(error.diagnosticCode)
            await publishFailureIfCurrent(
                mapped,
                sessionID: sessionID,
                operationID: operationID,
                expectedGeneration: activeGeneration
            )
            throw mapped
        } catch {
            let mapped = OnlineAuditionError.playbackFailed("engine_failure")
            await publishFailureIfCurrent(
                mapped,
                sessionID: sessionID,
                operationID: operationID,
                expectedGeneration: activeGeneration
            )
            throw mapped
        }
    }

    private func requireCurrent(
        _ operationID: UUID,
        sessionID: UUID
    ) throws {
        guard currentOperationID == operationID,
              self.sessionID == sessionID
        else {
            throw CancellationError()
        }
    }

    private func ensureEventObservation() {
        guard eventTask == nil, let engine else { return }
        let stream = engine.makeEventStream()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event)
            }
        }
    }

    private func ensureFormalPlaybackObservation() {
        guard formalPlaybackTask == nil, let formalPlayback else { return }
        let stream = formalPlayback.makeSnapshotStream()
        formalPlaybackTask = Task { @MainActor [weak self] in
            var ignoredInitialSnapshot = true
            for await formalSnapshot in stream {
                guard !Task.isCancelled, let self else { return }
                if ignoredInitialSnapshot {
                    ignoredInitialSnapshot = false
                    continue
                }
                guard self.snapshot.hasRetainedSession else { continue }
                switch formalSnapshot.phase {
                case .preparing, .buffering, .playing:
                    await self.close()
                case .idle, .paused, .stopped, .failed:
                    break
                }
            }
        }
        ensureAudioSessionObservation(from: formalPlayback)
    }

    private func ensureAudioSessionObservation(from formalPlayback: any PlaybackServing) {
        guard audioSessionTask == nil else { return }
        let stream = formalPlayback.makeAudioSessionEventStream()
        audioSessionTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                await self.handleAudioSessionEvent(event)
            }
        }
    }

    private func receive(_ event: PlaybackEvent) async {
        let isEndedEvent: Bool
        if case .ended = event {
            isEndedEvent = true
        } else {
            isEndedEvent = false
        }
        guard event.generation == activeGeneration
                || (isEndedEvent && event.generation == pendingNaturalEndGeneration)
        else { return }
        if let itemID = event.itemID,
           itemID.externalID != snapshot.itemID?.externalID
            || itemID.sourceID != snapshot.itemID?.sourceID
        {
            return
        }

        switch event {
        case .phaseChanged(_, _, let phase):
            Self.logger.info(
                "engine phase source=\(snapshot.sourceID?.rawValue ?? "unknown") item=\(snapshot.itemID?.externalID ?? "unknown") phase=\(phase.rawValue)"
            )
            if phase == .preparing, hasStartedActiveGeneration {
                return
            }
            if phase == .playing {
                hasStartedActiveGeneration = true
            }
            if phase == .stopped {
                // A natural VLC EOF is delivered as `.phaseChanged(.stopped)`
                // followed by `.ended` for the same generation. Keep the
                // generation alive until the terminal event so handleEnded()
                // can advance the frozen audition queue, and avoid publishing
                // a transient stopped snapshot that would hide the global bar
                // or make the catalog row briefly look idle. Explicit stops
                // clear the generation before calling engine.stop(), so their
                // resulting stopped event is ignored by the guard above.
                currentOperationID = nil
                // The event stream can be delivered after the command that
                // started playback has published its state, so do not rely on
                // the local started marker here. An explicit stop clears
                // activeGeneration before calling engine.stop() and is
                // filtered by the guard above; a stopped event that reaches
                // this branch therefore represents the current generation's
                // natural terminal path.
                pendingNaturalEndGeneration = event.generation
                return
            }
            publishState(engine?.state, fallbackPhase: Self.auditionPhase(for: phase))
        case .positionChanged(_, _, let position, let duration):
            publishCurrent(
                phase: snapshot.phase,
                position: position,
                duration: duration ?? snapshot.duration,
                failureReason: snapshot.failureReason
            )
        case .ended:
            await handleEnded()
        case .failed(_, _, let error):
            Self.logger.error(
                "engine event failure source=\(snapshot.sourceID?.rawValue ?? "unknown") item=\(snapshot.itemID?.externalID ?? "unknown") diagnostic=\(error.diagnosticCode)"
            )
            await publishFailureIfCurrent(
                .playbackFailed(error.diagnosticCode),
                sessionID: sessionID,
                operationID: nil,
                expectedGeneration: event.generation
            )
        }
    }

    private func handleEnded() async {
        guard let sessionID,
              let currentIndex,
              queue.indices.contains(currentIndex)
        else { return }
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        currentOperationID = nil

        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            publishCurrent(
                phase: .ended,
                position: snapshot.duration ?? snapshot.position,
                duration: snapshot.duration,
                failureReason: nil
            )
            return
        }

        do {
            try await switchTo(index: nextIndex)
        } catch is CancellationError {
            return
        } catch {
            // `switchTo` already retains a recoverable failure for the new
            // item. Do not skip it or close the queue automatically.
            guard self.sessionID == sessionID else { return }
        }
    }

    private func publishFailureIfCurrent(
        _ error: OnlineAuditionError,
        sessionID: UUID?,
        operationID: UUID?,
        expectedGeneration: PlaybackGeneration?
    ) async {
        guard let sessionID else { return }
        await withEngineMutation {
            // The operation may have been superseded while this failure was
            // waiting for the single-resource engine lock. Re-check both
            // identities after acquiring the lock before stopping or
            // publishing, otherwise a stale failure can replace a newer
            // selection in the same audition session.
            guard self.sessionID == sessionID,
                  operationID == nil || self.currentOperationID == operationID,
                  expectedGeneration == nil || self.activeGeneration == expectedGeneration
            else { return }

            self.currentOperationID = nil
            self.activeGeneration = nil
            self.hasStartedActiveGeneration = false
            self.stopEngine()
            self.publishCurrent(
                phase: .failed,
                position: self.snapshot.position,
                duration: self.snapshot.duration,
                failureReason: error.description
            )
        }
    }

    private func publishState(
        _ state: PlaybackState?,
        fallbackPhase: OnlineAuditionPhase
    ) {
        let state = state
        publishCurrent(
            phase: state.map { Self.auditionPhase(for: $0.phase) } ?? fallbackPhase,
            position: state?.position ?? snapshot.position,
            duration: state?.duration ?? snapshot.duration,
            failureReason: state?.error?.userFacingReason
        )
    }

    private func publishCurrent(
        phase: OnlineAuditionPhase,
        position: Duration? = nil,
        duration: Duration? = nil,
        failureReason: String? = nil
    ) {
        guard let currentIndex,
              queue.indices.contains(currentIndex)
        else {
            publish(OnlineAuditionSnapshot.idle)
            return
        }
        let queueItem = queue[currentIndex]
        let isSameItem = snapshot.itemID == queueItem.itemID
        let effectiveDuration = duration
            ?? (isSameItem ? snapshot.duration : nil)
            ?? queueItem.duration
        let effectivePosition = Self.normalizedPosition(
            position ?? (isSameItem ? snapshot.position : .zero),
            duration: effectiveDuration
        )
        let engineState = engine?.state
        let preparedGeneration = activeGeneration != nil
            && engineState?.generation == activeGeneration
            && engineState?.itemID?.sourceID == queueItem.sourceID
            && engineState?.itemID?.externalID == queueItem.itemID.externalID
        let canSeek = !isInterrupted
            && (phase == .playing || phase == .paused)
            && effectiveDuration.map { $0 > .zero } == true
            && engine?.capabilities.contains(.seeking) == true
            && preparedGeneration
        publish(OnlineAuditionSnapshot(
            phase: phase,
            sourceID: queueItem.sourceID,
            itemID: queueItem.itemID,
            displayName: queueItem.title ?? queueItem.displayName,
            artist: queueItem.artist,
            album: queueItem.album,
            sourceDisplayName: sourceDisplayName,
            queue: queue,
            currentIndex: currentIndex,
            position: effectivePosition,
            duration: effectiveDuration,
            canSeek: canSeek,
            canPrevious: currentIndex > queue.startIndex,
            canNext: currentIndex + 1 < queue.endIndex,
            failureReason: failureReason
        ))
    }

    private func publish(_ value: OnlineAuditionSnapshot) {
        snapshot = value
        continuations.values.forEach { $0.yield(value) }
    }

    private func stopEngine(force: Bool = false) {
        activeGeneration = nil
        pendingNaturalEndGeneration = nil
        hasStartedActiveGeneration = false
        guard let engine else { return }
        guard force
                || engine.state.itemID != nil
                || [.preparing, .buffering, .playing, .paused].contains(engine.state.phase)
        else { return }
        engine.stop()
    }

    private func withEngineMutation<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        await acquireEngineMutation()
        defer { releaseEngineMutation() }
        return try await operation()
    }

    private func acquireEngineMutation() async {
        if !isMutatingEngine {
            isMutatingEngine = true
            return
        }
        await withCheckedContinuation { continuation in
            engineMutationWaiters.append(continuation)
        }
    }

    private func releaseEngineMutation() {
        if engineMutationWaiters.isEmpty {
            isMutatingEngine = false
        } else {
            engineMutationWaiters.removeFirst().resume()
        }
    }

    private func onlineSourceDisplayName(for sourceID: MediaSourceID) async -> String? {
        let sourceSnapshot = await onlineSources.snapshot()
        return sourceSnapshot.sources.first(where: { $0.sourceID == sourceID })?.displayName
    }

    private static func freeze(
        items: [SourceCatalogItem],
        sourceID: MediaSourceID
    ) -> [OnlineAuditionQueueItem] {
        var seen = Set<SourceObjectID>()
        return items.compactMap { item in
            guard item.id.sourceID == sourceID,
                  item.isPlayable,
                  seen.insert(item.id).inserted
            else { return nil }
            return OnlineAuditionQueueItem(item: item)
        }
    }

    private static func normalizedPosition(
        _ position: Duration,
        duration: Duration?
    ) -> Duration {
        let nonNegative = max(.zero, position)
        guard let duration else { return nonNegative }
        return min(nonNegative, max(.zero, duration))
    }

    private static func diagnosticCode(for error: Error) -> String {
        if let error = error as? PlaybackError {
            return error.diagnosticCode
        }
        return "engine_failure"
    }

    private static func auditionPhase(for phase: PlaybackPhase) -> OnlineAuditionPhase {
        switch phase {
        case .idle: .idle
        case .preparing: .preparing
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        case .failed: .failed
        }
    }
}
