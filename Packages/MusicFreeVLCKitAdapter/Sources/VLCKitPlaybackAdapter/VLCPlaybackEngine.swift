import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI

#if canImport(VLCKit)
@preconcurrency import VLCKit

/// Audio-profile builds retain these Objective-C accessors in the binary even
/// when their declarations are absent from the generated Swift module.
private enum VLCAudioProfileRuntimeAccess {
  private static let audioKey = "audio"
  private static let audioSelector = NSSelectorFromString(audioKey)
  private static let rateKey = "rate"
  private static let rateSetterSelector = NSSelectorFromString("setRate:")

  static func setRate(_ rate: Float, on player: VLCMediaPlayer) throws {
    guard player.responds(to: rateSetterSelector) else {
      throw VLCKitAdapterError.engineFailure(code: "playback_rate_unavailable")
    }
    player.setValue(NSNumber(value: rate), forKey: rateKey)
  }

  static func audioController(for player: VLCMediaPlayer?) -> VLCAudio? {
    guard let player, player.responds(to: audioSelector) else {
      return nil
    }
    return player.value(forKey: audioKey) as? VLCAudio
  }
}
#endif

/// The single-resource VLCKit playback engine. Queue progression, recovery,
/// and system media-session policy remain outside this type.
@MainActor
public final class VLCPlaybackEngine: PlaybackEngine, PlaybackAudioControlling {
  public static var isVLCKitLinked: Bool {
#if canImport(VLCKit)
    true
#else
    false
#endif
  }

  public let capabilities: PlaybackCapabilities
  public private(set) var state: PlaybackState
  public private(set) var volume: Float
  public private(set) var isMuted: Bool
  public private(set) var equalizerDescriptor: EqualizerDescriptor?

  private let configuration: VLCKitAdapterConfiguration
  private var currentItem: PlaybackItem?
  private var currentDuration: Duration?
  private var pendingStartAt: Duration?
  private var configuredRate: Float = 1
  private var configuredEqualizer: EqualizerConfiguration?
  private var stopWasRequested = false
  private var playbackStarted = false
  private var naturalEndGeneration: PlaybackGeneration?
  private var eventContinuation: AsyncStream<PlaybackEvent>.Continuation?

#if canImport(VLCKit)
  private let library: VLCLibrary
  private var player: VLCMediaPlayer?
  private var delegateBridge: VLCPlaybackDelegateBridge?
#endif

  public init(configuration: VLCKitAdapterConfiguration) throws {
    self.configuration = configuration
    self.state = .idle
    self.volume = 1
    self.isMuted = false
    self.equalizerDescriptor = nil

#if canImport(VLCKit)
    let library = try VLCLibraryFactory.shared(configuration: configuration)
    self.library = library

    let equalizer = VLCAudioEqualizer()
    let descriptor = VLCAudioEffectsMapper.descriptor(from: equalizer)
    self.equalizerDescriptor = descriptor
    self.capabilities = VLCCapabilityResolver.resolve(
      policy: configuration.capabilityPolicy,
      runtime: VLCRuntimeCapabilitySnapshot(
        seeking: true,
        variableRate: true,
        equalizerDescriptor: descriptor
      )
    )
#else
    self.capabilities = []
    throw VLCKitAdapterError.binaryUnavailable
#endif
  }

  public func makeEventStream() -> AsyncStream<PlaybackEvent> {
    precondition(
      eventContinuation == nil,
      "VLCPlaybackEngine supports one active event stream"
    )
    let (stream, continuation) = AsyncStream<PlaybackEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    eventContinuation = continuation
    continuation.onTermination = { @Sendable [weak self] _ in
      Task { @MainActor [weak self] in
        self?.eventContinuation = nil
      }
    }
    return stream
  }

  public func prepare(_ item: PlaybackItem, startAt: Duration?) async throws {
    try Task.checkCancellation()
    try validatePosition(startAt, duration: item.display.duration)

    let generation = state.generation.advanced()
    teardownPlayer()
    currentItem = item
    currentDuration = item.display.duration
    pendingStartAt = startAt
    stopWasRequested = false
    playbackStarted = false
    naturalEndGeneration = nil
    state = PlaybackState(
      phase: .preparing,
      generation: generation,
      itemID: item.itemID,
      position: startAt ?? .zero,
      duration: currentDuration
    )
    yield(.phaseChanged(generation: generation, itemID: item.itemID, phase: .preparing))

#if canImport(VLCKit)
    do {
      let media = try VLCMediaFactory.makeMedia(
        for: item.resource,
        configuration: configuration
      )
      let player = VLCMediaPlayer(library: library)
      let bridge = VLCPlaybackDelegateBridge(
        generation: generation,
        itemID: item.itemID
      ) { [weak self] event in
        self?.receive(event)
      }
      player.delegate = bridge
      player.media = media
      player.timeChangeUpdateInterval = 1
      player.minimalTimePeriod = 500_000
      try VLCAudioProfileRuntimeAccess.setRate(configuredRate, on: player)
      self.player = player
      self.delegateBridge = bridge
      applyAudioOutputIfAvailable()
      try applyConfiguredEqualizerIfAvailable()
    } catch {
      let playbackError = VLCPlaybackErrorMapper.playbackError(from: error)
      fail(playbackError, generation: generation, itemID: item.itemID)
      throw playbackError
    }
#else
    let error = VLCPlaybackErrorMapper.playbackError(
      from: VLCKitAdapterError.binaryUnavailable
    )
    fail(error, generation: generation, itemID: item.itemID)
    throw error
#endif
  }

  public func play() throws {
#if canImport(VLCKit)
    guard let player else {
      throw PlaybackError.noCurrentItem
    }
    if let pendingStartAt {
      player.time = try makeVLCTime(for: pendingStartAt)
      self.pendingStartAt = nil
    }
    player.play()
    playbackStarted = true
    if let itemID = currentItem?.itemID {
      apply(
        .phaseChanged(
          generation: state.generation,
          itemID: itemID,
          phase: .playing
        )
      )
    }
#else
    throw PlaybackError.engineFailure(code: "vlckit_unavailable")
#endif
  }

  public func pause() {
#if canImport(VLCKit)
    player?.pause()
#endif
  }

  public func stop() {
    stopWasRequested = true
    playbackStarted = false
    naturalEndGeneration = nil
    let generation = state.generation
    let itemID = currentItem?.itemID
    teardownPlayer()
    currentItem = nil
    currentDuration = nil
    pendingStartAt = nil
    state = PlaybackState(
      phase: .stopped,
      generation: generation,
      position: state.position,
      duration: state.duration
    )
    if let itemID {
      yield(.phaseChanged(generation: generation, itemID: itemID, phase: .stopped))
    }
    stopWasRequested = false
  }

  public func dispose() {
    stopWasRequested = true
    playbackStarted = false
    naturalEndGeneration = nil
    teardownPlayer()
    currentItem = nil
    currentDuration = nil
    pendingStartAt = nil
    state = PlaybackState(
      phase: .idle,
      generation: state.generation,
      itemID: nil,
      position: .zero,
      duration: nil
    )
    eventContinuation?.finish()
    eventContinuation = nil
#if canImport(VLCKit)
    delegateBridge = nil
#endif
    stopWasRequested = false
  }

  public func seek(to position: Duration) async throws {
    guard capabilities.contains(.seeking) else {
      throw PlaybackError.unsupportedCapability(.seeking)
    }
    guard currentItem != nil else {
      throw PlaybackError.noCurrentItem
    }
    try validatePosition(position, duration: currentDuration)

#if canImport(VLCKit)
    guard let player else {
      throw PlaybackError.noCurrentItem
    }
    guard player.isSeekable else {
      throw PlaybackError.unsupportedCapability(.seeking)
    }
    player.time = try makeVLCTime(for: position)
    state = PlaybackState(
      phase: state.phase,
      generation: state.generation,
      itemID: state.itemID,
      position: position,
      duration: state.duration,
      error: state.error
    )
#else
    throw PlaybackError.engineFailure(code: "vlckit_unavailable")
#endif
  }

  public func setRate(_ rate: Float) throws {
    guard rate.isFinite, rate > 0 else {
      throw PlaybackError.invalidRate
    }
    guard rate == 1 || capabilities.contains(.variableRate) else {
      throw PlaybackError.unsupportedCapability(.variableRate)
    }
#if canImport(VLCKit)
    if let player {
      try VLCAudioProfileRuntimeAccess.setRate(rate, on: player)
    }
    configuredRate = rate
#else
    throw PlaybackError.engineFailure(code: "vlckit_unavailable")
#endif
  }

  public func apply(_ effects: AudioEffectConfiguration) throws {
    if effects.rate != 1 {
      guard capabilities.contains(.variableRate) else {
        throw PlaybackError.unsupportedCapability(.variableRate)
      }
    }
    if effects.equalizer != nil {
      guard capabilities.contains(.equalizer), equalizerDescriptor != nil else {
        throw PlaybackError.unsupportedCapability(.equalizer)
      }
    }
    if effects.replayGain.mode != .disabled {
      throw PlaybackError.unsupportedCapability(.replayGain)
    }
    switch effects.transition.mode {
    case .disabled:
      break
    case .gapless:
      throw PlaybackError.unsupportedCapability(.gapless)
    case .crossfade:
      throw PlaybackError.unsupportedCapability(.crossfade)
    }

    try setRate(effects.rate)

#if canImport(VLCKit)
    configuredEqualizer = effects.equalizer
    try applyConfiguredEqualizerIfAvailable()
#else
    if effects.equalizer != nil {
      throw PlaybackError.engineFailure(code: "vlckit_unavailable")
    }
#endif
  }

  /// Sets the normalized software volume. libVLC's native 0...200 range is
  /// kept inside this adapter and never leaks into AppServices or Feature.
  public func setVolume(_ volume: Float) throws {
    guard volume.isFinite, (0...1).contains(volume) else {
      throw PlaybackError.invalidEffects
    }
    self.volume = volume
#if canImport(VLCKit)
    if let audio = VLCAudioProfileRuntimeAccess.audioController(for: player) {
      audio.volume = Int32((volume * 200).rounded())
    }
#endif
  }

  public func setMuted(_ muted: Bool) throws {
    isMuted = muted
#if canImport(VLCKit)
    if let audio = VLCAudioProfileRuntimeAccess.audioController(for: player) {
      audio.isMuted = muted
    }
#endif
  }

  private func receive(_ event: VLCPlaybackDelegateEvent) {
    guard VLCPlaybackEventMapper.accepts(
      event,
      currentGeneration: state.generation,
      currentItemID: currentItem?.itemID
    ) else {
      return
    }

    applyAudioOutputIfAvailable()

    if case .time(_, _, nil, let durationMilliseconds) = event {
      guard let duration = VLCPlaybackEventMapper.durationFromMilliseconds(durationMilliseconds),
            let itemID = currentItem?.itemID
      else {
        return
      }
      currentDuration = duration
      state = PlaybackState(
        phase: state.phase,
        generation: state.generation,
        itemID: itemID,
        position: state.position,
        duration: duration,
        error: state.error
      )
      yield(
        .positionChanged(
          generation: state.generation,
          itemID: itemID,
          position: state.position,
          duration: duration
        )
      )
      return
    }

    for mappedEvent in VLCPlaybackEventMapper.events(
      for: event,
      stopWasRequested: stopWasRequested,
      playbackStarted: playbackStarted
    ) {
      if case .ended = mappedEvent {
        // libVLC 4 can report EOF as both Stopping and Stopped. The queue
        // coordinator must receive one completion for one player generation.
        guard naturalEndGeneration != state.generation else { continue }
        naturalEndGeneration = state.generation
      }
      apply(mappedEvent)
    }
  }

  private func apply(_ event: PlaybackEvent) {
    switch event {
    case .phaseChanged(let generation, let itemID, let phase):
      guard generation == state.generation else { return }
      state = PlaybackState(
        phase: phase,
        generation: generation,
        itemID: itemID,
        position: state.position,
        duration: state.duration,
        error: phase == .failed ? state.error : nil
      )
      yield(event)
    case .positionChanged(let generation, let itemID, let position, let duration):
      guard generation == state.generation else { return }
      currentDuration = duration ?? currentDuration
      state = PlaybackState(
        phase: state.phase,
        generation: generation,
        itemID: itemID,
        position: position,
        duration: currentDuration,
        error: state.error
      )
      yield(event)
    case .ended(let generation, let itemID, _):
      guard generation == state.generation else { return }
      state = PlaybackState(
        phase: .stopped,
        generation: generation,
        itemID: itemID,
        position: state.position,
        duration: state.duration
      )
      yield(event)
    case .failed(let generation, let itemID, let error):
      guard generation == state.generation else { return }
      state = PlaybackState(
        phase: .failed,
        generation: generation,
        itemID: itemID,
        position: state.position,
        duration: state.duration,
        error: error
      )
      yield(event)
    }
  }

  private func fail(
    _ error: PlaybackError,
    generation: PlaybackGeneration,
    itemID: MediaItemID
  ) {
    state = PlaybackState(
      phase: .failed,
      generation: generation,
      itemID: itemID,
      position: state.position,
      duration: currentDuration,
      error: error
    )
    yield(.phaseChanged(generation: generation, itemID: itemID, phase: .failed))
    yield(.failed(generation: generation, itemID: itemID, error: error))
  }

  private func yield(_ event: PlaybackEvent) {
    eventContinuation?.yield(event)
  }

  private func validatePosition(_ position: Duration?, duration: Duration?) throws {
    guard let position else {
      return
    }
    guard position >= .zero, duration == nil || position <= duration! else {
      throw PlaybackError.invalidPosition
    }
  }

  private func teardownPlayer() {
#if canImport(VLCKit)
    player?.delegate = nil
    player?.stop()
    player?.media = nil
    player = nil
    delegateBridge = nil
#endif
  }

  private func applyAudioOutputIfAvailable() {
#if canImport(VLCKit)
    guard let audio = VLCAudioProfileRuntimeAccess.audioController(for: player) else { return }
    audio.volume = Int32((volume * 200).rounded())
    audio.isMuted = isMuted
#endif
  }

#if canImport(VLCKit)
  private func applyConfiguredEqualizerIfAvailable() throws {
    guard let player else { return }
    guard let configuredEqualizer else {
      player.equalizer = nil
      return
    }
    guard let equalizerDescriptor else {
      throw PlaybackError.unsupportedCapability(.equalizer)
    }
    let equalizer = player.equalizer ?? VLCAudioEqualizer()
    try VLCAudioEffectsMapper.apply(
      configuredEqualizer,
      to: equalizer,
      descriptor: equalizerDescriptor
    )
    player.equalizer = equalizer
  }
#endif

#if canImport(VLCKit)
  private func makeVLCTime(for duration: Duration) throws -> VLCTime {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0 else {
      throw PlaybackError.invalidPosition
    }
    let wholeMilliseconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    guard !wholeMilliseconds.overflow else {
      throw PlaybackError.invalidPosition
    }
    let fractionalMilliseconds = components.attoseconds / 1_000_000_000_000_000
    let milliseconds = wholeMilliseconds.partialValue.addingReportingOverflow(fractionalMilliseconds)
    guard !milliseconds.overflow,
          milliseconds.partialValue <= Int64(Int.max)
    else {
      throw PlaybackError.invalidPosition
    }
    return VLCTime(number: NSNumber(value: milliseconds.partialValue))
  }
#endif

  deinit {
    eventContinuation?.finish()
#if canImport(VLCKit)
    player?.delegate = nil
    player?.stop()
    player?.media = nil
#endif
  }
}
