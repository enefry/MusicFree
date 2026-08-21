import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

/// Owns the cancellation handle for one import without relying on the order
/// in which a newly-created Task is scheduled. The handle is installed in the
/// registry before the task starts doing file work, so an immediate cancel is
/// still observed by the task.
private final class ImportOperationHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancellationRequested = false

  func attach(_ task: Task<Void, Never>) {
    lock.lock()
    self.task = task
    let shouldCancel = cancellationRequested
    lock.unlock()

    if shouldCancel {
      task.cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}

fileprivate actor ImportSessionRegistry {
  enum Reservation {
    case reserved
    case alreadyRunning
    case cancelledBeforeStart
  }

  private var sessions: [UUID: ImportOperationHandle] = [:]
  private var cancelledBeforeStart: Set<UUID> = []

  func reserve(_ importID: UUID, handle: ImportOperationHandle) -> Reservation {
    guard sessions[importID] == nil else { return .alreadyRunning }
    if cancelledBeforeStart.remove(importID) != nil {
      return .cancelledBeforeStart
    }
    sessions[importID] = handle
    return .reserved
  }

  func cancel(_ importID: UUID, handle expectedHandle: ImportOperationHandle? = nil) {
    if let session = sessions[importID] {
      guard expectedHandle == nil || session === expectedHandle else { return }
      session.cancel()
    } else if expectedHandle == nil {
      cancelledBeforeStart.insert(importID)
    }
  }

  func remove(_ importID: UUID, handle: ImportOperationHandle) {
    guard sessions[importID] === handle else { return }
    sessions[importID] = nil
  }
}

/// Allows imports to remain concurrent while giving staging maintenance an
/// exclusive window. Waiting maintenance has priority so new imports cannot
/// indefinitely postpone startup pruning.
actor ImportMaintenanceGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var activeImportCount = 0
  private var maintenanceIsActive = false
  private var waitingImports: [Waiter] = []
  private var waitingMaintenance: [Waiter] = []

  func enterImport() async -> Bool {
    guard !Task.isCancelled else { return false }
    if !maintenanceIsActive, waitingMaintenance.isEmpty {
      activeImportCount += 1
      return true
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: false)
        } else {
          waitingImports.append(
            Waiter(id: waiterID, continuation: continuation)
          )
        }
      }
    } onCancel: {
      Task { await self.cancelImportWaiter(waiterID) }
    }
  }

  func leaveImport() {
    precondition(activeImportCount > 0)
    activeImportCount -= 1
    guard activeImportCount == 0,
          !maintenanceIsActive,
          !waitingMaintenance.isEmpty
    else { return }
    maintenanceIsActive = true
    waitingMaintenance.removeFirst().continuation.resume(returning: true)
  }

  func enterMaintenance() async -> Bool {
    guard !Task.isCancelled else { return false }
    if activeImportCount == 0, !maintenanceIsActive {
      maintenanceIsActive = true
      return true
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: false)
        } else {
          waitingMaintenance.append(
            Waiter(id: waiterID, continuation: continuation)
          )
        }
      }
    } onCancel: {
      Task { await self.cancelMaintenanceWaiter(waiterID) }
    }
  }

  func leaveMaintenance() {
    precondition(maintenanceIsActive)
    if !waitingMaintenance.isEmpty {
      waitingMaintenance.removeFirst().continuation.resume(returning: true)
      return
    }

    maintenanceIsActive = false
    let imports = waitingImports
    waitingImports.removeAll()
    activeImportCount += imports.count
    for waiter in imports {
      waiter.continuation.resume(returning: true)
    }
  }

  private func cancelImportWaiter(_ id: UUID) {
    guard let index = waitingImports.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = waitingImports.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  private func cancelMaintenanceWaiter(_ id: UUID) {
    guard let index = waitingMaintenance.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = waitingMaintenance.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}

struct ImportCoordinatorKey: Hashable {
  let managedRoot: String
  let stagingRoot: String
  let quarantineRoot: String

  init(configuration: LocalMediaConfiguration) {
    managedRoot = Self.canonicalPath(configuration.managedRoot)
    stagingRoot = Self.canonicalPath(configuration.stagingRoot)
    quarantineRoot = Self.canonicalPath(configuration.quarantineRoot)
  }

  private static func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }
}

final class ImportCoordinator: @unchecked Sendable {
  let store: ManagedMediaStore
  fileprivate let sessions = ImportSessionRegistry()
  fileprivate let contentGate = ImportContentGate()
  let maintenanceGate = ImportMaintenanceGate()

  init(configuration: LocalMediaConfiguration) throws {
    store = try ManagedMediaStore(configuration: configuration)
    try StagingArea.prepareRoot(configuration: configuration)
  }
}

final class WeakImportCoordinator {
  weak var value: ImportCoordinator?

  init(_ value: ImportCoordinator) {
    self.value = value
  }
}

final class ImportCoordinatorRegistry: @unchecked Sendable {
  static let shared = ImportCoordinatorRegistry()

  private let lock = NSLock()
  private var coordinators: [ImportCoordinatorKey: WeakImportCoordinator] = [:]

  private init() {}

  func coordinator(for configuration: LocalMediaConfiguration) throws -> ImportCoordinator {
    let key = ImportCoordinatorKey(configuration: configuration)
    lock.lock()
    defer { lock.unlock() }

    if let coordinator = coordinators[key]?.value {
      return coordinator
    }
    coordinators = coordinators.filter { $0.value.value != nil }
    let coordinator = try ImportCoordinator(configuration: configuration)
    coordinators[key] = WeakImportCoordinator(coordinator)
    return coordinator
  }
}

/// Serializes the content-addressed recovery transaction. Different content
/// IDs remain fully concurrent, while waiters for one ID are resumed FIFO and
/// can be removed safely when their task is cancelled.
fileprivate actor ImportContentGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var lockedKeys = Set<String>()
  private var waiters: [String: [Waiter]] = [:]

  func withLock<T: Sendable>(
    for key: String,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await acquire(key)
    defer { release(key) }
    try Task.checkCancellation()
    return try await operation()
  }

  func withLocks<T: Sendable>(
    for keys: [String],
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    let orderedKeys = Array(Set(keys)).sorted()
    var acquiredKeys: [String] = []
    do {
      for key in orderedKeys {
        try await acquire(key)
        acquiredKeys.append(key)
      }
      try Task.checkCancellation()
      let result = try await operation()
      for key in acquiredKeys.reversed() {
        release(key)
      }
      return result
    } catch {
      for key in acquiredKeys.reversed() {
        release(key)
      }
      throw error
    }
  }

  private func acquire(_ key: String) async throws {
    try Task.checkCancellation()
    guard lockedKeys.insert(key).inserted else {
      let waiterID = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters[key, default: []].append(
              Waiter(id: waiterID, continuation: continuation)
            )
          }
        }
      } onCancel: {
        Task { await self.cancelWaiter(waiterID, for: key) }
      }
      return
    }
  }

  private func release(_ key: String) {
    guard var queued = waiters[key], !queued.isEmpty else {
      waiters[key] = nil
      lockedKeys.remove(key)
      return
    }

    let next = queued.removeFirst()
    waiters[key] = queued.isEmpty ? nil : queued
    next.continuation.resume()
  }

  private func cancelWaiter(_ waiterID: UUID, for key: String) {
    guard var queued = waiters[key],
          let index = queued.firstIndex(where: { $0.id == waiterID })
    else { return }

    let waiter = queued.remove(at: index)
    waiters[key] = queued.isEmpty ? nil : queued
    waiter.continuation.resume(throwing: CancellationError())
  }
}

private final class SecurityScopedURLAccess: @unchecked Sendable {
  private let url: URL
  private var didStartAccess = false

  init(url: URL) {
    self.url = url
#if os(iOS) || os(macOS)
    didStartAccess = url.startAccessingSecurityScopedResource()
#endif
  }

  func stop() {
#if os(iOS) || os(macOS)
    guard didStartAccess else { return }
    url.stopAccessingSecurityScopedResource()
    didStartAccess = false
#endif
  }

  deinit {
    stop()
  }
}

/// Imports user-selected local files into managed storage.
@available(macOS 13.0, iOS 16.0, *)
public final class LocalMediaImporter: MediaImporting, @unchecked Sendable {
  private enum ItemOutcome: Sendable {
    case imported
    case duplicate
    case skipped
  }

  private struct BundleOutcome: Sendable {
    let imported: Int
    let duplicate: Int
    let skipped: Int
  }

  private struct UserPlaybackState: Sendable {
    let isFavorite: Bool
    let statistics: PlaybackStatistics
  }

  private struct ExistingTrackCounts: Sendable {
    let albumTrackIDs: [AlbumID: Set<MediaItemID>]
    let discTrackIDs: [DiscID: Set<MediaItemID>]
    let albumFallbackCounts: [AlbumID: Int]
    let discFallbackCounts: [DiscID: Int]
    let existingDiscs: [DiscID: Disc]
  }

  private let configuration: LocalMediaConfiguration
  private let coordinator: ImportCoordinator
  private let store: ManagedMediaStore
  private let staging: StagingArea
  private let probeReader: any MediaProbing
  private let metadataReader: any MetadataReading
  private let libraryRepository: any LibraryRepository
  private let hasher: any LocalMediaHashing
  private let sessions: ImportSessionRegistry
  private let contentGate: ImportContentGate

  public init(
    configuration: LocalMediaConfiguration,
    probe: any MediaProbing,
    metadataReader: any MetadataReading,
    libraryRepository: any LibraryRepository,
    hasher: (any LocalMediaHashing)? = nil
  ) throws {
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    self.configuration = configuration
    self.coordinator = coordinator
    self.store = coordinator.store
    self.staging = try StagingArea(configuration: configuration)
    self.probeReader = probe
    self.metadataReader = metadataReader
    self.libraryRepository = libraryRepository
    self.hasher = hasher ?? ContentHasher()
    self.sessions = coordinator.sessions
    self.contentGate = coordinator.contentGate
  }

  public nonisolated func importMedia(
    _ request: MediaImportRequest
  ) -> AsyncThrowingStream<MediaImportEvent, Error> {
    AsyncThrowingStream { continuation in
      let handle = ImportOperationHandle()
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish()
          return
        }
        switch await self.sessions.reserve(request.importID, handle: handle) {
        case .alreadyRunning:
          continuation.finish(
            throwing: MediaSourceError.sourceUnavailable(.local)
          )
          return
        case .cancelledBeforeStart:
          continuation.yield(
            .cancelled(
              importID: request.importID,
              result: MediaImportResult(
                importID: request.importID,
                imported: 0,
                duplicate: 0,
                skipped: 0,
                failed: 0,
                cancelled: 1,
                status: .cancelled
              )
            )
          )
          continuation.finish()
          return
        case .reserved:
          break
        }
        guard !Task.isCancelled else {
          await self.sessions.remove(request.importID, handle: handle)
          continuation.finish()
          return
        }
        let acquiredImport = await self.coordinator.maintenanceGate.enterImport()
        guard acquiredImport else {
          await self.finishSession(request.importID, handle: handle)
          continuation.yield(
            .cancelled(
              importID: request.importID,
              result: MediaImportResult(
                importID: request.importID,
                imported: 0,
                duplicate: 0,
                skipped: 0,
                failed: 0,
                cancelled: 1,
                status: .cancelled
              )
            )
          )
          continuation.finish()
          return
        }
        await self.run(
          request: request,
          continuation: continuation,
          handle: handle
        )
        await self.coordinator.maintenanceGate.leaveImport()
      }
      handle.attach(task)

      continuation.onTermination = { @Sendable [weak self] termination in
        guard case .cancelled = termination else { return }
        task.cancel()
        Task {
          await self?.sessions.cancel(request.importID, handle: handle)
        }
      }
    }
  }

  public func cancelImport(_ importID: UUID) async {
    await sessions.cancel(importID)
  }

  private func run(
    request: MediaImportRequest,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation,
    handle: ImportOperationHandle
  ) async {
    var imported = 0
    var duplicate = 0
    var skipped = 0
    var failed = 0
    var cancelled = 0

    guard !request.urls.isEmpty else {
      await finishSession(request.importID, handle: handle)
      continuation.finish(throwing: MediaSourceError.importFailed(.invalidRequest))
      return
    }

    do {
      for inputURL in request.urls {
        try Task.checkCancellation()
        let isSelectedCUE = inputURL.pathExtension.caseInsensitiveCompare("cue") == .orderedSame
        let enumerationURL = isSelectedCUE ? inputURL.deletingLastPathComponent() : inputURL

        // A selected CUE needs directory authorization because its FILE entries
        // are sibling resources. Scope each request independently so a large
        // multi-selection does not retain every security scope until completion.
        let access = SecurityScopedURLAccess(url: enumerationURL)
        defer { access.stop() }

        let isDirectory = (try? inputURL.resourceValues(forKeys: [.isDirectoryKey]))?
          .isDirectory == true
        let files: [ImportFile]
        do {
          files = try ImportFileEnumerator(configuration: configuration).enumerate(enumerationURL)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as LocalMediaError {
          failed += 1
          continuation.yield(
            .itemFailed(
              importID: request.importID,
              url: inputURL,
              error: error.importError
            )
          )
          continue
        } catch {
          failed += 1
          continuation.yield(
            .itemFailed(
              importID: request.importID,
              url: inputURL,
              error: .inaccessibleInput
            )
          )
          continue
        }

        let bundle: FolderImportBundle
        do {
          let analyzed = try FolderImportBundleAnalyzer().analyze(
            inputURL: enumerationURL,
            files: files
          )
          bundle = isSelectedCUE
            ? try Self.bundle(forSelectedCUE: inputURL, from: analyzed)
            : analyzed
        } catch {
          failed += 1
          continuation.yield(
            MediaImportEvent.itemFailed(
              importID: request.importID,
              url: inputURL,
              error: LocalMediaError.enumerationFailed.importError
            )
          )
          continue
        }
        let allowRootArtwork = Self.likelySingleRelease(bundle)

        if isDirectory || isSelectedCUE || !bundle.cueFiles.isEmpty {
          for file in bundle.mediaCandidates {
            continuation.yield(.discovered(importID: request.importID, url: file.url))
          }
          do {
            let outcome = try await processBundle(
              bundle,
              allowRootArtwork: allowRootArtwork,
              request: request,
              continuation: continuation
            )
            imported += outcome.imported
            duplicate += outcome.duplicate
            skipped += outcome.skipped
          } catch is CancellationError {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .cancelled {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .duplicate {
            duplicate += 1
            continuation.yield(.itemFailed(
              importID: request.importID,
              url: inputURL,
              error: error.importError
            ))
          } catch {
            failed += 1
            continuation.yield(.itemFailed(
              importID: request.importID,
              url: inputURL,
              error: Self.mapImportError(error)
            ))
          }
          continue
        }

        for file in bundle.mediaCandidates {
          try Task.checkCancellation()
          let fileURL = file.url
          continuation.yield(.discovered(importID: request.importID, url: fileURL))
          do {
            let outcome = try await process(
              fileURL: fileURL,
              folderPath: file.folderPath,
              folderArtwork: FolderArtworkResolver().selection(
                for: fileURL,
                in: bundle,
                allowRootArtwork: allowRootArtwork
              ),
              request: request,
              continuation: continuation
            )
            switch outcome {
            case .imported: imported += 1
            case .duplicate: duplicate += 1
            case .skipped: skipped += 1
            }
          } catch is CancellationError {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .cancelled {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .duplicate {
            duplicate += 1
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: fileURL,
                error: error.importError
              )
            )
          } catch let error as LocalMediaError {
            failed += 1
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: fileURL,
                error: error.importError
              )
            )
          } catch let error as MediaImportError {
            failed += 1
            continuation.yield(
              .itemFailed(importID: request.importID, url: fileURL, error: error)
            )
          } catch {
            failed += 1
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: fileURL,
                error: Self.mapImportError(error)
              )
            )
          }
        }
      }

      let result = MediaImportResult(
        importID: request.importID,
        imported: imported,
        duplicate: duplicate,
        skipped: skipped,
        failed: failed,
        cancelled: cancelled,
        status: .completed
      )
      await finishSession(request.importID, handle: handle)
      continuation.yield(.completed(importID: request.importID, result: result))
      continuation.finish()
    } catch is CancellationError {
      cancelled = max(cancelled, 1)
      let result = MediaImportResult(
        importID: request.importID,
        imported: imported,
        duplicate: duplicate,
        skipped: skipped,
        failed: failed,
        cancelled: cancelled,
        status: .cancelled
      )
      await finishSession(request.importID, handle: handle)
      continuation.yield(.cancelled(importID: request.importID, result: result))
      continuation.finish()
    } catch {
      await finishSession(request.importID, handle: handle)
      continuation.finish(throwing: Self.mapStreamError(error))
    }
  }

  private func finishSession(_ importID: UUID, handle: ImportOperationHandle) async {
    await staging.removeBatch(for: importID)
    await sessions.remove(importID, handle: handle)
  }

  private func processBundle(
    _ bundle: FolderImportBundle,
    allowRootArtwork: Bool,
    request: MediaImportRequest,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
  ) async throws -> BundleOutcome {
    guard !bundle.mediaCandidates.isEmpty else {
      throw LocalMediaError.unsupportedInput
    }

    var stagedURLs: [URL] = []
    do {
      var assets: [PreparedLocalMediaAsset] = []
      for file in bundle.mediaCandidates {
        try Task.checkCancellation()
        continuation.yield(.copying(importID: request.importID, url: file.url))
        let staged = try await staging.stage(
          sourceURL: file.url,
          importID: request.importID
        )
        stagedURLs.append(staged)

        continuation.yield(.hashing(importID: request.importID, url: file.url))
        let contentHash = try await hasher.hash(fileAt: staged).lowercased()
        guard contentHash.count == 64, contentHash.allSatisfy(\.isHexDigit) else {
          throw LocalMediaError.hashingFailed
        }

        continuation.yield(.probing(importID: request.importID, url: file.url))
        let resource = PlaybackResource.localFile(staged)
        let probeResult: MediaProbeResult
        do {
          probeResult = try await probeReader.probe(resource).validated()
        } catch let error as MediaSourceError {
          throw Self.mapProbeError(error)
        } catch let error as MediaProbeError {
          throw Self.mapProbeError(MediaSourceError.probeFailed(error))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw LocalMediaError.probeFailed
        }

        let rawMetadata: RawMediaMetadata
        do {
          let embeddedMetadata = try await metadataReader.readMetadata(from: resource)
          let sidecarLyrics = try? LocalLyricsReader.readSidecar(for: file.url)
          rawMetadata = embeddedMetadata.lyrics == nil
            ? embeddedMetadata.replacingLyrics(sidecarLyrics ?? nil)
            : embeddedMetadata
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw LocalMediaError.metadataFailed
        }

        let externalID = "sha256-\(contentHash)"
        assets.append(PreparedLocalMediaAsset(
          file: file,
          stagedURL: staged,
          contentHash: contentHash,
          assetID: MediaAssetID(sourceID: .local, externalID: externalID),
          probe: probeResult,
          metadata: rawMetadata,
          folderArtwork: FolderArtworkResolver().selection(
            for: file.url,
            in: bundle,
            allowRootArtwork: allowRootArtwork
          )
        ))
      }

      let plan = try LocalMediaBundlePlanner().plan(
        bundle: bundle,
        assets: assets,
        importID: request.importID
      )
      let preparedAssets = assets
      let lockKeys = preparedAssets.map(\.assetID.externalID)
      let outcome = try await contentGate.withLocks(for: lockKeys) { [self] in
        try await finishBundleProcessing(
          plan: plan,
          assets: preparedAssets,
          request: request,
          continuation: continuation
        )
      }
      for staged in stagedURLs {
        await staging.remove(staged)
      }
      return outcome
    } catch {
      for staged in stagedURLs {
        await staging.remove(staged)
      }
      throw error
    }
  }

  private func finishBundleProcessing(
    plan: LocalMediaBundlePlan,
    assets: [PreparedLocalMediaAsset],
    request: MediaImportRequest,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
  ) async throws -> BundleOutcome {
    var existingItemIDs = Set<MediaItemID>()
    var existingAssetIDsByItemID: [MediaItemID: MediaAssetID] = [:]
    var existingTracksByItemID: [MediaItemID: Track] = [:]
    do {
      for itemID in plan.itemIDs {
        if let track = try await libraryRepository.track(id: itemID) {
          existingItemIDs.insert(itemID)
          existingAssetIDsByItemID[itemID] = track.assetID
          existingTracksByItemID[itemID] = track
        } else if let variant = try await libraryRepository.trackVariant(id: itemID) {
          existingItemIDs.insert(itemID)
          existingAssetIDsByItemID[itemID] = variant.assetID
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LocalMediaError.persistenceFailed
    }

    let assetsByID = Dictionary(grouping: assets, by: \.assetID)
    var availableAssetIDs = Set<MediaAssetID>()
    for assetID in assetsByID.keys.sorted() {
      guard let candidates = assetsByID[assetID],
            let canonical = candidates.sorted(by: { $0.file.url.path < $1.file.url.path }).first
      else { continue }
      if let managedURL = try await store.existingMediaURL(
        forExternalID: assetID.externalID
      ) {
        let managedHash = try await hasher.hash(fileAt: managedURL)
        guard managedHash.caseInsensitiveCompare(canonical.contentHash) == .orderedSame else {
          throw LocalMediaError.destinationConflict
        }
        availableAssetIDs.insert(assetID)
      }
    }

    // A library record without its content-addressed file is repairable. Keep
    // healthy duplicates skipped, but include broken or changed records in a
    // new transaction so the managed asset and graph are restored together.
    let repairItemIDs = Set(plan.normalizedTracks.compactMap { media -> MediaItemID? in
      guard existingItemIDs.contains(media.itemID),
            let existingAssetID = existingAssetIDsByItemID[media.itemID]
      else { return nil }
      return existingAssetID != media.track.assetID
        || !availableAssetIDs.contains(media.track.assetID)
        ? media.itemID
        : nil
    })
    if request.duplicatePolicy == .report,
       !existingItemIDs.subtracting(repairItemIDs).isEmpty
    {
      throw LocalMediaError.duplicate
    }

    let includedItemIDs = Set(plan.itemIDs)
      .subtracting(existingItemIDs)
      .union(repairItemIDs)
    guard !includedItemIDs.isEmpty else {
      return BundleOutcome(imported: 0, duplicate: 0, skipped: existingItemIDs.count)
    }

    var movedAssets: [(location: ManagedMediaLocation, stagedURL: URL)] = []
    var artworkClaims: [ArtworkID] = []
    do {
      let requiredAssetIDs = Set(plan.normalizedTracks.lazy
        .filter { includedItemIDs.contains($0.itemID) }
        .map { $0.track.assetID })
      for assetID in requiredAssetIDs.sorted() where !availableAssetIDs.contains(assetID) {
        guard let canonical = assetsByID[assetID]?
          .sorted(by: { $0.file.url.path < $1.file.url.path }).first
        else { throw LocalMediaError.itemNotFound }
        let location = try await store.moveToManaged(
          stagedURL: canonical.stagedURL,
          externalID: assetID.externalID
        )
        movedAssets.append((location, canonical.stagedURL))
      }

      var artworkByID: [ArtworkID: Data] = [:]
      for media in plan.normalizedTracks where includedItemIDs.contains(media.itemID) {
        if let artworkID = media.artworkID, let artworkData = media.artworkData {
          artworkByID[artworkID] = artworkData
        }
      }
      for artworkID in artworkByID.keys.sorted() {
        guard let data = artworkByID[artworkID] else { continue }
        _ = try await store.beginImportedArtworkWrite(data, artworkID: artworkID)
        artworkClaims.append(artworkID)
      }

      guard let baseTransaction = try plan.transaction(
        including: includedItemIDs,
        idempotencyKey: "local-bundle-\(request.importID.uuidString)"
      ) else {
        throw LocalMediaError.persistenceFailed
      }
      let countedTransaction = try await transactionWithReconciledTrackCounts(
        baseTransaction,
        incomingTracks: plan.normalizedTracks
          .filter { includedItemIDs.contains($0.itemID) }
          .map(\.track),
        knownExistingItemIDs: existingItemIDs
      )
      let existingLogicalTracks = try await existingLogicalTracks(
        for: plan.normalizedTracks.map(\.track.logicalTrackID)
      )
      let transaction = try preservingUserPlaybackState(
        in: countedTransaction,
        existingTracks: existingTracksByItemID,
        existingLogicalTracks: existingLogicalTracks
      )
      do {
        try await libraryRepository.apply(transaction)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.persistenceFailed
      }

      for itemID in includedItemIDs.sorted() {
        continuation.yield(.persisting(importID: request.importID, itemID: itemID))
      }
      for artworkID in artworkClaims {
        await store.finishImportedArtworkWrite(artworkID, committed: true)
      }
      artworkClaims.removeAll()
      return BundleOutcome(
        imported: includedItemIDs.count,
        duplicate: 0,
        skipped: existingItemIDs.subtracting(includedItemIDs).count
      )
    } catch {
      var recoveryFailed = false
      for moved in movedAssets.reversed() {
        do {
          try await store.moveManagedBack(moved.location.url, to: moved.stagedURL)
        } catch {
          recoveryFailed = true
        }
      }
      for artworkID in artworkClaims {
        await store.finishImportedArtworkWrite(artworkID, committed: false)
      }
      if recoveryFailed {
        throw LocalMediaError.recoveryFailed
      }
      throw error
    }
  }

  private func process(
    fileURL: URL,
    folderPath: String?,
    folderArtwork: FolderArtworkSelection?,
    request: MediaImportRequest,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
  ) async throws -> ItemOutcome {
    continuation.yield(.copying(importID: request.importID, url: fileURL))
    let staged = try await staging.stage(sourceURL: fileURL, importID: request.importID)
    do {
      continuation.yield(.hashing(importID: request.importID, url: fileURL))
      try Task.checkCancellation()
      let contentHash = try await hasher.hash(fileAt: staged)
      let externalID = "sha256-\(contentHash.lowercased())"
      guard contentHash.count == 64, contentHash.allSatisfy({ $0.isHexDigit }) else {
        throw LocalMediaError.hashingFailed
      }

      let itemID = MediaItemID(sourceID: .local, externalID: externalID)
      return try await contentGate.withLock(for: externalID) { [self] in
        try Task.checkCancellation()
        return try await finishProcessing(
          staged: staged,
          fileURL: fileURL,
          folderPath: folderPath,
          folderArtwork: folderArtwork,
          contentHash: contentHash,
          itemID: itemID,
          request: request,
          continuation: continuation
        )
      }
    } catch {
      // A cancelled waiter never enters finishProcessing, so its staged copy
      // is cleaned here. Calls that entered the gate already cleaned it while
      // still holding the content lock; removing twice is harmless.
      await staging.remove(staged)
      throw error
    }
  }

  private func finishProcessing(
    staged: URL,
    fileURL: URL,
    folderPath: String?,
    folderArtwork: FolderArtworkSelection?,
    contentHash: String,
    itemID: MediaItemID,
    request: MediaImportRequest,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
  ) async throws -> ItemOutcome {
    var stagedURL: URL? = staged
    var managedLocation: ManagedMediaLocation?
    var artworkWriteClaim: ArtworkID?

    do {
      // Recheck the library only after acquiring the content lock. A prior
      // waiter may have restored this exact managed file and record.
      let existingManagedURL = try await store.existingMediaURL(
        forExternalID: itemID.externalID
      )
      let existingTrack: Track?
      let existingAssetID: MediaAssetID?
      do {
        existingTrack = try await libraryRepository.track(id: itemID)
        if let existingTrack {
          existingAssetID = existingTrack.assetID
        } else {
          existingAssetID = try await libraryRepository.trackVariant(id: itemID)?.assetID
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.persistenceFailed
      }
      let alreadyImported = existingAssetID != nil
      if let existingManagedURL {
        // The external ID identifies the source bytes, so an existing managed
        // path is reusable only when its contents still match that identity.
        // This check must precede duplicate handling; a corrupt managed file
        // must not be silently accepted by the skip policy.
        let managedContentHash = try await hasher.hash(fileAt: existingManagedURL)
        guard managedContentHash.lowercased() == contentHash.lowercased() else {
          throw LocalMediaError.destinationConflict
        }

        if alreadyImported {
          switch request.duplicatePolicy {
          case .skip:
            await staging.remove(staged)
            stagedURL = nil
            return .skipped
          case .report:
            throw LocalMediaError.duplicate
          }
        }
      }

      continuation.yield(.probing(importID: request.importID, url: fileURL))
      let resource = PlaybackResource.localFile(staged)
      let probeResult: MediaProbeResult
      do {
        probeResult = try await probeReader.probe(resource).validated()
      } catch let error as MediaSourceError {
        throw Self.mapProbeError(error)
      } catch let error as MediaProbeError {
        throw Self.mapProbeError(MediaSourceError.probeFailed(error))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.probeFailed
      }

      let rawMetadata: RawMediaMetadata
      do {
        let embeddedMetadata = try await metadataReader.readMetadata(from: resource)
        let sidecarLyrics = try? LocalLyricsReader.readSidecar(for: fileURL)
        rawMetadata = embeddedMetadata.lyrics == nil
          ? embeddedMetadata.replacingLyrics(sidecarLyrics ?? nil)
          : embeddedMetadata
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.metadataFailed
      }

      let normalized = try MetadataNormalizer().normalize(
        fileURL: fileURL,
        stagedFileURL: staged,
        folderPath: folderPath,
        contentHash: contentHash,
        probe: probeResult,
        metadata: rawMetadata,
        fallbackArtwork: folderArtwork.map {
          RawArtwork(
            data: $0.data,
            pixelWidth: $0.pixelWidth,
            pixelHeight: $0.pixelHeight
          )
        },
        idempotencyKey: "local-import-\(request.importID.uuidString)-\(itemID.externalID)"
      )

      let existingLogicalTracks = try await existingLogicalTracks(
        for: [normalized.track.logicalTrackID]
      )
      let transaction = try preservingUserPlaybackState(
        in: normalized.transaction,
        existingTracks: existingTrack.map { [itemID: $0] } ?? [:],
        existingLogicalTracks: existingLogicalTracks
      )
      let countedTransaction = try await transactionWithReconciledTrackCounts(
        transaction,
        incomingTracks: [normalized.track],
        knownExistingItemIDs: existingAssetID == nil ? [] : [itemID]
      )

      if existingManagedURL == nil {
        managedLocation = try await store.moveToManaged(
          stagedURL: staged,
          externalID: normalized.itemID.externalID
        )
      }
      if let artworkID = normalized.artworkID,
         let artworkData = normalized.artworkData
      {
        _ = try await store.beginImportedArtworkWrite(artworkData, artworkID: artworkID)
        artworkWriteClaim = artworkID
      }

      do {
        try await libraryRepository.apply(countedTransaction)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.persistenceFailed
      }
      continuation.yield(.persisting(importID: request.importID, itemID: normalized.itemID))
      if let claim = artworkWriteClaim {
        await store.finishImportedArtworkWrite(claim, committed: true)
        artworkWriteClaim = nil
      }
      await staging.remove(staged)
      stagedURL = nil
      return .imported
    } catch {
      var recoveryFailed = false
      if let managedLocation, let stagedURL {
        do {
          try await store.moveManagedBack(managedLocation.url, to: stagedURL)
        } catch {
          recoveryFailed = true
        }
      }
      if let stagedURL {
        await staging.remove(stagedURL)
      }
      if let artworkWriteClaim {
        await store.finishImportedArtworkWrite(artworkWriteClaim, committed: false)
      }
      if recoveryFailed {
        throw LocalMediaError.recoveryFailed
      }
      if let error = error as? CancellationError {
        throw error
      }
      throw error
    }
  }

  private func existingLogicalTracks(
    for logicalTrackIDs: [LogicalTrackID]
  ) async throws -> [LogicalTrackID: LogicalTrack] {
    var result: [LogicalTrackID: LogicalTrack] = [:]
    for logicalTrackID in Set(logicalTrackIDs) {
      if let value = try await libraryRepository.logicalTrack(id: logicalTrackID) {
        result[logicalTrackID] = value
      }
    }
    return result
  }

  private func transactionWithReconciledTrackCounts(
    _ transaction: LibraryTransaction,
    incomingTracks: [Track],
    knownExistingItemIDs: Set<MediaItemID>
  ) async throws -> LibraryTransaction {
    let counts = try await existingTrackCounts(
      for: incomingTracks
    )
    var discIDs = Set<DiscID>()
    var mutations = transaction.mutations.map { mutation -> LibraryMutation in
      switch mutation {
      case .upsert(.album(let value)):
        let incoming = incomingTracks.filter { $0.albumID == value.id }.map(\.id)
        guard !incoming.isEmpty else { return mutation }
        let count = mergedTrackCount(
          existing: counts.albumTrackIDs[value.id] ?? [],
          incoming: incoming,
          fallback: counts.albumFallbackCounts[value.id],
          knownExistingItemIDs: knownExistingItemIDs
        )
        return .upsert(.album(Album(
          id: value.id,
          title: value.title,
          sortTitle: value.sortTitle,
          artistIDs: value.artistIDs,
          artwork: value.artwork,
          releaseYear: value.releaseYear,
          trackCount: count,
          albumType: value.albumType
        )))
      case .upsert(.disc(let value)):
        discIDs.insert(value.id)
        let incoming = incomingTracks
          .filter { $0.discProjection?.id == value.id }
          .map(\.id)
        guard !incoming.isEmpty else { return mutation }
        let count = mergedTrackCount(
          existing: counts.discTrackIDs[value.id] ?? [],
          incoming: incoming,
          fallback: counts.discFallbackCounts[value.id],
          knownExistingItemIDs: knownExistingItemIDs
        )
        return .upsert(.disc(Disc(
          id: value.id,
          releaseID: value.releaseID,
          number: value.number,
          title: value.title ?? counts.existingDiscs[value.id]?.title,
          trackCount: count
        )))
      default:
        return mutation
      }
    }

    for track in incomingTracks {
      guard let disc = track.discProjection, discIDs.insert(disc.id).inserted else {
        continue
      }
      let incoming = incomingTracks
        .filter { $0.discProjection?.id == disc.id }
        .map(\.id)
      let count = mergedTrackCount(
        existing: counts.discTrackIDs[disc.id] ?? [],
        incoming: incoming,
        fallback: counts.discFallbackCounts[disc.id],
        knownExistingItemIDs: knownExistingItemIDs
      )
      mutations.append(.upsert(.disc(Disc(
        id: disc.id,
        releaseID: disc.releaseID,
        number: disc.number,
        title: counts.existingDiscs[disc.id]?.title,
        trackCount: count
      ))))
    }

    return try LibraryTransaction(
      idempotencyKey: transaction.idempotencyKey,
      expectedRevision: transaction.expectedRevision,
      mutations: mutations
    )
  }

  private func existingTrackCounts(
    for incomingTracks: [Track]
  ) async throws -> ExistingTrackCounts {
    do {
      let albumIDs = Set(incomingTracks.compactMap(\.albumID))
      var albumTrackIDs: [AlbumID: Set<MediaItemID>] = [:]
      var discTrackIDs: [DiscID: Set<MediaItemID>] = [:]
      var albumFallbackCounts: [AlbumID: Int] = [:]
      var discFallbackCounts: [DiscID: Int] = [:]
      var existingDiscs: [DiscID: Disc] = [:]

      for albumID in albumIDs.sorted() {
        if let count = try await libraryRepository.album(id: albumID)?.trackCount {
          albumFallbackCounts[albumID] = count
        }
        let releaseID = AlbumReleaseID(legacyAlbumID: albumID)
        for disc in try await libraryRepository.discs(for: releaseID) {
          existingDiscs[disc.id] = disc
          if let count = disc.trackCount {
            discFallbackCounts[disc.id] = count
          }
        }

        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        while true {
          let page = try await libraryRepository.tracks(
            matching: TrackQuery(albumID: albumID),
            page: request
          )
          for track in page.elements where track.albumID == albumID {
            albumTrackIDs[albumID, default: []].insert(track.id)
            if let discID = track.discProjection?.id {
              discTrackIDs[discID, default: []].insert(track.id)
            }
          }
          guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else {
            break
          }
          request = next
        }
      }

      return ExistingTrackCounts(
        albumTrackIDs: albumTrackIDs,
        discTrackIDs: discTrackIDs,
        albumFallbackCounts: albumFallbackCounts,
        discFallbackCounts: discFallbackCounts,
        existingDiscs: existingDiscs
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as LocalMediaError {
      throw error
    } catch {
      throw LocalMediaError.persistenceFailed
    }
  }

  private func mergedTrackCount(
    existing: Set<MediaItemID>,
    incoming: [MediaItemID],
    fallback: Int?,
    knownExistingItemIDs: Set<MediaItemID>
  ) -> Int {
    let incomingIDs = Set(incoming)
    guard existing.isEmpty else {
      return existing.union(incomingIDs).count
    }
    guard let fallback else {
      return incomingIDs.count
    }
    let knownIncomingCount = incomingIDs.intersection(knownExistingItemIDs).count
    let newIncomingCount = incomingIDs.subtracting(knownExistingItemIDs).count
    return max(fallback, knownIncomingCount) + newIncomingCount
  }

  private func preservingUserPlaybackState(
    in transaction: LibraryTransaction,
    existingTracks: [MediaItemID: Track],
    existingLogicalTracks: [LogicalTrackID: LogicalTrack]
  ) throws -> LibraryTransaction {
    var stateByLogicalTrackID: [LogicalTrackID: UserPlaybackState] = [:]
    for itemID in existingTracks.keys.sorted() {
      guard let track = existingTracks[itemID], stateByLogicalTrackID[track.logicalTrackID] == nil else {
        continue
      }
      stateByLogicalTrackID[track.logicalTrackID] = UserPlaybackState(
        isFavorite: track.isFavorite,
        statistics: track.statistics
      )
    }

    let mutations = transaction.mutations.map { mutation -> LibraryMutation in
      switch mutation {
      case .upsert(.track(let value)):
        let state = existingTracks[value.id].map(Self.userPlaybackState)
          ?? existingLogicalTracks[value.logicalTrackID].map(Self.userPlaybackState)
          ?? stateByLogicalTrackID[value.logicalTrackID]
        return .upsert(.track(Self.applying(state, to: value)))
      case .upsert(.logicalTrack(let value)):
        let state = existingLogicalTracks[value.id].map(Self.userPlaybackState)
          ?? stateByLogicalTrackID[value.id]
        return .upsert(.logicalTrack(Self.applying(state, to: value)))
      default:
        return mutation
      }
    }
    return try LibraryTransaction(
      idempotencyKey: transaction.idempotencyKey,
      expectedRevision: transaction.expectedRevision,
      mutations: mutations
    )
  }

  private static func userPlaybackState(from track: Track) -> UserPlaybackState {
    UserPlaybackState(isFavorite: track.isFavorite, statistics: track.statistics)
  }

  private static func userPlaybackState(from logicalTrack: LogicalTrack) -> UserPlaybackState {
    UserPlaybackState(isFavorite: logicalTrack.isFavorite, statistics: logicalTrack.statistics)
  }

  private static func applying(_ state: UserPlaybackState?, to value: Track) -> Track {
    guard let state else { return value }
    return Track(
      id: value.id,
      logicalTrackID: value.logicalTrackID,
      assetID: value.assetID,
      playbackSelection: value.playbackSelection,
      title: value.title,
      sortTitle: value.sortTitle,
      albumID: value.albumID,
      artistIDs: value.artistIDs,
      genreIDs: value.genreIDs,
      trackNumber: value.trackNumber,
      trackTotal: value.trackTotal,
      discNumber: value.discNumber,
      discTotal: value.discTotal,
      fileName: value.fileName,
      folderPath: value.folderPath,
      duration: value.duration,
      technicalInfo: value.technicalInfo,
      year: value.year,
      comment: value.comment,
      lyrics: value.lyrics,
      artwork: value.artwork,
      isFavorite: state.isFavorite,
      statistics: state.statistics
    )
  }

  private static func applying(_ state: UserPlaybackState?, to value: LogicalTrack) -> LogicalTrack {
    guard let state else { return value }
    return LogicalTrack(
      id: value.id,
      releaseID: value.releaseID,
      discID: value.discID,
      title: value.title,
      artistIDs: value.artistIDs,
      genreIDs: value.genreIDs,
      trackNumber: value.trackNumber,
      trackTotal: value.trackTotal,
      discNumber: value.discNumber,
      discTotal: value.discTotal,
      duration: value.duration,
      artwork: value.artwork,
      isFavorite: state.isFavorite,
      statistics: state.statistics
    )
  }

  private static func mapProbeError(_ error: MediaSourceError) -> LocalMediaError {
    switch error {
    case .cancelled:
      return .cancelled
    case .probeFailed(let probeError):
      switch probeError {
      case .noDecodableAudioTrack: return .unsupportedInput
      case .unsupportedFormat: return .unsupportedInput
      case .corruptedMedia: return .probeFailed
      case .readFailed, .timedOut: return .probeFailed
      case .cancelled: return .cancelled
      }
    default:
      return .probeFailed
    }
  }

  private static func bundle(
    forSelectedCUE cueURL: URL,
    from analyzed: FolderImportBundle
  ) throws -> FolderImportBundle {
    let standardizedCUE = cueURL.standardizedFileURL
    guard analyzed.cueFiles.contains(where: {
      $0.url.standardizedFileURL == standardizedCUE
    }) else {
      throw LocalMediaError.inaccessibleInput
    }
    do {
      let data = try Data(contentsOf: standardizedCUE, options: [.mappedIfSafe])
      guard !data.isEmpty, data.count <= 4 * 1_024 * 1_024 else {
        throw LocalMediaError.metadataFailed
      }
      let sheet = try CUESheetParser().parse(data: data)
      let candidates = analyzed.mediaCandidates.map(\.url)
      let referencedURLs = try Set(sheet.files.map {
        try CUEReferencedFileResolver().resolve(
          $0,
          cueURL: standardizedCUE,
          candidates: candidates
        ).standardizedFileURL
      })
      let resources = analyzed.resources.filter { resource in
        switch resource.kind {
        case .cue:
          return resource.file.url.standardizedFileURL == standardizedCUE
        case .mediaCandidate:
          return referencedURLs.contains(resource.file.url.standardizedFileURL)
        default:
          return true
        }
      }
      return FolderImportBundle(
        rootURL: analyzed.rootURL,
        resources: resources,
        collectionManifest: nil
      )
    } catch let error as LocalMediaError {
      throw error
    } catch {
      throw LocalMediaError.metadataFailed
    }
  }

  private static func likelySingleRelease(_ bundle: FolderImportBundle) -> Bool {
    let releaseFolders = Set(bundle.mediaCandidates.map { file in
      var components = file.folderPath?.split(separator: "/").map(String.init) ?? []
      if components.last.map({ Self.isDiscFolder($0) }) == true {
        components.removeLast()
      }
      return components.joined(separator: "/").lowercased()
    })
    return releaseFolders.count <= 1
  }

  private static func isDiscFolder(_ name: String) -> Bool {
    let normalized = name.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    return normalized.range(
      of: #"^(cd|disc|disk|dvd|part|volume|vol)\s*[0-9]+$"#,
      options: .regularExpression
    ) != nil
  }

  private static func mapImportError(_ error: Error) -> MediaImportError {
    if let error = error as? LocalMediaError {
      return error.importError
    }
    if let error = error as? MediaSourceError,
       case .importFailed(let importError) = error
    {
      return importError
    }
    if error is CancellationError {
      return .cancelled
    }
    return .unknown
  }

  private static func mapStreamError(_ error: Error) -> Error {
    if let error = error as? MediaSourceError {
      return error
    }
    if let error = error as? LocalMediaError {
      return MediaSourceError.importFailed(error.importError)
    }
    if error is CancellationError {
      return MediaSourceError.cancelled
    }
    return MediaSourceError.importFailed(.unknown)
  }
}
