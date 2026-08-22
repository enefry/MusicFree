import CoreFoundation
import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import SettingsAPI
import Testing
@testable import LocalMediaAdapter

struct LocalMediaAdapterInitialTests {
  @Test("CUE parser supports BOM, multi-file tracks, INDEX boundaries, and gap metadata")
  func cueParserSupportsRequiredCommandsAndSegments() throws {
    let text = """
    \u{FEFF}REM GENRE Classical
    TITLE "中文专辑"
    PERFORMER "Album Artist"
    FILE "Disc 1\\image one.flac" WAVE
      TRACK 01 AUDIO
        TITLE "Opening"
        SONGWRITER "Composer"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second"
        PERFORMER "Guest"
        INDEX 00 01:59:00
        INDEX 01 02:00:00
        PREGAP 00:02:00
    FILE "Disc 2.flac" WAVE
      TRACK 03 AUDIO
        TITLE "Finale"
        INDEX 01 00:00:00
        POSTGAP 00:01:00
    """
    let sheet = try CUESheetParser().parse(data: try #require(text.data(using: .utf8)))

    #expect(sheet.title == "中文专辑")
    #expect(sheet.performer == "Album Artist")
    #expect(sheet.files.map(\.path) == ["Disc 1/image one.flac", "Disc 2.flac"])
    #expect(sheet.tracks.map(\.number) == [1, 2, 3])
    #expect(sheet.tracks[1].performer == "Guest")
    #expect(sheet.tracks[1].index00?.duration == .seconds(119))
    #expect(sheet.tracks[1].pregap?.duration == .seconds(2))
    #expect(sheet.tracks[2].postgap?.duration == .seconds(1))

    let segments = try sheet.segments(assetDurations: [
      "disc 1/image one.flac": .seconds(300),
      "disc 2.flac": .seconds(240),
    ])
    #expect(segments.map(\.start) == [.zero, .seconds(120), .zero])
    #expect(segments.map(\.end) == [.seconds(119), .seconds(300), .seconds(239)])
  }

  @Test("CUE parser decodes legacy Chinese GB18030 text")
  func cueParserDecodesGB18030() throws {
    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))
    let text = """
    TITLE "中文专辑"
    FILE "音乐.flac" WAVE
      TRACK 01 AUDIO
        TITLE "第一轨"
        INDEX 01 00:00:00
    """
    let data = try #require(text.data(using: encoding))
    let sheet = try CUESheetParser().parse(data: data)
    #expect(sheet.title == "中文专辑")
    #expect(sheet.files.first?.path == "音乐.flac")
    #expect(sheet.tracks.first?.title == "第一轨")
  }

  @Test("CUE parser decodes UTF-16 little and big endian BOM text")
  func cueParserDecodesUTF16BOM() throws {
    let text = """
    TITLE "UTF-16 Album"
    FILE "music.flac" WAVE
      TRACK 01 AUDIO
        TITLE "Opening"
        INDEX 01 00:00:00
    """

    let littleEndian = try #require(text.data(using: .utf16LittleEndian))
    let bigEndian = try #require(text.data(using: .utf16BigEndian))
    let littleSheet = try CUESheetParser().parse(
      data: Data([0xFF, 0xFE]) + littleEndian
    )
    let bigSheet = try CUESheetParser().parse(
      data: Data([0xFE, 0xFF]) + bigEndian
    )

    #expect(littleSheet.title == "UTF-16 Album")
    #expect(littleSheet.tracks.first?.title == "Opening")
    #expect(bigSheet.title == littleSheet.title)
    #expect(bigSheet.files.first?.path == "music.flac")
  }

  @Test("CUE parser derives a pregap boundary when INDEX 00 is absent")
  func cueParserUsesDeclaredPregapWithoutIndex00() throws {
    let sheet = try CUESheetParser().parse(text: """
    FILE "music.flac" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        PREGAP 00:02:00
        INDEX 01 02:00:00
      TRACK 03 AUDIO
        INDEX 01 03:00:00
    """)

    let segments = try sheet.segments(assetDurations: ["MUSIC.FLAC": .seconds(240)])
    #expect(segments.map(\.start) == [.zero, .seconds(120), .seconds(180)])
    #expect(segments.map(\.end) == [.seconds(118), .seconds(180), .seconds(240)])
  }

  @Test("CUE FILE references preserve consecutive spaces through resolution")
  func cueFileReferencePreservesConsecutiveSpaces() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let cueURL = fixture.inputRoot.appendingPathComponent("album.cue")
    let audioURL = fixture.inputRoot.appendingPathComponent("My  File.flac")
    try Data("cue".utf8).write(to: cueURL)
    try Data("audio".utf8).write(to: audioURL)

    let sheet = try CUESheetParser().parse(text: """
    FILE "My  File.flac" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
    """)
    let file = try #require(sheet.files.first)

    #expect(file.path == "My  File.flac")
    #expect(try CUEReferencedFileResolver().resolve(
      file,
      cueURL: cueURL,
      candidates: [audioURL]
    ) == audioURL)
  }

  @Test("CUE parser rejects path traversal and non-monotonic indexes")
  func cueParserRejectsUnsafeOrInvalidStructures() {
    #expect(throws: CUESheetError.unsafeFileReference(line: 1)) {
      try CUESheetParser().parse(text: "FILE \"../outside.flac\" WAVE")
    }
    #expect(throws: CUESheetError.nonMonotonicIndex(track: 2)) {
      try CUESheetParser().parse(text: """
      FILE "image.flac" WAVE
        TRACK 01 AUDIO
          INDEX 01 01:00:00
        TRACK 02 AUDIO
          INDEX 01 00:30:00
      """)
    }
  }

  @Test("Folder bundles classify sidecars and select the highest-priority valid cover")
  func folderBundleClassificationAndArtworkSelection() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Bundle Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    let audioURL = albumRoot.appendingPathComponent("01 Song.flac")
    let cueURL = albumRoot.appendingPathComponent("album.cue")
    let lyricsURL = albumRoot.appendingPathComponent("01 Song.lrc")
    let coverURL = albumRoot.appendingPathComponent("cover.jpg")
    let frontURL = albumRoot.appendingPathComponent("front.png")
    let notesURL = albumRoot.appendingPathComponent("notes.nfo")
    let checksumURL = albumRoot.appendingPathComponent("album.sfv")
    try Data("audio".utf8).write(to: audioURL)
    try Data("FILE \"01 Song.flac\" WAVE".utf8).write(to: cueURL)
    try Data("[00:01]line".utf8).write(to: lyricsURL)
    try Data("damaged".utf8).write(to: coverURL)
    try validPNGData().write(to: frontURL)
    try Data("notes".utf8).write(to: notesURL)
    try Data("01 Song.flac 00000000".utf8).write(to: checksumURL)

    let files = try ImportFileEnumerator(configuration: fixture.configuration).enumerate(albumRoot)
    let bundle = try FolderImportBundleAnalyzer().analyze(inputURL: albumRoot, files: files)

    #expect(bundle.mediaCandidates.map(\.url) == [audioURL])
    #expect(bundle.cueFiles.map(\.url) == [cueURL])
    #expect(bundle.lyricsFiles.map(\.url) == [lyricsURL])
    #expect(bundle.artworkFiles.map(\.url) == [coverURL, frontURL])
    #expect(bundle.resources.first(where: { $0.file.url == notesURL })?.kind == .sidecar)
    #expect(bundle.resources.first(where: { $0.file.url == checksumURL })?.kind == .sidecar)

    let artwork = try #require(FolderArtworkResolver().selection(
      for: audioURL,
      in: bundle,
      allowRootArtwork: true
    ))
    #expect(artwork.url == frontURL)
    #expect(artwork.reason == .frontFile)
    #expect(artwork.pixelWidth > 0)
    #expect(artwork.pixelHeight > 0)
  }

  @Test("Directory imports ignore an undecodable unknown sidecar beside audio")
  func directoryImportIgnoresUndecodableUnknownSidecar() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Unknown Sidecar", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("playable-audio".utf8).write(to: albumRoot.appendingPathComponent("01.flac"))
    try Data("sidecar".utf8).write(to: albumRoot.appendingPathComponent("download.unknown"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(
      repository: repository,
      probe: UnknownSidecarProbe()
    )
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let result = try completedResult(in: events)
    let tracks = try await repository.tracks(
      matching: TrackQuery(sourceID: .local),
      page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
    )

    #expect(result.imported == 1)
    #expect(result.failed == 0)
    #expect(tracks.elements.count == 1)
    #expect(tracks.elements.first?.fileName == "01.flac")
  }

  @Test("CUE references to an undecodable unknown asset fail strictly")
  func cueReferenceToUnknownAssetFailsStrictly() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Strict CUE", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("not-audio".utf8).write(to: albumRoot.appendingPathComponent("referenced.unknown"))
    try Data("""
    TITLE "Strict CUE"
    FILE "referenced.unknown" BINARY
      TRACK 01 AUDIO
        TITLE "Referenced"
        INDEX 01 00:00:00
    """.utf8).write(to: albumRoot.appendingPathComponent("album.cue"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(
      repository: repository,
      probe: UnknownSidecarProbe()
    )
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let result = try completedResult(in: events)
    let tracks = try await repository.tracks(
      matching: TrackQuery(sourceID: .local),
      page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
    )

    #expect(result.imported == 0)
    #expect(result.failed == 1)
    #expect(tracks.elements.isEmpty)
  }

  @Test("A root musicfree.collection.json manifest creates an ordered Box Set")
  func collectionManifestCreatesOrderedBoxSet() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.inputRoot.appendingPathComponent("Box Set", isDirectory: true)
    let firstAlbum = root.appendingPathComponent("Album B", isDirectory: true)
    let secondAlbum = root.appendingPathComponent("Album A", isDirectory: true)
    try FileManager.default.createDirectory(at: firstAlbum, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondAlbum, withIntermediateDirectories: true)
    try Data("b-track".utf8).write(to: firstAlbum.appendingPathComponent("01.flac"))
    try Data("a-track".utf8).write(to: secondAlbum.appendingPathComponent("01.flac"))
    try Data("""
    {
      "kind": "boxSet",
      "title": "Ordered Box",
      "albums": [
        { "path": "Album A", "title": "Album A", "position": 0 },
        { "path": "Album B", "title": "Album B", "position": 1 }
      ]
    }
    """.utf8).write(to: root.appendingPathComponent(LocalMediaCollectionManifest.fileName))

    let files = try ImportFileEnumerator(configuration: fixture.configuration).enumerate(root)
    let bundle = try FolderImportBundleAnalyzer().analyze(inputURL: root, files: files)
    #expect(bundle.collectionManifest?.title == "Ordered Box")
    #expect(bundle.collectionManifest?.albums.map(\.folderPath) == ["Album A", "Album B"])

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [root]
    )))
    #expect(try completedResult(in: events).imported == 2)

    let mutations = await repository.appliedTransactions.flatMap(\.mutations)
    let collection = try #require(mutations.compactMap { mutation -> LibraryCollection? in
      guard case .upsert(.collection(let value)) = mutation else { return nil }
      return value
    }.first)
    #expect(collection.kind == .boxSet)
    #expect(collection.title == "Ordered Box")
    let members = mutations.compactMap { mutation -> LibraryCollectionMember? in
      guard case .upsert(.collectionMember(let value)) = mutation else { return nil }
      return value
    }.sorted { $0.position < $1.position }
    #expect(members.map(\.position) == [0, 1])
    #expect(members.allSatisfy { $0.collectionID == collection.id })
    await repository.assertDistinctAlbumReleaseCount(expected: 2)
  }

  @Test("Folder artwork does not leak from a multi-album root")
  func folderArtworkDoesNotLeakAcrossAlbums() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.inputRoot.appendingPathComponent("Collection", isDirectory: true)
    let album = root.appendingPathComponent("Album A", isDirectory: true)
    try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    let audioURL = album.appendingPathComponent("song.flac")
    let rootCover = root.appendingPathComponent("cover.png")
    try Data("audio".utf8).write(to: audioURL)
    try validPNGData().write(to: rootCover)

    let files = try ImportFileEnumerator(configuration: fixture.configuration).enumerate(root)
    let bundle = try FolderImportBundleAnalyzer().analyze(inputURL: root, files: files)
    #expect(FolderArtworkResolver().selection(
      for: audioURL,
      in: bundle,
      allowRootArtwork: false
    ) == nil)
  }

  @Test("Root artwork stays isolated when root and nested releases coexist")
  func rootArtworkStaysIsolatedWhenRootAndNestedReleasesCoexist() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.inputRoot.appendingPathComponent("Mixed Releases", isDirectory: true)
    let nestedRelease = root.appendingPathComponent("Album A", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedRelease, withIntermediateDirectories: true)
    try Data("root-audio".utf8).write(to: root.appendingPathComponent("root.flac"))
    try Data("nested-audio".utf8).write(to: nestedRelease.appendingPathComponent("nested.flac"))
    try validPNGData().write(to: root.appendingPathComponent("cover.png"))

    let repository = InMemoryLibraryRepository()
    let importer = try LocalMediaImporter(
      configuration: fixture.configuration,
      probe: FixedProbe(),
      metadataReader: NoArtworkMetadataReader(),
      libraryRepository: repository
    )
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [root]
    )))

    #expect(try completedResult(in: events).imported == 2)
    let tracks = await repository.appliedTransactions
      .flatMap(\.mutations)
      .compactMap { mutation -> Track? in
        guard case .upsert(.track(let value)) = mutation else { return nil }
        return value
      }
    #expect(tracks.count == 2)
    #expect(tracks.allSatisfy { $0.artwork == nil })
  }

  @Test("Release grouping keys avoid separator collisions")
  func releaseGroupingKeysAvoidSeparatorCollisions() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.inputRoot.appendingPathComponent("Same Name Releases", isDirectory: true)
    let firstFolder = root.appendingPathComponent("Original|Edition", isDirectory: true)
    let secondFolder = root.appendingPathComponent("Original", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)

    let firstURL = firstFolder.appendingPathComponent("01.flac")
    let secondURL = secondFolder.appendingPathComponent("01.flac")
    let firstFile = ImportFile(url: firstURL, folderPath: "Original|Edition")
    let secondFile = ImportFile(url: secondURL, folderPath: "Original")
    let bundle = FolderImportBundle(
      rootURL: root,
      resources: [
        FolderImportResource(file: firstFile, kind: .mediaCandidate),
        FolderImportResource(file: secondFile, kind: .mediaCandidate)
      ]
    )
    let firstMetadata = RawMediaMetadata(
      title: "Same Song",
      artist: "Same Artist",
      album: "Same Album",
      albumArtist: "Same Artist"
    )
    let secondMetadata = RawMediaMetadata(
      title: "Same Song",
      artist: "Same Artist",
      album: "Edition|Same Album",
      albumArtist: "Same Artist"
    )
    let probe = MediaProbeResult(
      audioTracks: [ProbedAudioTrack(index: 0, codec: "flac")],
      duration: .seconds(180)
    )
    let assets = [
      PreparedLocalMediaAsset(
        file: firstFile,
        stagedURL: firstURL,
        contentHash: String(repeating: "a", count: 64),
        assetID: MediaAssetID(sourceID: .local, externalID: "sha256-" + String(repeating: "a", count: 64)),
        probe: probe,
        metadata: firstMetadata,
        folderArtwork: nil
      ),
      PreparedLocalMediaAsset(
        file: secondFile,
        stagedURL: secondURL,
        contentHash: String(repeating: "b", count: 64),
        assetID: MediaAssetID(sourceID: .local, externalID: "sha256-" + String(repeating: "b", count: 64)),
        probe: probe,
        metadata: secondMetadata,
        folderArtwork: nil
      )
    ]

    let plan = try LocalMediaBundlePlanner().plan(
      bundle: bundle,
      assets: assets,
      importID: UUID()
    )
    let albumIDs = Set(plan.normalizedTracks.compactMap(\.track.albumID))
    #expect(plan.normalizedTracks.count == 2)
    #expect(albumIDs.count == 2)
    #expect(plan.normalizedTracks.compactMap(\.track.trackTotal).sorted() == [1, 1])

    let first = try #require(plan.normalizedTracks.first)
    let transaction = try #require(try plan.transaction(
      including: [first.itemID],
      idempotencyKey: "same-name-release-subset"
    ))
    let discs = transaction.mutations.compactMap { mutation -> Disc? in
      guard case .upsert(.disc(let value)) = mutation else { return nil }
      return value
    }
    #expect(discs.map(\.id) == [try #require(first.track.discProjection?.id)])
  }

  @Test("Directory bundles commit all tracks atomically and reimport idempotently")
  func directoryBundleIsAtomicAndIdempotent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Atomic Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("first-audio".utf8).write(to: albumRoot.appendingPathComponent("01.flac"))
    try Data("second-audio".utf8).write(to: albumRoot.appendingPathComponent("02.flac"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let firstEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let firstResult = try completedResult(in: firstEvents)
    #expect(firstResult.imported == 2)
    #expect(firstResult.failed == 0)
    #expect(persistedItemIDs(in: firstEvents).count == 2)
    #expect(await repository.applyAttemptCount() == 1)

    let secondEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let secondResult = try completedResult(in: secondEvents)
    #expect(secondResult.imported == 0)
    #expect(secondResult.skipped == 2)
    #expect(secondResult.failed == 0)
    #expect(await repository.applyAttemptCount() == 1)
  }

  @Test("Directory re-import attaches newly discovered artwork to an existing track")
  func directoryBundleRepairsMissingArtworkWithoutMovingAudio() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Artwork Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    let audioURL = albumRoot.appendingPathComponent("01.flac")
    try Data("artwork-repair-audio".utf8).write(to: audioURL)

    let repository = InMemoryLibraryRepository()
    let initialImporter = try LocalMediaImporter(
      configuration: fixture.configuration,
      probe: FixedProbe(),
      metadataReader: NoArtworkMetadataReader(),
      libraryRepository: repository
    )
    let initialEvents = try await collect(initialImporter.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let itemID = try #require(persistedItemID(in: initialEvents))
    #expect(try await repository.track(id: itemID)?.artwork == nil)

    let coverURL = albumRoot.appendingPathComponent("cover.png")
    try validPNGData().write(to: coverURL)
    let artworkImporter = try LocalMediaImporter(
      configuration: fixture.configuration,
      probe: FixedProbe(),
      metadataReader: NoArtworkMetadataReader(),
      libraryRepository: repository
    )
    let artworkEvents = try await collect(artworkImporter.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let artworkResult = try completedResult(in: artworkEvents)
    let repairedTrack = try #require(await repository.track(id: itemID))

    #expect(artworkResult.imported == 1)
    #expect(artworkResult.skipped == 0)
    #expect(artworkResult.failed == 0)
    #expect(repairedTrack.artworkID != nil)
    #expect(await repository.applyAttemptCount() == 2)
  }

  @Test("Separate bundle imports merge album and disc track counts")
  func separateBundleImportsPreserveTrackCounts() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstRoot = fixture.inputRoot.appendingPathComponent("Batch One", isDirectory: true)
    let secondRoot = fixture.inputRoot.appendingPathComponent("Batch Two", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    try Data("batch-one".utf8).write(to: firstRoot.appendingPathComponent("01.flac"))
    try Data("batch-two".utf8).write(to: secondRoot.appendingPathComponent("02.flac"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let firstEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [firstRoot]
    )))
    #expect(try completedResult(in: firstEvents).imported == 1)
    let secondEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [secondRoot]
    )))
    #expect(try completedResult(in: secondEvents).imported == 1)

    let transaction = try #require((await repository.appliedTransactions).last)
    let album = try #require(transaction.mutations.compactMap { mutation -> Album? in
      guard case .upsert(.album(let value)) = mutation else { return nil }
      return value
    }.first)
    let disc = try #require(transaction.mutations.compactMap { mutation -> Disc? in
      guard case .upsert(.disc(let value)) = mutation else { return nil }
      return value
    }.first)
    #expect(album.trackCount == 2)
    #expect(disc.trackCount == 2)
  }

  @Test("Directory re-import repairs a missing managed asset")
  func directoryBundleRepairsMissingManagedAsset() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Repair Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("repair-first".utf8).write(to: albumRoot.appendingPathComponent("01.flac"))
    try Data("repair-second".utf8).write(to: albumRoot.appendingPathComponent("02.flac"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let firstEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    #expect(try completedResult(in: firstEvents).imported == 2)
    let initialTransaction = try #require((await repository.appliedTransactions).first)
    #expect(initialTransaction.mutations.compactMap { mutation -> Int? in
      guard case .upsert(.album(let value)) = mutation else { return nil }
      return value.trackCount
    }.first == 2)
    #expect(initialTransaction.mutations.compactMap { mutation -> Int? in
      guard case .upsert(.disc(let value)) = mutation else { return nil }
      return value.trackCount
    }.first == 2)
    let itemID = try #require(persistedItemID(in: firstEvents))
    let track = try #require(await repository.track(id: itemID))
    let preservedStatistics = PlaybackStatistics(
      playCount: 7,
      completionCount: 3,
      skipCount: 1,
      lastPlayedAt: Date(timeIntervalSince1970: 1234),
      lastCompletionReason: .ended,
      totalListeningDuration: .seconds(42)
    )
    await repository.replaceTrack(trackReplacingUserState(
      track,
      isFavorite: true,
      statistics: preservedStatistics
    ))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }
    try FileManager.default.removeItem(at: managedURL)

    let recoveryEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let result = try completedResult(in: recoveryEvents)

    #expect(result.imported == 1)
    #expect(result.skipped == 1)
    #expect(result.failed == 0)
    #expect(persistedItemIDs(in: recoveryEvents) == [itemID])
    #expect(await repository.applyAttemptCount() == 2)
    #expect(FileManager.default.fileExists(atPath: managedURL.path))
    let recoveryTransaction = try #require((await repository.appliedTransactions).last)
    #expect(recoveryTransaction.mutations.compactMap { mutation -> Int? in
      guard case .upsert(.album(let value)) = mutation else { return nil }
      return value.trackCount
    }.first == 2)
    #expect(recoveryTransaction.mutations.compactMap { mutation -> Int? in
      guard case .upsert(.disc(let value)) = mutation else { return nil }
      return value.trackCount
    }.first == 2)
    let restored = try Data(contentsOf: managedURL)
    #expect(restored == Data((track.fileName == "01.flac" ? "repair-first" : "repair-second").utf8))
    let restoredTrack = try #require(await repository.track(id: itemID))
    #expect(restoredTrack.isFavorite)
    #expect(restoredTrack.statistics == preservedStatistics)
  }

  @Test("Single-file imports preserve album and disc counts")
  func singleFileImportsPreserveTrackCounts() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstURL = fixture.inputRoot.appendingPathComponent("single-first.flac")
    let secondURL = fixture.inputRoot.appendingPathComponent("single-second.flac")
    try Data("single-first".utf8).write(to: firstURL)
    try Data("single-second".utf8).write(to: secondURL)

    let repository = MusicTestSupport.InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let firstEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [firstURL]
    )))
    #expect(try completedResult(in: firstEvents).imported == 1)
    let secondEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [secondURL]
    )))
    #expect(try completedResult(in: secondEvents).imported == 1)

    let tracks = try await repository.tracks(
      matching: TrackQuery(sourceID: .local),
      page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
    )
    let albumID = try #require(tracks.elements.first?.albumID)
    let album = try await repository.album(id: albumID)
    #expect(album?.trackCount == 2)
    let releaseID = AlbumReleaseID(legacyAlbumID: albumID)
    let discs = try await repository.discs(for: releaseID)
    #expect(discs.first?.trackCount == 2)
  }

  @Test("Restoring a local asset preserves playlist membership and logical playback state")
  func retryRestoresPlaylistAndLogicalPlaybackState() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("stateful-recovery.mp3")
    try Data("stateful-recovery-content".utf8).write(to: input)

    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let playlists = SwiftDataPlaylistRepository(store: store)
    let importer = try fixture.makeImporter(repository: library)
    let initialEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [input]
    )))
    let itemID = try #require(persistedItemID(in: initialEvents))
    let initialTrack = try #require(await library.track(id: itemID))
    let preservedStatistics = PlaybackStatistics(
      playCount: 11,
      completionCount: 4,
      skipCount: 2,
      lastPlayedAt: Date(timeIntervalSince1970: 5678),
      lastCompletionReason: .skipped,
      totalListeningDuration: .seconds(91)
    )
    let statefulTrack = trackReplacingUserState(
      initialTrack,
      isFavorite: true,
      statistics: preservedStatistics
    )
    try await library.apply(try LibraryTransaction(
      idempotencyKey: "seed-local-recovery-user-state",
      mutations: [.upsert(.track(statefulTrack))]
    ))

    let playlist = try await playlists.create(PlaylistDraft(name: "Recovery Favorites"))
    try await playlists.apply(PlaylistEntriesMutation(
      playlistID: playlist.id,
      operation: .insert([
        PlaylistEntryInsertion(itemID: itemID, position: 0)
      ])
    ))

    let source = try fixture.makeSource()
    guard case .localFile(let managedURL) = try await source.resolve(itemID) else {
      Issue.record("Imported media must resolve to a managed local file")
      await store.close()
      return
    }
    try FileManager.default.removeItem(at: managedURL)

    let recoveryEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [input]
    )))
    let result = try completedResult(in: recoveryEvents)
    let restoredTrack = try #require(await library.track(id: itemID))
    let restoredLogicalTrack = try #require(
      await library.logicalTrack(id: restoredTrack.logicalTrackID)
    )

    #expect(result.imported == 1)
    #expect(result.skipped == 0)
    #expect(result.failed == 0)
    #expect(restoredTrack.isFavorite)
    #expect(restoredTrack.statistics == preservedStatistics)
    #expect(restoredLogicalTrack.isFavorite)
    #expect(restoredLogicalTrack.statistics == preservedStatistics)
    #expect(try await playlists.entries(in: playlist.id).map(\.trackID) == [itemID])
    #expect(FileManager.default.fileExists(atPath: managedURL.path))
    await store.close()
  }

  @Test("Partial box-set imports do not retain excluded release structure")
  func partialBundleImportPrunesExcludedReleaseStructure() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.inputRoot.appendingPathComponent("Partial Box", isDirectory: true)
    let firstAlbum = root.appendingPathComponent("Album A", isDirectory: true)
    let secondAlbum = root.appendingPathComponent("Album B", isDirectory: true)
    try FileManager.default.createDirectory(at: firstAlbum, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondAlbum, withIntermediateDirectories: true)
    let firstData = Data("partial-existing-audio".utf8)
    try firstData.write(to: firstAlbum.appendingPathComponent("01.flac"))
    try Data("partial-new-audio".utf8).write(to: secondAlbum.appendingPathComponent("01.flac"))
    try Data("""
    {
      "kind": "boxSet",
      "title": "Partial Box",
      "albums": [
        { "path": "Album A", "title": "Album A", "position": 0 },
        { "path": "Album B", "title": "Album B", "position": 1 }
      ]
    }
    """.utf8).write(to: root.appendingPathComponent(LocalMediaCollectionManifest.fileName))

    let files = try ImportFileEnumerator(configuration: fixture.configuration).enumerate(root)
    let bundle = try FolderImportBundleAnalyzer().analyze(inputURL: root, files: files)
    let manifest = try #require(bundle.collectionManifest)
    let firstAlbumID = try #require(manifest.albumID(for: "Album A"))
    let firstReleaseID = AlbumReleaseID(legacyAlbumID: firstAlbumID)
    let firstDiscID = DiscID(releaseID: firstReleaseID, number: 1)
    let firstItemID = MediaItemID(
      sourceID: .local,
      externalID: "sha256-\(MusicContentIdentity.sha256Hex(firstData))"
    )
    let firstAssetID = MediaAssetID(
      sourceID: .local,
      externalID: firstItemID.externalID
    )
    let repository = MusicTestSupport.InMemoryLibraryRepository()
    try await repository.apply(try LibraryTransaction(
      idempotencyKey: "partial-existing-graph",
      mutations: [
        .upsert(.album(Album(id: firstAlbumID, title: "Album A"))),
        .upsert(.albumRelease(AlbumRelease(
          id: firstReleaseID,
          legacyAlbumID: firstAlbumID,
          title: "Album A"
        ))),
        .upsert(.disc(Disc(
          id: firstDiscID,
          releaseID: firstReleaseID,
          number: 1,
          trackCount: 1
        ))),
        .upsert(.logicalTrack(LogicalTrack(
          id: LogicalTrackID("partial-existing-logical"),
          releaseID: firstReleaseID,
          discID: firstDiscID,
          title: "Existing"
        ))),
        .upsert(.mediaAsset(MediaAsset(
          id: firstAssetID,
          contentRevision: firstAssetID.externalID,
          fileName: "01.flac"
        ))),
        .upsert(.trackVariant(TrackVariant(
          id: firstItemID,
          logicalTrackID: LogicalTrackID("partial-existing-logical"),
          assetID: firstAssetID
        )))
      ]
    ))

    let managedItemsRoot = fixture.configuration.managedRoot
      .appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: managedItemsRoot, withIntermediateDirectories: true)
    try firstData.write(
      to: managedItemsRoot.appendingPathComponent(firstItemID.externalID + ".flac")
    )

    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [root]
    )))
    #expect(try completedResult(in: events).imported == 1)
    #expect(try completedResult(in: events).skipped == 1)

    let transaction = try #require(await repository.appliedTransactions.last)
    let releaseIDs = Set(transaction.mutations.compactMap { mutation -> AlbumReleaseID? in
      guard case .upsert(.albumRelease(let value)) = mutation else { return nil }
      return value.id
    })
    let memberReleaseIDs = Set(transaction.mutations.compactMap { mutation -> AlbumReleaseID? in
      guard case .upsert(.collectionMember(let value)) = mutation else { return nil }
      return value.releaseID
    })
    let albumIDs = Set(transaction.mutations.compactMap { mutation -> AlbumID? in
      guard case .upsert(.album(let value)) = mutation else { return nil }
      return value.id
    })
    #expect(releaseIDs.count == 1)
    #expect(!releaseIDs.contains(firstReleaseID))
    #expect(memberReleaseIDs == releaseIDs)
    #expect(!albumIDs.contains(firstAlbumID))
  }

  @Test("A failed directory transaction rolls every managed file and artwork back")
  func directoryBundleRollbackRemovesAllNewFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Rollback Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("rollback-first".utf8).write(to: albumRoot.appendingPathComponent("01.flac"))
    try Data("rollback-second".utf8).write(to: albumRoot.appendingPathComponent("02.flac"))

    let repository = InMemoryLibraryRepository(failsWrites: true)
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let result = try completedResult(in: events)
    #expect(result.imported == 0)
    #expect(result.failed == 1)
    #expect(await repository.applyAttemptCount() == 1)

    let managedItems = try FileManager.default.contentsOfDirectory(
      at: fixture.configuration.managedRoot.appendingPathComponent("items", isDirectory: true),
      includingPropertiesForKeys: nil
    )
    let managedArtwork = try FileManager.default.contentsOfDirectory(
      at: fixture.configuration.managedRoot.appendingPathComponent("artwork", isDirectory: true),
      includingPropertiesForKeys: nil
    )
    #expect(managedItems.isEmpty)
    #expect(managedArtwork.isEmpty)
  }

  @Test("Selecting a single-file CUE creates logical segments over one shared asset")
  func selectedSingleFileCUECreatesSharedSegments() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("CUE Album", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    let audioURL = albumRoot.appendingPathComponent("image.flac")
    let cueURL = albumRoot.appendingPathComponent("album.cue")
    try Data("cue-shared-audio".utf8).write(to: audioURL)
    try Data("""
    TITLE "CUE Album"
    PERFORMER "CUE Artist"
    FILE "image.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second"
        INDEX 01 00:01:00
    """.utf8).write(to: cueURL)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [cueURL]
    )))
    let result = try completedResult(in: events)
    let itemIDs = persistedItemIDs(in: events).sorted()
    #expect(result.imported == 2)
    #expect(itemIDs.count == 2)
    #expect(itemIDs.allSatisfy { $0.externalID.hasPrefix("cue-") })

    let first = try #require(await repository.track(id: itemIDs[0]))
    let second = try #require(await repository.track(id: itemIDs[1]))
    #expect(first.assetID == second.assetID)
    #expect(first.playbackSelection.range?.start == .zero)
    #expect(first.playbackSelection.range?.end == .seconds(1))
    #expect(second.playbackSelection.range?.start == .seconds(1))
    #expect(second.playbackSelection.range?.end == .seconds(3))
    #expect(first.duration == .seconds(1))
    #expect(second.duration == .seconds(2))
    #expect(try await repository.track(id: first.assetID.mediaItemID) == nil)

    let source = try fixture.makeSource()
    let firstResource = try await source.resolve(first.assetID.mediaItemID)
    let secondResource = try await source.resolve(second.assetID.mediaItemID)
    guard case let .localFile(firstURL) = firstResource,
          case let .localFile(secondURL) = secondResource
    else {
      Issue.record("CUE variants must resolve through their shared physical asset")
      return
    }
    #expect(firstURL == secondURL)
    #expect(try Data(contentsOf: firstURL) == Data("cue-shared-audio".utf8))
  }

  @Test("CUE item IDs remain stable across metadata revisions")
  func cueItemIDsRemainStableAcrossMetadataRevisions() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Stable CUE", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("stable-cue-audio".utf8).write(to: albumRoot.appendingPathComponent("image.flac"))
    let cueURL = albumRoot.appendingPathComponent("album.cue")
    try Data("""
    TITLE "Original Album"
    PERFORMER "Original Artist"
    FILE "image.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second"
        INDEX 01 00:01:00
    """.utf8).write(to: cueURL)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let firstEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let firstResult = try completedResult(in: firstEvents)
    let firstIDs = Set(persistedItemIDs(in: firstEvents))
    #expect(firstResult.imported == 2)
    #expect(firstIDs.count == 2)

    try Data("""

    TITLE   "Revised Album"
    PERFORMER "Revised Artist"
    FILE "image.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First Revised"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second Revised"
        INDEX 01 00:01:00
    """.utf8).write(to: cueURL)

    let secondEvents = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let secondResult = try completedResult(in: secondEvents)
    let tracks = try await repository.tracks(
      matching: TrackQuery(sourceID: .local),
      page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
    )

    #expect(secondResult.imported == 0)
    #expect(secondResult.skipped == 2)
    #expect(secondResult.failed == 0)
    #expect(Set(tracks.elements.map(\.id)) == firstIDs)
    #expect(tracks.elements.count == 2)
  }

  @Test("CUE removal keeps a shared asset until its last logical track is removed")
  func cueRemovalUsesSharedAssetReferenceCount() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("CUE Removal", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    let audioURL = albumRoot.appendingPathComponent("image.flac")
    let cueURL = albumRoot.appendingPathComponent("album.cue")
    try Data("cue-removal-audio".utf8).write(to: audioURL)
    try Data("""
    TITLE "CUE Removal"
    FILE "image.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second"
        INDEX 01 00:01:00
    """.utf8).write(to: cueURL)

    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let importer = try fixture.makeImporter(repository: library)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    #expect(try completedResult(in: events).imported == 2)
    let itemIDs = persistedItemIDs(in: events).sorted()
    let first = try #require(await library.track(id: itemIDs[0]))
    let second = try #require(await library.track(id: itemIDs[1]))
    #expect(first.assetID == second.assetID)

    let remover = try ManagedMediaRemover(
      configuration: fixture.configuration,
      libraryRepository: library
    )
    let firstRemoval = try await remover.prepareRemoval(of: [first.id])
    #expect(firstRemoval.assetIDs?.isEmpty == true)
    try await library.remove([first.id])
    try await remover.commitRemoval(firstRemoval)
    #expect(try managedMediaItemCount(in: fixture) == 1)

    let secondRemoval = try await remover.prepareRemoval(of: [second.id])
    #expect(secondRemoval.assetIDs == Set([second.assetID]))
    try await library.remove([second.id])
    try await remover.commitRemoval(secondRemoval)
    #expect(try managedMediaItemCount(in: fixture) == 0)
    await store.close()
  }

  @Test("Multi-file CUE maps each segment to its referenced asset without whole-file tracks")
  func multiFileCUEUsesReferencedAssetsOnly() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Multi CUE", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    try Data("disc-one-audio".utf8).write(to: albumRoot.appendingPathComponent("disc1.flac"))
    try Data("disc-two-audio".utf8).write(to: albumRoot.appendingPathComponent("disc2.flac"))
    try Data("""
    TITLE "Multi CUE"
    FILE "disc1.flac" WAVE
      TRACK 01 AUDIO
        TITLE "One"
        INDEX 01 00:00:00
    FILE "disc2.flac" WAVE
      TRACK 02 AUDIO
        TITLE "Two"
        INDEX 01 00:00:00
    """.utf8).write(to: albumRoot.appendingPathComponent("album.cue"))

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [albumRoot]
    )))
    let itemIDs = persistedItemIDs(in: events).sorted()
    #expect(try completedResult(in: events).imported == 2)
    #expect(itemIDs.count == 2)
    var tracks: [Track] = []
    for itemID in itemIDs {
      if let track = try await repository.track(id: itemID) {
        tracks.append(track)
      }
    }
    #expect(Set(tracks.map(\.assetID)).count == 2)
    #expect(tracks.allSatisfy { $0.playbackSelection.range != nil })
    #expect(tracks.allSatisfy { $0.id.externalID.hasPrefix("cue-") })
  }

  @Test("Metadata normalization prefers the probed media duration")
  func metadataNormalizationPrefersProbedDuration() throws {
    let normalized = try MetadataNormalizer().normalize(
      fileURL: URL(fileURLWithPath: "/fixture/duration.m4a"),
      contentHash: String(repeating: "d", count: 64),
      probe: MediaProbeResult(
        audioTracks: [ProbedAudioTrack(index: 0, codec: "aac")],
        duration: .seconds(222)
      ),
      metadata: RawMediaMetadata(
        title: "Duration",
        duration: .seconds(12)
      )
    )

    #expect(normalized.track.duration == .seconds(222))
    #expect(normalized.track.technicalInfo?.duration == .seconds(222))
  }

  @Test("Metadata normalization preserves positive track and disc numbers")
  func metadataNormalizationPreservesNumbering() throws {
    let normalizer = MetadataNormalizer()
    let probe = MediaProbeResult(
      audioTracks: [ProbedAudioTrack(index: 0, codec: "flac")],
      container: "flac"
    )
    let numbered = try normalizer.normalize(
      fileURL: URL(fileURLWithPath: "/fixture/numbered.flac"),
      contentHash: String(repeating: "a", count: 64),
      probe: probe,
      metadata: RawMediaMetadata(
        title: "Numbered",
        album: "Album",
        trackNumber: 7,
        discNumber: 2
      )
    )
    #expect(numbered.track.trackNumber == 7)
    #expect(numbered.track.discNumber == 2)

    let invalid = try normalizer.normalize(
      fileURL: URL(fileURLWithPath: "/fixture/invalid-number.flac"),
      contentHash: String(repeating: "b", count: 64),
      probe: probe,
      metadata: RawMediaMetadata(
        title: "Invalid Number",
        trackNumber: 0,
        discNumber: -1
      )
    )
    #expect(invalid.track.trackNumber == nil)
    #expect(invalid.track.discNumber == nil)
  }

  @Test("Metadata normalization carries reported audio bit rate into technical details")
  func metadataNormalizationCarriesBitRate() throws {
    let normalizer = MetadataNormalizer()
    let normalized = try normalizer.normalize(
      fileURL: URL(fileURLWithPath: "/fixture/bitrate.flac"),
      contentHash: String(repeating: "c", count: 64),
      probe: MediaProbeResult(
        audioTracks: [
          ProbedAudioTrack(
            index: 0,
            codec: "flac",
            sampleRate: 44_100,
            channelCount: 2,
            bitRate: 768_000
          )
        ],
        container: "flac"
      ),
      metadata: RawMediaMetadata(title: "Bitrate")
    )

    #expect(normalized.track.technicalInfo?.primaryAudioStream?.bitRate == 768_000)
    #expect(normalized.track.technicalInfo?.bitRate == 768_000)
  }

  @Test("Multi-stream imports persist decodable streams and select the default stream")
  func multiStreamImportPersistsAndSelectsDefaultStream() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("multi-stream.mka")
    try Data("multi-stream-audio".utf8).write(to: input)
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(
      repository: repository,
      probe: MultipleAudioStreamProbe()
    )

    let events = try await collect(importer.importMedia(MediaImportRequest(
      importID: UUID(),
      urls: [input]
    )))
    let itemID = try #require(persistedItemID(in: events))
    let track = try #require(try await repository.track(id: itemID))
    let streams = try #require(track.technicalInfo?.audioStreams)
    let selection = try #require(track.playbackSelection.audioStream)

    #expect(streams.count == 2)
    #expect(streams.map(\.streamID) == [AudioStreamID("stream-commentary"), AudioStreamID("stream-main")])
    #expect(streams.map(\.indexHint) == [0, 2])
    #expect(streams[1].isDefault)
    #expect(streams[1].language == "eng")
    #expect(streams[1].title == "Main Mix")
    #expect(selection.streamID == AudioStreamID("stream-main"))
    #expect(selection.fallbackSignature == AudioStreamSignature(
      language: "eng",
      title: "Main Mix",
      codec: "aac",
      channelCount: 2,
      indexHint: 2
    ))
  }

  @Test("Multi-stream probes without a default do not force the first stream")
  func multiStreamWithoutDefaultLeavesSelectionToDecoder() throws {
    let probe = MediaProbeResult(
      audioTracks: [
        ProbedAudioTrack(index: 0, stableID: "stream-one", codec: "aac"),
        ProbedAudioTrack(index: 1, stableID: "stream-two", codec: "aac")
      ],
      container: "matroska",
      duration: .seconds(30)
    )

    #expect(ProbedAudioStreamSelector.preferred(in: probe) == nil)

    let normalized = try MetadataNormalizer().normalize(
      fileURL: URL(fileURLWithPath: "/fixture/no-default.mka"),
      contentHash: String(repeating: "f", count: 64),
      probe: probe,
      metadata: RawMediaMetadata(title: "No Default")
    )
    #expect(normalized.track.playbackSelection.audioStream == nil)
  }

  @Test("Malformed probed stream values are normalized without domain precondition failures")
  func malformedAudioStreamValuesAreNormalizedSafely() throws {
    let normalized = try MetadataNormalizer().normalize(
      fileURL: URL(fileURLWithPath: "/fixture/malformed-streams.mka"),
      contentHash: String(repeating: "e", count: 64),
      probe: MediaProbeResult(
        audioTracks: [
          ProbedAudioTrack(
            index: 0,
            stableID: "   ",
            sampleRate: 0.25,
            channelCount: 0,
            bitDepth: 0,
            bitRate: 0
          ),
          ProbedAudioTrack(
            index: 1,
            stableID: "duplicate-stream",
            sampleRate: 44_100,
            channelCount: 2
          ),
          ProbedAudioTrack(
            index: 2,
            stableID: " duplicate-stream ",
            sampleRate: 0.6,
            channelCount: 2,
            isDefault: true
          )
        ],
        duration: .seconds(30)
      ),
      metadata: RawMediaMetadata(title: "Malformed Streams")
    )

    let streams = try #require(normalized.track.technicalInfo?.audioStreams)
    #expect(streams.count == 3)
    #expect(streams[0].streamID == nil)
    #expect(streams[0].sampleRate == nil)
    #expect(streams[0].channels == nil)
    #expect(streams[1].streamID == AudioStreamID("duplicate-stream"))
    #expect(streams[2].streamID == nil)
    #expect(streams[2].sampleRate == 1)
    #expect(normalized.track.playbackSelection.audioStream?.streamID == nil)
    #expect(normalized.track.playbackSelection.audioStream?.fallbackSignature.indexHint == 2)
  }

  @Test
  func sourceDeclaresCapabilitiesAndResolvesManagedResource() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("song.mp3")
    try Data("audio-data".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [input])
      )
    )
    let itemID = try #require(persistedItemID(in: events))
    let result = try completedResult(in: events)

    #expect(result.imported == 1)
    #expect(result.failed == 0)
    #expect(itemID.sourceID == .local)
    #expect(!itemID.externalID.contains("items"))

    let source = try fixture.makeSource()
    #expect(source.descriptor.sourceID == .local)
    #expect(source.descriptor.kind == .local)
    #expect(source.capabilities.contains(.managedRemoval))
    #expect(source.capabilities.contains(.artwork))
    #expect(source.capabilities.contains(.metadataReading))
    #expect(!source.capabilities.contains(.incrementalSync))

    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Local source must resolve to a local file resource")
      return
    }
    #expect(managedURL.path.hasPrefix(fixture.configuration.managedRoot.path + "/"))
    #expect(managedURL.standardizedFileURL != input.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: managedURL.path))

    let probe = try await source.probe(itemID)
    #expect(probe.isPlayable)
    let metadata = try await source.metadata(for: itemID)
    #expect(metadata.title == "Fixture song")

    let track = try #require(await repository.track(id: itemID))
    let artworkID = try #require(track.artworkID)
    let artwork = try await source.artwork(for: artworkID)
    guard case .localFile(let artworkURL)? = artwork else {
      Issue.record("Imported artwork must resolve to managed local storage")
      return
    }
    #expect(artworkURL.path.hasPrefix(fixture.configuration.managedRoot.path + "/"))
    #expect(FileManager.default.fileExists(atPath: artworkURL.path))
  }

  @Test("Artwork writes reject an existing file with the wrong content hash")
  func artworkWritesRejectMismatchedContent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try ManagedMediaStore(configuration: fixture.configuration)
    let data = Data("expected-artwork".utf8)
    let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(data))")
    let location = try await store.writeArtwork(data, artworkID: artworkID)
    try Data("wrong-artwork".utf8).write(to: location.url)

    do {
      _ = try await store.writeArtwork(data, artworkID: artworkID)
      Issue.record("A mismatched artwork file must not be reused")
    } catch let error as LocalMediaError {
      #expect(error == .destinationConflict)
    } catch {
      Issue.record("Unexpected artwork write error: \(error)")
    }

    do {
      _ = try await store.artworkURL(for: artworkID)
      Issue.record("A mismatched artwork file must not be resolved")
    } catch let error as LocalMediaError {
      #expect(error == .destinationConflict)
    } catch {
      Issue.record("Unexpected artwork lookup error: \(error)")
    }
  }

  @Test("Legacy artwork extensions remain readable and collectible")
  func legacyArtworkExtensionIsSupported() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let data = Data("legacy-artwork".utf8)
    let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(data))")
    let artworkRoot = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
    try FileManager.default.createDirectory(
      at: artworkRoot,
      withIntermediateDirectories: true
    )
    let legacyURL = artworkRoot.appendingPathComponent(artworkID.rawValue + ".jpg")
    try data.write(to: legacyURL)

    let store = try ManagedMediaStore(configuration: fixture.configuration)
    #expect(try await store.artworkURL(for: artworkID) == legacyURL)

    let maintenance = try LocalMediaStorageMaintenance(
      configuration: fixture.configuration,
      libraryRepository: InMemoryLibraryRepository()
    )
    _ = try await maintenance.pruneOrphanedArtwork()
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  }

  @Test("Artwork writes reject a new file when its content hash does not match the identifier")
  func artworkWritesRejectNewMismatchedIdentifier() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try ManagedMediaStore(configuration: fixture.configuration)
    let data = Data("actual-artwork".utf8)
    let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(Data("different-artwork".utf8)))")
    let destination = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
      .appendingPathComponent(artworkID.rawValue + ".bin")

    do {
      _ = try await store.writeArtwork(data, artworkID: artworkID)
      Issue.record("Artwork content must match its content-addressed identifier")
    } catch let error as LocalMediaError {
      #expect(error == .invalidItemID)
    } catch {
      Issue.record("Unexpected artwork identifier error: \(error)")
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("Artwork writes reject data larger than the shared artwork limit")
  func artworkWritesRejectOversizedData() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try ManagedMediaStore(configuration: fixture.configuration)
    let artworkID = ArtworkID("sha256-\(String(repeating: "a", count: 64))")
    let data = Data(repeating: 0x7f, count: ArtworkDataLimits.maximumByteCount + 1)

    do {
      _ = try await store.writeArtwork(data, artworkID: artworkID)
      Issue.record("Artwork data over the shared limit must be rejected")
    } catch let error as LocalMediaError {
      #expect(error == .fileTooLarge)
    } catch {
      Issue.record("Unexpected oversized artwork error: \(error)")
    }
  }

  @Test("Existing oversized artwork is rejected before it is read")
  func artworkLookupRejectsOversizedExistingFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try ManagedMediaStore(configuration: fixture.configuration)
    let artworkID = ArtworkID("sha256-\(String(repeating: "a", count: 64))")
    let artworkURL = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
      .appendingPathComponent(artworkID.rawValue + ".bin")
    try makeSparseFile(
      at: artworkURL,
      byteCount: UInt64(ArtworkDataLimits.maximumByteCount) + 1
    )

    do {
      _ = try await store.artworkURL(for: artworkID)
      Issue.record("An existing artwork file over the shared limit must be rejected")
    } catch let error as LocalMediaError {
      #expect(error == .destinationConflict)
    } catch {
      Issue.record("Unexpected oversized artwork lookup error: \(error)")
    }
  }

  @Test("Artwork write receipts retain shared files until all owners finish")
  func artworkWriteReceiptsCoordinateSharedFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = try fixture.makeSource()
    let data = Data("shared-artwork-bytes".utf8)
    let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(data))")

    let first = try await source.beginArtworkWrite(data, artworkID: artworkID)
    let second = try await source.beginArtworkWrite(data, artworkID: artworkID)

    #expect(first.wasCreated)
    #expect(!second.wasCreated)
    guard case .localFile(let artworkURL)? = try await source.artwork(for: artworkID) else {
      Issue.record("Shared artwork must resolve while write receipts are active")
      return
    }

    await first.finish(committed: false)
    #expect(FileManager.default.fileExists(atPath: artworkURL.path))

    await second.finish(committed: true)
    #expect(FileManager.default.fileExists(atPath: artworkURL.path))
  }

  @Test("Source artwork claims coordinate with failed importer cleanup")
  func sourceArtworkClaimSurvivesImporterFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("shared-artwork.mp3")
    try Data("audio-data".utf8).write(to: input)

    let source = try fixture.makeSource()
    let artworkData = Data("artwork".utf8)
    let artworkID = ArtworkID("sha256-\(MusicContentIdentity.sha256Hex(artworkData))")
    let receipt = try await source.beginArtworkWrite(artworkData, artworkID: artworkID)
    let repository = InMemoryLibraryRepository(failsWrites: true)
    let importer = try fixture.makeImporter(repository: repository)

    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [input])
      )
    )
    let result = try completedResult(in: events)
    #expect(result.failed == 1)
    #expect(result.imported == 0)
    #expect(result.duplicate == 0)
    #expect(result.skipped == 0)

    guard case .localFile(let artworkURL)? = try await source.artwork(for: artworkID) else {
      Issue.record("A metadata artwork claim must survive a failed importer transaction")
      await receipt.finish(committed: false)
      return
    }
    #expect(FileManager.default.fileExists(atPath: artworkURL.path))
    await receipt.finish(committed: true)
  }

  @Test("Import stores same-name sidecar lyrics and safe file details")
  func importStoresSidecarLyricsAndFileDetails() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let albumRoot = fixture.inputRoot.appendingPathComponent("Albums/Live", isDirectory: true)
    try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
    let input = albumRoot.appendingPathComponent("sidecar.mp3")
    let audio = Data("sidecar-audio".utf8)
    try audio.write(to: input)
    try """
    [offset:-250]
    [00:01.00]Sidecar line
    """.data(using: .utf8)!.write(
      to: albumRoot.appendingPathComponent("sidecar.lrc")
    )

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [fixture.inputRoot]))
    )
    let result = try completedResult(in: events)
    let itemID = try #require(persistedItemID(in: events))
    let track = try #require(await repository.track(id: itemID))

    #expect(result.imported == 1)
    #expect(track.fileName == "sidecar.mp3")
    #expect(track.folderPath == "Albums/Live")
    #expect(track.relativePath == "Albums/Live/sidecar.mp3")
    #expect(track.technicalInfo?.fileSizeBytes == Int64(audio.count))
    #expect(track.lyrics?.declaredOffsetMilliseconds == -250)
    #expect(track.lyrics?.timedLines.map(\.text) == ["Sidecar line"])
  }

  @Test("Sidecar lyrics keep a case-insensitive directory fallback")
  func sidecarLyricsUseCaseInsensitiveDirectoryFallback() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let mediaURL = fixture.inputRoot.appendingPathComponent("CaseFallback.mp3")
    let sidecarURL = fixture.inputRoot.appendingPathComponent("CaseFallback.LRC")
    try Data("audio".utf8).write(to: mediaURL)
    try "[00:01.00]Case fallback".data(using: .utf8)!.write(to: sidecarURL)

    #expect(
      try LocalLyricsReader.readSidecar(for: mediaURL) == "[00:01.00]Case fallback"
    )
  }

  @Test("Import ignores a sidecar lyrics symlink")
  func importIgnoresSidecarLyricsSymlink() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("symlink-sidecar.mp3")
    try Data("symlink-sidecar-audio".utf8).write(to: input)
    let outsideLyrics = fixture.root.appendingPathComponent("outside.lrc")
    try "[00:01.00]Outside lyrics".data(using: .utf8)!.write(to: outsideLyrics)
    try FileManager.default.createSymbolicLink(
      at: fixture.inputRoot.appendingPathComponent("symlink-sidecar.lrc"),
      withDestinationURL: outsideLyrics
    )

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: events))
    let track = try #require(await repository.track(id: itemID))

    #expect(track.lyrics == nil)
  }

  @Test("Import ignores an oversized sidecar lyrics file")
  func importIgnoresOversizedSidecarLyrics() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("oversized-sidecar.mp3")
    try Data("oversized-sidecar-audio".utf8).write(to: input)
    let prefix = Data("[00:01.00]Should not be imported\n".utf8)
    var sidecarData = prefix
    sidecarData.append(Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1 - prefix.count))
    try sidecarData.write(
      to: fixture.inputRoot.appendingPathComponent("oversized-sidecar.lrc")
    )

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: events))
    let track = try #require(await repository.track(id: itemID))

    #expect(track.lyrics == nil)
  }

  @Test("Sidecar lyrics keep the configured byte limit during a raced read")
  func sidecarLyricsKeepByteLimitDuringRead() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let mediaURL = fixture.inputRoot.appendingPathComponent("raced-sidecar.mp3")
    let sidecarURL = fixture.inputRoot.appendingPathComponent("raced-sidecar.lrc")
    try Data("audio".utf8).write(to: mediaURL)
    try Data(repeating: 0x20, count: LocalLyricsReader.maximumByteCount + 1).write(to: sidecarURL)

    #expect(try LocalLyricsReader.readSidecar(for: mediaURL) == nil)
  }

  @Test("Import records the staged file size when the source changes after staging")
  func importUsesStagedFileSize() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("staged-size.mp3")
    try Data("small".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(
      repository: repository,
      probe: SourceMutatingProbe(sourceURL: input)
    )
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: events))
    let track = try #require(await repository.track(id: itemID))

    #expect(track.technicalInfo?.fileSizeBytes == 5)
  }

  @Test
  func importedMediaIsIndependentFromItsSourceFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("independent.mp3")
    let importedData = Data("original-audio-data".utf8)
    try importedData.write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: events))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }

    let sourceInode = try #require(
      FileManager.default.attributesOfItem(atPath: input.path)[.systemFileNumber] as? NSNumber
    )
    let managedInode = try #require(
      FileManager.default.attributesOfItem(atPath: managedURL.path)[.systemFileNumber] as? NSNumber
    )
    #expect(sourceInode != managedInode)

    try Data("changed-source-data".utf8).write(to: input)
    let managedData = try Data(contentsOf: managedURL)
    #expect(managedData == importedData)
  }

  @Test
  func directoryEnumerationSkipsHiddenPackagesAndSymlinkLoops() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let visible = fixture.inputRoot.appendingPathComponent("visible.mp3")
    let nestedRoot = fixture.inputRoot.appendingPathComponent("nested", isDirectory: true)
    let nested = nestedRoot.appendingPathComponent("nested.m4a")
    let hidden = fixture.inputRoot.appendingPathComponent(".hidden.mp3")
    let packageRoot = fixture.inputRoot.appendingPathComponent("Album.bundle", isDirectory: true)
    let packageFile = packageRoot.appendingPathComponent("inside.mp3")
    try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: visible)
    try Data("two".utf8).write(to: nested)
    try Data("hidden".utf8).write(to: hidden)
    try Data("package".utf8).write(to: packageFile)
    try? FileManager.default.createSymbolicLink(
      at: fixture.inputRoot.appendingPathComponent("loop"),
      withDestinationURL: fixture.inputRoot
    )

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [fixture.inputRoot])
      )
    )
    let result = try completedResult(in: events)

    #expect(result.imported == 2)
    #expect(result.failed == 0)
    #expect(events.filter { event in
      if case .discovered(_, let url) = event {
        return url.lastPathComponent == ".hidden.mp3" || url.path.contains("Album.bundle")
      }
      return false
    }.isEmpty)
  }

  @Test
  func duplicatePoliciesSeparateSkipAndReport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("same.mp3")
    try Data("same-content".utf8).write(to: input)
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)

    _ = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let skippedEvents = try await collect(
      importer.importMedia(
        MediaImportRequest(
          importID: UUID(),
          urls: [input],
          duplicatePolicy: .skip
        )
      )
    )
    let skipped = try completedResult(in: skippedEvents)
    #expect(skipped.imported == 0)
    #expect(skipped.skipped == 1)
    #expect(skipped.duplicate == 0)
    #expect(await repository.applyAttemptCount() == 1)

    let reportedEvents = try await collect(
      importer.importMedia(
        MediaImportRequest(
          importID: UUID(),
          urls: [input],
          duplicatePolicy: .report
        )
      )
    )
    let reported = try completedResult(in: reportedEvents)
    #expect(reported.duplicate == 1)
    #expect(reported.failed == 0)
    #expect(await repository.applyAttemptCount() == 1)
    #expect(reportedEvents.contains { event in
      if case .itemFailed(_, _, let error) = event { return error == .duplicate }
      return false
    })
  }

  @Test("Duplicate imports reject a corrupted managed file before skip")
  func duplicateImportRejectsCorruptedManagedFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("corrupted-duplicate.mp3")
    try Data("original-content".utf8).write(to: input)
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)

    let initialEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }
    try Data("corrupted-content".utf8).write(to: managedURL)

    let events = try await collect(
      importer.importMedia(MediaImportRequest(
        importID: UUID(),
        urls: [input],
        duplicatePolicy: .skip
      ))
    )
    let result = try completedResult(in: events)

    #expect(result.imported == 0)
    #expect(result.skipped == 0)
    #expect(result.failed == 1)
    #expect(await repository.applyAttemptCount() == 1)
    #expect(events.contains { event in
      if case .itemFailed(_, _, let error) = event { return error == .copyFailed }
      return false
    })
  }

  @Test("A managed file without its library record is recovered on retry")
  func retryRecoversManagedFileMissingLibraryRecord() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("recoverable.mp3")
    let content = Data("recoverable-content".utf8)
    try content.write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let initialEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }

    try await repository.remove([itemID])
    #expect(try await repository.track(id: itemID) == nil)

    let recoveryEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let result = try completedResult(in: recoveryEvents)

    #expect(result.imported == 1)
    #expect(result.skipped == 0)
    #expect(result.failed == 0)
    #expect(try await repository.track(id: itemID) != nil)
    #expect(await repository.applyAttemptCount() == 2)
    #expect(try Data(contentsOf: managedURL) == content)
  }

  @Test("A missing managed file is restored while its library record remains")
  func retryRestoresManagedFileMissingFromExistingLibraryRecord() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("missing-managed-file.mp3")
    let content = Data("missing-managed-content".utf8)
    try content.write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let initialEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }
    try FileManager.default.removeItem(at: managedURL)

    let recoveryEvents = try await collect(
      importer.importMedia(MediaImportRequest(
        importID: UUID(),
        urls: [input],
        duplicatePolicy: .skip
      ))
    )
    let result = try completedResult(in: recoveryEvents)

    #expect(result.imported == 1)
    #expect(result.skipped == 0)
    #expect(result.failed == 0)
    #expect(await repository.applyAttemptCount() == 2)
    #expect(FileManager.default.fileExists(atPath: managedURL.path))
    #expect(try Data(contentsOf: managedURL) == content)
  }

  @Test("A failed recovery transaction is reported and remains retryable")
  func recoveryTransactionFailureDoesNotReportSuccess() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("recovery-fails.mp3")
    let content = Data("recovery-failure-content".utf8)
    try content.write(to: input)

    let initialRepository = InMemoryLibraryRepository()
    let initialImporter = try fixture.makeImporter(repository: initialRepository)
    let initialEvents = try await collect(
      initialImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }

    let failingRepository = InMemoryLibraryRepository(failsWrites: true)
    let recoveryImporter = try fixture.makeImporter(repository: failingRepository)
    let recoveryEvents = try await collect(
      recoveryImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let result = try completedResult(in: recoveryEvents)

    #expect(result.imported == 0)
    #expect(result.skipped == 0)
    #expect(result.failed == 1)
    #expect(try await failingRepository.track(id: itemID) == nil)
    #expect(await failingRepository.applyAttemptCount() == 1)
    #expect(FileManager.default.fileExists(atPath: managedURL.path))
    #expect(try Data(contentsOf: managedURL) == content)
    #expect(recoveryEvents.contains { event in
      if case .itemFailed(_, _, let error) = event { return error == .persistenceFailed }
      return false
    })
  }

  @Test("A failed import removes artwork written before the library commit")
  func failedImportRemovesNewArtwork() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("artwork-fails.mp3")
    try Data("artwork-failure-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository(failsWrites: true)
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let result = try completedResult(in: events)

    #expect(result.imported == 0)
    #expect(result.failed == 1)
    #expect(await repository.applyAttemptCount() == 1)
    let artworkRoot = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
    let artworkFiles = try FileManager.default.contentsOfDirectory(
      at: artworkRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    #expect(artworkFiles.isEmpty)
  }

  @Test("Recovery never overwrites a conflicting managed target")
  func recoveryRejectsManagedContentConflict() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("conflicting.mp3")
    try Data("expected-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let initialEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    let source = try fixture.makeSource()
    let resource = try await source.resolve(itemID)
    guard case .localFile(let managedURL) = resource else {
      Issue.record("Imported media must resolve to a managed local file")
      return
    }
    let conflictingContent = Data("conflicting-managed-content".utf8)
    try conflictingContent.write(to: managedURL)
    try await repository.remove([itemID])

    let recoveryEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let result = try completedResult(in: recoveryEvents)

    #expect(result.imported == 0)
    #expect(result.skipped == 0)
    #expect(result.failed == 1)
    #expect(try await repository.track(id: itemID) == nil)
    #expect(await repository.applyAttemptCount() == 1)
    #expect(try Data(contentsOf: managedURL) == conflictingContent)
    #expect(recoveryEvents.contains { event in
      if case .itemFailed(_, _, let error) = event { return error == .copyFailed }
      return false
    })
  }

  @Test("Concurrent recovery across importer instances applies once and skips the waiter")
  func concurrentRecoveryAcrossImportersSerializesByContentID() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("concurrent-recovery.mp3")
    try Data("concurrent-recovery".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let hasher = CountingHasher()
    let initialImporter = try fixture.makeImporter(
      repository: repository,
      hasher: hasher
    )
    let initialEvents = try await collect(
      initialImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    try await repository.remove([itemID])

    let probe = FirstCallBlockingProbe()
    let ownerImporter = try fixture.makeImporter(
      repository: repository,
      probe: probe,
      hasher: hasher
    )
    let firstTask = Task {
      try await collect(
        ownerImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()

    let waiterImporter = try fixture.makeImporter(
      repository: repository,
      probe: probe,
      hasher: hasher
    )
    let secondTask = Task {
      try await collect(
        waiterImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
      )
    }
    await hasher.waitForCallCount(4)
    await probe.releaseFirstCall()

    let firstResult = try completedResult(in: try await firstTask.value)
    let secondResult = try completedResult(in: try await secondTask.value)
    #expect(firstResult.imported == 1)
    #expect(secondResult.imported == 0)
    #expect(secondResult.skipped == 1)
    #expect(await repository.applyAttemptCount() == 2)
  }

  @Test("Creating another importer does not delete an active staging batch")
  func importerInitializationPreservesActiveStaging() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("active-staging.mp3")
    try Data("active-staging-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let probe = FirstCallBlockingProbe()
    let ownerImporter = try fixture.makeImporter(repository: repository, probe: probe)
    let ownerTask = Task {
      try await collect(
        ownerImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()

    _ = try fixture.makeImporter(repository: repository)
    await probe.releaseFirstCall()

    let ownerResult = try completedResult(in: try await ownerTask.value)
    #expect(ownerResult.imported == 1)
    #expect(ownerResult.failed == 0)
  }

  @Test("A failed import cannot remove artwork committed by another content ID")
  func failedImportPreservesSharedCommittedArtwork() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstInput = fixture.inputRoot.appendingPathComponent("artwork-owner.mp3")
    let secondInput = fixture.inputRoot.appendingPathComponent("artwork-consumer.mp3")
    try Data("artwork-owner-content".utf8).write(to: firstInput)
    try Data("artwork-consumer-content".utf8).write(to: secondInput)

    let repository = InMemoryLibraryRepository(failFirstWriteAfterRelease: true)
    let importer = try fixture.makeImporter(repository: repository)
    let firstTask = Task {
      try await collect(
        importer.importMedia(MediaImportRequest(importID: UUID(), urls: [firstInput]))
      )
    }
    await repository.waitUntilFirstWriteBlocks()

    let secondEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [secondInput]))
    )
    let secondResult = try completedResult(in: secondEvents)
    let secondItemID = try #require(persistedItemID(in: secondEvents))
    await repository.releaseFirstWrite()
    let firstResult = try completedResult(in: try await firstTask.value)

    #expect(firstResult.imported == 0)
    #expect(firstResult.failed == 1)
    #expect(secondResult.imported == 1)
    let secondTrack = try #require(await repository.track(id: secondItemID))
    let artworkID = try #require(secondTrack.artworkID)
    let source = try fixture.makeSource()
    guard case .localFile(let artworkURL)? = try await source.artwork(for: artworkID) else {
      Issue.record("Committed shared artwork must remain in managed storage")
      return
    }
    #expect(FileManager.default.fileExists(atPath: artworkURL.path))
  }

  @Test("Cancelling a content-gate waiter does not retain the lock")
  func cancelledRecoveryWaiterReleasesContentGate() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("cancelled-recovery.mp3")
    try Data("cancelled-recovery".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let hasher = CountingHasher()
    let initialImporter = try fixture.makeImporter(
      repository: repository,
      hasher: hasher
    )
    let initialEvents = try await collect(
      initialImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: initialEvents))
    try await repository.remove([itemID])

    let probe = FirstCallBlockingProbe()
    let recoveryImporter = try fixture.makeImporter(
      repository: repository,
      probe: probe,
      hasher: hasher
    )
    let ownerTask = Task {
      try await collect(
        recoveryImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()

    let cancelledID = UUID()
    let waiterTask = Task {
      try await collect(
        recoveryImporter.importMedia(
          MediaImportRequest(importID: cancelledID, urls: [input])
        )
      )
    }
    await hasher.waitForCallCount(4)
    await recoveryImporter.cancelImport(cancelledID)
    await probe.releaseFirstCall()

    let ownerResult = try completedResult(in: try await ownerTask.value)
    let cancelledResult = try completedResult(in: try await waiterTask.value)
    #expect(ownerResult.imported == 1)
    #expect(cancelledResult.status == .cancelled)

    let laterEvents = try await collect(
      recoveryImporter.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let laterResult = try completedResult(in: laterEvents)
    #expect(laterResult.skipped == 1)
    #expect(await repository.applyAttemptCount() == 2)
  }

  @Test("Import sessions reject duplicate IDs and preserve immediate cancellation")
  func importSessionRegistryIsRaceFree() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("slow.mp3")
    try Data("slow-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let probe = FirstCallBlockingProbe()
    let importer = try fixture.makeImporter(repository: repository, probe: probe)
    let importID = UUID()
    let firstStream = importer.importMedia(
      MediaImportRequest(importID: importID, urls: [input])
    )
    let firstTask = Task { try await collect(firstStream) }
    await probe.waitUntilFirstCallBlocks()

    let secondImporter = try fixture.makeImporter(repository: repository, probe: probe)
    let duplicateStream = secondImporter.importMedia(
      MediaImportRequest(importID: importID, urls: [input])
    )
    let duplicateTask = Task { try await collect(duplicateStream) }
    await probe.releaseFirstCall()
    _ = try await firstTask.value
    do {
      _ = try await duplicateTask.value
      Issue.record("A second stream with the same import ID must be rejected")
    } catch {
      #expect(error is MediaSourceError)
    }

    let cancelledID = UUID()
    let cancelledStream = importer.importMedia(
      MediaImportRequest(importID: cancelledID, urls: [input])
    )
    await importer.cancelImport(cancelledID)
    let cancelledEvents = try await collect(cancelledStream)
    let cancelledResult = try completedResult(in: cancelledEvents)
    #expect(cancelledResult.status == .cancelled)
  }

  @Test("A completed import ID can be reused immediately")
  func completedImportIDDoesNotLeaveStaleCancellation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("reused-session.mp3")
    try Data("reused-session-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let importID = UUID()
    let firstEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: importID, urls: [input]))
    )
    let firstResult = try completedResult(in: firstEvents)
    #expect(firstResult.imported == 1)

    let repeatedEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: importID, urls: [input]))
    )
    let repeatedResult = try completedResult(in: repeatedEvents)
    #expect(repeatedResult.status == .completed)
    #expect(repeatedResult.skipped == 1)
    #expect(await repository.applyAttemptCount() == 1)
  }

  @Test
  func persistenceFailureMovesFileBackOutOfManagedStorage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("will-fail.mp3")
    try Data("persist-failure".utf8).write(to: input)

    let repository = InMemoryLibraryRepository(failsWrites: true)
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let result = try completedResult(in: events)

    #expect(result.imported == 0)
    #expect(result.failed == 1)
    let managedItems = try FileManager.default.contentsOfDirectory(
      at: fixture.configuration.managedRoot.appendingPathComponent("items"),
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    #expect(managedItems.isEmpty)
    #expect(FileManager.default.fileExists(atPath: input.path))
  }

  @Test("Re-import after committed removal uses a new operation idempotency key")
  func reimportAfterRemovalDoesNotReuseContentIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("reimportable.mp3")
    try Data("reimportable".utf8).write(to: input)

    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let importer = try fixture.makeImporter(repository: library)

    let firstEvents = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [input])
      )
    )
    let firstResult = try completedResult(in: firstEvents)
    let itemID = try #require(persistedItemID(in: firstEvents))
    #expect(firstResult.imported == 1)

    let remover = try ManagedMediaRemover(configuration: fixture.configuration)
    let removal = try await remover.prepareRemoval(of: [itemID])
    try await library.remove([itemID])
    try await remover.commitRemoval(removal)

    let secondEvents = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [input])
      )
    )
    let secondResult = try completedResult(in: secondEvents)
    #expect(secondResult.imported == 1)
    let restoredTrack = try await library.track(id: itemID)
    #expect(restoredTrack != nil)

    await store.close()
  }

  @Test
  func removalPersistsPendingStateAcrossAdapterInstances() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("removable.mp3")
    try Data("removable".utf8).write(to: input)
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let importEvents = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: importEvents))
    let source = try fixture.makeSource()
    let remover = try ManagedMediaRemover(configuration: fixture.configuration)

    let firstTransaction = try await remover.prepareRemoval(of: [itemID])
    let firstPending = try await remover.pendingRemovals()
    #expect(firstPending == [firstTransaction])
    await #expect(throws: MediaSourceError.self) {
      _ = try await source.resolve(itemID)
    }

    let restartedRemover = try ManagedMediaRemover(configuration: fixture.configuration)
    let restartedPending = try await restartedRemover.pendingRemovals()
    #expect(restartedPending == [firstTransaction])
    try await restartedRemover.rollbackRemoval(firstTransaction)
    let pendingAfterRollback = try await restartedRemover.pendingRemovals()
    #expect(pendingAfterRollback.isEmpty)
    _ = try await source.resolve(itemID)

    let secondTransaction = try await restartedRemover.prepareRemoval(of: [itemID])
    let finalRemover = try ManagedMediaRemover(configuration: fixture.configuration)
    let finalPending = try await finalRemover.pendingRemovals()
    #expect(finalPending == [secondTransaction])
    try await finalRemover.commitRemoval(secondTransaction)
    let pendingAfterCommit = try await finalRemover.pendingRemovals()
    #expect(pendingAfterCommit.isEmpty)
    await #expect(throws: MediaSourceError.self) {
      _ = try await source.resolve(itemID)
    }
    await #expect(throws: MediaSourceError.self) {
      try await finalRemover.commitRemoval(secondTransaction)
    }
  }

  @Test("Restart rollback recovers a manifest persisted before any media move")
  func restartRollbackRecoversManifestOnlyPreparation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstInput = fixture.inputRoot.appendingPathComponent("manifest-first-a.mp3")
    let secondInput = fixture.inputRoot.appendingPathComponent("manifest-first-b.mp3")
    try Data("manifest-first-audio-a".utf8).write(to: firstInput)
    try Data("manifest-first-audio-b".utf8).write(to: secondInput)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [firstInput, secondInput])
      )
    )
    let itemIDs = persistedItemIDs(in: events)
    try #require(itemIDs.count == 2)

    let interruptedStore = try ManagedMediaStore(
      configuration: fixture.configuration,
      preparationInterruptionPoint: .afterManifest
    )
    var originalURLs: [URL] = []
    for itemID in itemIDs.sorted() {
      originalURLs.append(
        try await interruptedStore.mediaURL(forExternalID: itemID.externalID)
      )
    }

    await #expect(throws: ManagedMediaPreparationInterrupted.self) {
      _ = try await interruptedStore.prepareRemoval(of: itemIDs)
    }

    let transactionRoot = try #require(
      onlyElement(in: pendingTransactionRoots(in: fixture))
    )
    #expect(
      FileManager.default.fileExists(
        atPath: transactionRoot.appendingPathComponent("manifest.json").path
      )
    )
    #expect(try manifestLocationCount(in: transactionRoot) == itemIDs.count)
    #expect(try quarantinedMediaURLs(in: transactionRoot).isEmpty)
    #expect(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

    let restartedRemover = try ManagedMediaRemover(configuration: fixture.configuration)
    let restartedPending = try await restartedRemover.pendingRemovals()
    let transaction = try #require(onlyElement(in: restartedPending))
    try await restartedRemover.rollbackRemoval(transaction)

    let pendingAfterRollback = try await restartedRemover.pendingRemovals()
    #expect(pendingAfterRollback.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: transactionRoot.path))
    #expect(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test("Restart rollback recovers a manifest persisted with only a subset moved")
  func restartRollbackRecoversPartialPreparation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstInput = fixture.inputRoot.appendingPathComponent("partial-prepare-a.mp3")
    let secondInput = fixture.inputRoot.appendingPathComponent("partial-prepare-b.mp3")
    try Data("partial-prepare-audio-a".utf8).write(to: firstInput)
    try Data("partial-prepare-audio-b".utf8).write(to: secondInput)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [firstInput, secondInput])
      )
    )
    let itemIDs = persistedItemIDs(in: events)
    try #require(itemIDs.count == 2)

    let interruptedStore = try ManagedMediaStore(
      configuration: fixture.configuration,
      preparationInterruptionPoint: .afterMovedFiles(1)
    )
    let sortedItemIDs = itemIDs.sorted()
    var originalURLs: [URL] = []
    for itemID in sortedItemIDs {
      originalURLs.append(
        try await interruptedStore.mediaURL(forExternalID: itemID.externalID)
      )
    }

    await #expect(throws: ManagedMediaPreparationInterrupted.self) {
      _ = try await interruptedStore.prepareRemoval(of: itemIDs)
    }

    let transactionRoot = try #require(
      onlyElement(in: pendingTransactionRoots(in: fixture))
    )
    #expect(
      FileManager.default.fileExists(
        atPath: transactionRoot.appendingPathComponent("manifest.json").path
      )
    )
    #expect(try manifestLocationCount(in: transactionRoot) == itemIDs.count)
    #expect(try quarantinedMediaURLs(in: transactionRoot).count == 1)
    #expect(!FileManager.default.fileExists(atPath: originalURLs[0].path))
    #expect(FileManager.default.fileExists(atPath: originalURLs[1].path))

    let restartedRemover = try ManagedMediaRemover(configuration: fixture.configuration)
    let restartedPending = try await restartedRemover.pendingRemovals()
    let transaction = try #require(onlyElement(in: restartedPending))
    await #expect(throws: MediaSourceError.self) {
      try await restartedRemover.commitRemoval(transaction)
    }
    let pendingAfterRejectedCommit = try await restartedRemover.pendingRemovals()
    #expect(pendingAfterRejectedCommit == [transaction])

    try await restartedRemover.rollbackRemoval(transaction)
    let pendingAfterRollback = try await restartedRemover.pendingRemovals()
    #expect(pendingAfterRollback.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: transactionRoot.path))
    #expect(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test("Malformed pending entries do not block valid removal recovery")
  func malformedPendingEntryDoesNotAbortRecovery() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("valid-pending.mp3")
    try Data("valid-pending-content".utf8).write(to: input)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
    )
    let itemID = try #require(persistedItemID(in: events))
    let remover = try ManagedMediaRemover(configuration: fixture.configuration)
    let transaction = try await remover.prepareRemoval(of: [itemID])

    let malformedRoot = fixture.configuration.quarantineRoot
      .appendingPathComponent("pending", isDirectory: true)
      .appendingPathComponent("legacy-corrupt", isDirectory: true)
    try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(
      to: malformedRoot.appendingPathComponent("manifest.json", isDirectory: false)
    )

    #expect(try await remover.pendingRemovals() == [transaction])
    let maintenance = try LocalMediaStorageMaintenance(configuration: fixture.configuration)
    #expect(try await maintenance.usage().pendingRemovalCount == 2)

    try await remover.rollbackRemoval(transaction)
    #expect(try await remover.pendingRemovals().isEmpty)
    #expect(FileManager.default.fileExists(atPath: malformedRoot.path))
    #expect(try await maintenance.usage().pendingRemovalCount == 1)
  }

  @Test("Unreadable pending manifest restores only unambiguous moved media")
  func unreadablePendingManifestRepairsMovedMediaWithoutOverwritingConflict() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstInput = fixture.inputRoot.appendingPathComponent("corrupt-manifest-a.mp3")
    let secondInput = fixture.inputRoot.appendingPathComponent("corrupt-manifest-b.mp3")
    try Data("corrupt-manifest-audio-a".utf8).write(to: firstInput)
    try Data("corrupt-manifest-audio-b".utf8).write(to: secondInput)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [firstInput, secondInput])
      )
    )
    let itemIDs = persistedItemIDs(in: events)
    try #require(itemIDs.count == 2)

    let store = try ManagedMediaStore(configuration: fixture.configuration)
    var originalURLs: [URL] = []
    var originalContents: [Data] = []
    for itemID in itemIDs.sorted() {
      let originalURL = try await store.mediaURL(forExternalID: itemID.externalID)
      originalURLs.append(originalURL)
      originalContents.append(try Data(contentsOf: originalURL))
    }

    _ = try await store.prepareRemoval(of: itemIDs)
    let transactionRoot = try #require(
      onlyElement(in: pendingTransactionRoots(in: fixture))
    )
    #expect(originalURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

    try Data("not-json".utf8).write(
      to: transactionRoot.appendingPathComponent("manifest.json", isDirectory: false)
    )
    let conflictingContent = Data("managed-destination-conflict".utf8)
    try conflictingContent.write(to: originalURLs[1])

    let restartedStore = try ManagedMediaStore(configuration: fixture.configuration)
    #expect(try await restartedStore.pendingRemovals().isEmpty)

    #expect(try Data(contentsOf: originalURLs[0]) == originalContents[0])
    #expect(try Data(contentsOf: originalURLs[1]) == conflictingContent)
    let unresolvedMedia = try quarantinedMediaURLs(in: transactionRoot)
    let unresolved = try #require(onlyElement(in: unresolvedMedia))
    #expect(unresolved.lastPathComponent == originalURLs[1].lastPathComponent)
    #expect(try Data(contentsOf: unresolved) == originalContents[1])
    #expect(FileManager.default.fileExists(atPath: transactionRoot.path))

    let maintenance = try LocalMediaStorageMaintenance(configuration: fixture.configuration)
    #expect(try await maintenance.usage().pendingRemovalCount == 1)
  }

  @Test("Unreadable pending manifests do not restore content with a forged filename")
  func unreadablePendingManifestRejectsForgedContentIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let expectedContent = Data("expected-recovery-content".utf8)
    let forgedContent = Data("different-content".utf8)
    let expectedID = "sha256-" + MusicContentIdentity.sha256Hex(expectedContent)
    let forgedID = "sha256-" + MusicContentIdentity.sha256Hex(
      Data("expected-but-forged".utf8)
    )
    let mediaRoot = fixture.configuration.quarantineRoot
      .appendingPathComponent("pending", isDirectory: true)
      .appendingPathComponent("legacy-corrupt", isDirectory: true)
      .appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
    let expectedURL = mediaRoot.appendingPathComponent(expectedID + ".mp3")
    let forgedURL = mediaRoot.appendingPathComponent(forgedID + ".mp3")
    try expectedContent.write(to: expectedURL)
    try forgedContent.write(to: forgedURL)
    try Data("not-json".utf8).write(
      to: mediaRoot.deletingLastPathComponent().appendingPathComponent("manifest.json")
    )

    let store = try ManagedMediaStore(configuration: fixture.configuration)
    #expect(try await store.pendingRemovals().isEmpty)

    let managedRoot = fixture.configuration.managedRoot.appendingPathComponent(
      "items",
      isDirectory: true
    )
    #expect(FileManager.default.fileExists(
      atPath: managedRoot.appendingPathComponent(expectedID + ".mp3").path
    ))
    #expect(!FileManager.default.fileExists(
      atPath: managedRoot.appendingPathComponent(forgedID + ".mp3").path
    ))
    #expect(FileManager.default.fileExists(atPath: forgedURL.path))
  }

  @Test("Failed prepare compensation preserves quarantine for restart recovery")
  func failedPrepareCompensationRemainsRecoverable() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let firstInput = fixture.inputRoot.appendingPathComponent("compensation-a.mp3")
    let secondInput = fixture.inputRoot.appendingPathComponent("compensation-b.mp3")
    try Data("compensation-audio-a".utf8).write(to: firstInput)
    try Data("compensation-audio-b".utf8).write(to: secondInput)

    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let events = try await collect(
      importer.importMedia(
        MediaImportRequest(importID: UUID(), urls: [firstInput, secondInput])
      )
    )
    let itemIDs = persistedItemIDs(in: events)
    try #require(itemIDs.count == 2)

    let failingStore = try ManagedMediaStore(
      configuration: fixture.configuration,
      preparationFailurePlan: ManagedMediaPreparationFailurePlan(
        prepareMove: 2,
        restoreMove: 1
      )
    )
    var originalURLs: [URL] = []
    for itemID in itemIDs.sorted() {
      originalURLs.append(
        try await failingStore.mediaURL(forExternalID: itemID.externalID)
      )
    }

    await #expect(throws: LocalMediaError.recoveryFailed) {
      _ = try await failingStore.prepareRemoval(of: itemIDs)
    }

    let transactionRoot = try #require(
      onlyElement(in: pendingTransactionRoots(in: fixture))
    )
    #expect(
      FileManager.default.fileExists(
        atPath: transactionRoot.appendingPathComponent("manifest.json").path
      )
    )
    #expect(try quarantinedMediaURLs(in: transactionRoot).count == 1)
    #expect(originalURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)

    let restartedStore = try ManagedMediaStore(configuration: fixture.configuration)
    let pending = try await restartedStore.pendingRemovals()
    let transaction = try #require(onlyElement(in: pending))
    try await restartedStore.rollbackRemoval(transaction)

    #expect(try await restartedStore.pendingRemovals().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: transactionRoot.path))
    #expect(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test("A symlinked managed items ancestor cannot escape the configured root")
  func managedItemsAncestorSymlinkEscapeIsRejected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let fileManager = FileManager.default
    let itemsRoot = fixture.configuration.managedRoot
      .appendingPathComponent("items", isDirectory: true)
    let outsideRoot = fixture.root.appendingPathComponent("outside", isDirectory: true)
    let outsideMedia = outsideRoot.appendingPathComponent(
      "sha256-" + String(repeating: "a", count: 64) + ".mp3",
      isDirectory: false
    )
    try fileManager.createDirectory(at: itemsRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
    try Data("outside-content".utf8).write(to: outsideMedia)
    try fileManager.removeItem(at: itemsRoot)
    try fileManager.createSymbolicLink(at: itemsRoot, withDestinationURL: outsideRoot)

    #expect(throws: LocalMediaError.rootContainmentViolation) {
      _ = try ManagedMediaStore(configuration: fixture.configuration)
    }
    #expect(fileManager.fileExists(atPath: outsideMedia.path))
    #expect(try Data(contentsOf: outsideMedia) == Data("outside-content".utf8))
  }

  @Test("Storage maintenance clears only explicitly selected derived data")
  func storageMaintenanceReportsUsageAndFreesArtifacts() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let fileManager = FileManager.default
    let maintenance = try LocalMediaStorageMaintenance(
      configuration: fixture.configuration
    )
    let stagingArtifact = fixture.configuration.stagingRoot
      .appendingPathComponent("orphan-import.bin")
    let committedArtifact = fixture.configuration.quarantineRoot
      .appendingPathComponent("committed", isDirectory: true)
      .appendingPathComponent("orphan.json")
    try fileManager.createDirectory(
      at: stagingArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: committedArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 1, count: 17).write(to: stagingArtifact)
    try Data(repeating: 2, count: 23).write(to: committedArtifact)

    let before = try await maintenance.usage()
    #expect(before.cacheBytes >= 17)
    #expect(before.quarantineBytes >= 23)

    let result = try await maintenance.perform([
      .clearImportStaging,
      .clearFinalizedQuarantine
    ])
    #expect(result.usageBefore == before)
    #expect(result.usageAfter.cacheBytes == 0)
    #expect(result.usageAfter.quarantineBytes == 0)
    #expect(result.freedBytes >= 40)
    #expect(!fileManager.fileExists(atPath: stagingArtifact.path))
    #expect(!fileManager.fileExists(atPath: committedArtifact.path))
  }

  @Test("Orphaned artwork cleanup preserves referenced and invalid files")
  func orphanedArtworkCleanupPreservesReferencedArtwork() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let repository = InMemoryLibraryRepository()
    let store = try ManagedMediaStore(configuration: fixture.configuration)
    let referencedData = Data("referenced-artwork".utf8)
    let orphanedData = Data("orphaned-artwork".utf8)
    let referencedID = ArtworkID(
      "sha256-\(MusicContentIdentity.sha256Hex(referencedData))"
    )
    let orphanedID = ArtworkID(
      "sha256-\(MusicContentIdentity.sha256Hex(orphanedData))"
    )
    let referencedLocation = try await store.writeArtwork(
      referencedData,
      artworkID: referencedID
    )
    let orphanedLocation = try await store.writeArtwork(
      orphanedData,
      artworkID: orphanedID
    )
    let invalidID = ArtworkID("sha256-\(String(repeating: "a", count: 64))")
    let invalidURL = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
      .appendingPathComponent(invalidID.rawValue + ".bin")
    let malformedURL = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
      .appendingPathComponent("manual.bin")
    let oversizedID = ArtworkID("sha256-\(String(repeating: "b", count: 64))")
    let oversizedURL = fixture.configuration.managedRoot
      .appendingPathComponent("artwork", isDirectory: true)
      .appendingPathComponent(oversizedID.rawValue + ".bin")
    try Data("not-the-hash".utf8).write(to: invalidURL)
    try Data("manual".utf8).write(to: malformedURL)
    try makeSparseFile(
      at: oversizedURL,
      byteCount: UInt64(ArtworkDataLimits.maximumByteCount) + 1
    )

    let reference = ArtworkReference(
      id: referencedID,
      variants: [.original],
      preferredVariant: .original
    )
    let orphanedReference = ArtworkReference(
      id: orphanedID,
      variants: [.original],
      preferredVariant: .original
    )
    let transaction = try LibraryTransaction(
      idempotencyKey: "artwork-reference",
      mutations: [
        .upsert(.artwork(reference)),
        .upsert(.artwork(orphanedReference)),
        .upsert(.track(Track(
          id: MediaItemID(sourceID: .local, externalID: "artwork-owner"),
          title: "Artwork owner",
          artwork: reference
        )))
      ]
    )
    try await repository.apply(transaction)

    let maintenance = try LocalMediaStorageMaintenance(
      configuration: fixture.configuration,
      libraryRepository: repository
    )
    let result = try await maintenance.pruneOrphanedArtwork()

    #expect(result.freedBytes >= Int64(orphanedData.count))
    #expect(FileManager.default.fileExists(atPath: referencedLocation.url.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedLocation.url.path))
    #expect(FileManager.default.fileExists(atPath: invalidURL.path))
    #expect(FileManager.default.fileExists(atPath: malformedURL.path))
    #expect(FileManager.default.fileExists(atPath: oversizedURL.path))
  }

  @Test("Automatic pruning removes stale staging before oldest cache entries")
  func automaticPruningUsesRetentionThenByteLimit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let fileManager = FileManager.default
    let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
    let maintenance = try LocalMediaStorageMaintenance(
      configuration: fixture.configuration,
      now: { referenceDate }
    )
    let stale = fixture.configuration.stagingRoot.appendingPathComponent("stale.bin")
    let oldestFresh = fixture.configuration.stagingRoot.appendingPathComponent("oldest.bin")
    let newestFresh = fixture.configuration.stagingRoot.appendingPathComponent("newest.bin")
    let managed = fixture.configuration.managedRoot.appendingPathComponent("protected.bin")
    let pending = fixture.configuration.quarantineRoot
      .appendingPathComponent("pending", isDirectory: true)
      .appendingPathComponent("protected.bin")

    try makeSparseFile(at: stale, byteCount: 1 * 1_024 * 1_024)
    try makeSparseFile(at: oldestFresh, byteCount: 40 * 1_024 * 1_024)
    try makeSparseFile(at: newestFresh, byteCount: 40 * 1_024 * 1_024)
    try makeSparseFile(at: managed, byteCount: 1)
    try makeSparseFile(at: pending, byteCount: 1)
    try fileManager.setAttributes(
      [.modificationDate: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: stale.path
    )
    try fileManager.setAttributes(
      [.modificationDate: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60)],
      ofItemAtPath: oldestFresh.path
    )
    try fileManager.setAttributes(
      [.modificationDate: referenceDate.addingTimeInterval(-1 * 24 * 60 * 60)],
      ofItemAtPath: newestFresh.path
    )

    let result = try await maintenance.pruneCache(
      to: StorageByteLimit(bytes: 64 * 1_024 * 1_024),
      retainingStagingFor: .seconds(7 * 24 * 60 * 60)
    )

    #expect(!fileManager.fileExists(atPath: stale.path))
    #expect(!fileManager.fileExists(atPath: oldestFresh.path))
    #expect(fileManager.fileExists(atPath: newestFresh.path))
    #expect(fileManager.fileExists(atPath: managed.path))
    #expect(fileManager.fileExists(atPath: pending.path))
    #expect(result.usageAfter.cacheBytes <= 64 * 1_024 * 1_024)
    #expect(result.freedBytes >= 41 * 1_024 * 1_024)
  }

  @Test("Automatic pruning waits for an active import batch")
  func automaticPruningDoesNotRaceActiveImport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("active-prune.mp3")
    try Data("active-prune-content".utf8).write(to: input)
    let importID = UUID()
    let probe = FirstCallBlockingProbe()
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository, probe: probe)
    let maintenance = try LocalMediaStorageMaintenance(configuration: fixture.configuration)
    let importTask = Task {
      try await collect(
        importer.importMedia(MediaImportRequest(importID: importID, urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()
    let batchRoot = fixture.configuration.stagingRoot
      .appendingPathComponent(importID.uuidString, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: batchRoot.path))

    let pruningState = AsyncCompletionState()
    let pruneTask = Task {
      _ = try await maintenance.pruneCache(
        to: .fiveGiB,
        retainingStagingFor: .zero
      )
      await pruningState.finish()
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(!(await pruningState.isFinished))
    #expect(FileManager.default.fileExists(atPath: batchRoot.path))

    await probe.releaseFirstCall()
    let result = try completedResult(in: try await importTask.value)
    try await pruneTask.value
    #expect(result.imported == 1)
    #expect(await pruningState.isFinished)
  }

  @Test("Manual staging clear waits for an active import batch")
  func manualStagingClearDoesNotRaceActiveImport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("active-manual-clear.mp3")
    try Data("active-manual-clear-content".utf8).write(to: input)
    let importID = UUID()
    let probe = FirstCallBlockingProbe()
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository, probe: probe)
    let maintenance = try LocalMediaStorageMaintenance(configuration: fixture.configuration)
    let importTask = Task {
      try await collect(
        importer.importMedia(MediaImportRequest(importID: importID, urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()
    let batchRoot = fixture.configuration.stagingRoot
      .appendingPathComponent(importID.uuidString, isDirectory: true)

    let clearState = AsyncCompletionState()
    let clearTask = Task {
      _ = try await maintenance.perform([.clearImportStaging])
      await clearState.finish()
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(!(await clearState.isFinished))
    #expect(FileManager.default.fileExists(atPath: batchRoot.path))

    await probe.releaseFirstCall()
    let result = try completedResult(in: try await importTask.value)
    try await clearTask.value
    #expect(result.imported == 1)
    #expect(await clearState.isFinished)
  }

  @Test("Finalized quarantine clear waits for an active import batch")
  func finalizedQuarantineClearDoesNotRaceActiveImport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let input = fixture.inputRoot.appendingPathComponent("active-quarantine-clear.mp3")
    try Data("active-quarantine-clear-content".utf8).write(to: input)
    let committedArtifact = fixture.configuration.quarantineRoot
      .appendingPathComponent("committed", isDirectory: true)
      .appendingPathComponent("before-import-finishes.json")
    try FileManager.default.createDirectory(
      at: committedArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("committed".utf8).write(to: committedArtifact)

    let probe = FirstCallBlockingProbe()
    let importer = try fixture.makeImporter(
      repository: InMemoryLibraryRepository(),
      probe: probe
    )
    let maintenance = try LocalMediaStorageMaintenance(configuration: fixture.configuration)
    let importTask = Task {
      try await collect(
        importer.importMedia(MediaImportRequest(importID: UUID(), urls: [input]))
      )
    }
    await probe.waitUntilFirstCallBlocks()

    let clearState = AsyncCompletionState()
    let clearTask = Task {
      _ = try await maintenance.perform([.clearFinalizedQuarantine])
      await clearState.finish()
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(!(await clearState.isFinished))
    #expect(FileManager.default.fileExists(atPath: committedArtifact.path))

    await probe.releaseFirstCall()
    _ = try completedResult(in: try await importTask.value)
    try await clearTask.value
    #expect(await clearState.isFinished)
    #expect(!FileManager.default.fileExists(atPath: committedArtifact.path))
  }

  @Test("Managed media removal uses the shared maintenance gate")
  func managedMediaRemovalWaitsForMaintenanceWindow() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let remover = try ManagedMediaRemover(configuration: fixture.configuration)
    let importer = try fixture.makeImporter(repository: InMemoryLibraryRepository())
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(
      for: fixture.configuration
    )
    _ = importer
    #expect(await coordinator.maintenanceGate.enterMaintenance())

    let state = AsyncCompletionState()
    let pendingTask = Task {
      _ = try await remover.pendingRemovals()
      await state.finish()
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(!(await state.isFinished))

    await coordinator.maintenanceGate.leaveMaintenance()
    try await pendingTask.value
    #expect(await state.isFinished)
  }

  @Test("Cancelled maintenance gate waiters do not poison ownership")
  func cancelledMaintenanceGateWaitersReleaseWithoutPoisoningGate() async {
    let gate = ImportMaintenanceGate()

    #expect(await gate.enterImport())
    let maintenanceWaiter = Task { await gate.enterMaintenance() }
    for _ in 0..<20 { await Task.yield() }
    maintenanceWaiter.cancel()
    #expect(await maintenanceWaiter.value == false)
    await gate.leaveImport()

    #expect(await gate.enterMaintenance())
    let importWaiter = Task { await gate.enterImport() }
    for _ in 0..<20 { await Task.yield() }
    importWaiter.cancel()
    #expect(await importWaiter.value == false)
    await gate.leaveMaintenance()

    #expect(await gate.enterImport())
    await gate.leaveImport()
  }

  @Test("Cancelling an import while waiting for maintenance does not run it")
  func cancelledImportWaitingForMaintenanceDoesNotRun() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let repository = InMemoryLibraryRepository()
    let importer = try fixture.makeImporter(repository: repository)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(
      for: fixture.configuration
    )
    #expect(await coordinator.maintenanceGate.enterMaintenance())

    let importID = UUID()
    let importTask = Task {
      try await collect(
        importer.importMedia(MediaImportRequest(importID: importID, urls: []))
      )
    }
    for _ in 0..<20 { await Task.yield() }
    await importer.cancelImport(importID)

    let events = try await importTask.value
    let result = try completedResult(in: events)
    #expect(result.status == .cancelled)
    #expect(await repository.applyAttemptCount() == 0)
    await coordinator.maintenanceGate.leaveMaintenance()
  }

  @Test
  func invalidSourceAndBookmarkValuesAreRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = try fixture.makeSource()
    let remoteID = MediaItemID(
      sourceID: MediaSourceID(rawValue: "remote"),
      externalID: "sha256-" + String(repeating: "0", count: 64)
    )
    await #expect(throws: MediaSourceError.self) {
      _ = try await source.resolve(remoteID)
    }

    #expect(throws: LocalMediaError.self) {
      _ = try LocalMediaBookmark(data: Data())
    }
    let remover = try ManagedMediaRemover(configuration: fixture.configuration)
    let traversalID = MediaItemID(sourceID: .local, externalID: "../outside")
    await #expect(throws: MediaSourceError.self) {
      _ = try await remover.prepareRemoval(of: [traversalID])
    }
  }
}

private func validPNGData() throws -> Data {
  try #require(Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  ))
}

private func trackReplacingUserState(
  _ track: Track,
  isFavorite: Bool,
  statistics: PlaybackStatistics
) -> Track {
  Track(
    id: track.id,
    logicalTrackID: track.logicalTrackID,
    assetID: track.assetID,
    playbackSelection: track.playbackSelection,
    title: track.title,
    sortTitle: track.sortTitle,
    albumID: track.albumID,
    artistIDs: track.artistIDs,
    genreIDs: track.genreIDs,
    trackNumber: track.trackNumber,
    trackTotal: track.trackTotal,
    discNumber: track.discNumber,
    discTotal: track.discTotal,
    fileName: track.fileName,
    folderPath: track.folderPath,
    duration: track.duration,
    technicalInfo: track.technicalInfo,
    year: track.year,
    comment: track.comment,
    lyrics: track.lyrics,
    artwork: track.artwork,
    isFavorite: isFavorite,
    statistics: statistics
  )
}

private actor AsyncCompletionState {
  private(set) var isFinished = false

  func finish() {
    isFinished = true
  }
}

private func makeSparseFile(at url: URL, byteCount: UInt64) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  FileManager.default.createFile(atPath: url.path, contents: nil)
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.truncate(atOffset: byteCount)
}

private struct Fixture {
  let root: URL
  let inputRoot: URL
  let configuration: LocalMediaConfiguration

  init() throws {
    let fileManager = FileManager.default
    root = fileManager.temporaryDirectory
      .appendingPathComponent("MusicFree-LocalMedia-\(UUID().uuidString)", isDirectory: true)
    inputRoot = root.appendingPathComponent("input", isDirectory: true)
    try fileManager.createDirectory(at: inputRoot, withIntermediateDirectories: true)
    configuration = try LocalMediaConfiguration(
      managedRoot: root.appendingPathComponent("managed", isDirectory: true),
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
    )
  }

  func makeImporter(
    repository: any LibraryRepository,
    probe: any MediaProbing = FixedProbe(),
    hasher: (any LocalMediaHashing)? = nil
  ) throws -> LocalMediaImporter {
    try LocalMediaImporter(
      configuration: configuration,
      probe: probe,
      metadataReader: FixedMetadataReader(),
      libraryRepository: repository,
      hasher: hasher
    )
  }

  func makeSource() throws -> LocalMediaSource {
    try LocalMediaSource(
      configuration: configuration,
      probe: FixedProbe(),
      metadataReader: FixedMetadataReader()
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct FixedProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    MediaProbeResult(
      audioTracks: [ProbedAudioTrack(index: 0, codec: "fixture", sampleRate: 44_100, channelCount: 2)],
      container: "fixture",
      duration: .seconds(3)
    )
  }
}

private struct MultipleAudioStreamProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    _ = resource
    return MediaProbeResult(
      audioTracks: [
        ProbedAudioTrack(
          index: 0,
          stableID: "stream-commentary",
          codec: "aac",
          sampleRate: 48_000,
          channelCount: 2,
          language: "eng",
          title: "Commentary"
        ),
        ProbedAudioTrack(
          index: 1,
          stableID: "stream-undecodable",
          codec: "unsupported",
          isDecodable: false
        ),
        ProbedAudioTrack(
          index: 2,
          stableID: "stream-main",
          codec: "aac",
          sampleRate: 48_000,
          channelCount: 2,
          language: "eng",
          title: "Main Mix",
          isDefault: true
        )
      ],
      container: "matroska",
      duration: .seconds(180)
    )
  }
}

private struct UnknownSidecarProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    if case .localFile(let url) = resource,
       url.pathExtension.caseInsensitiveCompare("unknown") == .orderedSame
    {
      throw MediaSourceError.probeFailed(.unsupportedFormat)
    }
    return try await FixedProbe().probe(resource)
  }
}

private struct SourceMutatingProbe: MediaProbing {
  let sourceURL: URL

  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    try Data(repeating: 1, count: 32).write(to: sourceURL)
    return try await FixedProbe().probe(resource)
  }
}

private actor FirstCallBlockingProbe: MediaProbing {
  private var didBlock = false
  private var isBlocked = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    if !didBlock {
      didBlock = true
      isBlocked = true
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
      try Task.checkCancellation()
    }
    return try await FixedProbe().probe(resource)
  }

  func waitUntilFirstCallBlocks() async {
    guard !isBlocked else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstCall() {
    releaseContinuation?.resume()
    releaseContinuation = nil
    isBlocked = false
  }
}

private actor CountingHasher: LocalMediaHashing {
  private let value = String(repeating: "a", count: 64)
  private var callCount = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func hash(fileAt url: URL) async throws -> String {
    try Task.checkCancellation()
    callCount += 1
    let ready = waiters.filter { $0.0 <= callCount }
    waiters.removeAll { $0.0 <= callCount }
    for waiter in ready { waiter.1.resume() }
    return value
  }

  func waitForCallCount(_ minimumCount: Int) async {
    guard callCount < minimumCount else { return }
    await withCheckedContinuation { continuation in
      waiters.append((minimumCount, continuation))
    }
  }
}

private struct FixedMetadataReader: MetadataReading {
  func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
    RawMediaMetadata(
      title: "Fixture song",
      artist: "Fixture artist",
      album: "Fixture album",
      genre: "Fixture genre",
      artworks: [RawArtwork(data: Data("artwork".utf8), mimeType: "image/png")]
    )
  }
}

private struct NoArtworkMetadataReader: MetadataReading {
  func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
    _ = resource
    return RawMediaMetadata(
      title: "Fixture song",
      artist: "Fixture artist",
      album: "Fixture album"
    )
  }
}

private final actor InMemoryLibraryRepository: LibraryRepository {
  private var tracks: [MediaItemID: Track] = [:]
  private var artworks: [ArtworkID: ArtworkReference] = [:]
  private var applyAttempts = 0
  private(set) var appliedTransactions: [LibraryTransaction] = []
  private let failsWrites: Bool
  private let failFirstWriteAfterRelease: Bool
  private var firstWriteIsBlocked = false
  private var firstWriteStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstWriteReleaseContinuation: CheckedContinuation<Void, Never>?

  init(
    failsWrites: Bool = false,
    failFirstWriteAfterRelease: Bool = false
  ) {
    self.failsWrites = failsWrites
    self.failFirstWriteAfterRelease = failFirstWriteAfterRelease
  }

  func track(id: MediaItemID) async throws -> Track? {
    tracks[id]
  }

  func album(id: AlbumID) async throws -> Album? {
    nil
  }

  func artist(id: ArtistID) async throws -> Artist? {
    nil
  }

  func artwork(id: ArtworkID) async throws -> ArtworkReference? {
    artworks[id]
  }

  func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
    tracks.values.contains { $0.artworkID == artworkID }
  }

  func tracks(
    matching query: TrackQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: Array(tracks.values))
  }

  func albums(
    matching query: AlbumQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Album> {
    LibraryPage(elements: [])
  }

  func artists(
    matching query: ArtistQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    LibraryPage(elements: [])
  }

  func apply(_ transaction: LibraryTransaction) async throws {
    applyAttempts += 1
    if failFirstWriteAfterRelease, applyAttempts == 1 {
      firstWriteIsBlocked = true
      let waiters = firstWriteStartWaiters
      firstWriteStartWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        firstWriteReleaseContinuation = continuation
      }
      firstWriteIsBlocked = false
      throw LibraryError.capacity(.storageUnavailable)
    }
    if failsWrites {
      throw LibraryError.capacity(.storageUnavailable)
    }
    appliedTransactions.append(transaction)
    for mutation in transaction.mutations {
      guard case .upsert(let upsert) = mutation else { continue }
      switch upsert {
      case .track(let track):
        tracks[track.id] = track
      case .artwork(let artwork):
        artworks[artwork.id] = artwork
      default:
        continue
      }
    }
  }

  func assertDistinctAlbumReleaseCount(expected: Int) {
    let releaseIDs = appliedTransactions
      .flatMap(\.mutations)
      .compactMap { mutation -> AlbumReleaseID? in
        guard case .upsert(.albumRelease(let value)) = mutation else { return nil }
        return value.id
      }
    #expect(Set(releaseIDs).count == expected)
  }

  func replaceTrack(_ track: Track) {
    tracks[track.id] = track
  }

  func applyAttemptCount() -> Int {
    applyAttempts
  }

  func waitUntilFirstWriteBlocks() async {
    guard !firstWriteIsBlocked else { return }
    await withCheckedContinuation { continuation in
      firstWriteStartWaiters.append(continuation)
    }
  }

  func releaseFirstWrite() {
    firstWriteReleaseContinuation?.resume()
    firstWriteReleaseContinuation = nil
  }

  func remove(_ itemIDs: Set<MediaItemID>) async throws {
    for itemID in itemIDs {
      tracks[itemID] = nil
    }
  }

  nonisolated func changes() -> AsyncStream<LibraryChange> {
    AsyncStream { continuation in continuation.finish() }
  }
}

private func collect(
  _ stream: AsyncThrowingStream<MediaImportEvent, Error>
) async throws -> [MediaImportEvent] {
  var events: [MediaImportEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
}

private func completedResult(in events: [MediaImportEvent]) throws -> MediaImportResult {
  for event in events {
    if case .completed(_, let result) = event { return result }
    if case .cancelled(_, let result) = event { return result }
  }
  throw TestError.missingTerminalEvent
}

private func persistedItemID(in events: [MediaImportEvent]) -> MediaItemID? {
  for event in events {
    if case .persisting(_, let itemID) = event { return itemID }
  }
  return nil
}

private func persistedItemIDs(in events: [MediaImportEvent]) -> Set<MediaItemID> {
  Set(
    events.compactMap { event in
      guard case .persisting(_, let itemID) = event else { return nil }
      return itemID
    }
  )
}

private func pendingTransactionRoots(in fixture: Fixture) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: fixture.configuration.quarantineRoot.appendingPathComponent("pending"),
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  )
}

private func quarantinedMediaURLs(in transactionRoot: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: transactionRoot.appendingPathComponent("media", isDirectory: true),
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
  )
}

private func manifestLocationCount(in transactionRoot: URL) throws -> Int {
  let data = try Data(
    contentsOf: transactionRoot.appendingPathComponent("manifest.json", isDirectory: false)
  )
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let locations = object["locations"] as? [[String: Any]]
  else {
    throw TestError.invalidManifest
  }
  return locations.count
}

private func managedMediaItemCount(in fixture: Fixture) throws -> Int {
  try FileManager.default.contentsOfDirectory(
    at: fixture.configuration.managedRoot.appendingPathComponent("items", isDirectory: true),
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
  ).count
}

private func onlyElement<Element>(in elements: [Element]) -> Element? {
  elements.count == 1 ? elements[0] : nil
}

private enum TestError: Error {
  case invalidManifest
  case missingTerminalEvent
}
