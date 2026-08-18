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

  private func acquire(_ key: String) async throws {
    try Task.checkCancellation()
    guard !lockedKeys.insert(key).inserted else { return }

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
        let access = SecurityScopedURLAccess(url: inputURL)
        defer { access.stop() }

        let files: [ImportFile]
        do {
          files = try ImportFileEnumerator(configuration: configuration).enumerate(inputURL)
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

        for file in files {
          try Task.checkCancellation()
          let fileURL = file.url
          continuation.yield(.discovered(importID: request.importID, url: fileURL))
          do {
            let outcome = try await process(
              fileURL: fileURL,
              folderPath: file.folderPath,
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

  private func process(
    fileURL: URL,
    folderPath: String?,
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
      if let existingManagedURL {
        // The external ID identifies the source bytes, so an existing managed
        // path is reusable only when its contents still match that identity.
        // This check must precede duplicate handling; a corrupt managed file
        // must not be silently accepted by the skip policy.
        let managedContentHash = try await hasher.hash(fileAt: existingManagedURL)
        guard managedContentHash.lowercased() == contentHash.lowercased() else {
          throw LocalMediaError.destinationConflict
        }

        let existingTrack: Track?
        do {
          existingTrack = try await libraryRepository.track(id: itemID)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw LocalMediaError.persistenceFailed
        }

        if existingTrack != nil {
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
        idempotencyKey: "local-import-\(request.importID.uuidString)-\(itemID.externalID)"
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
        try await libraryRepository.apply(normalized.transaction)
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
