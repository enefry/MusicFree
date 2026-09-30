import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

@available(macOS 13.0, iOS 16.0, *)
public actor LocalMediaLibraryConverter: ManagedLibraryConverting {
  struct BatchRecord: Codable, Sendable {
    let id: UUID
    let scope: LibraryConversionScope
    let target: AudioConversionTarget
    var state: LibraryConversionBatchState
    let totalAssetCount: Int
    var completedAssetCount: Int
    var skippedAssetCount: Int
    var cancelledAssetCount: Int
    var failures: [LibraryConversionFailure]
    var pendingAssetIDs: [MediaAssetID]
    let itemIDsByAsset: [MediaAssetID: Set<MediaItemID>]
    let createdAt: Date
    var updatedAt: Date

    func snapshot(
      progress: [MediaAssetID: MediaTranscodeProgress] = [:]
    ) -> LibraryConversionBatchSnapshot {
      LibraryConversionBatchSnapshot(
        id: id,
        scope: scope,
        target: target,
        state: state,
        totalAssetCount: totalAssetCount,
        completedAssetCount: completedAssetCount,
        skippedAssetCount: skippedAssetCount,
        cancelledAssetCount: cancelledAssetCount,
        failures: failures,
        currentProgress: progress,
        createdAt: createdAt,
        updatedAt: updatedAt
      )
    }
  }

  enum JournalStage: String, Codable, Sendable {
    case prepared
    case managed
    case committed
  }

  struct ConversionJournal: Codable, Sendable {
    let id: UUID
    let batchID: UUID
    let oldAssetID: MediaAssetID
    let newAssetID: MediaAssetID
    let stagingRelativePath: String
    var stage: JournalStage
  }

  private enum AssetOutcome: Sendable {
    case completed(MediaAssetID)
    case skipped(MediaAssetID)
    case deferred(MediaAssetID)
    case cancelled(MediaAssetID)
    case failed(MediaAssetID, String)

    var assetID: MediaAssetID {
      switch self {
      case .completed(let id), .skipped(let id), .deferred(let id),
           .cancelled(let id), .failed(let id, _): id
      }
    }
  }

  private struct BatchDeferredError: Error {}

  private let configuration: LocalMediaConfiguration
  private let coordinator: ImportCoordinator
  private let store: ManagedMediaStore
  private let repository: any LibraryRepository
  private let probe: any MediaProbing
  private let transcoder: any MediaTranscoding
  private let losslessValidator: any MediaLosslessValidating
  private let scheduler: any MediaConversionScheduling
  private let hasher: any LocalMediaHashing
  private let persistence: ConversionPersistence

  private var batches: [UUID: BatchRecord] = [:]
  private var progressByBatch: [UUID: [MediaAssetID: MediaTranscodeProgress]] = [:]
  private var batchTasks: [UUID: Task<Void, Never>] = [:]
  private var activeAssetIDs = Set<MediaAssetID>()
  private var eventContinuations: [UUID: AsyncStream<LibraryConversionEvent>.Continuation] = [:]
  private var didRecover = false
  private var recoveryWaiters: [CheckedContinuation<Void, any Error>]?

  public init(
    configuration: LocalMediaConfiguration,
    repository: any LibraryRepository,
    probe: any MediaProbing,
    transcoder: any MediaTranscoding,
    losslessValidator: any MediaLosslessValidating,
    scheduler: any MediaConversionScheduling,
    hasher: (any LocalMediaHashing)? = nil
  ) throws {
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    self.configuration = configuration
    self.coordinator = coordinator
    self.store = coordinator.store
    self.repository = repository
    self.probe = probe
    self.transcoder = transcoder
    self.losslessValidator = losslessValidator
    self.scheduler = scheduler
    self.hasher = hasher ?? ContentHasher()
    persistence = try ConversionPersistence(configuration: configuration)
  }

  public func preflight(
    scope: LibraryConversionScope,
    target: AudioConversionTarget
  ) async throws -> LibraryConversionPreflight {
    try await ensureRecovered()
    return try await buildPreflight(scope: scope, target: target)
  }

  public func start(
    scope: LibraryConversionScope,
    target: AudioConversionTarget
  ) async throws -> UUID {
    try await ensureRecovered()
    let preflight = try await buildPreflight(scope: scope, target: target)
    let preflightEligible = preflight.candidates.filter(\.isEligible)
    let eligible = preflightEligible.filter { !activeAssetIDs.contains($0.assetID) }
    let concurrentlyReservedCount = preflightEligible.count - eligible.count
    let now = Date()
    let id = UUID()
    let record = BatchRecord(
      id: id,
      scope: scope,
      target: target,
      state: eligible.isEmpty ? .completed : .queued,
      totalAssetCount: preflight.candidates.count,
      completedAssetCount: 0,
      skippedAssetCount: preflight.skippedAssetCount + concurrentlyReservedCount,
      cancelledAssetCount: 0,
      failures: [],
      pendingAssetIDs: eligible.map(\.assetID),
      itemIDsByAsset: Dictionary(uniqueKeysWithValues: eligible.map { ($0.assetID, $0.itemIDs) }),
      createdAt: now,
      updatedAt: now
    )
    batches[id] = record
    activeAssetIDs.formUnion(record.pendingAssetIDs)
    do {
      try await persistence.save(record)
    } catch {
      batches[id] = nil
      progressByBatch[id] = nil
      activeAssetIDs.subtract(record.pendingAssetIDs)
      throw error
    }
    publish(record.snapshot())
    if !eligible.isEmpty { launchBatch(id) }
    return id
  }

  public func snapshots() async -> [LibraryConversionBatchSnapshot] {
    try? await ensureRecovered()
    return batches.values.map {
      $0.snapshot(progress: progressByBatch[$0.id] ?? [:])
    }.sorted { $0.createdAt > $1.createdAt }
  }

  public func snapshot(id: UUID) async -> LibraryConversionBatchSnapshot? {
    try? await ensureRecovered()
    return batches[id]?.snapshot(progress: progressByBatch[id] ?? [:])
  }

  public func pause(id: UUID) async {
    guard var record = batches[id], record.state == .running || record.state == .queued else {
      return
    }
    record.state = .paused
    record.updatedAt = Date()
    batches[id] = record
    try? await persistence.save(record)
    publish(record.snapshot(progress: progressByBatch[id] ?? [:]))
  }

  public func resume(id: UUID) async {
    guard var record = batches[id], record.state == .paused else { return }
    record.state = batchTasks[id] == nil ? .queued : .running
    record.updatedAt = Date()
    batches[id] = record
    try? await persistence.save(record)
    publish(record.snapshot(progress: progressByBatch[id] ?? [:]))
    if batchTasks[id] == nil { launchBatch(id) }
  }

  public func cancel(id: UUID) async {
    guard var record = batches[id],
          record.state == .queued || record.state == .running || record.state == .paused
    else { return }
    record.state = .cancelling
    record.updatedAt = Date()
    batches[id] = record
    try? await persistence.save(record)
    publish(record.snapshot(progress: progressByBatch[id] ?? [:]))
    batchTasks[id]?.cancel()
    if batchTasks[id] == nil { await finishCancelledBatch(id) }
  }

  public func retryFailures(id: UUID) async throws -> UUID {
    try await ensureRecovered()
    guard let record = batches[id], !record.failures.isEmpty else {
      throw MediaTranscodeError.unsupportedInput
    }
    let failedIDs = Set(record.failures.map(\.assetID))
    let itemIDs = record.itemIDsByAsset
      .filter { failedIDs.contains($0.key) }
      .values.reduce(into: Set<MediaItemID>()) { $0.formUnion($1) }
    guard !itemIDs.isEmpty else { throw MediaTranscodeError.unsupportedInput }
    return try await start(scope: .items(itemIDs), target: record.target)
  }

  public func recover() async {
    try? await ensureRecovered()
  }

  public func makeEventStream() async -> AsyncStream<LibraryConversionEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<LibraryConversionEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    eventContinuations[id] = continuation
    continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.removeEventContinuation(id) }
    }
    return stream
  }

  private func ensureRecovered() async throws {
    guard !didRecover else { return }
    if recoveryWaiters != nil {
      try await withCheckedThrowingContinuation { continuation in
        recoveryWaiters?.append(continuation)
      }
      return
    }

    recoveryWaiters = []
    do {
      try await performRecovery()
      didRecover = true
      let waiters = recoveryWaiters ?? []
      recoveryWaiters = nil
      for waiter in waiters { waiter.resume() }
    } catch {
      let waiters = recoveryWaiters ?? []
      recoveryWaiters = nil
      for waiter in waiters { waiter.resume(throwing: error) }
      throw error
    }
  }

  private func performRecovery() async throws {
    let stored = try await persistence.loadBatches().sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
    for var record in stored {
      var needsSave = false
      if record.state == .running {
        record.state = .queued
        record.updatedAt = Date()
        needsSave = true
      } else if record.state == .cancelling {
        record.cancelledAssetCount += record.pendingAssetIDs.count
        record.pendingAssetIDs.removeAll()
        record.state = .cancelled
        record.updatedAt = Date()
        needsSave = true
      }
      if record.state == .queued || record.state == .paused {
        let reservedElsewhere = record.pendingAssetIDs.filter(activeAssetIDs.contains)
        if !reservedElsewhere.isEmpty {
          let reservedSet = Set(reservedElsewhere)
          record.pendingAssetIDs.removeAll { reservedSet.contains($0) }
          record.skippedAssetCount += reservedElsewhere.count
          record.updatedAt = Date()
          if record.pendingAssetIDs.isEmpty {
            record.state = .completed
          }
          needsSave = true
        }
        activeAssetIDs.formUnion(record.pendingAssetIDs)
      }
      if needsSave { try await persistence.save(record) }
      batches[record.id] = record
    }
    try await recoverJournals()
    for record in batches.values where record.state == .queued {
      launchBatch(record.id)
    }
  }

  private func recoverJournals() async throws {
    for var journal in try await persistence.loadJournals() {
      let oldReferenced = try await repository.isMediaAssetReferenced(
        journal.oldAssetID,
        excluding: []
      )
      let newReferenced = try await repository.isMediaAssetReferenced(
        journal.newAssetID,
        excluding: []
      )
      switch journal.stage {
      case .prepared:
        if newReferenced && !oldReferenced {
          journal.stage = .committed
          try await persistence.save(journal)
          try await retireOldAsset(for: journal)
        } else {
          if !newReferenced {
            try? await store.removeManagedAsset(forExternalID: journal.newAssetID.externalID)
          }
          await removeStagedOutput(journal)
          try await persistence.removeJournal(journal.id)
        }
      case .managed:
        if newReferenced && !oldReferenced {
          journal.stage = .committed
          try await persistence.save(journal)
          try await retireOldAsset(for: journal)
        } else {
          if !newReferenced {
            try? await store.removeManagedAsset(forExternalID: journal.newAssetID.externalID)
          }
          await removeStagedOutput(journal)
          try await persistence.removeJournal(journal.id)
        }
      case .committed:
        if newReferenced && !oldReferenced {
          try await retireOldAsset(for: journal)
        } else if !newReferenced {
          try? await store.removeManagedAsset(forExternalID: journal.newAssetID.externalID)
          try await persistence.removeJournal(journal.id)
        } else {
          try await persistence.removeJournal(journal.id)
        }
      }
    }
  }

  private func buildPreflight(
    scope: LibraryConversionScope,
    target: AudioConversionTarget
  ) async throws -> LibraryConversionPreflight {
    let selectedAssetIDs: Set<MediaAssetID>
    switch scope {
    case .allLocalMedia:
      selectedAssetIDs = Set(try await repository.mediaAssets()
        .map(\.id).filter { $0.sourceID == .local })
    case .items(let itemIDs):
      var values = Set<MediaAssetID>()
      for itemID in itemIDs where itemID.sourceID == .local {
        if let track = try await repository.track(id: itemID) {
          values.insert(track.assetID)
        } else if let variant = try await repository.trackVariant(id: itemID) {
          values.insert(variant.assetID)
        }
      }
      selectedAssetIDs = values
    }

    var candidates: [LibraryConversionCandidate] = []
    for assetID in selectedAssetIDs.sorted() {
      try Task.checkCancellation()
      let variants = try await repository.trackVariants(referencing: assetID)
      let itemIDs = Set(variants.map(\.id))
      guard assetID.sourceID == .local, !itemIDs.isEmpty else {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          skipReason: assetID.sourceID == .local ? .unsupportedAudio : .nonLocal
        ))
        continue
      }
      if activeAssetIDs.contains(assetID) {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          skipReason: .alreadyInProgress
        ))
        continue
      }

      let url: URL
      let lease: MediaResourceReadLease
      do {
        (url, lease) = try await coordinator.mediaAccess.resolveAndAcquire(assetID)
      } catch {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          skipReason: .missingResource
        ))
        continue
      }
      defer { lease.release() }

      let values = try? url.resourceValues(forKeys: [.fileSizeKey])
      let byteCount = values?.fileSize.map(Int64.init)
      let sourceProbe: MediaProbeResult
      do {
        sourceProbe = try await probe.probe(.leasedLocalFile(url, lease)).validated()
      } catch {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          sourceByteCount: byteCount,
          skipReason: .unsupportedAudio
        ))
        continue
      }
      guard let track = preferredTrack(in: sourceProbe), track.isLossless else {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          sourceByteCount: byteCount,
          skipReason: .lossySource
        ))
        continue
      }
      if LocalAudioConversionEligibility.isAlreadyTarget(track, target: target) {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          sourceByteCount: byteCount,
          skipReason: .alreadyTargetFormat
        ))
        continue
      }
      guard LocalAudioConversionEligibility.isSupported(track, target: target) else {
        candidates.append(LibraryConversionCandidate(
          assetID: assetID,
          itemIDs: itemIDs,
          sourceByteCount: byteCount,
          skipReason: .unsupportedAudio
        ))
        continue
      }
      candidates.append(LibraryConversionCandidate(
        assetID: assetID,
        itemIDs: itemIDs,
        sourceByteCount: byteCount,
        estimatedOutputByteCount: estimateOutputBytes(
          sourceBytes: byteCount,
          duration: sourceProbe.duration,
          target: target
        )
      ))
    }
    return LibraryConversionPreflight(scope: scope, target: target, candidates: candidates)
  }

  private func launchBatch(_ id: UUID) {
    guard batchTasks[id] == nil else { return }
    batchTasks[id] = Task { [weak self] in
      await self?.runBatch(id)
    }
  }

  private func runBatch(_ id: UUID) async {
    defer {
      batchTasks[id] = nil
      if batches[id]?.state == .queued {
        launchBatch(id)
      }
    }
    guard var record = batches[id], !record.pendingAssetIDs.isEmpty else {
      await finishBatchIfNeeded(id)
      return
    }
    if record.state == .queued {
      record.state = .running
      record.updatedAt = Date()
      batches[id] = record
      try? await persistence.save(record)
      publish(record.snapshot(progress: progressByBatch[id] ?? [:]))
    }

    let maximumPrefetchedTasks = MediaConversionConcurrency.four.rawValue
    await withTaskGroup(of: AssetOutcome.self) { group in
      var nextIndex = 0
      var runningCount = 0

      func add(_ assetID: MediaAssetID) {
        runningCount += 1
        group.addTask { [weak self] in
          guard let self else { return .cancelled(assetID) }
          return await self.convertAsset(assetID, batchID: id)
        }
      }

      while nextIndex < record.pendingAssetIDs.count,
            runningCount < maximumPrefetchedTasks,
            batches[id]?.state == .running,
            !Task.isCancelled {
        add(record.pendingAssetIDs[nextIndex])
        nextIndex += 1
      }

      while runningCount > 0 {
        guard let outcome = await group.next() else { break }
        runningCount -= 1
        await recordOutcome(outcome, batchID: id)

        if batches[id]?.state == .paused {
          continue
        }
        guard batches[id]?.state == .running, !Task.isCancelled else {
          group.cancelAll()
          continue
        }
        if nextIndex < record.pendingAssetIDs.count {
          add(record.pendingAssetIDs[nextIndex])
          nextIndex += 1
        }
      }
      if Task.isCancelled { group.cancelAll() }
    }

    let finalState = batches[id]?.state
    if Task.isCancelled || finalState == .cancelling {
      await finishCancelledBatch(id)
    } else if finalState == .paused {
      return
    } else if batches[id]?.pendingAssetIDs.isEmpty == true {
      await finishBatchIfNeeded(id)
    } else if var remaining = batches[id] {
      remaining.state = .queued
      remaining.updatedAt = Date()
      batches[id] = remaining
      try? await persistence.save(remaining)
      publish(remaining.snapshot(progress: progressByBatch[id] ?? [:]))
    }
  }

  private func convertAsset(_ assetID: MediaAssetID, batchID: UUID) async -> AssetOutcome {
    guard let target = batches[batchID]?.target else { return .cancelled(assetID) }
    do {
      return try await coordinator.contentGate.withLock(for: assetID.externalID) {
        try await self.performConversion(assetID, batchID: batchID, target: target)
      }
    } catch is BatchDeferredError {
      return .deferred(assetID)
    } catch is CancellationError {
      return .cancelled(assetID)
    } catch {
      return .failed(assetID, Self.failureCode(error))
    }
  }

  private func performConversion(
    _ oldAssetID: MediaAssetID,
    batchID: UUID,
    target: AudioConversionTarget
  ) async throws -> AssetOutcome {
    try Task.checkCancellation()
    let acquired = await coordinator.maintenanceGate.enterImport()
    guard acquired else { throw CancellationError() }

    do {
      let outcome = try await performConversionWithMaintenanceAccess(
        oldAssetID,
        batchID: batchID,
        target: target
      )
      await coordinator.maintenanceGate.leaveImport()
      return outcome
    } catch {
      await coordinator.maintenanceGate.leaveImport()
      throw error
    }
  }

  private func performConversionWithMaintenanceAccess(
    _ oldAssetID: MediaAssetID,
    batchID: UUID,
    target: AudioConversionTarget
  ) async throws -> AssetOutcome {
    guard let oldAsset = try await repository.mediaAsset(id: oldAssetID) else {
      return .skipped(oldAssetID)
    }
    let (inputURL, inputLease) = try await coordinator.mediaAccess.resolveAndAcquire(oldAssetID)
    defer { inputLease.release() }
    let inputHash = try await hasher.hash(fileAt: inputURL).lowercased()
    let sourceProbe = try await probe.probe(.leasedLocalFile(inputURL, inputLease)).validated()
    guard let sourceTrack = preferredTrack(in: sourceProbe),
          sourceTrack.isLossless,
          LocalAudioConversionEligibility.isSupported(sourceTrack, target: target)
    else {
      return .skipped(oldAssetID)
    }
    if LocalAudioConversionEligibility.isAlreadyTarget(sourceTrack, target: target) {
      return .skipped(oldAssetID)
    }

    let outputRelativePath = "conversions/\(batchID.uuidString)/\(UUID().uuidString).m4a"
    let outputURL = configuration.stagingRoot.appendingPathComponent(outputRelativePath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let result = try await scheduler.schedule {
      try await self.requireRunningBatch(batchID)
      return try await self.transcoder.transcode(
        MediaTranscodeRequest(
          inputURL: inputURL,
          outputURL: outputURL,
          target: target,
          sourceTrack: sourceTrack,
          sourceDuration: sourceProbe.duration
        ),
        progress: { progress in
          Task { await self.updateProgress(progress, assetID: oldAssetID, batchID: batchID) }
        }
      )
    }
    try Task.checkCancellation()
    let outputProbe = try await probe.probe(.localFile(result.outputURL)).validated()
    guard let outputTrack = preferredTrack(in: outputProbe),
          outputTrack.channelCount == sourceTrack.channelCount,
          expectedCodec(outputTrack.codec, target: target),
          durationsAreCompatible(sourceProbe.duration, outputProbe.duration)
    else {
      throw MediaTranscodeError.validationFailed
    }
    if case .alac = target {
      try await losslessValidator.validateLosslessPCM(
        inputURL: inputURL,
        outputURL: result.outputURL
      )
    }

    let managedHash = try await hasher.hash(fileAt: result.outputURL).lowercased()
    guard managedHash.count == 64, managedHash.allSatisfy(\.isHexDigit) else {
      throw LocalMediaError.hashingFailed
    }
    let newAssetID = MediaAssetID(sourceID: .local, externalID: "sha256-\(managedHash)")
    let journalID = UUID()
    var journal = ConversionJournal(
      id: journalID,
      batchID: batchID,
      oldAssetID: oldAssetID,
      newAssetID: newAssetID,
      stagingRelativePath: outputRelativePath,
      stage: .prepared
    )
    try await persistence.save(journal)

    let managedURL: URL
    if let existing = try await store.existingMediaURL(forExternalID: newAssetID.externalID) {
      let existingHash = try await hasher.hash(fileAt: existing).lowercased()
      guard existingHash == managedHash else { throw LocalMediaError.destinationConflict }
      managedURL = existing
    } else {
      managedURL = try await store.moveToManaged(
        stagedURL: result.outputURL,
        externalID: newAssetID.externalID
      ).url
    }
    journal.stage = .managed
    try await persistence.save(journal)

    let byteCount = Int64((try managedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let technicalInfo = makeTechnicalInfo(
      probe: outputProbe,
      fileSize: byteCount
    )
    let conversion = makeConversion(
      oldAsset: oldAsset,
      inputHash: inputHash,
      sourceTrack: sourceTrack,
      result: result,
      target: target
    )
    let newAsset = MediaAsset(
      id: newAssetID,
      contentRevision: managedHash,
      fileName: convertedFileName(oldAsset.fileName),
      folderPath: oldAsset.folderPath,
      byteCount: byteCount,
      technicalInfo: technicalInfo,
      conversion: conversion
    )
    try await commitReplacement(
      oldAssetID: oldAssetID,
      newAsset: newAsset,
      outputProbe: outputProbe,
      batchID: batchID
    )
    journal.stage = .committed
    try await persistence.save(journal)
    try await retireOldAsset(for: journal)
    updateProgress(nil, assetID: oldAssetID, batchID: batchID)
    return .completed(oldAssetID)
  }

  private func commitReplacement(
    oldAssetID: MediaAssetID,
    newAsset: MediaAsset,
    outputProbe: MediaProbeResult,
    batchID: UUID
  ) async throws {
    for attempt in 0..<3 {
      try Task.checkCancellation()
      let variants = try await repository.trackVariants(referencing: oldAssetID)
      guard !variants.isEmpty else { throw MediaTranscodeError.validationFailed }
      var mutations: [LibraryMutation] = [.upsert(.mediaAsset(newAsset))]
      let outputSelection = preferredSelection(in: outputProbe)
      for variant in variants {
        let selection = PlaybackSelection(
          range: variant.selection.range,
          audioStream: outputSelection
        )
        if let track = try await repository.track(id: variant.id), track.assetID == oldAssetID {
          mutations.append(.upsert(.track(replacing(
            track,
            assetID: newAsset.id,
            selection: selection,
            technicalInfo: newAsset.technicalInfo,
            fileName: newAsset.fileName
          ))))
        }
        mutations.append(.upsert(.trackVariant(TrackVariant(
          id: variant.id,
          logicalTrackID: variant.logicalTrackID,
          assetID: newAsset.id,
          selection: selection,
          availability: variant.availability,
          sourceIdentityHint: variant.sourceIdentityHint,
          sourceMetadataRevision: variant.sourceMetadataRevision,
          sourceMetadata: variant.sourceMetadata
        ))))
      }
      let revision = try await repository.currentRevision()
      let transaction = try LibraryTransaction(
        idempotencyKey: "library-conversion-\(batchID.uuidString)-\(oldAssetID.externalID)-\(attempt)",
        expectedRevision: revision,
        mutations: mutations
      )
      do {
        try await repository.apply(transaction)
        return
      } catch let error as LibraryError where error.isRetryable && attempt < 2 {
        continue
      }
    }
    throw MediaTranscodeError.validationFailed
  }

  private func retireOldAsset(for journal: ConversionJournal) async throws {
    guard journal.oldAssetID != journal.newAssetID else {
      try await persistence.removeJournal(journal.id)
      return
    }
    _ = try await coordinator.mediaAccess.retire(
      journal.oldAssetID,
      if: {
        !(try await self.repository.isMediaAssetReferenced(
          journal.oldAssetID,
          excluding: []
        ))
      },
      completion: {
        try? await self.persistence.removeJournal(journal.id)
      }
    )
  }

  private func recordOutcome(_ outcome: AssetOutcome, batchID: UUID) async {
    guard var record = batches[batchID] else { return }
    if case .deferred(let assetID) = outcome {
      progressByBatch[batchID]?[assetID] = nil
      publish(record.snapshot(progress: progressByBatch[batchID] ?? [:]))
      return
    }
    record.pendingAssetIDs.removeAll { $0 == outcome.assetID }
    activeAssetIDs.remove(outcome.assetID)
    progressByBatch[batchID]?[outcome.assetID] = nil
    switch outcome {
    case .completed:
      record.completedAssetCount += 1
    case .skipped:
      record.skippedAssetCount += 1
    case .deferred:
      break
    case .cancelled:
      record.cancelledAssetCount += 1
    case .failed(let assetID, let code):
      record.failures.append(LibraryConversionFailure(assetID: assetID, code: code))
    }
    record.updatedAt = Date()
    batches[batchID] = record
    try? await persistence.save(record)
    publish(record.snapshot(progress: progressByBatch[batchID] ?? [:]))
  }

  private func finishBatchIfNeeded(_ id: UUID) async {
    guard var record = batches[id], record.pendingAssetIDs.isEmpty else { return }
    record.state = .completed
    record.updatedAt = Date()
    batches[id] = record
    try? await persistence.save(record)
    publish(record.snapshot(progress: progressByBatch[id] ?? [:]))
  }

  private func finishCancelledBatch(_ id: UUID) async {
    guard var record = batches[id] else { return }
    let remaining = record.pendingAssetIDs.count
    record.cancelledAssetCount += remaining
    activeAssetIDs.subtract(record.pendingAssetIDs)
    record.pendingAssetIDs.removeAll()
    record.state = .cancelled
    record.updatedAt = Date()
    batches[id] = record
    progressByBatch[id] = nil
    try? await persistence.save(record)
    publish(record.snapshot())
  }

  private func updateProgress(
    _ progress: MediaTranscodeProgress?,
    assetID: MediaAssetID,
    batchID: UUID
  ) {
    guard let record = batches[batchID], record.pendingAssetIDs.contains(assetID) else {
      progressByBatch[batchID]?[assetID] = nil
      return
    }
    if let progress {
      progressByBatch[batchID, default: [:]][assetID] = progress
    } else {
      progressByBatch[batchID]?[assetID] = nil
    }
    publish(record.snapshot(progress: progressByBatch[batchID] ?? [:]))
  }

  private func requireRunningBatch(_ id: UUID) throws {
    guard let state = batches[id]?.state else { throw CancellationError() }
    switch state {
    case .running:
      return
    case .paused, .queued:
      throw BatchDeferredError()
    case .cancelling, .completed, .cancelled:
      throw CancellationError()
    }
  }

  private func publish(_ snapshot: LibraryConversionBatchSnapshot) {
    for continuation in eventContinuations.values {
      continuation.yield(.updated(snapshot))
    }
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations[id] = nil
  }

  private func removeStagedOutput(_ journal: ConversionJournal) async {
    let url = configuration.stagingRoot.appendingPathComponent(journal.stagingRelativePath)
    guard Self.isContained(url, in: configuration.stagingRoot) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private nonisolated func preferredTrack(in probe: MediaProbeResult) -> ProbedAudioTrack? {
    probe.decodableAudioTracks.first(where: \.isDefault)
      ?? probe.decodableAudioTracks.first
  }

  private nonisolated func preferredSelection(in probe: MediaProbeResult) -> AudioStreamSelection? {
    preferredTrack(in: probe).map {
      AudioStreamSelection(
        streamID: $0.stableID.map { AudioStreamID(rawValue: $0) },
        fallbackSignature: AudioStreamSignature(
          language: $0.language,
          title: $0.title,
          codec: $0.codec,
          channelCount: $0.channelCount,
          indexHint: $0.index
        )
      )
    }
  }

  private nonisolated func estimateOutputBytes(
    sourceBytes: Int64?,
    duration: Duration?,
    target: AudioConversionTarget
  ) -> Int64? {
    switch target {
    case .aacLC(let bitRate):
      guard let duration else { return nil }
      let seconds = Self.durationSeconds(duration)
      guard seconds.isFinite, seconds >= 0 else { return nil }
      return Int64((seconds * Double(bitRate.rawValue) / 8 * 1.03).rounded(.up))
    case .alac:
      return sourceBytes.map { Int64((Double($0) * 1.2).rounded(.up)) }
    }
  }

  private nonisolated func expectedCodec(
    _ codec: String?,
    target: AudioConversionTarget
  ) -> Bool {
    guard let codec = codec?.lowercased() else { return false }
    switch target {
    case .alac: return codec == "alac"
    case .aacLC: return codec == "aac"
    }
  }

  private nonisolated func durationsAreCompatible(
    _ source: Duration?,
    _ output: Duration?
  ) -> Bool {
    guard let source, let output else { return true }
    let seconds = Self.durationSeconds(source)
    return abs(seconds - Self.durationSeconds(output)) <= max(0.1, seconds * 0.005)
  }

  private nonisolated func makeTechnicalInfo(
    probe: MediaProbeResult,
    fileSize: Int64
  ) -> MediaTechnicalInfo {
    let streams = probe.decodableAudioTracks.map {
      AudioStreamInfo(
        streamID: $0.stableID.map { AudioStreamID(rawValue: $0) },
        indexHint: $0.index,
        language: $0.language,
        title: $0.title,
        isDefault: $0.isDefault,
        codec: $0.codec,
        sampleRate: $0.sampleRate.map { Int($0.rounded()) },
        bitDepth: $0.bitDepth,
        channels: $0.channelCount,
        channelLayout: $0.channelCount.map { ChannelLayout(channelCount: $0) },
        bitRate: $0.bitRate
      )
    }
    let bitRates = streams.compactMap { $0.bitRate }
    return MediaTechnicalInfo(
      container: probe.container,
      codec: streams.first?.codec,
      duration: probe.duration,
      audioStreams: streams,
      bitRate: bitRates.isEmpty ? nil : bitRates.reduce(0, +),
      fileSizeBytes: fileSize
    )
  }

  private nonisolated func makeConversion(
    oldAsset: MediaAsset,
    inputHash: String,
    sourceTrack: ProbedAudioTrack,
    result: MediaTranscodeResult,
    target: AudioConversionTarget
  ) -> MediaAssetConversion {
    let codec: MediaAssetConversionCodec
    let bitRate: Int?
    switch target {
    case .alac:
      codec = .alac
      bitRate = nil
    case .aacLC(let value):
      codec = .aacLC
      bitRate = value.rawValue
    }
    return MediaAssetConversion(
      sourceHash: oldAsset.conversion?.sourceHash ?? inputHash,
      inputHash: inputHash,
      sourceFileName: oldAsset.conversion?.sourceFileName ?? oldAsset.fileName,
      sourceCodec: sourceTrack.codec,
      targetCodec: codec,
      requestedBitRate: bitRate,
      outputSampleRate: result.sampleRate,
      outputChannelCount: result.channelCount,
      outputBitDepth: result.bitDepth
    )
  }

  private nonisolated func replacing(
    _ track: Track,
    assetID: MediaAssetID,
    selection: PlaybackSelection,
    technicalInfo: MediaTechnicalInfo?,
    fileName: String?
  ) -> Track {
    Track(
      id: track.id,
      logicalTrackID: track.logicalTrackID,
      assetID: assetID,
      playbackSelection: selection,
      title: track.title,
      sortTitle: track.sortTitle,
      albumID: track.albumID,
      artistIDs: track.artistIDs,
      genreIDs: track.genreIDs,
      trackNumber: track.trackNumber,
      trackTotal: track.trackTotal,
      discNumber: track.discNumber,
      discTotal: track.discTotal,
      fileName: fileName,
      folderPath: track.folderPath,
      duration: track.duration,
      technicalInfo: technicalInfo,
      year: track.year,
      comment: track.comment,
      lyrics: track.lyrics,
      artwork: track.artwork,
      isFavorite: track.isFavorite,
      statistics: track.statistics,
      details: track.details
    )
  }

  private nonisolated func convertedFileName(_ value: String?) -> String? {
    guard let value else { return nil }
    return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent + ".m4a"
  }

  private nonisolated static func failureCode(_ error: Error) -> String {
    if let error = error as? MediaTranscodeError { return "transcode.\(error.rawValue)" }
    if let error = error as? LocalMediaError { return "local.\(error.diagnosticCode)" }
    if let error = error as? LibraryError { return error.diagnosticCode }
    return "conversion.failed"
  }

  private nonisolated static func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }

  private nonisolated static func isContained(_ candidate: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }
}

actor ConversionPersistence {
  private let root: URL
  private let batchesRoot: URL
  private let journalsRoot: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  init(configuration: LocalMediaConfiguration) throws {
    root = configuration.quarantineRoot.appendingPathComponent("conversions", isDirectory: true)
    batchesRoot = root.appendingPathComponent("batches", isDirectory: true)
    journalsRoot = root.appendingPathComponent("journals", isDirectory: true)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try FileManager.default.createDirectory(at: batchesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: journalsRoot, withIntermediateDirectories: true)
  }

  func save<T: Encodable & Sendable>(_ value: T) throws {
    let id: UUID
    let directory: URL
    if let batch = value as? LocalMediaLibraryConverter.BatchRecord {
      id = batch.id
      directory = batchesRoot
    } else if let journal = value as? LocalMediaLibraryConverter.ConversionJournal {
      id = journal.id
      directory = journalsRoot
    } else {
      throw LocalMediaError.persistenceFailed
    }
    try encoder.encode(value).write(
      to: directory.appendingPathComponent(id.uuidString + ".json"),
      options: [.atomic]
    )
  }

  func loadBatches() throws -> [LocalMediaLibraryConverter.BatchRecord] {
    try load(LocalMediaLibraryConverter.BatchRecord.self, from: batchesRoot)
  }

  func loadJournals() throws -> [LocalMediaLibraryConverter.ConversionJournal] {
    try load(LocalMediaLibraryConverter.ConversionJournal.self, from: journalsRoot)
  }

  func removeJournal(_ id: UUID) throws {
    let url = journalsRoot.appendingPathComponent(id.uuidString + ".json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func load<T: Decodable>(_ type: T.Type, from directory: URL) throws -> [T] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
      else { return nil }
      return try decoder.decode(type, from: Data(contentsOf: url))
    }
  }
}
