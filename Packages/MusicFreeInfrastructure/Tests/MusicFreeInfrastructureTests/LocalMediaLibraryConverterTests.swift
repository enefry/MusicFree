import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing

@testable import LocalMediaAdapter

@Suite("Managed library audio conversion")
struct LocalMediaLibraryConverterTests {
  @Test("Shared assets convert once and preserve every logical track value")
  func sharedAssetConversionPreservesLibraryIdentityAndDefersRetirement() async throws {
    let fixture = try await ConversionFixture.makeSharedAsset()
    defer { fixture.remove() }

    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(
      for: fixture.configuration
    )
    let (_, playbackLease) = try await coordinator.mediaAccess.resolveAndAcquire(
      fixture.oldAssetID
    )

    let batchID = try await fixture.converter.start(
      scope: .items([fixture.tracks[0].id]),
      target: .aacLC(.kbps256)
    )
    let snapshot = try await waitForTerminalBatch(fixture.converter, id: batchID)

    #expect(snapshot.state == .completed)
    #expect(snapshot.completedAssetCount == 1)
    #expect(await fixture.transcoder.callCount == 1)
    await fixture.transcoder.emitLateProgress()
    for _ in 0..<20 { await Task.yield() }
    #expect(await fixture.converter.snapshot(id: batchID)?.currentProgress.isEmpty == true)

    let first = try #require(try await fixture.repository.track(id: fixture.tracks[0].id))
    let second = try #require(try await fixture.repository.track(id: fixture.tracks[1].id))
    #expect(first.id == fixture.tracks[0].id)
    #expect(second.id == fixture.tracks[1].id)
    #expect(first.assetID == second.assetID)
    #expect(first.assetID != fixture.oldAssetID)
    #expect(first.title == fixture.tracks[0].title)
    #expect(first.albumID == fixture.tracks[0].albumID)
    #expect(first.artistIDs == fixture.tracks[0].artistIDs)
    #expect(first.genreIDs == fixture.tracks[0].genreIDs)
    #expect(first.isFavorite == fixture.tracks[0].isFavorite)
    #expect(first.statistics == fixture.tracks[0].statistics)
    #expect(first.details == fixture.tracks[0].details)
    #expect(first.playbackSelection.range == fixture.tracks[0].playbackSelection.range)
    #expect(second.playbackSelection.range == fixture.tracks[1].playbackSelection.range)

    let firstVariant = try #require(
      try await fixture.repository.trackVariant(id: fixture.tracks[0].id)
    )
    #expect(firstVariant.assetID == first.assetID)
    #expect(firstVariant.sourceIdentityHint == "cue-source-identity")
    #expect(firstVariant.sourceMetadata?.title == fixture.tracks[0].title)

    #expect(try await fixture.repository.mediaAsset(id: fixture.oldAssetID) == nil)
    let convertedAsset = try #require(
      try await fixture.repository.mediaAsset(id: first.assetID)
    )
    #expect(convertedAsset.conversion?.targetCodec == .aacLC)
    #expect(convertedAsset.conversion?.requestedBitRate == 256_000)

    // The converter's own input lease has ended, but playback still owns one.
    #expect(FileManager.default.fileExists(atPath: fixture.oldManagedURL.path))
    playbackLease.release()
    try await waitUntil {
      !FileManager.default.fileExists(atPath: fixture.oldManagedURL.path)
    }
    #expect(try await ConversionPersistence(
      configuration: fixture.configuration
    ).loadJournals().isEmpty)
  }

  @Test("Recovery reconciles prepared, managed, and committed journals")
  func recoveryUsesDatabaseReferencesAsSourceOfTruth() async throws {
    for stage in [
      LocalMediaLibraryConverter.JournalStage.prepared,
      .managed,
      .committed,
    ] {
      let fixture = try await RecoveryFixture.make(stage: stage)
      defer { fixture.remove() }

      await fixture.converter.recover()

      #expect(try await fixture.persistence.loadJournals().isEmpty)
      switch stage {
      case .prepared:
        #expect(FileManager.default.fileExists(atPath: fixture.oldManagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.newManagedURL.path))
      case .managed, .committed:
        #expect(!FileManager.default.fileExists(atPath: fixture.oldManagedURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.newManagedURL.path))
      }
    }
  }

  @Test("Pausing defers queued assets and resume completes every pending asset")
  func pauseAndResumePreservePendingAssets() async throws {
    let fixture = try await PauseResumeFixture.make()
    defer { fixture.remove() }

    let batchID = try await fixture.converter.start(
      scope: .allLocalMedia,
      target: .aacLC(.kbps256)
    )
    try await fixture.transcoder.waitForFirstCall()

    await fixture.converter.pause(id: batchID)
    await fixture.transcoder.releaseFirstCall()
    try await waitUntil {
      guard let snapshot = await fixture.converter.snapshot(id: batchID) else { return false }
      return snapshot.state == .paused && snapshot.completedAssetCount == 1
    }

    let paused = try #require(await fixture.converter.snapshot(id: batchID))
    #expect(paused.totalAssetCount == 2)
    #expect(paused.completedAssetCount == 1)
    #expect(paused.cancelledAssetCount == 0)
    #expect(paused.failedAssetCount == 0)
    #expect(await fixture.transcoder.callCount == 1)

    await fixture.converter.resume(id: batchID)
    let completed = try await waitForTerminalBatch(fixture.converter, id: batchID)
    #expect(completed.state == .completed)
    #expect(completed.totalAssetCount == 2)
    #expect(completed.completedAssetCount == 2)
    #expect(completed.cancelledAssetCount == 0)
    #expect(completed.failedAssetCount == 0)
    #expect(await fixture.transcoder.callCount == 2)
  }

  @Test("Recovery completes an interrupted cancellation without restarting work")
  func recoveryPreservesCancellationIntent() async throws {
    let root = try makeLibraryConversionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try makeLocalMediaConfiguration(root: root)
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: InMemoryLibraryRepository(),
      probe: ConversionProbe(),
      transcoder: CountingAACTranscoder(),
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: ImmediateConversionScheduler()
    )
    let persistence = try ConversionPersistence(configuration: configuration)
    let batchID = UUID()
    let pendingAssetIDs = [1, 2].map {
      MediaAssetID(
        sourceID: .local,
        externalID: "sha256-\(String(repeating: String($0), count: 64))"
      )
    }
    try await persistence.save(LocalMediaLibraryConverter.BatchRecord(
      id: batchID,
      scope: .allLocalMedia,
      target: .aacLC(.kbps256),
      state: .cancelling,
      totalAssetCount: pendingAssetIDs.count,
      completedAssetCount: 0,
      skippedAssetCount: 0,
      cancelledAssetCount: 0,
      failures: [],
      pendingAssetIDs: pendingAssetIDs,
      itemIDsByAsset: [:],
      createdAt: Date(),
      updatedAt: Date()
    ))

    await converter.recover()

    let snapshot = try #require(await converter.snapshot(id: batchID))
    #expect(snapshot.state == .cancelled)
    #expect(snapshot.cancelledAssetCount == 2)
    #expect(snapshot.processedAssetCount == snapshot.totalAssetCount)
    let stored = try #require(try await persistence.loadBatches().first { $0.id == batchID })
    #expect(stored.state == .cancelled)
    #expect(stored.pendingAssetIDs.isEmpty)
  }

  @Test("Concurrent recovery deduplicates assets persisted in multiple batches")
  func concurrentRecoveryDeduplicatesPersistedReservations() async throws {
    let root = try makeLibraryConversionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try makeLocalMediaConfiguration(root: root)
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: InMemoryLibraryRepository(),
      probe: ConversionProbe(),
      transcoder: CountingAACTranscoder(),
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: ImmediateConversionScheduler()
    )
    let persistence = try ConversionPersistence(configuration: configuration)
    let assetID = MediaAssetID(
      sourceID: .local,
      externalID: "sha256-\(String(repeating: "7", count: 64))"
    )
    let earlierID = UUID()
    let laterID = UUID()
    for (id, createdAt) in [
      (earlierID, Date(timeIntervalSince1970: 1)),
      (laterID, Date(timeIntervalSince1970: 2)),
    ] {
      try await persistence.save(LocalMediaLibraryConverter.BatchRecord(
        id: id,
        scope: .allLocalMedia,
        target: .aacLC(.kbps256),
        state: .paused,
        totalAssetCount: 1,
        completedAssetCount: 0,
        skippedAssetCount: 0,
        cancelledAssetCount: 0,
        failures: [],
        pendingAssetIDs: [assetID],
        itemIDsByAsset: [:],
        createdAt: createdAt,
        updatedAt: createdAt
      ))
    }

    await withTaskGroup(of: Void.self) { group in
      group.addTask { await converter.recover() }
      group.addTask { await converter.recover() }
    }

    let earlier = try #require(await converter.snapshot(id: earlierID))
    let later = try #require(await converter.snapshot(id: laterID))
    #expect(earlier.state == .paused)
    #expect(earlier.skippedAssetCount == 0)
    #expect(later.state == .completed)
    #expect(later.skippedAssetCount == 1)
    #expect(later.processedAssetCount == later.totalAssetCount)
  }

  @Test("Concurrent starts reserve each asset for only one batch")
  func concurrentStartsDoNotConvertTheSameAssetTwice() async throws {
    let fixture = try await ConcurrentStartFixture.make()
    defer { fixture.remove() }

    async let firstID = fixture.converter.start(
      scope: .allLocalMedia,
      target: .aacLC(.kbps256)
    )
    async let secondID = fixture.converter.start(
      scope: .allLocalMedia,
      target: .aacLC(.kbps256)
    )
    let batchIDs = [try await firstID, try await secondID]
    try await fixture.transcoder.waitForFirstCall()

    var snapshots: [LibraryConversionBatchSnapshot] = []
    for batchID in batchIDs {
      snapshots.append(try #require(await fixture.converter.snapshot(id: batchID)))
    }
    #expect(snapshots.count(where: { $0.completedAssetCount == 0 && $0.skippedAssetCount == 1 }) == 1)
    #expect(snapshots.count(where: { $0.skippedAssetCount == 0 }) == 1)
    #expect(await fixture.transcoder.callCount == 1)

    await fixture.transcoder.releaseFirstCall()
    for batchID in batchIDs {
      _ = try await waitForTerminalBatch(fixture.converter, id: batchID)
    }
    #expect(await fixture.transcoder.callCount == 1)
  }

  @Test("A failed initial batch save releases its asset reservation")
  func initialPersistenceFailureCanBeRetried() async throws {
    let fixture = try await ConversionFixture.makeSharedAsset()
    defer { fixture.remove() }
    let batchesRoot = fixture.configuration.quarantineRoot
      .appendingPathComponent("conversions/batches", isDirectory: true)
    try FileManager.default.removeItem(at: batchesRoot)
    try Data("blocks-batch-directory".utf8).write(to: batchesRoot)

    await #expect(throws: (any Error).self) {
      _ = try await fixture.converter.start(
        scope: .allLocalMedia,
        target: .aacLC(.kbps256)
      )
    }

    try FileManager.default.removeItem(at: batchesRoot)
    try FileManager.default.createDirectory(at: batchesRoot, withIntermediateDirectories: true)
    let retryID = try await fixture.converter.start(
      scope: .allLocalMedia,
      target: .aacLC(.kbps256)
    )
    let retry = try await waitForTerminalBatch(fixture.converter, id: retryID)
    #expect(retry.completedAssetCount == 1)
    #expect(retry.skippedAssetCount == 0)
  }

  @Test("Every deferred retirement completion runs after the final read lease")
  func deferredRetirementsDoNotOverwriteEachOther() async throws {
    let root = try makeLibraryConversionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    let stagedURL = configuration.stagingRoot.appendingPathComponent("retired.flac")
    try Data("retirement-source".utf8).write(to: stagedURL)
    let hash = try await ContentHasher().hash(fileAt: stagedURL)
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-\(hash)")
    let managedURL = try await coordinator.store.moveToManaged(
      stagedURL: stagedURL,
      externalID: assetID.externalID
    ).url
    let (_, lease) = try await coordinator.mediaAccess.resolveAndAcquire(assetID)
    let completions = RetirementCompletionCounter()

    _ = try await coordinator.mediaAccess.retire(assetID, completion: {
      await completions.record()
    })
    _ = try await coordinator.mediaAccess.retire(assetID, completion: {
      await completions.record()
    })
    lease.release()

    try await waitUntil {
      await completions.count == 2
        && !FileManager.default.fileExists(atPath: managedURL.path)
    }
  }

  @Test("Exclusive managed media mutation rejects new read leases")
  func exclusiveManagedMediaMutationClosesTheRemovalLeaseRace() async throws {
    let root = try makeLibraryConversionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    let stagedURL = configuration.stagingRoot.appendingPathComponent("exclusive.flac")
    try Data("exclusive-source".utf8).write(to: stagedURL)
    let hash = try await ContentHasher().hash(fileAt: stagedURL)
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-\(hash)")
    _ = try await coordinator.store.moveToManaged(
      stagedURL: stagedURL,
      externalID: assetID.externalID
    )
    let gate = ExclusiveAccessTestGate()

    let mutation = Task {
      try await coordinator.mediaAccess.withExclusiveAccess(to: [assetID]) {
        await gate.enterAndWait()
      }
    }
    await gate.waitUntilEntered()

    await #expect(throws: LocalMediaError.itemNotFound) {
      _ = try await coordinator.mediaAccess.resolveAndAcquire(assetID)
    }

    await gate.release()
    try await mutation.value
    let (_, lease) = try await coordinator.mediaAccess.resolveAndAcquire(assetID)
    lease.release()
  }
}

private actor ExclusiveAccessTestGate {
  private var entered = false
  private var released = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func enterAndWait() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    waiters.forEach { $0.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private struct ConcurrentStartFixture {
  let root: URL
  let converter: LocalMediaLibraryConverter
  let transcoder: PausingAACTranscoder

  static func make() async throws -> Self {
    let root = try makeLibraryConversionTestRoot()
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    let stagedURL = configuration.stagingRoot.appendingPathComponent("concurrent.flac")
    try Data("concurrent-source".utf8).write(to: stagedURL)
    let hash = try await ContentHasher().hash(fileAt: stagedURL)
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-\(hash)")
    _ = try await coordinator.store.moveToManaged(
      stagedURL: stagedURL,
      externalID: assetID.externalID
    )
    let track = Track(
      id: MediaItemID(sourceID: .local, externalID: "concurrent-track"),
      assetID: assetID,
      title: "Concurrent Track",
      fileName: "concurrent.flac",
      duration: .seconds(120)
    )
    let transcoder = PausingAACTranscoder()
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: InMemoryLibraryRepository(tracks: [track]),
      probe: RendezvousConversionProbe(),
      transcoder: transcoder,
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: ImmediateConversionScheduler()
    )
    return Self(root: root, converter: converter, transcoder: transcoder)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct PauseResumeFixture {
  let root: URL
  let converter: LocalMediaLibraryConverter
  let transcoder: PausingAACTranscoder

  static func make() async throws -> Self {
    let root = try makeLibraryConversionTestRoot()
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    var tracks: [Track] = []

    for index in 1...2 {
      let stagedURL = configuration.stagingRoot.appendingPathComponent("pause-\(index).flac")
      try Data("pause-input-\(index)".utf8).write(to: stagedURL)
      let hash = try await ContentHasher().hash(fileAt: stagedURL)
      let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-\(hash)")
      _ = try await coordinator.store.moveToManaged(
        stagedURL: stagedURL,
        externalID: assetID.externalID
      )
      tracks.append(Track(
        id: MediaItemID(sourceID: .local, externalID: "pause-track-\(index)"),
        assetID: assetID,
        title: "Pause Track \(index)",
        fileName: "pause-\(index).flac",
        duration: .seconds(120)
      ))
    }

    let transcoder = PausingAACTranscoder()
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: InMemoryLibraryRepository(tracks: tracks),
      probe: ConversionProbe(),
      transcoder: transcoder,
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: SerialConversionScheduler()
    )
    return Self(root: root, converter: converter, transcoder: transcoder)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct ConversionFixture {
  let root: URL
  let configuration: LocalMediaConfiguration
  let repository: InMemoryLibraryRepository
  let converter: LocalMediaLibraryConverter
  let transcoder: CountingAACTranscoder
  let oldAssetID: MediaAssetID
  let oldManagedURL: URL
  let tracks: [Track]

  static func makeSharedAsset() async throws -> Self {
    let root = try makeLibraryConversionTestRoot()
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    let stagedInput = configuration.stagingRoot.appendingPathComponent("shared.flac")
    try Data("shared-lossless-input".utf8).write(to: stagedInput)
    let inputHash = try await ContentHasher().hash(fileAt: stagedInput)
    let oldAssetID = MediaAssetID(
      sourceID: .local,
      externalID: "sha256-\(inputHash)"
    )
    let oldManagedURL = try await coordinator.store.moveToManaged(
      stagedURL: stagedInput,
      externalID: oldAssetID.externalID
    ).url

    let albumID = AlbumID("conversion-album")
    let artistID = ArtistID("conversion-artist")
    let genreID = GenreID("conversion-genre")
    let artwork = ArtworkReference(
      id: ArtworkID("conversion-artwork"),
      variants: [.original],
      preferredVariant: .original
    )
    let statistics = PlaybackStatistics(
      playCount: 9,
      completionCount: 7,
      skipCount: 2,
      lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000),
      totalListeningDuration: .seconds(777)
    )
    let first = Track(
      id: MediaItemID(sourceID: .local, externalID: "conversion-cue-01"),
      logicalTrackID: LogicalTrackID("conversion-logical-01"),
      assetID: oldAssetID,
      playbackSelection: PlaybackSelection(range: PlaybackRange(
        start: .zero,
        end: .seconds(60)
      )),
      title: "User Edited First",
      sortTitle: "First, User Edited",
      albumID: albumID,
      artistIDs: [artistID],
      genreIDs: [genreID],
      trackNumber: 1,
      trackTotal: 2,
      discNumber: 1,
      discTotal: 1,
      fileName: "shared.flac",
      folderPath: "Edited Album",
      duration: .seconds(60),
      year: 2024,
      comment: "Keep this comment",
      artwork: artwork,
      isFavorite: true,
      statistics: statistics,
      details: TrackDetailMetadata(
        composers: ["Composer"],
        additionalArtists: ["Guest"],
        contentRating: .explicit
      )
    )
    let second = Track(
      id: MediaItemID(sourceID: .local, externalID: "conversion-cue-02"),
      logicalTrackID: LogicalTrackID("conversion-logical-02"),
      assetID: oldAssetID,
      playbackSelection: PlaybackSelection(range: PlaybackRange(
        start: .seconds(60),
        end: .seconds(120)
      )),
      title: "Second",
      albumID: albumID,
      artistIDs: [artistID],
      genreIDs: [genreID],
      trackNumber: 2,
      trackTotal: 2,
      discNumber: 1,
      discTotal: 1,
      fileName: "shared.flac",
      duration: .seconds(60)
    )
    let repository = InMemoryLibraryRepository(
      tracks: [first, second],
      albums: [Album(id: albumID, title: "Edited Album", artistIDs: [artistID])],
      artists: [Artist(id: artistID, name: "Edited Artist")],
      genres: [Genre(id: genreID, name: "Edited Genre")]
    )
    try await repository.apply(try LibraryTransaction(
      idempotencyKey: "install-conversion-source-snapshot",
      mutations: [.upsert(.trackVariant(TrackVariant(
        id: first.id,
        logicalTrackID: first.logicalTrackID,
        assetID: oldAssetID,
        selection: first.playbackSelection,
        sourceIdentityHint: "cue-source-identity",
        sourceMetadataRevision: "source-revision",
        sourceMetadata: TrackSourceMetadataSnapshot(track: first)
      )))]
    ))

    let transcoder = CountingAACTranscoder()
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: repository,
      probe: ConversionProbe(),
      transcoder: transcoder,
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: ImmediateConversionScheduler()
    )
    return Self(
      root: root,
      configuration: configuration,
      repository: repository,
      converter: converter,
      transcoder: transcoder,
      oldAssetID: oldAssetID,
      oldManagedURL: oldManagedURL,
      tracks: [first, second]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct RecoveryFixture {
  let root: URL
  let converter: LocalMediaLibraryConverter
  let persistence: ConversionPersistence
  let oldManagedURL: URL
  let newManagedURL: URL

  static func make(
    stage: LocalMediaLibraryConverter.JournalStage
  ) async throws -> Self {
    let root = try makeLibraryConversionTestRoot()
    let configuration = try makeLocalMediaConfiguration(root: root)
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    let oldAssetID = MediaAssetID(
      sourceID: .local,
      externalID: "sha256-\(String(repeating: "1", count: 64))"
    )
    let newAssetID = MediaAssetID(
      sourceID: .local,
      externalID: "sha256-\(String(repeating: "2", count: 64))"
    )
    let oldStagedURL = configuration.stagingRoot.appendingPathComponent("old.flac")
    try Data("old".utf8).write(to: oldStagedURL)
    let oldManagedURL = try await coordinator.store.moveToManaged(
      stagedURL: oldStagedURL,
      externalID: oldAssetID.externalID
    ).url
    let newStagedURL = configuration.stagingRoot.appendingPathComponent("new.m4a")
    try Data("new".utf8).write(to: newStagedURL)
    let newManagedURL = try await coordinator.store.moveToManaged(
      stagedURL: newStagedURL,
      externalID: newAssetID.externalID
    ).url

    let referencedAssetID = stage == .prepared ? oldAssetID : newAssetID
    let track = Track(
      id: MediaItemID(sourceID: .local, externalID: "recovery-track"),
      assetID: referencedAssetID,
      title: "Recovery Track",
      fileName: stage == .prepared ? "old.flac" : "new.m4a"
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let converter = try LocalMediaLibraryConverter(
      configuration: configuration,
      repository: repository,
      probe: ConversionProbe(),
      transcoder: CountingAACTranscoder(),
      losslessValidator: AcceptingLosslessValidator(),
      scheduler: ImmediateConversionScheduler()
    )
    let persistence = try ConversionPersistence(configuration: configuration)
    try await persistence.save(LocalMediaLibraryConverter.ConversionJournal(
      id: UUID(),
      batchID: UUID(),
      oldAssetID: oldAssetID,
      newAssetID: newAssetID,
      stagingRelativePath: "conversions/recovery/output.m4a",
      stage: stage
    ))
    return Self(
      root: root,
      converter: converter,
      persistence: persistence,
      oldManagedURL: oldManagedURL,
      newManagedURL: newManagedURL
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor CountingAACTranscoder: MediaTranscoding {
  private(set) var callCount = 0
  private var lateProgress: (@Sendable (MediaTranscodeProgress) -> Void)?

  func transcode(
    _ request: MediaTranscodeRequest,
    progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
  ) async throws -> MediaTranscodeResult {
    callCount += 1
    lateProgress = progress
    progress(MediaTranscodeProgress(stage: .encoding, completedFrames: 1, totalFrames: 2))
    try Task.checkCancellation()
    try Data("deterministic-aac-output".utf8).write(to: request.outputURL)
    progress(MediaTranscodeProgress(stage: .finalizing, completedFrames: 2, totalFrames: 2))
    return MediaTranscodeResult(
      outputURL: request.outputURL,
      target: request.target,
      processedFrames: 5_292_000,
      sampleRate: 44_100,
      channelCount: 2
    )
  }

  func emitLateProgress() {
    lateProgress?(MediaTranscodeProgress(
      stage: .finalizing,
      completedFrames: 2,
      totalFrames: 2
    ))
  }
}

private actor RetirementCompletionCounter {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private actor RendezvousConversionProbe: MediaProbing {
  private var inputProbeCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    let isOutput = resource.localFileURL?.pathExtension.lowercased() == "m4a"
    if !isOutput {
      inputProbeCount += 1
      if inputProbeCount < 2 {
        await withCheckedContinuation { continuation in
          waiters.append(continuation)
        }
      } else {
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters { waiter.resume() }
      }
    }
    return try await ConversionProbe().probe(resource)
  }
}

private actor PausingAACTranscoder: MediaTranscoding {
  private(set) var callCount = 0
  private var firstCallStarted = false
  private var shouldReleaseFirstCall = false

  func transcode(
    _ request: MediaTranscodeRequest,
    progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
  ) async throws -> MediaTranscodeResult {
    callCount += 1
    if callCount == 1 {
      firstCallStarted = true
      while !shouldReleaseFirstCall {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    progress(MediaTranscodeProgress(stage: .encoding, completedFrames: 1, totalFrames: 2))
    let input = try Data(contentsOf: request.inputURL)
    try (input + Data("-aac".utf8)).write(to: request.outputURL)
    progress(MediaTranscodeProgress(stage: .finalizing, completedFrames: 2, totalFrames: 2))
    return MediaTranscodeResult(
      outputURL: request.outputURL,
      target: request.target,
      processedFrames: 5_292_000,
      sampleRate: 44_100,
      channelCount: 2
    )
  }

  func waitForFirstCall() async throws {
    for _ in 0..<200 {
      if firstCallStarted { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the first conversion to start")
  }

  func releaseFirstCall() {
    shouldReleaseFirstCall = true
  }
}

private actor SerialConversionScheduler: MediaConversionScheduling {
  private var isActive = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) async {}

  func schedule(
    _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
  ) async throws -> MediaTranscodeResult {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    if !isActive {
      isActive = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      isActive = false
      return
    }
    waiters.removeFirst().resume()
  }
}

private struct ConversionProbe: MediaProbing {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    let isOutput = resource.localFileURL?.pathExtension.lowercased() == "m4a"
    return MediaProbeResult(
      audioTracks: [ProbedAudioTrack(
        index: 0,
        stableID: isOutput ? "aac-stream" : "flac-stream",
        codec: isOutput ? "aac" : "flac",
        sampleRate: 44_100,
        channelCount: 2,
        bitDepth: isOutput ? nil : 24,
        bitRate: isOutput ? 256_000 : 900_000,
        isDefault: true,
        isLossless: !isOutput
      )],
      container: isOutput ? "mov,mp4,m4a" : "flac",
      duration: .seconds(120)
    )
  }
}

private struct AcceptingLosslessValidator: MediaLosslessValidating {
  func validateLosslessPCM(inputURL: URL, outputURL: URL) async throws {}
}

private struct ImmediateConversionScheduler: MediaConversionScheduling {
  func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) async {}

  func schedule(
    _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
  ) async throws -> MediaTranscodeResult {
    try await operation()
  }
}

private func waitForTerminalBatch(
  _ converter: LocalMediaLibraryConverter,
  id: UUID
) async throws -> LibraryConversionBatchSnapshot {
  var latest: LibraryConversionBatchSnapshot?
  for _ in 0..<200 {
    latest = await converter.snapshot(id: id)
    if let latest, latest.state == .completed || latest.state == .cancelled {
      return latest
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for conversion batch \(id)")
  return try #require(latest)
}

private func waitUntil(
  _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
  for _ in 0..<200 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for asynchronous resource cleanup")
}

private func makeLocalMediaConfiguration(root: URL) throws -> LocalMediaConfiguration {
  try LocalMediaConfiguration(
    managedRoot: root.appendingPathComponent("managed", isDirectory: true),
    stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
    quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
  )
}

private func makeLibraryConversionTestRoot() throws -> URL {
  var repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
  for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
  let parent = repositoryRoot
    .appendingPathComponent(".noindex/tmp/library-conversion-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}
