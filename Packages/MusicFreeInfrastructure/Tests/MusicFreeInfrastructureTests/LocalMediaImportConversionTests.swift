import Foundation
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing

@testable import LocalMediaAdapter

@Suite("Local media import audio conversion")
struct LocalMediaImportConversionTests {
  @Test("Unsupported lossless audio remains importable with its original bytes")
  func unsupportedLosslessAudioIsImportedWithoutConversion() async throws {
    let fixture = try ImportConversionFixture()
    defer { fixture.remove() }
    let inputURL = fixture.inputRoot.appendingPathComponent("surround.flac")
    let sourceData = Data("six-channel-lossless-source".utf8)
    try sourceData.write(to: inputURL)
    let repository = InMemoryLibraryRepository()
    let transcoder = RecordingImportTranscoder()
    let importer = try LocalMediaImporter(
      configuration: fixture.configuration,
      probe: UnsupportedSurroundProbe(),
      metadataReader: EmptyImportMetadataReader(),
      libraryRepository: repository,
      transcoder: transcoder,
      losslessValidator: AcceptingImportLosslessValidator(),
      conversionScheduler: ImmediateImportConversionScheduler()
    )

    let events = try await collectImportEvents(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [inputURL],
      duplicatePolicy: .report,
      audioConversionPolicy: AudioImportConversionPolicy(target: .aacLC(.kbps256))
    )))

    let result = try terminalImportResult(in: events)
    let itemID = try #require(persistedImportItemID(in: events))
    let track = try #require(try await repository.track(id: itemID))
    let asset = try #require(try await repository.mediaAsset(id: track.assetID))
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: fixture.configuration)
    let managedURL = try await coordinator.store.mediaURL(forExternalID: asset.id.externalID)
    #expect(result.status == .completed)
    #expect(result.imported == 1)
    #expect(result.failed == 0)
    #expect(asset.conversion == nil)
    #expect(await transcoder.callCount == 0)
    #expect(try Data(contentsOf: managedURL) == sourceData)
  }

  @Test("Cancelling ALAC sample validation preserves import cancellation semantics")
  func alacValidationCancellationDoesNotBecomeAnItemFailure() async throws {
    let fixture = try ImportConversionFixture()
    defer { fixture.remove() }
    let inputURL = fixture.inputRoot.appendingPathComponent("cancel-validation.flac")
    try Data("supported-lossless-source".utf8).write(to: inputURL)
    let repository = InMemoryLibraryRepository()
    let importer = try LocalMediaImporter(
      configuration: fixture.configuration,
      probe: ALACRoundTripProbe(),
      metadataReader: EmptyImportMetadataReader(),
      libraryRepository: repository,
      transcoder: RecordingImportTranscoder(),
      losslessValidator: CancellingImportLosslessValidator(),
      conversionScheduler: ImmediateImportConversionScheduler()
    )

    let events = try await collectImportEvents(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [inputURL],
      duplicatePolicy: .report,
      audioConversionPolicy: AudioImportConversionPolicy(target: .alac)
    )))

    let result = try terminalImportResult(in: events)
    #expect(result.status == .cancelled)
    #expect(result.failed == 0)
    #expect(result.cancelled == 1)
    #expect(!events.contains(where: {
      if case .itemFailed = $0 { return true }
      return false
    }))
    #expect(try await repository.mediaAssets().isEmpty)
  }
}

private struct ImportConversionFixture {
  let root: URL
  let inputRoot: URL
  let configuration: LocalMediaConfiguration

  init() throws {
    var repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
    let parent = repositoryRoot
      .appendingPathComponent(".noindex/tmp/import-conversion-tests", isDirectory: true)
    root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    inputRoot = root.appendingPathComponent("input", isDirectory: true)
    try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
    configuration = try LocalMediaConfiguration(
      managedRoot: root.appendingPathComponent("managed", isDirectory: true),
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct UnsupportedSurroundProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    _ = resource
    return MediaProbeResult(
      audioTracks: [ProbedAudioTrack(
        index: 0,
        codec: "flac",
        sampleRate: 48_000,
        channelCount: 6,
        bitDepth: 24,
        isDefault: true,
        isLossless: true
      )],
      container: "flac",
      duration: .seconds(30)
    )
  }
}

private struct ALACRoundTripProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    let isOutput = resource.localFileURL?.pathExtension.lowercased() == "m4a"
    return MediaProbeResult(
      audioTracks: [ProbedAudioTrack(
        index: 0,
        codec: isOutput ? "alac" : "flac",
        sampleRate: 44_100,
        channelCount: 2,
        bitDepth: 24,
        isDefault: true,
        isLossless: true
      )],
      container: isOutput ? "mov,mp4,m4a" : "flac",
      duration: .seconds(30)
    )
  }
}

private actor RecordingImportTranscoder: MediaTranscoding {
  private(set) var callCount = 0

  func transcode(
    _ request: MediaTranscodeRequest,
    progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
  ) async throws -> MediaTranscodeResult {
    callCount += 1
    progress(MediaTranscodeProgress(stage: .encoding, completedFrames: 1, totalFrames: 1))
    try Data("converted-output".utf8).write(to: request.outputURL)
    return MediaTranscodeResult(
      outputURL: request.outputURL,
      target: request.target,
      processedFrames: 1,
      sampleRate: 44_100,
      channelCount: 2,
      bitDepth: request.target == .alac ? 24 : nil
    )
  }
}

private struct EmptyImportMetadataReader: MetadataReading {
  func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
    _ = resource
    return RawMediaMetadata()
  }
}

private struct AcceptingImportLosslessValidator: MediaLosslessValidating {
  func validateLosslessPCM(inputURL: URL, outputURL: URL) async throws {}
}

private struct CancellingImportLosslessValidator: MediaLosslessValidating {
  func validateLosslessPCM(inputURL: URL, outputURL: URL) async throws {
    throw CancellationError()
  }
}

private struct ImmediateImportConversionScheduler: MediaConversionScheduling {
  func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) async {}

  func schedule(
    _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
  ) async throws -> MediaTranscodeResult {
    try await operation()
  }
}

private func collectImportEvents(
  _ stream: AsyncThrowingStream<MediaImportEvent, Error>
) async throws -> [MediaImportEvent] {
  var events: [MediaImportEvent] = []
  for try await event in stream { events.append(event) }
  return events
}

private func terminalImportResult(in events: [MediaImportEvent]) throws -> MediaImportResult {
  for event in events {
    if case .completed(_, let result) = event { return result }
    if case .cancelled(_, let result) = event { return result }
  }
  struct MissingTerminalEvent: Error {}
  throw MissingTerminalEvent()
}

private func persistedImportItemID(in events: [MediaImportEvent]) -> MediaItemID? {
  for event in events {
    if case .persisting(_, let itemID) = event { return itemID }
  }
  return nil
}
