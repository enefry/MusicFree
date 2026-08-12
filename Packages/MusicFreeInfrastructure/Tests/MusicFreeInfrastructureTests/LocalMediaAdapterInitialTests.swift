import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import MediaSourceAPI
import MusicDomain
import SettingsAPI
import Testing
@testable import LocalMediaAdapter

struct LocalMediaAdapterInitialTests {
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

private final actor InMemoryLibraryRepository: LibraryRepository {
  private var tracks: [MediaItemID: Track] = [:]
  private var applyAttempts = 0
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
    for mutation in transaction.mutations {
      guard case .upsert(.track(let track)) = mutation else { continue }
      tracks[track.id] = track
    }
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

private func onlyElement<Element>(in elements: [Element]) -> Element? {
  elements.count == 1 ? elements[0] : nil
}

private enum TestError: Error {
  case invalidManifest
  case missingTerminalEvent
}
