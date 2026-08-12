import Foundation
import MediaSourceAPI
import MusicDomain
import Testing

@Test("remote playback requests remain transient and redacted")
func remotePlaybackRequestsAreTransientAndRedacted() {
  let request = RemotePlaybackRequest(
    url: URL(string: "https://media.example.test/track")!,
    headers: ["Authorization": "fixture-header-value"],
    expiresAt: Date(timeIntervalSince1970: 100)
  )
  let resource = PlaybackResource.remote(request)

  #expect(request.headers["Authorization"] == "fixture-header-value")
  #expect(request.isExpired(at: Date(timeIntervalSince1970: 99)) == false)
  #expect(request.isExpired(at: Date(timeIntervalSince1970: 100)))
  #expect(!request.description.contains("fixture-header-value"))
  #expect(!String(reflecting: request).contains("fixture-header-value"))
  #expect(!resource.description.contains("fixture-header-value"))
  #expect(!String(reflecting: resource).contains("fixture-header-value"))
  #expect(!(RemotePlaybackRequest.self is any Encodable.Type))
  #expect(!(PlaybackResource.self is any Encodable.Type))
}

@Test("raw metadata omits blank values and round trips stable fields")
func rawMetadataNormalizesBlankValues() throws {
  let metadata = RawMediaMetadata(
    title: "  ",
    artist: "  Artist  ",
    duration: .seconds(12),
    artworks: [RawArtwork(data: Data([0x01, 0x02]), mimeType: "image/jpeg")]
  )

  #expect(metadata.title == nil)
  #expect(metadata.artist == "Artist")
  #expect(metadata.firstArtwork?.mimeType == "image/jpeg")

  let encoded = try JSONEncoder().encode(metadata)
  let decoded = try JSONDecoder().decode(RawMediaMetadata.self, from: encoded)
  #expect(decoded == metadata)
}

@Test("probe validation requires a decodable audio track")
func probeValidationRequiresAudio() {
  let empty = MediaProbeResult(audioTracks: [])
  let undecodable = MediaProbeResult(
    audioTracks: [ProbedAudioTrack(index: 0, isDecodable: false)]
  )
  let playable = MediaProbeResult(
    audioTracks: [ProbedAudioTrack(index: 0, codec: "aac")]
  )

  #expect(empty.isPlayable == false)
  #expect(undecodable.isPlayable == false)
  #expect(playable.isPlayable)
  #expect(throws: MediaSourceError.self) {
    try empty.validated()
  }
  let validated = try? playable.validated()
  #expect(validated?.isPlayable == true)
  #expect(validated?.audioTracks == playable.audioTracks)
}

@Test("cancelled import is a terminal result and not a failure")
func cancelledImportIsTerminal() {
  let importID = UUID()
  let result = MediaImportResult(
    importID: importID,
    imported: 1,
    duplicate: 0,
    skipped: 0,
    failed: 0,
    cancelled: 2,
    status: .cancelled
  )
  let event = MediaImportEvent.cancelled(importID: importID, result: result)

  #expect(event.isTerminal)
  #expect(event.importID == importID)
  #expect(result.isCancelled)
  #expect(result.failed == 0)
  #expect(MediaImportError.cancelled.isCancellation)
  #expect(MediaImportError.cancelled.isRetryable == false)
}

@Test("import phases keep item failures non-terminal")
func importPhasesAndItemFailuresAreClassified() {
  let importID = UUID()
  let inputURL = URL(fileURLWithPath: "/private/temporary/fixture.m4a")
  let events: [MediaImportEvent] = [
    .discovered(importID: importID, url: inputURL),
    .hashing(importID: importID, url: inputURL),
    .probing(importID: importID, url: inputURL),
    .copying(importID: importID, url: inputURL),
    .itemFailed(importID: importID, url: inputURL, error: .duplicate),
    .completed(
      importID: importID,
      result: MediaImportResult(
        importID: importID,
        imported: 0,
        duplicate: 1,
        skipped: 0,
        failed: 0,
        cancelled: 0
      )
    ),
  ]

  #expect(events.dropLast().allSatisfy { !$0.isTerminal })
  #expect(events.last?.isTerminal == true)
  #expect(!events[0].description.contains("fixture.m4a"))
  #expect(MediaImportError.duplicate.isRetryable == false)
}

@Test("cancelled import streams finish normally")
func cancelledImportStreamFinishesNormally() async throws {
  let importID = UUID()
  let result = MediaImportResult(
    importID: importID,
    imported: 0,
    duplicate: 0,
    skipped: 0,
    failed: 0,
    cancelled: 1,
    status: .cancelled
  )
  let stream = AsyncThrowingStream<MediaImportEvent, Error> { continuation in
    continuation.yield(.cancelled(importID: importID, result: result))
    continuation.finish()
  }
  var events: [MediaImportEvent] = []

  for try await event in stream {
    events.append(event)
  }

  #expect(events.count == 1)
  #expect(events.first?.isTerminal == true)
}

@Test("source and removal errors expose deterministic classifications")
func sourceAndRemovalErrorsAreClassified() {
  let unknownSource = MediaSourceError.unknownSource(.local)

  #expect(unknownSource.isRetryable == false)
  #expect(unknownSource.isCancellation == false)
  if case .sourceNotFound(let sourceID) = unknownSource {
    #expect(sourceID == .local)
  } else {
    Issue.record("unknownSource did not preserve the source-not-found category")
  }

  #expect(MediaProbeError.unsupportedFormat.isRetryable == false)
  #expect(MediaRemovalError.alreadyCommitted.isRetryable == false)
  #expect(MediaRemovalError.alreadyCommitted.isCancellation == false)
}

@Test("media source capabilities encode as a stable bit set")
func mediaSourceCapabilitiesRoundTrip() throws {
  let capabilities: MediaSourceCapabilities = [.importing, .managedRemoval]
  let encoded = try JSONEncoder().encode(capabilities)
  let decoded = try JSONDecoder().decode(MediaSourceCapabilities.self, from: encoded)

  #expect(decoded == capabilities)
  #expect(decoded.contains(.importing))
  #expect(decoded.contains(.managedMediaRemoval))
  #expect(!decoded.contains(.incrementalSync))
}

@Test("removal transaction contains only stable IDs")
func removalTransactionContainsStableIDs() throws {
  let itemID = MediaItemID(sourceID: .local, externalID: "fixture-track")
  let transaction = MediaRemovalTransaction(
    transactionID: UUID(),
    itemIDs: [itemID]
  )

  let encoded = try JSONEncoder().encode(transaction)
  let decoded = try JSONDecoder().decode(MediaRemovalTransaction.self, from: encoded)

  #expect(decoded == transaction)
  #expect(decoded.itemIDs == [itemID])
  #expect(!transaction.description.contains("/"))
}
