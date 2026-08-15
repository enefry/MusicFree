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
      stopWasRequested: false
    )
    let completedEvents = VLCPlaybackEventMapper.events(
      for: .buffering(generation: generation, itemID: itemID, progress: 1),
      stopWasRequested: false
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

  @Test("Natural stop and requested stop have distinct terminal mapping")
  func terminalMapping() {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let event = VLCPlaybackDelegateEvent.state(
      generation: PlaybackGeneration(4),
      itemID: itemID,
      code: VLCPlaybackStateCode.stopped
    )

    let naturalEvents = VLCPlaybackEventMapper.events(for: event, stopWasRequested: false)
    let requestedEvents = VLCPlaybackEventMapper.events(for: event, stopWasRequested: true)
    #expect(naturalEvents.contains { $0.isTerminal })
    #expect(requestedEvents.allSatisfy { !$0.isTerminal })
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
}
