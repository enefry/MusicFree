import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing

@Test("Playback generations stay attached to events and errors stay classified")
func playbackGenerationAndEventContract() throws {
  let generation = PlaybackGeneration.initial.advanced()
  let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
  let event = PlaybackEvent.failed(
    generation: generation,
    itemID: itemID,
    error: .engineFailure(code: "/private/fixture/playback-error")
  )

  #expect(event.generation == generation)
  #expect(event.itemID == itemID)
  #expect(event.isTerminal)

  if case .failed(_, _, let error) = event {
    #expect(error.diagnosticCode == "engine_failure")
    #expect(!error.description.contains("/private/fixture"))
    #expect(error.isRetryable)
  } else {
    Issue.record("Expected a failed playback event")
  }

  let data = try JSONEncoder().encode(event)
  let decodedEvent = try JSONDecoder().decode(PlaybackEvent.self, from: data)
  #expect(decodedEvent == event)
}

@Test("Queue snapshots preserve duplicate items without persisting resources")
func playbackQueueSnapshotContract() throws {
  let itemID = MediaItemID(sourceID: .local, externalID: "same-track")
  let firstEntry = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    itemID: itemID
  )
  let secondEntry = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    itemID: itemID
  )
  let snapshot = PlaybackQueueSnapshot(
    entries: [firstEntry, secondEntry],
    currentEntryID: secondEntry.id,
    repeatMode: .all,
    shuffleMode: .on,
    shuffleSeed: 42,
    shuffleOrder: [secondEntry.id, firstEntry.id],
    resumePosition: .seconds(12)
  )

  #expect(snapshot.itemIDs == [itemID, itemID])
  #expect(snapshot.currentItemID == itemID)
  #expect(snapshot.entries[0].id != snapshot.entries[1].id)

  let data = try JSONEncoder().encode(snapshot)
  let decoded = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
  #expect(decoded == snapshot)
  #expect(!String(decoding: data, as: UTF8.self).contains("PlaybackResource"))
  #expect(!(PlaybackItem.self is any Encodable.Type))
}

@Test("Legacy queue entries decode to logical identity with the old item preferred")
func legacyPlaybackQueueEntryDecoding() throws {
  let payload = #"{"id":"00000000-0000-0000-0000-000000000099","itemID":{"sourceID":"local","externalID":"legacy-queue-track"}}"#.data(using: .utf8)!
  let entry = try JSONDecoder().decode(PlaybackQueueEntry.self, from: payload)
  let expectedItemID = MediaItemID(sourceID: .local, externalID: "legacy-queue-track")

  #expect(entry.itemID == expectedItemID)
  #expect(entry.preferredVariantID == expectedItemID)
  #expect(entry.logicalTrackID == LogicalTrackID(legacyVariantID: expectedItemID))

  let encoded = try JSONEncoder().encode(entry)
  let roundTrip = try JSONDecoder().decode(PlaybackQueueEntry.self, from: encoded)
  #expect(roundTrip == entry)
  #expect(!String(decoding: encoded, as: UTF8.self).contains("itemID"))
}

@Test("Queue edits are deterministic value transformations")
func playbackQueueEdits() throws {
  let first = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
    itemID: MediaItemID(sourceID: .local, externalID: "first")
  )
  let second = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
    itemID: MediaItemID(sourceID: .local, externalID: "second")
  )

  let appended = try PlaybackQueueSnapshot.empty.applying(.append(first))
  let filled = try appended.applying(.append(second))
  let moved = try filled.applying(.move(second.id, to: 0))
  #expect(moved.entries.map(\.id) == [second.id, first.id])

  let selected = try moved.applying(.setCurrent(first.id))
  #expect(selected.currentEntryID == first.id)
  #expect(selected.resumePosition == nil)

  let removed = try selected.applying(.remove(first.id))
  #expect(removed.entries == [second])
  #expect(removed.currentEntryID == nil)
  let cleared = try removed.applying(.clear)
  #expect(cleared == .empty)
}

@Test("Capabilities and runtime EQ values do not assume ten fixed bands")
func playbackCapabilitiesAndEffects() throws {
  let descriptor = EqualizerDescriptor(
    bands: [
      EqualizerBandDescriptor(
        centerFrequencyHz: 80,
        minimumGainDecibels: -6,
        maximumGainDecibels: 6
      ),
      EqualizerBandDescriptor(
        centerFrequencyHz: 1_000,
        minimumGainDecibels: -12,
        maximumGainDecibels: 12
      ),
    ]
  )
  let equalizer = EqualizerConfiguration(
    preampDecibels: 1,
    bandGains: [
      EqualizerBandGain(centerFrequencyHz: 80, gainDecibels: 2),
      EqualizerBandGain(centerFrequencyHz: 1_000, gainDecibels: -1),
    ]
  )
  let validatedEqualizer = try equalizer.validated(against: descriptor)
  #expect(validatedEqualizer == equalizer)

  let capabilities: PlaybackCapabilities = [
    .seeking,
    .variableRate,
    .equalizer,
    .visualization,
  ]
  let encodedCapabilities = try JSONEncoder().encode(capabilities)
  let decodedCapabilities = try JSONDecoder().decode(
    PlaybackCapabilities.self,
    from: encodedCapabilities
  )
  #expect(decodedCapabilities == capabilities)

  let effects = AudioEffectConfiguration(
    equalizer: equalizer,
    replayGain: ReplayGainConfiguration(mode: .track),
    transition: AudioTransitionConfiguration(
      mode: .crossfade,
      crossfadeDuration: .seconds(2)
    ),
    rate: 1.25
  )
  let encodedEffects = try JSONEncoder().encode(effects)
  let decodedEffects = try JSONDecoder().decode(
    AudioEffectConfiguration.self,
    from: encodedEffects
  )
  #expect(decodedEffects == effects)
}

@Test("Runtime equalizer presets round-trip without breaking legacy descriptors")
func equalizerPresetDescriptorsRemainBackwardCompatible() throws {
  let bands = [
    EqualizerBandDescriptor(
      centerFrequencyHz: 80,
      minimumGainDecibels: -12,
      maximumGainDecibels: 12
    ),
    EqualizerBandDescriptor(
      centerFrequencyHz: 1_000,
      minimumGainDecibels: -12,
      maximumGainDecibels: 12
    ),
  ]
  let presetConfiguration = EqualizerConfiguration(
    preampDecibels: 1,
    bandGains: [
      EqualizerBandGain(centerFrequencyHz: 80, gainDecibels: -2),
      EqualizerBandGain(centerFrequencyHz: 1_000, gainDecibels: 4),
    ]
  )
  let descriptor = EqualizerDescriptor(
    bands: bands,
    presets: [
      EqualizerPresetDescriptor(
        id: 7,
        name: "Test preset",
        configuration: presetConfiguration
      )
    ]
  )

  let encoded = try JSONEncoder().encode(descriptor)
  #expect(try JSONDecoder().decode(EqualizerDescriptor.self, from: encoded) == descriptor)

  var legacyObject = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  legacyObject.removeValue(forKey: "presets")
  let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
  let legacyDescriptor = try JSONDecoder().decode(EqualizerDescriptor.self, from: legacyData)
  #expect(legacyDescriptor.presets.isEmpty)
  #expect(legacyDescriptor.bands == bands)
}

@Test("Playback items retain transient resource boundaries")
func playbackItemAndVisualizationContracts() throws {
  let generation = PlaybackGeneration(3)
  let frame = AudioVisualizationFrame(
    generation: generation,
    timestamp: .seconds(4),
    magnitudes: [0.1, 0.4, 0.9]
  )
  let frameData = try JSONEncoder().encode(frame)
  let decodedFrame = try JSONDecoder().decode(AudioVisualizationFrame.self, from: frameData)
  #expect(decodedFrame == frame)

  let item = PlaybackItem(
    itemID: MediaItemID(sourceID: .local, externalID: "visualized"),
    resource: .local(URL(fileURLWithPath: "/private/example/song.flac")),
    displaySnapshot: PlaybackDisplaySnapshot(
      title: "Song",
      artist: "Artist",
      duration: .seconds(30)
    )
  )
  #expect(item.display.title == "Song")
  #expect(item.display.artist == "Artist")
  #expect(item.resource.isEphemeral)
  #expect(!(PlaybackItem.self is any Encodable.Type))
}
