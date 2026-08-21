import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import VLCKitPlaybackAdapter

struct VLCKitPlaybackAdapterInitialTests {
  @Test("VLC player states map to stable playback phases")
  func stateMapping() {
    #expect(VLCPlaybackEventMapper.phase(for: VLCPlaybackStateCode.opening) == .preparing)
    #expect(VLCPlaybackEventMapper.phase(for: VLCPlaybackStateCode.playing) == .playing)
    #expect(VLCPlaybackEventMapper.phase(for: VLCPlaybackStateCode.paused) == .paused)
    #expect(VLCPlaybackEventMapper.phase(for: VLCPlaybackStateCode.stopped) == .stopped)
    #expect(VLCPlaybackEventMapper.phase(for: VLCPlaybackStateCode.error) == .failed)
    #expect(VLCPlaybackEventMapper.phase(for: 99) == nil)
  }

  @Test("Buffering completion clears the loading phase")
  func bufferingCompletionMapping() {
    let generation = PlaybackGeneration(2)
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")

    let bufferingEvents = VLCPlaybackEventMapper.events(
      for: .buffering(generation: generation, itemID: itemID, progress: 0.5),
      stopWasRequested: false,
      playbackStarted: false
    )
    let completedEvents = VLCPlaybackEventMapper.events(
      for: .buffering(generation: generation, itemID: itemID, progress: 1),
      stopWasRequested: false,
      playbackStarted: true
    )

    #expect(
      bufferingEvents == [
        .phaseChanged(generation: generation, itemID: itemID, phase: .buffering)
      ]
    )
    #expect(
      completedEvents == [
        .phaseChanged(generation: generation, itemID: itemID, phase: .playing)
      ]
    )
  }

  @Test("Natural stopping and stopped states have terminal mapping")
  func terminalMapping() {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    for code in [VLCPlaybackStateCode.stopping, VLCPlaybackStateCode.stopped] {
      let event = VLCPlaybackDelegateEvent.state(
        generation: PlaybackGeneration(4),
        itemID: itemID,
        code: code
      )
      let naturalEvents = VLCPlaybackEventMapper.events(
        for: event,
        stopWasRequested: false,
        playbackStarted: true
      )
      let requestedEvents = VLCPlaybackEventMapper.events(
        for: event,
        stopWasRequested: true,
        playbackStarted: true
      )
      #expect(naturalEvents.contains { $0.isTerminal })
      #expect(requestedEvents.allSatisfy { !$0.isTerminal })
    }
  }

  @Test("Preparation-time stopped states do not complete a track")
  func preparationStoppedStateIsNotNaturalCompletion() {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let event = VLCPlaybackDelegateEvent.state(
      generation: PlaybackGeneration(5),
      itemID: itemID,
      code: VLCPlaybackStateCode.stopped
    )

    let events = VLCPlaybackEventMapper.events(
      for: event,
      stopWasRequested: false,
      playbackStarted: false
    )

    #expect(events.allSatisfy { !$0.isTerminal })
  }

  @Test("Late delegate events are rejected by generation and item identity")
  func generationFiltering() {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let otherItemID = MediaItemID(sourceID: .local, externalID: "track-2")
    let currentGeneration = PlaybackGeneration(9)
    let currentEvent = VLCPlaybackDelegateEvent.buffering(
      generation: currentGeneration,
      itemID: itemID,
      progress: 0.25
    )
    let oldEvent = VLCPlaybackDelegateEvent.buffering(
      generation: PlaybackGeneration(8),
      itemID: itemID,
      progress: 0.25
    )
    let otherItemEvent = VLCPlaybackDelegateEvent.buffering(
      generation: currentGeneration,
      itemID: otherItemID,
      progress: 0.25
    )

    #expect(VLCPlaybackEventMapper.accepts(currentEvent, currentGeneration: currentGeneration, currentItemID: itemID))
    #expect(!VLCPlaybackEventMapper.accepts(oldEvent, currentGeneration: currentGeneration, currentItemID: itemID))
    #expect(!VLCPlaybackEventMapper.accepts(otherItemEvent, currentGeneration: currentGeneration, currentItemID: itemID))
  }

  @Test("Stable audio stream IDs win over a conflicting fallback signature")
  func stableAudioStreamIDMatchWins() {
    let selection = AudioStreamSelection(
      streamID: AudioStreamID("vlc-media-id:42"),
      fallbackSignature: AudioStreamSignature(
        language: "jpn",
        title: "Original",
        codec: "flac",
        channelCount: 2,
        indexHint: 0
      )
    )
    let candidates = [
      VLCAudioStreamCandidate(
        stableIDs: ["vlc-media-id:42"],
        index: 1,
        language: "eng",
        title: "Commentary",
        codec: "aac",
        channelCount: 2
      ),
      VLCAudioStreamCandidate(
        stableIDs: ["vlc-media-id:7"],
        index: 0,
        language: "jpn",
        title: "Original",
        codec: "flac",
        channelCount: 2
      )
    ]

    #expect(VLCAudioStreamMatcher.index(for: selection, candidates: candidates) == 1)
  }

  @Test("Audio stream selection falls back deterministically when a stable ID disappears")
  func audioStreamSelectionFallbackIsDeterministic() {
    let selection = AudioStreamSelection(
      streamID: AudioStreamID("old-vlc-id"),
      fallbackSignature: AudioStreamSignature(
        language: "eng",
        title: "Main Mix",
        codec: "aac",
        channelCount: 2,
        indexHint: 2
      )
    )
    let candidates = [
      VLCAudioStreamCandidate(
        stableIDs: ["new-vlc-id-a"],
        index: 0,
        language: "eng",
        title: "Main Mix",
        codec: "aac",
        channelCount: 2
      ),
      VLCAudioStreamCandidate(
        stableIDs: ["new-vlc-id-b"],
        index: 2,
        language: "eng",
        title: "Main Mix",
        codec: "aac",
        channelCount: 2
      )
    ]

    #expect(VLCAudioStreamMatcher.index(for: selection, candidates: candidates) == 2)
  }

  @Test("Only public VLCKit options and supported resource headers are injected")
  func safeOptionInjection() throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree",
      mediaOptions: [.networkCaching(milliseconds: 1_500), .reconnect]
    )
    let request = RemotePlaybackRequest(
      url: URL(string: "https://media.example.test/song.mp3")!,
      headers: [
        "User-Agent": "MusicFree/1.0",
        "Referer": "https://media.example.test/",
        "Cookie": "session=opaque-value"
      ]
    )

    let options = try VLCMediaFactory.makeOptions(
      for: .remote(request),
      configuration: configuration,
      now: Date(timeIntervalSince1970: 100)
    )
    #expect(options.arguments.contains(":network-caching=1500"))
    #expect(options.arguments.contains(":http-reconnect"))
    #expect(options.arguments.contains(":http-user-agent=MusicFree/1.0"))
    #expect(options.arguments.contains(":http-referrer=https://media.example.test/"))
    #expect(options.cookies.count == 1)
    #expect(!options.description.contains("opaque-value"))
    #expect(!String(reflecting: options).contains("opaque-value"))
  }

  @Test("Unsupported sensitive headers fail without exposing their values")
  func unsupportedHeaderIsRedacted() throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree"
    )
    let fixtureHeaderValue = "fixture-header-value"
    let request = RemotePlaybackRequest(
      url: URL(string: "https://media.example.test/song.mp3")!,
      headers: ["Authorization": fixtureHeaderValue]
    )

    do {
      _ = try VLCMediaFactory.makeOptions(
        for: .remote(request),
        configuration: configuration,
        now: Date(timeIntervalSince1970: 100)
      )
      Issue.record("Authorization should not be silently injected")
    } catch {
      #expect(error is VLCKitAdapterError)
      #expect(!String(describing: error).contains(fixtureHeaderValue))
      #expect(String(describing: error).contains("authorization") == false)
    }
  }

  @Test("Adapter errors map to stable PlaybackAPI errors")
  func errorMapping() {
    #expect(
      VLCPlaybackErrorMapper.playbackError(from: VLCKitAdapterError.expiredResource)
        == .resourceUnavailable
    )
    #expect(
      VLCPlaybackErrorMapper.playbackError(from: VLCKitAdapterError.parserTimedOut)
        == .engineFailure(code: "parser_timed_out")
    )
    #expect(
      VLCPlaybackErrorMapper.playbackError(from: VLCKitAdapterError.cancelled)
        == .cancelled
    )
  }

  @Test("Capability resolver only enables policy-approved runtime capabilities")
  func capabilityPolicy() throws {
    let descriptor = EqualizerDescriptor(
      bands: [
        EqualizerBandDescriptor(
          centerFrequencyHz: 100,
          minimumGainDecibels: -20,
          maximumGainDecibels: 20
        )
      ],
      minimumPreampDecibels: -20,
      maximumPreampDecibels: 20
    )
    let runtime = VLCRuntimeCapabilitySnapshot(
      seeking: true,
      variableRate: true,
      equalizerDescriptor: descriptor
    )
    let policy = VLCKitCapabilityPolicy(
      enabledCapabilities: [.seeking, .equalizer, .gapless]
    )
    let resolved = VLCCapabilityResolver.resolve(policy: policy, runtime: runtime)

    #expect(resolved.contains(.seeking))
    #expect(resolved.contains(.equalizer))
    #expect(!resolved.contains(.variableRate))
    #expect(!resolved.contains(.gapless))
  }

  @Test("Equalizer mapper preserves the runtime VLC band layout")
  func equalizerDescriptorMapping() throws {
    let descriptor = try #require(
      VLCAudioEffectsMapper.descriptor(frequencies: [60, 170, 1_000, 16_000])
    )
    #expect(descriptor.bandCount == 4)
    #expect(descriptor.bands.map(\.centerFrequencyHz) == [60, 170, 1_000, 16_000])
    #expect(descriptor.minimumPreampDecibels == -20)
    #expect(descriptor.maximumPreampDecibels == 20)

    let configuration = EqualizerConfiguration(
      preampDecibels: 3,
      bandGains: descriptor.bands.map {
        EqualizerBandGain(centerFrequencyHz: $0.centerFrequencyHz, gainDecibels: 0)
      }
    )
    #expect(try configuration.validated(against: descriptor) == configuration)
  }

  @MainActor
  @Test("Equalizer configuration can be staged before a VLC player exists")
  func equalizerConfigurationBeforePrepare() throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree",
      capabilityPolicy: VLCKitCapabilityPolicy(enabledCapabilities: [.equalizer])
    )
    let engine = try VLCPlaybackEngine(configuration: configuration)
    let descriptor = try #require(engine.equalizerDescriptor)
    let preset = try #require(descriptor.presets.first)
    #expect(!preset.name.isEmpty)
    #expect(try preset.configuration.validated(against: descriptor) == preset.configuration)
    let equalizer = EqualizerConfiguration(
      preampDecibels: 2,
      bandGains: descriptor.bands.map {
        EqualizerBandGain(centerFrequencyHz: $0.centerFrequencyHz, gainDecibels: 0)
      }
    )

    try engine.apply(AudioEffectConfiguration(equalizer: equalizer))
    try engine.apply(.neutral)
  }

  @MainActor
  @Test("Audio profile exposes rate, volume, and mute at runtime")
  func audioProfileRuntimeAccessors() async throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree",
      capabilityPolicy: VLCKitCapabilityPolicy(enabledCapabilities: [.variableRate])
    )
    let engine = try VLCPlaybackEngine(configuration: configuration)
    let mediaURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("musicfree-vlckit-audio-profile-\(UUID().uuidString)")
      .appendingPathExtension("mp3")
    #expect(FileManager.default.createFile(atPath: mediaURL.path, contents: Data()))
    defer {
      engine.dispose()
      try? FileManager.default.removeItem(at: mediaURL)
    }

    try engine.setRate(1.25)
    try await engine.prepare(
      PlaybackItem(
        itemID: MediaItemID(sourceID: .local, externalID: "audio-profile-runtime"),
        resource: .local(mediaURL),
        displaySnapshot: PlaybackDisplaySnapshot(title: "Audio Profile Runtime")
      ),
      startAt: nil
    )
    try engine.setRate(1)
    try engine.setVolume(0.5)
    try engine.setMuted(true)

    #expect(engine.volume == 0.5)
    #expect(engine.isMuted)
  }

  @MainActor
  @Test("A local WAV natural EOF emits one completion before the next item")
  func naturalEOFPreparesTheFollowingItem() async throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree"
    )
    let engine = try VLCPlaybackEngine(configuration: configuration)
    let firstURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("musicfree-natural-end-first-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    let secondURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("musicfree-natural-end-second-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    try makePlaybackTestWaveData().write(to: firstURL, options: .atomic)
    try makePlaybackTestWaveData(frequency: 660).write(to: secondURL, options: .atomic)
    defer {
      engine.dispose()
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
    }

    let firstID = MediaItemID(sourceID: .local, externalID: "natural-end-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "natural-end-second")
    let stream = engine.makeEventStream()
    let recorder = PlaybackEventRecorder()
    let eventTask = Task { @MainActor in
      for await event in stream {
        recorder.events.append(event)
      }
    }

    try await engine.prepare(
      PlaybackItem(
        itemID: firstID,
        resource: .local(firstURL),
        displaySnapshot: PlaybackDisplaySnapshot(title: "First")
      ),
      startAt: nil
    )
    try engine.play()
    for _ in 0..<100 {
      if engine.state.phase == .stopped {
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    for _ in 0..<10 {
      await Task.yield()
    }
    eventTask.cancel()
    await eventTask.value

    let firstEndedEvents = recorder.events.filter { event in
      if case .ended(_, let itemID, _) = event {
        return itemID == firstID
      }
      return false
    }
    #expect(firstEndedEvents.count == 1)
    #expect(engine.state.phase == .stopped)

    try await engine.prepare(
      PlaybackItem(
        itemID: secondID,
        resource: .local(secondURL),
        displaySnapshot: PlaybackDisplaySnapshot(title: "Second")
      ),
      startAt: nil
    )
    try engine.play()
    #expect(engine.state.phase == .playing)
  }

  @MainActor
  @Test("A CUE-style playback range maps seek and ends once at the logical boundary")
  func playbackRangeStopsAtLogicalBoundary() async throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree",
      applicationVersion: "1.0",
      applicationName: "MusicFree",
      capabilityPolicy: VLCKitCapabilityPolicy(enabledCapabilities: [.seeking])
    )
    let engine = try VLCPlaybackEngine(configuration: configuration)
    let mediaURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("musicfree-cue-range-(UUID().uuidString)")
      .appendingPathExtension("wav")
    try makePlaybackTestWaveData(duration: 0.35).write(to: mediaURL, options: .atomic)
    defer {
      engine.dispose()
      try? FileManager.default.removeItem(at: mediaURL)
    }

    let itemID = MediaItemID(sourceID: .local, externalID: "cue-range")
    let range = PlaybackRange(start: .milliseconds(50), end: .milliseconds(150))
    let recorder = PlaybackEventRecorder()
    let stream = engine.makeEventStream()
    let eventTask = Task { @MainActor in
      for await event in stream {
        recorder.events.append(event)
      }
    }

    try await engine.prepare(
      PlaybackItem(
        itemID: itemID,
        resource: .local(mediaURL),
        selection: PlaybackSelection(range: range),
        displaySnapshot: PlaybackDisplaySnapshot(title: "CUE Range")
      ),
      startAt: nil
    )
    try await engine.seek(to: .milliseconds(20))
    #expect(engine.state.position == .milliseconds(20))
    try engine.play()

    for _ in 0..<100 {
      if engine.state.phase == .stopped { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    for _ in 0..<10 { await Task.yield() }
    eventTask.cancel()
    await eventTask.value

    let endedEvents = recorder.events.filter { event in
      if case .ended(_, let endedItemID, _) = event { return endedItemID == itemID }
      return false
    }
    let finalPositions = recorder.events.compactMap { event -> Duration? in
      if case .positionChanged(_, let positionItemID, let position, _) = event,
         positionItemID == itemID
      {
        return position
      }
      return nil
    }

    #expect(endedEvents.count == 1)
    #expect(finalPositions.contains(range.duration))
    #expect(engine.state.position == range.duration)
    #expect(engine.state.duration == range.duration)
  }
}

@MainActor
private final class PlaybackEventRecorder {
  var events: [PlaybackEvent] = []
}

private func makePlaybackTestWaveData(
  frequency: Double = 440,
  duration: Double = 0.35
) -> Data {
  let sampleRate: UInt32 = 8_000
  let channelCount: UInt16 = 1
  let bitsPerSample: UInt16 = 16
  let bytesPerSample = Int(bitsPerSample / 8)
  let sampleCount = Int(Double(sampleRate) * duration)
  let dataSize = UInt32(sampleCount * bytesPerSample)
  let byteRate = sampleRate * UInt32(channelCount) * UInt32(bytesPerSample)
  let blockAlign = channelCount * UInt16(bytesPerSample)

  var data = Data()
  data.append(contentsOf: "RIFF".utf8)
  data.appendPlaybackTestLittleEndian(UInt32(36) + dataSize)
  data.append(contentsOf: "WAVE".utf8)
  data.append(contentsOf: "fmt ".utf8)
  data.appendPlaybackTestLittleEndian(UInt32(16))
  data.appendPlaybackTestLittleEndian(UInt16(1))
  data.appendPlaybackTestLittleEndian(channelCount)
  data.appendPlaybackTestLittleEndian(sampleRate)
  data.appendPlaybackTestLittleEndian(byteRate)
  data.appendPlaybackTestLittleEndian(blockAlign)
  data.appendPlaybackTestLittleEndian(bitsPerSample)
  data.append(contentsOf: "data".utf8)
  data.appendPlaybackTestLittleEndian(dataSize)

  for index in 0..<sampleCount {
    let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
    let sample = Int16((sin(phase) * Double(Int16.max) * 0.08).rounded())
    data.appendPlaybackTestLittleEndian(sample)
  }
  return data
}

private extension Data {
  mutating func appendPlaybackTestLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
      append(contentsOf: bytes)
    }
  }
}
