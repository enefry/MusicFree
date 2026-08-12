import Foundation
import PlaybackAPI
import MusicDomain

/// Scripted failures and delays for one fake playback engine.
public struct FakePlaybackEngineScript: Sendable {
    public var prepareError: PlaybackError?
    public var playError: PlaybackError?
    public var seekError: PlaybackError?
    public var rateError: PlaybackError?
    public var effectsError: PlaybackError?
    public var delay: Duration

    public init(
        prepareError: PlaybackError? = nil,
        playError: PlaybackError? = nil,
        seekError: PlaybackError? = nil,
        rateError: PlaybackError? = nil,
        effectsError: PlaybackError? = nil,
        delay: Duration = .zero
    ) {
        self.prepareError = prepareError
        self.playError = playError
        self.seekError = seekError
        self.rateError = rateError
        self.effectsError = effectsError
        self.delay = delay
    }
}

/// A main-actor playback fake that validates the same command preconditions a
/// single-resource engine exposes and keeps generation-bearing events under
/// explicit test control.
@MainActor
public final class FakePlaybackEngine: PlaybackEngine, PlaybackAudioControlling {
    public private(set) var capabilities: PlaybackCapabilities
    public private(set) var state: PlaybackState = .idle
    public private(set) var lastRate: Float = 1
    public private(set) var lastEffects: AudioEffectConfiguration?
    public private(set) var volume: Float = 1
    public private(set) var isMuted = false
    public private(set) var subscriptionError: TestSupportError?

    public var equalizerDescriptor: EqualizerDescriptor?
    public var script: FakePlaybackEngineScript
    public var eventScript: [PlaybackEvent]

    public private(set) var prepareCalls: [(item: PlaybackItem, startAt: Duration?)] = []
    public private(set) var playCallCount = 0
    public private(set) var pauseCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var seekCalls: [Duration] = []
    public private(set) var rateCalls: [Float] = []
    public private(set) var effectsCalls: [AudioEffectConfiguration] = []
    public private(set) var emittedEvents: [PlaybackEvent] = []

    private var eventContinuation: AsyncStream<PlaybackEvent>.Continuation?
    private var eventSubscriptionID: UUID?

    public init(
        capabilities: PlaybackCapabilities = .all,
        script: FakePlaybackEngineScript = .init(),
        eventScript: [PlaybackEvent] = [],
        equalizerDescriptor: EqualizerDescriptor? = nil
    ) {
        self.capabilities = capabilities
        self.script = script
        self.eventScript = eventScript
        self.equalizerDescriptor = equalizerDescriptor
    }

    public func makeEventStream() -> AsyncStream<PlaybackEvent> {
        guard eventContinuation == nil else {
            subscriptionError = .duplicateActiveSubscription
            return AsyncStream { $0.finish() }
        }

        let subscriptionID = UUID()
        return AsyncStream { continuation in
            self.eventSubscriptionID = subscriptionID
            self.eventContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard self?.eventSubscriptionID == subscriptionID else { return }
                    self?.eventContinuation = nil
                    self?.eventSubscriptionID = nil
                }
            }
        }
    }

    public func prepare(_ item: PlaybackItem, startAt: Duration?) async throws {
        prepareCalls.append((item, startAt))
        try await wait()
        try Task.checkCancellation()
        let generation = state.generation.advanced()
        if let error = script.prepareError {
            state = PlaybackState(
                phase: .failed,
                generation: generation,
                itemID: item.itemID,
                position: .zero,
                duration: item.display.duration,
                error: error
            )
            emit(.failed(generation: generation, itemID: item.itemID, error: error))
            throw error
        }
        if let startAt {
            guard startAt >= .zero,
                  item.display.duration == nil || startAt <= item.display.duration!
            else {
                throw PlaybackError.invalidPosition
            }
        }

        state = PlaybackState(
            phase: .preparing,
            generation: generation,
            itemID: item.itemID,
            position: startAt ?? .zero,
            duration: item.display.duration
        )
        emit(.phaseChanged(generation: generation, itemID: item.itemID, phase: .preparing))
    }

    public func play() throws {
        playCallCount += 1
        if let error = script.playError { throw error }
        guard let itemID = state.itemID else { throw PlaybackError.noCurrentItem }
        guard state.phase == .preparing || state.phase == .buffering || state.phase == .paused else {
            throw PlaybackError.invalidState(expected: .paused, actual: state.phase)
        }
        state = PlaybackState(
            phase: .playing,
            generation: state.generation,
            itemID: itemID,
            position: state.position,
            duration: state.duration
        )
        emit(.phaseChanged(generation: state.generation, itemID: itemID, phase: .playing))
    }

    public func pause() {
        pauseCallCount += 1
        guard let itemID = state.itemID, state.phase == .playing else { return }
        state = PlaybackState(
            phase: .paused,
            generation: state.generation,
            itemID: itemID,
            position: state.position,
            duration: state.duration
        )
        emit(.phaseChanged(generation: state.generation, itemID: itemID, phase: .paused))
    }

    public func stop() {
        stopCallCount += 1
        guard state.itemID != nil || state.phase != .idle else { return }
        let oldItemID = state.itemID
        state = PlaybackState(phase: .stopped, generation: state.generation)
        emit(.phaseChanged(generation: state.generation, itemID: oldItemID, phase: .stopped))
    }

    public func seek(to position: Duration) async throws {
        seekCalls.append(position)
        try await wait()
        try Task.checkCancellation()
        guard capabilities.contains(.seeking) else {
            throw PlaybackError.unsupportedCapability(.seeking)
        }
        guard let itemID = state.itemID else { throw PlaybackError.noCurrentItem }
        guard position >= .zero,
              state.duration == nil || position <= state.duration!
        else { throw PlaybackError.invalidPosition }
        if let error = script.seekError { throw error }
        state = PlaybackState(
            phase: state.phase,
            generation: state.generation,
            itemID: itemID,
            position: position,
            duration: state.duration
        )
        emit(
            .positionChanged(
                generation: state.generation,
                itemID: itemID,
                position: position,
                duration: state.duration
            )
        )
    }

    public func setRate(_ rate: Float) throws {
        rateCalls.append(rate)
        guard capabilities.contains(.variableRate) else {
            throw PlaybackError.unsupportedCapability(.variableRate)
        }
        guard rate.isFinite, rate > 0 else { throw PlaybackError.invalidRate }
        if let error = script.rateError { throw error }
        lastRate = rate
    }

    public func apply(_ effects: AudioEffectConfiguration) throws {
        effectsCalls.append(effects)
        if effects.equalizer != nil {
            guard capabilities.contains(.equalizer) else {
                throw PlaybackError.unsupportedCapability(.equalizer)
            }
            if let descriptor = equalizerDescriptor {
                _ = try effects.equalizer?.validated(against: descriptor)
            }
        }
        if effects.replayGain.mode != .disabled,
           !capabilities.contains(.replayGain) {
            throw PlaybackError.unsupportedCapability(.replayGain)
        }
        switch effects.transition.mode {
        case .disabled:
            break
        case .gapless:
            guard capabilities.contains(.gapless) else {
                throw PlaybackError.unsupportedCapability(.gapless)
            }
        case .crossfade:
            guard capabilities.contains(.crossfade) else {
                throw PlaybackError.unsupportedCapability(.crossfade)
            }
        }
        guard effects.rate.isFinite, effects.rate > 0 else {
            throw PlaybackError.invalidRate
        }
        if let error = script.effectsError { throw error }
        lastEffects = effects
    }

    public func setVolume(_ volume: Float) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw PlaybackError.invalidEffects
        }
        self.volume = volume
    }

    public func setMuted(_ isMuted: Bool) throws {
        self.isMuted = isMuted
    }

    public func setCapabilities(_ capabilities: PlaybackCapabilities) {
        self.capabilities = capabilities
    }

    public func emit(_ event: PlaybackEvent) {
        emittedEvents.append(event)
        eventContinuation?.yield(event)
    }

    public func emitScript() {
        for event in eventScript {
            emit(event)
        }
    }

    public func finishEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventSubscriptionID = nil
    }

    public func activeEventSubscription() -> Bool {
        eventContinuation != nil
    }

    public func resetCallHistory() {
        prepareCalls.removeAll()
        playCallCount = 0
        pauseCallCount = 0
        stopCallCount = 0
        seekCalls.removeAll()
        rateCalls.removeAll()
        effectsCalls.removeAll()
        emittedEvents.removeAll()
    }

    private func wait() async throws {
        guard script.delay > .zero else { return }
        do {
            try await Task.sleep(for: script.delay)
        } catch {
            throw PlaybackError.cancelled
        }
    }
}
