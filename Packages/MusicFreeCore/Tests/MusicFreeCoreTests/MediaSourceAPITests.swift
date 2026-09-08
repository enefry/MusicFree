import CoreFoundation
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

@Test("media import metadata hints normalize input URLs without leaking values")
func mediaImportMetadataHintsNormalizeAndRemainRedacted() throws {
  let inputURL = URL(fileURLWithPath: "/tmp/musicfree/album/../track.mp3")
  let hint = MediaImportMetadataHint(
    displayName: "  Remote Track.mp3  ",
    title: "  Remote Track  ",
    artist: "  Remote Artist  ",
    album: "  Remote Album  ",
    duration: .seconds(42)
  )
  let request = MediaImportRequest(
    importID: UUID(),
    urls: [inputURL],
    duplicatePolicy: .report,
    metadataHints: [inputURL: hint]
  )
  let resolved = try #require(
    request.metadataHint(for: inputURL.standardizedFileURL)
  )

  #expect(resolved.displayName == "Remote Track.mp3")
  #expect(resolved.title == "Remote Track")
  #expect(resolved.artist == "Remote Artist")
  #expect(resolved.album == "Remote Album")
  #expect(resolved.duration == .seconds(42))
  #expect(request.duplicatePolicy == .report)
  #expect(request.description.contains("metadataHintCount: 1"))
  #expect(!request.description.contains("Remote Artist"))
  #expect(!String(reflecting: request).contains("Remote Album"))
}

@Test("online provider capabilities and catalog values round trip")
func onlineProviderCapabilitiesAndCatalogRoundTrip() throws {
  let sourceID = MediaSourceID("dsaudio.fixture")
  let objectID = SourceObjectID(sourceID: sourceID, externalID: "folder/track-1")
  let capabilities: OnlineSourceCapabilities = [
    .browsing,
    .downloading,
    .searching,
    .onlinePlayback,
    .httpTranscoding,
    .artwork,
  ]
  let item = SourceCatalogItem(
    id: objectID,
    kind: .track,
    displayName: "  Fixture Track  ",
    parentID: SourceObjectID(sourceID: sourceID, externalID: "folder"),
    title: "  Track 1 ",
    artist: "  Artist 1 ",
    album: "  Album 1 ",
    duration: .seconds(42),
    byteSize: -1,
    contentRevision: "  rev-1 ",
    mimeType: " audio/mpeg ",
    isPlayable: true
  )

  let encodedCapabilities = try JSONEncoder().encode(capabilities)
  let decodedCapabilities = try JSONDecoder().decode(
    OnlineSourceCapabilities.self,
    from: encodedCapabilities
  )
  let encodedItem = try JSONEncoder().encode(item)
  let decodedItem = try JSONDecoder().decode(SourceCatalogItem.self, from: encodedItem)

  #expect(decodedCapabilities == capabilities)
  #expect(decodedCapabilities.contains(.onlinePlayback))
  #expect(decodedItem == item)
  #expect(decodedItem.displayName == "Fixture Track")
  #expect(decodedItem.title == "Track 1")
  #expect(decodedItem.byteSize == 0)
  #expect(decodedItem.mimeType == "audio/mpeg")
  #expect(decodedItem.isPlayable)
  #expect(objectID.description.contains("redacted"))
  #expect(!objectID.description.contains("folder/track-1"))
}

@Test("online source configuration validates and normalizes its endpoint")
func onlineSourceConfigurationValidatesAndNormalizesEndpoint() throws {
  let sourceID = MediaSourceID("drive.fixture")
  let configuration = try OnlineSourceConfiguration(
    sourceID: sourceID,
    providerKind: .googleDrive,
    displayName: "  Work Drive  ",
    endpoint: URL(string: "HTTPS://drive.example.test/root/")!,
    credentialRecordID: "  credential-1  ",
    isEnabled: false
  )

  #expect(configuration.displayName == "Work Drive")
  #expect(configuration.endpoint?.absoluteString == "https://drive.example.test/root")
  #expect(configuration.credentialRecordID == "credential-1")
  #expect(configuration.settingEnabled(true).isEnabled)
  #expect(configuration.privacyPolicyVersion == nil)

  let consented = try configuration
    .acceptingPrivacyPolicy(version: "  drive-policy-1.2  ")
  #expect(consented.privacyPolicyVersion == "drive-policy-1.2")
  #expect(consented.isPrivacyPolicyAccepted(currentVersion: "drive-policy-1.2"))
  #expect(!consented.isPrivacyPolicyAccepted(currentVersion: "drive-policy-1.1"))
  #expect(consented.revokingPrivacyPolicy().privacyPolicyVersion == nil)
  #expect(!consented.revokingPrivacyPolicy().isEnabled)

  #expect(throws: OnlineSourceConfigurationError.emptyDisplayName) {
    try OnlineSourceConfiguration(
      sourceID: sourceID,
      providerKind: .googleDrive,
      displayName: "   "
    )
  }
  #expect(throws: OnlineSourceConfigurationError.invalidEndpoint) {
    try OnlineSourceConfiguration(
      sourceID: sourceID,
      providerKind: .googleDrive,
      displayName: "Invalid",
      endpoint: URL(string: "file:///tmp/fixture")
    )
  }
  #expect(throws: OnlineSourceConfigurationError.endpointContainsSensitiveComponents) {
    try OnlineSourceConfiguration(
      sourceID: sourceID,
      providerKind: .googleDrive,
      displayName: "Invalid",
      endpoint: URL(string: "https://drive.example.test/root?token=secret")
    )
  }
}

@Test("online source preferences isolate instances and privacy revocation")
func onlineSourcePreferencesIsolateInstancesAndPrivacyRevocation() throws {
  let firstID = MediaSourceID("drive.work")
  let secondID = MediaSourceID("drive.personal")
  let first = try OnlineSourceConfiguration(
    sourceID: firstID,
    providerKind: .googleDrive,
    displayName: "Work Drive"
  )
  let second = try OnlineSourceConfiguration(
    sourceID: secondID,
    providerKind: .googleDrive,
    displayName: "Personal Drive"
  )
  let firstReady = try first
    .acceptingPrivacyPolicy(version: "drive-policy-1.2")
    .settingEnabled(true)
  let secondReady = try second
    .acceptingPrivacyPolicy(version: "drive-policy-1.2")
    .settingEnabled(true)

  let preferences = try OnlineSourcePreferences()
    .adding(firstReady)
    .adding(secondReady)
  let runtime = preferences.runtimeSources(applicationPrivacyAccepted: true)

  #expect(preferences.sources.count == 2)
  #expect(runtime.map(\.sourceID) == [firstID, secondID])
  #expect(preferences.runtimeSources(applicationPrivacyAccepted: false).isEmpty)
  #expect(throws: OnlineSourcePreferencesError.duplicateSource(firstID)) {
    try preferences.adding(firstReady)
  }

  let oneRevoked = try preferences.revokingSourcePrivacy(firstID)
  #expect(oneRevoked.source(for: firstID)?.privacyPolicyVersion == nil)
  #expect(oneRevoked.source(for: firstID)?.isEnabled == false)
  #expect(oneRevoked.source(for: secondID)?.privacyPolicyVersion == "drive-policy-1.2")
  #expect(oneRevoked.runtimeSources(applicationPrivacyAccepted: true).map(\.sourceID) == [secondID])

  let allRevoked = preferences.revokingAllPrivacy()
  #expect(allRevoked.sources.allSatisfy { $0.privacyPolicyVersion == nil && !$0.isEnabled })
  #expect(allRevoked.sources.map(\.sourceID) == [firstID, secondID])
}

@Test("catalog requests clamp page sizes and normalize search text")
func catalogRequestsClampPageSizesAndNormalizeSearchText() {
  let sourceID = MediaSourceID("catalog.fixture")
  let parentID = SourceObjectID(sourceID: sourceID, externalID: "root")
  let cursor = MediaSourceCursor("opaque-cursor")

  let browse = SourceBrowseRequest(parentID: parentID, pageSize: 0, pageToken: cursor)
  let largeBrowse = SourceBrowseRequest(pageSize: 9_999)
  let search = SourceSearchRequest(
    query: "  guitar  ",
    parentID: parentID,
    pageSize: -10,
    pageToken: cursor
  )

  #expect(browse.pageSize == 1)
  #expect(largeBrowse.pageSize == 500)
  #expect(search.query == "guitar")
  #expect(search.pageSize == 1)
  #expect(search.parentID == parentID)
  #expect(search.pageToken == cursor)
}

@Test("catalog requests preserve sort and decode legacy defaults")
func catalogRequestsPreserveSortAndDecodeLegacyDefaults() throws {
  let sort = SourceCatalogSort(
    key: .year,
    direction: .descending
  )
  let request = SourceBrowseRequest(
    mode: .allMusic,
    sort: sort,
    pageSize: 200
  )
  #expect(request.mode == .allMusic)
  #expect(request.sort == sort)
  #expect(SourceCatalogSort.options(for: .albums).contains(sort))
  #expect(SourceCatalogSort.options(for: .artists).contains(
    SourceCatalogSort(key: .name, direction: .descending)
  ))

  let legacyData = Data(
    #"{"parentID":null,"mode":"folders","pageSize":50,"pageToken":null}"#.utf8
  )
  let decoded = try JSONDecoder().decode(SourceBrowseRequest.self, from: legacyData)
  #expect(decoded.mode == .folders)
  #expect(decoded.sort == .standard)
  #expect(decoded.pageSize == 50)
}

@Test("download receipts and playback access do not become persistent or leaky")
func downloadReceiptsAndPlaybackAccessRemainEphemeral() {
  let sourceID = MediaSourceID("remote.fixture")
  let itemID = SourceObjectID(sourceID: sourceID, externalID: "secret-track")
  let receipt = DownloadReceipt(
    sourceID: sourceID,
    itemID: itemID,
    fileURL: URL(fileURLWithPath: "/private/secret/fixture.m4a"),
    contentRevision: "  rev-2 ",
    byteCount: -10
  )
  let access = PlaybackAccess.http(
    request: RemotePlaybackRequest(
      url: URL(string: "https://media.example.test/secret-track")!,
      headers: ["Authorization": "secret-header"]
    ),
    transcode: TranscodeDescriptor(container: "  mp3 ", codec: "  aac ", bitRate: -1)
  )

  #expect(receipt.contentRevision == "rev-2")
  #expect(receipt.byteCount == 0)
  #expect(receipt.description.contains("redacted"))
  #expect(!receipt.description.contains("secret"))
  #expect(access.isEphemeral)
  #expect(access.description == "PlaybackAccess(http: redacted)")
  #expect(!(DownloadReceipt.self is any Encodable.Type))
  #expect(!(PlaybackAccess.self is any Encodable.Type))
  #expect(!String(reflecting: access).contains("secret-header"))
}

@Test("playback source contract includes browse and download operations")
func playbackSourceContractIncludesDownloadOperations() async throws {
  let source: any PlaybackSource = ContractPlaybackSource()
  let page = try await source.browse(SourceBrowseRequest())
  let itemID = try #require(page.items.first?.id)
  let receipt = try await source.download(itemID, options: DownloadOptions())
  let access = try await source.playbackAccess(for: itemID, purpose: .audition)

  #expect(source.providerKind == .dsAudio)
  #expect(source.onlineCapabilities.contains(.downloading))
  #expect(page.items.count == 1)
  #expect(receipt.itemID == itemID)
  #expect(access.isEphemeral)
}

private struct ContractPlaybackSource: PlaybackSource {
  private let sourceID = MediaSourceID("contract.fixture")

  var descriptor: MediaSourceDescriptor {
    MediaSourceDescriptor(
      sourceID: sourceID,
      kind: .remote,
      displayName: "Contract Fixture",
      isReadOnly: true
    )
  }

  var capabilities: MediaSourceCapabilities {
    [.artwork, .metadataReading]
  }

  var providerKind: OnlineProviderKind { .dsAudio }

  var onlineCapabilities: OnlineSourceCapabilities {
    [.browsing, .downloading, .onlinePlayback]
  }

  func resolve(_ assetID: MediaItemID) async throws -> PlaybackResource {
    .local(URL(fileURLWithPath: "/private/temporary/contract.m4a"))
  }

  func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
    nil
  }

  func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "contract-track")
    return SourceCatalogPage(
      items: [SourceCatalogItem(
        id: itemID,
        kind: .track,
        displayName: "Contract Track",
        isPlayable: true
      )]
    )
  }

  func download(
    _ itemID: SourceObjectID,
    options: DownloadOptions
  ) async throws -> DownloadReceipt {
    DownloadReceipt(
      sourceID: sourceID,
      itemID: itemID,
      fileURL: URL(fileURLWithPath: "/private/temporary/contract.m4a")
    )
  }

  func playbackAccess(
    for itemID: SourceObjectID,
    purpose: PlaybackPurpose
  ) async throws -> PlaybackAccess {
    .downloadRequired
  }
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

@Test("raw metadata repairs mojibake when decoded from JSON")
func rawMetadataRepairsMojibakeFromJSON() throws {
  let data = try #require("""
  {
    "title": "¼¸·ÖÖÓµÄÔ¼»á",
    "album": "Àë²»¿ª-³Â°ÙÇ¿ ¼ÍÄî¸è¼¯ 80-93 D",
    "artist": "³Â°ÙÇ¿"
  }
  """.data(using: .utf8))

  let metadata = try JSONDecoder().decode(RawMediaMetadata.self, from: data)
  #expect(metadata.title == "几分钟的约会")
  #expect(metadata.album == "离不开-陈百强 纪念歌集 80-93 D")
  #expect(metadata.artist == "陈百强")
}

@Test("shared metadata decoder supports BOM, legacy Chinese bytes, and mojibake")
func sharedMetadataDecoderSupportsLegacyTextEncodings() throws {
  let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
  ))
  let gbData = try #require("几分钟的约会".data(using: gb18030))
  let utf16Payload = try #require("离不开".data(using: .utf16LittleEndian))
  let utf16Data = Data([0xFF, 0xFE]) + utf16Payload
  let mojibakeData = try #require("ä¸­æ–‡".data(using: .utf8))

  #expect(MetadataTextRepair.decode(gbData) == "几分钟的约会")
  #expect(MetadataTextRepair.decode(utf16Data) == "离不开")
  #expect(MetadataTextRepair.decode(mojibakeData) == "中文")
}

@Test("metadata repair fixes LRC tag values without changing timing structure")
func metadataRepairPreservesLRCTagsAndTimestamps() {
  let lyrics = """
  [ar:ä¸­æ–‡]
  [offset:-250]
  [00:01.00][00:02.00]¼¸·ÖÖÓµÄÔ¼»á
  """

  #expect(MetadataTextRepair.repair(lyrics) == """
  [ar:中文]
  [offset:-250]
  [00:01.00][00:02.00]几分钟的约会
  """)
}

@Test("technical stream identifiers are trimmed while display titles are repaired")
func technicalStreamFieldsKeepIdentifierSemantics() {
  let track = ProbedAudioTrack(
    index: 0,
    stableID: "  ä¸­æ–‡  ",
    codec: "  aac  ",
    language: "  zh  ",
    title: "  ¼¸·ÖÖÓµÄÔ¼»á  "
  )

  #expect(track.stableID == "ä¸­æ–‡")
  #expect(track.codec == "aac")
  #expect(track.language == "zh")
  #expect(track.title == "几分钟的约会")
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

@Test("legacy removal transactions decode without physical asset IDs")
func legacyRemovalTransactionDecodesWithoutAssetIDs() throws {
  let itemID = MediaItemID(sourceID: .local, externalID: "legacy-track")
  let current = MediaRemovalTransaction(transactionID: UUID(), itemIDs: [itemID])
  let encoded = try JSONEncoder().encode(current)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "assetIDs")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(MediaRemovalTransaction.self, from: legacyData)
  #expect(decoded.itemIDs == [itemID])
  #expect(decoded.assetIDs == nil)
}
