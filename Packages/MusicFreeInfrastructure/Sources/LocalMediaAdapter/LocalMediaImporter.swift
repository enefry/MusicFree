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

fileprivate actor ImportConfirmationRegistry {
  enum Decision: Sendable {
    case continueImport
    case cancelled
  }

  private var waiters: [UUID: CheckedContinuation<Decision, Never>] = [:]
  private var decisions: [UUID: Decision] = [:]

  func wait(for importID: UUID) async -> Decision {
    if let decision = decisions.removeValue(forKey: importID) {
      return decision
    }

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: .cancelled)
        } else if let decision = decisions.removeValue(forKey: importID) {
          continuation.resume(returning: decision)
        } else {
          waiters[importID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(importID) }
    }
  }

  func continueImport(_ importID: UUID) {
    resolve(importID, decision: .continueImport)
  }

  func cancel(_ importID: UUID) {
    resolve(importID, decision: .cancelled)
  }

  func remove(_ importID: UUID) {
    waiters.removeValue(forKey: importID)
    decisions.removeValue(forKey: importID)
  }

  private func resolve(_ importID: UUID, decision: Decision) {
    if let continuation = waiters.removeValue(forKey: importID) {
      continuation.resume(returning: decision)
    } else {
      decisions[importID] = decision
    }
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
  fileprivate let confirmationRegistry = ImportConfirmationRegistry()
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

  var didStart: Bool {
    didStartAccess
  }

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
  private static let logger = MusicLogger(
    subsystem: "com.musicfree.app",
    category: "local-media-import"
  )

  private enum ItemOutcome: Sendable {
    case imported
    case duplicate
    case skipped
  }

  private struct BundleOutcome: Sendable {
    let imported: Int
    let duplicate: Int
    let skipped: Int
    let failed: Int
    let cancelled: Int

    init(
      imported: Int,
      duplicate: Int,
      skipped: Int,
      failed: Int = 0,
      cancelled: Int = 0
    ) {
      self.imported = imported
      self.duplicate = duplicate
      self.skipped = skipped
      self.failed = failed
      self.cancelled = cancelled
    }
  }

  /// One picked input, kept in both of the forms the pipeline needs.
  ///
  /// A security-scoped URL carries its sandbox extension inside the URL object
  /// itself, so any derived copy — including `standardizedFileURL` — loses the
  /// authorization. Path logic therefore uses `standardizedURL` while
  /// `startAccessingSecurityScopedResource()` must always be sent to
  /// `providedURL`, exactly as the document picker handed it over.
  private struct ImportInput: Sendable {
    let providedURL: URL
    let standardizedURL: URL

    init(providedURL: URL) {
      self.providedURL = providedURL
      standardizedURL = providedURL.standardizedFileURL
    }
  }

  private enum ImportWorkItem: Sendable {
    case standalone(ImportInput)
    case selectedFiles(rootURL: URL, inputs: [ImportInput])

    var inputURL: URL {
      switch self {
      case .standalone(let input):
        return input.standardizedURL
      case .selectedFiles(_, let inputs):
        return inputs[0].standardizedURL
      }
    }

    var accessURLs: [URL] {
      switch self {
      case .standalone(let input):
        let isSelectedCUE = input.standardizedURL.pathExtension
          .caseInsensitiveCompare("cue") == .orderedSame
        // A selected CUE is authorized as a file; its sibling FILE entries need
        // the enclosing directory, so claim both and let the caller work with
        // whichever scope the system actually grants.
        return isSelectedCUE
          ? [input.providedURL, input.providedURL.deletingLastPathComponent()]
          : [input.providedURL]
      case .selectedFiles(_, let inputs):
        return inputs.map(\.providedURL)
      }
    }
  }

  private struct FolderImportCancelled: Error, Sendable {
    let failedCount: Int
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
    let existingAlbums: [AlbumID: Album]
  }

  private struct SourceAwareImport: Sendable {
    let transaction: LibraryTransaction
    let tracksByItemID: [MediaItemID: Track]
  }

  private struct ExistingCUEState: Sendable {
    let tracks: [Track]
    let variants: [MediaItemID: TrackVariant]
  }

  private static func importWorkItems(
    for urls: [URL],
    maximumGroupSize: Int
  ) -> [ImportWorkItem] {
    enum WorkKey: Hashable {
      case standalone(Int)
      case directory(String)
    }

    var orderedKeys: [WorkKey] = []
    var groupedInputs: [WorkKey: [ImportInput]] = [:]

    for (index, inputURL) in urls.enumerated() {
      let input = ImportInput(providedURL: inputURL)
      let standardizedURL = input.standardizedURL
      let isSelectedCUE = standardizedURL.pathExtension.caseInsensitiveCompare("cue")
        == .orderedSame
      let values: URLResourceValues?
      if isSelectedCUE {
        values = nil
      } else {
        let access = SecurityScopedURLAccess(url: input.providedURL)
        values = try? standardizedURL.resourceValues(forKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .isPackageKey,
          .isHiddenKey,
        ])
        access.stop()
      }
      let isGroupableFile = !isSelectedCUE
        && values?.isDirectory != true
        && values?.isRegularFile == true
        && values?.isSymbolicLink != true
        && values?.isPackage != true
        && values?.isHidden != true
        && !standardizedURL.lastPathComponent.hasPrefix(".")

      let key: WorkKey
      if isGroupableFile {
        let parentURL = standardizedURL.deletingLastPathComponent()
          .resolvingSymlinksInPath()
          .standardizedFileURL
        key = .directory(parentURL.path)
      } else {
        key = .standalone(index)
      }

      if groupedInputs[key] == nil {
        orderedKeys.append(key)
      }
      groupedInputs[key, default: []].append(input)
    }

    return orderedKeys.flatMap { key -> [ImportWorkItem] in
      guard let grouped = groupedInputs[key] else { return [] }
      switch key {
      case .standalone:
        return grouped.map(ImportWorkItem.standalone)
      case .directory:
        guard grouped.count > 1, grouped.count <= maximumGroupSize else {
          return grouped.map(ImportWorkItem.standalone)
        }
        let rootURL = grouped[0].standardizedURL.deletingLastPathComponent()
          .resolvingSymlinksInPath()
          .standardizedFileURL
        return [.selectedFiles(rootURL: rootURL, inputs: grouped)]
      }
    }
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
  private let confirmationRegistry: ImportConfirmationRegistry
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
    self.confirmationRegistry = coordinator.confirmationRegistry
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

  public func continueImport(_ importID: UUID) async {
    await confirmationRegistry.continueImport(importID)
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
      Self.logger.error("import rejected empty request id=\(request.importID.uuidString)")
      await finishSession(request.importID, handle: handle)
      continuation.finish(throwing: MediaSourceError.importFailed(.invalidRequest))
      return
    }

    do {
      Self.logger.info(
        "import execution started id=\(request.importID.uuidString) inputCount=\(request.urls.count)"
      )
      let workItems = Self.importWorkItems(
        for: request.urls,
        maximumGroupSize: configuration.maximumFileCount
      )
      for workItem in workItems {
        try Task.checkCancellation()
        let inputURL = workItem.inputURL
        let isSelectedCUE = inputURL.pathExtension.caseInsensitiveCompare("cue") == .orderedSame
        let isSelectedFileGroup: Bool
        let enumerationURL: URL
        switch workItem {
        case .standalone:
          isSelectedFileGroup = false
          enumerationURL = isSelectedCUE ? inputURL.deletingLastPathComponent() : inputURL
        case .selectedFiles(let rootURL, _):
          isSelectedFileGroup = true
          enumerationURL = rootURL
        }

        // A selected CUE needs directory authorization because its FILE entries
        // are sibling resources. A grouped explicit selection retains each file's
        // authorization only while that group is being prepared and persisted.
        let accesses = workItem.accessURLs.map { SecurityScopedURLAccess(url: $0) }
        defer { accesses.forEach { $0.stop() } }
        let grantedScopeCount = accesses.filter(\.didStart).count

        let isDirectory = !isSelectedFileGroup
          && (try? inputURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        Self.logger.debug(
          "input opened id=\(request.importID.uuidString) name=\(inputURL.lastPathComponent) kind=\(isDirectory ? "directory" : (isSelectedFileGroup ? "file-group" : "file")) extension=\(inputURL.pathExtension) scopeCount=\(accesses.count) grantedScopeCount=\(grantedScopeCount)"
        )
        let files: [ImportFile]
        do {
          switch workItem {
          case .standalone:
            files = try ImportFileEnumerator(configuration: configuration).enumerate(enumerationURL)
          case .selectedFiles(_, let inputs):
            files = inputs.map { ImportFile(url: $0.standardizedURL, folderPath: nil) }
          }
          Self.logger.info(
            "input enumerated id=\(request.importID.uuidString) fileCount=\(files.count)"
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as LocalMediaError {
          Self.logger.error(
            "input enumeration failed id=\(request.importID.uuidString) code=\(error.diagnosticCode)"
          )
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
          Self.logger.error(
            "input enumeration failed id=\(request.importID.uuidString) code=inaccessible_input"
          )
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
          let analyzer = FolderImportBundleAnalyzer()
          let analyzed = isSelectedFileGroup
            ? try analyzer.analyze(rootURL: enumerationURL, files: files)
            : try analyzer.analyze(inputURL: enumerationURL, files: files)
          bundle = isSelectedCUE
            ? try Self.bundle(forSelectedCUE: inputURL, from: analyzed)
            : analyzed
        } catch {
          Self.logger.error(
            "bundle analysis failed id=\(request.importID.uuidString) code=enumeration_failed"
          )
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
        Self.logger.info(
          "bundle analyzed id=\(request.importID.uuidString) mediaCandidates=\(bundle.mediaCandidates.count) cueFiles=\(bundle.cueFiles.count)"
        )

        if isDirectory || isSelectedCUE || isSelectedFileGroup || !bundle.cueFiles.isEmpty {
          for file in bundle.mediaCandidates {
            continuation.yield(.discovered(importID: request.importID, url: file.url))
          }
          do {
            let outcome = try await processBundle(
              bundle,
              allowRootArtwork: allowRootArtwork,
              request: request,
              allowsFailureConfirmation: request.allowsFolderFailureConfirmation
                && isDirectory
                && bundle.cueFiles.isEmpty
                && bundle.collectionManifest == nil,
              continuation: continuation
            )
            imported += outcome.imported
            duplicate += outcome.duplicate
            skipped += outcome.skipped
            failed += outcome.failed
            cancelled += outcome.cancelled
          } catch is CancellationError {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .cancelled {
            cancelled += 1
            throw CancellationError()
          } catch let error as LocalMediaError where error == .duplicate {
            duplicate += 1
            Self.logger.warning(
              "bundle skipped duplicate id=\(request.importID.uuidString)"
            )
            continuation.yield(.itemFailed(
              importID: request.importID,
              url: inputURL,
              error: error.importError
            ))
          } catch {
            failed += 1
            Self.logger.error(
              "bundle processing failed id=\(request.importID.uuidString) file=\(inputURL.lastPathComponent) code=\(Self.mapImportError(error).diagnosticCode)"
            )
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
            Self.logger.warning(
              "item skipped duplicate id=\(request.importID.uuidString) file=\(fileURL.lastPathComponent)"
            )
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: fileURL,
                error: error.importError
              )
            )
          } catch let error as LocalMediaError {
            failed += 1
            Self.logger.error(
              "item processing failed id=\(request.importID.uuidString) file=\(fileURL.lastPathComponent) code=\(error.diagnosticCode)"
            )
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: fileURL,
                error: error.importError
              )
            )
          } catch let error as MediaImportError {
            failed += 1
            Self.logger.error(
              "item processing failed id=\(request.importID.uuidString) file=\(fileURL.lastPathComponent) code=\(error.diagnosticCode)"
            )
            continuation.yield(
              .itemFailed(importID: request.importID, url: fileURL, error: error)
            )
          } catch {
            failed += 1
            Self.logger.error(
              "item processing failed id=\(request.importID.uuidString) file=\(fileURL.lastPathComponent) code=\(Self.mapImportError(error).diagnosticCode)"
            )
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
      Self.logger.info(
        "import execution completed id=\(request.importID.uuidString) imported=\(imported) duplicate=\(duplicate) skipped=\(skipped) failed=\(failed)"
      )
      await finishSession(request.importID, handle: handle)
      continuation.yield(.completed(importID: request.importID, result: result))
      continuation.finish()
    } catch let error as FolderImportCancelled {
      Self.logger.warning(
        "folder import cancelled after confirmation id=\(request.importID.uuidString) failed=\(error.failedCount)"
      )
      failed += error.failedCount
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
    } catch is CancellationError {
      Self.logger.warning("import execution cancelled id=\(request.importID.uuidString)")
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
      Self.logger.error(
        "import execution terminated id=\(request.importID.uuidString) error=\(String(describing: error))"
      )
      await finishSession(request.importID, handle: handle)
      continuation.finish(throwing: Self.mapStreamError(error))
    }
  }

  private func finishSession(_ importID: UUID, handle: ImportOperationHandle) async {
    await staging.removeBatch(for: importID)
    await confirmationRegistry.remove(importID)
    await sessions.remove(importID, handle: handle)
  }

  private func processBundle(
    _ bundle: FolderImportBundle,
    allowRootArtwork: Bool,
    request: MediaImportRequest,
    allowsFailureConfirmation: Bool,
    continuation: AsyncThrowingStream<MediaImportEvent, Error>.Continuation
  ) async throws -> BundleOutcome {
    guard !bundle.mediaCandidates.isEmpty else {
      throw LocalMediaError.unsupportedInput
    }

    var stagedURLs: [URL] = []
    do {
      var assets: [PreparedLocalMediaAsset] = []
      var preparationFailures: [(url: URL, error: MediaImportError)] = []
      for file in bundle.mediaCandidates {
        var stagedForFile: URL?
        do {
          try Task.checkCancellation()
          continuation.yield(.copying(importID: request.importID, url: file.url))
          let staged = try await staging.stage(
            sourceURL: file.url,
            importID: request.importID
          )
          stagedForFile = staged
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
            let metadataWithLyrics = embeddedMetadata.lyrics == nil
              ? embeddedMetadata.replacingLyrics(sidecarLyrics ?? nil)
              : embeddedMetadata
            rawMetadata = Self.applyingMetadataHint(
              request.metadataHint(for: file.url),
              to: metadataWithLyrics,
              parsedFileURL: staged
            )
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
        } catch let error as LocalMediaError
          where !Self.hasRecognizedAudioExtension(file.url)
            && error == .unsupportedInput
        {
          // A directory can contain checksum files or other unknown
          // attachments. Ignore an unreferenced unknown file after probing;
          // an explicitly referenced CUE file still fails in the planner.
          if let stagedForFile {
            await staging.remove(stagedForFile)
          }
          continue
        } catch let error as LocalMediaError {
          Self.logger.error(
            "bundle file failed id=\(request.importID.uuidString) file=\(file.url.lastPathComponent) extension=\(file.url.pathExtension) code=\(error.diagnosticCode)"
          )
          if let stagedForFile {
            await staging.remove(stagedForFile)
          }
          guard allowsFailureConfirmation else { throw error }
          preparationFailures.append((file.url, error.importError))
        } catch {
          Self.logger.error(
            "bundle file failed id=\(request.importID.uuidString) file=\(file.url.lastPathComponent) extension=\(file.url.pathExtension) code=\(Self.mapImportError(error).diagnosticCode)"
          )
          if let stagedForFile {
            await staging.remove(stagedForFile)
          }
          guard allowsFailureConfirmation else { throw error }
          preparationFailures.append((file.url, Self.mapImportError(error)))
        }
      }

      guard !assets.isEmpty else {
        if !preparationFailures.isEmpty {
          for failure in preparationFailures {
            continuation.yield(
              .itemFailed(
                importID: request.importID,
                url: failure.url,
                error: failure.error
              )
            )
          }
          if allowsFailureConfirmation {
            Self.logger.info(
              "confirmation event yielding id=\(request.importID.uuidString) failureCount=\(preparationFailures.count) validCount=0"
            )
            let yieldResult = continuation.yield(
              .confirmationRequired(importID: request.importID)
            )
            Self.logger.info(
              "confirmation event yielded id=\(request.importID.uuidString) result=\(String(describing: yieldResult))"
            )
            Self.logger.info(
              "confirmation decision waiting id=\(request.importID.uuidString)"
            )
            let decision = await confirmationRegistry.wait(for: request.importID)
            Self.logger.info(
              "confirmation decision received id=\(request.importID.uuidString) decision=\(String(describing: decision))"
            )
            guard decision == .continueImport, !Task.isCancelled else {
              throw FolderImportCancelled(failedCount: preparationFailures.count)
            }
          }
          return BundleOutcome(
            imported: 0,
            duplicate: 0,
            skipped: 0,
            failed: preparationFailures.count
          )
        }
        throw LocalMediaError.unsupportedInput
      }

      for failure in preparationFailures {
        continuation.yield(
          .itemFailed(
            importID: request.importID,
            url: failure.url,
            error: failure.error
          )
        )
      }
      if allowsFailureConfirmation, !preparationFailures.isEmpty {
        Self.logger.info(
          "confirmation event yielding id=\(request.importID.uuidString) failureCount=\(preparationFailures.count) validCount=\(assets.count)"
        )
        let yieldResult = continuation.yield(
          .confirmationRequired(importID: request.importID)
        )
        Self.logger.info(
          "confirmation event yielded id=\(request.importID.uuidString) result=\(String(describing: yieldResult))"
        )
        Self.logger.info(
          "confirmation decision waiting id=\(request.importID.uuidString)"
        )
        let decision = await confirmationRegistry.wait(for: request.importID)
        Self.logger.info(
          "confirmation decision received id=\(request.importID.uuidString) decision=\(String(describing: decision))"
        )
        guard decision == .continueImport, !Task.isCancelled else {
          throw FolderImportCancelled(failedCount: preparationFailures.count)
        }
      }

      let existingCUEState = try await existingCUEState(
        required: !bundle.cueFiles.isEmpty
      )
      let plan = try LocalMediaBundlePlanner().plan(
        bundle: bundle,
        assets: assets,
        existingCUETracks: existingCUEState.tracks,
        existingCUEVariants: existingCUEState.variants,
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
      return BundleOutcome(
        imported: outcome.imported,
        duplicate: outcome.duplicate,
        skipped: outcome.skipped,
        failed: preparationFailures.count
      )
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
    var existingVariantsByItemID: [MediaItemID: TrackVariant] = [:]
    var existingAlbumsByID: [AlbumID: Album] = [:]
    do {
      for itemID in plan.itemIDs {
        if let track = try await libraryRepository.track(id: itemID) {
          existingItemIDs.insert(itemID)
          existingAssetIDsByItemID[itemID] = track.assetID
          existingTracksByItemID[itemID] = track
        }
        if let variant = try await libraryRepository.trackVariant(id: itemID) {
          existingItemIDs.insert(itemID)
          existingAssetIDsByItemID[itemID] = existingAssetIDsByItemID[itemID] ?? variant.assetID
          existingVariantsByItemID[itemID] = variant
        }
      }
      for albumID in Set(existingTracksByItemID.values.compactMap(\.albumID)).sorted() {
        if let album = try await libraryRepository.album(id: albumID) {
          existingAlbumsByID[albumID] = album
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
    // A Documents rescan can discover a sidecar cover after the audio bytes
    // were already imported. Reuse the healthy managed asset and fill only a
    // missing artwork reference; an existing user-selected cover remains
    // authoritative.
    let artworkRepairItemIDs = Set(plan.normalizedTracks.compactMap { media -> MediaItemID? in
      guard existingItemIDs.contains(media.itemID),
            !repairItemIDs.contains(media.itemID),
            let existingTrack = existingTracksByItemID[media.itemID],
            existingTrack.artwork == nil,
            media.artworkID != nil,
            media.artworkData != nil
      else { return nil }
      return media.itemID
    })
    let plannedVariantsByItemID = plan.variantsByItemID
    let sourceRefreshItemIDs = Set(plan.normalizedTracks.compactMap { media -> MediaItemID? in
      guard existingItemIDs.contains(media.itemID),
            let currentRevision = plannedVariantsByItemID[media.itemID]?.sourceMetadataRevision,
            existingVariantsByItemID[media.itemID]?.sourceMetadataRevision != currentRevision
      else { return nil }
      return media.itemID
    })
    let audioSelectionRepairItemIDs = Set(plan.normalizedTracks.compactMap { media -> MediaItemID? in
      guard let existingTrack = existingTracksByItemID[media.itemID],
            Self.needsAudioSelectionRepair(existingTrack)
      else { return nil }
      return media.itemID
    })
    let sourceMetadataRepairItemIDs = Set(plan.normalizedTracks.compactMap {
      media -> MediaItemID? in
      guard Self.needsSourceMetadataRepair(
        existingTrack: existingTracksByItemID[media.itemID],
        sourceTrack: media.track,
        existingAlbum: existingTracksByItemID[media.itemID]?.albumID.flatMap {
          existingAlbumsByID[$0]
        },
        sourceAlbum: Self.sourceAlbum(
          for: media.track.albumID,
          in: media.transaction
        )
      ) else { return nil }
      return media.itemID
    })
    let albumIdentityRepairItemIDs = Set(plan.normalizedTracks.compactMap {
      media -> MediaItemID? in
      guard Self.shouldRepairAlbumIdentity(
        existingTrack: existingTracksByItemID[media.itemID],
        existingAlbum: existingTracksByItemID[media.itemID]?.albumID.flatMap {
          existingAlbumsByID[$0]
        },
        previousSource: existingVariantsByItemID[media.itemID]?.sourceMetadata,
        sourceTrack: media.track,
        sourceAlbum: Self.sourceAlbum(for: media.track.albumID, in: media.transaction),
        legacyAlbumIDs: plan.legacyAlbumIDsByItemID[media.itemID] ?? []
      ) else { return nil }
      return media.itemID
    })
    let repairOrRefreshItemIDs = repairItemIDs
      .union(artworkRepairItemIDs)
      .union(sourceRefreshItemIDs)
      .union(audioSelectionRepairItemIDs)
      .union(sourceMetadataRepairItemIDs)
      .union(albumIdentityRepairItemIDs)
    if request.duplicatePolicy == .report,
       !existingItemIDs.subtracting(repairOrRefreshItemIDs).isEmpty
    {
      throw LocalMediaError.duplicate
    }

    let includedItemIDs = Set(plan.itemIDs)
      .subtracting(existingItemIDs)
      .union(repairOrRefreshItemIDs)
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

      guard let baseTransaction = try plan.transaction(
        including: includedItemIDs,
        idempotencyKey: "local-bundle-\(request.importID.uuidString)"
      ) else {
        throw LocalMediaError.persistenceFailed
      }
      let sourceAwareImport = try Self.applyingSourceMetadataPolicy(
        to: baseTransaction,
        plannedTracks: plan.normalizedTracks
          .filter { includedItemIDs.contains($0.itemID) }
          .map(\.track),
        existingTracks: existingTracksByItemID,
        existingVariants: existingVariantsByItemID,
        existingAlbums: existingAlbumsByID,
        artworkRepairItemIDs: artworkRepairItemIDs,
        audioSelectionRepairItemIDs: audioSelectionRepairItemIDs,
        sourceMetadataRepairItemIDs: sourceMetadataRepairItemIDs,
        albumIdentityRepairItemIDs: albumIdentityRepairItemIDs
      )

      let artworkIDsToPersist = Set(sourceAwareImport.transaction.mutations.compactMap {
        mutation -> ArtworkID? in
        guard case .upsert(.artwork(let artwork)) = mutation else { return nil }
        return artwork.id
      })
      var artworkByID: [ArtworkID: Data] = [:]
      for media in plan.normalizedTracks where includedItemIDs.contains(media.itemID) {
        guard let artworkID = media.artworkID,
              artworkIDsToPersist.contains(artworkID),
              let artworkData = media.artworkData
        else { continue }
        artworkByID[artworkID] = artworkData
      }
      for artworkID in artworkByID.keys.sorted() {
        guard let data = artworkByID[artworkID] else { continue }
        _ = try await store.beginImportedArtworkWrite(data, artworkID: artworkID)
        artworkClaims.append(artworkID)
      }

      let countedTransaction = try await transactionWithReconciledTrackCounts(
        sourceAwareImport.transaction,
        incomingTracks: sourceAwareImport.tracksByItemID.values.sorted { $0.id < $1.id },
        knownExistingItemIDs: existingItemIDs
      )
      let existingLogicalTracks = try await existingLogicalTracks(
        for: sourceAwareImport.tracksByItemID.values.map(\.logicalTrackID)
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
      let existingVariant: TrackVariant?
      let existingAlbum: Album?
      let existingAssetID: MediaAssetID?
      do {
        existingTrack = try await libraryRepository.track(id: itemID)
        existingVariant = try await libraryRepository.trackVariant(id: itemID)
        if let albumID = existingTrack?.albumID {
          existingAlbum = try await libraryRepository.album(id: albumID)
        } else {
          existingAlbum = nil
        }
        if let existingTrack {
          existingAssetID = existingTrack.assetID
        } else {
          existingAssetID = existingVariant?.assetID
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.persistenceFailed
      }
      let alreadyImported = existingAssetID != nil
      let shouldAttemptSourceMetadataRepair = Self.shouldAttemptSourceMetadataRepair(
        existingTrack: existingTrack,
        existingAlbum: existingAlbum,
        hint: request.metadataHint(for: fileURL)
      )
      Self.logger.debug(
        "content state id=\(request.importID.uuidString) managed=\(existingManagedURL != nil) track=\(existingTrack != nil) variant=\(existingVariant != nil) asset=\(existingAssetID != nil) policy=\(request.duplicatePolicy.rawValue)"
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

        if alreadyImported,
           !Self.needsAudioSelectionRepair(existingTrack),
           !shouldAttemptSourceMetadataRepair
        {
          switch request.duplicatePolicy {
          case .skip:
            Self.logger.info(
              "content decision id=\(request.importID.uuidString) result=skipped reason=content_hash_match"
            )
            await staging.remove(staged)
            stagedURL = nil
            return .skipped
          case .report:
            Self.logger.info(
              "content decision id=\(request.importID.uuidString) result=duplicate reason=content_hash_match"
            )
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
        let metadataWithLyrics = embeddedMetadata.lyrics == nil
          ? embeddedMetadata.replacingLyrics(sidecarLyrics ?? nil)
          : embeddedMetadata
        rawMetadata = Self.applyingMetadataHint(
          request.metadataHint(for: fileURL),
          to: metadataWithLyrics,
          parsedFileURL: staged
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalMediaError.metadataFailed
      }

      let normalized = try MetadataNormalizer().normalize(
        fileURL: fileURL,
        stagedFileURL: staged,
        preferredFileName: request.metadataHint(for: fileURL)?.displayName,
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
      let artworkRepairItemIDs: Set<MediaItemID> = {
        guard let existingTrack,
              existingTrack.artwork == nil,
              normalized.artworkID != nil,
              normalized.artworkData != nil
        else { return [] }
        return [itemID]
      }()
      let sourceMetadataRepairItemIDs: Set<MediaItemID> = Self.needsSourceMetadataRepair(
        existingTrack: existingTrack,
        sourceTrack: normalized.track,
        existingAlbum: existingAlbum,
        sourceAlbum: Self.sourceAlbum(
          for: normalized.track.albumID,
          in: normalized.transaction
        )
      ) ? [itemID] : []
      let sourceAwareImport = try Self.applyingSourceMetadataPolicy(
        to: normalized.transaction,
        plannedTracks: [normalized.track],
        existingTracks: existingTrack.map { [itemID: $0] } ?? [:],
        existingVariants: existingVariant.map { [itemID: $0] } ?? [:],
        existingAlbums: existingAlbum.map { [$0.id: $0] } ?? [:],
        artworkRepairItemIDs: artworkRepairItemIDs,
        audioSelectionRepairItemIDs: Self.needsAudioSelectionRepair(existingTrack)
          ? [itemID] : [],
        sourceMetadataRepairItemIDs: sourceMetadataRepairItemIDs,
        albumIdentityRepairItemIDs: []
      )
      let transaction = try preservingUserPlaybackState(
        in: sourceAwareImport.transaction,
        existingTracks: existingTrack.map { [itemID: $0] } ?? [:],
        existingLogicalTracks: existingLogicalTracks
      )
      let countedTransaction = try await transactionWithReconciledTrackCounts(
        transaction,
        incomingTracks: sourceAwareImport.tracksByItemID.values.sorted { $0.id < $1.id },
        knownExistingItemIDs: existingAssetID == nil ? [] : [itemID]
      )

      if existingManagedURL == nil {
        Self.logger.info(
          "content decision id=\(request.importID.uuidString) result=imported managedFile=new repair=\(alreadyImported)"
        )
        managedLocation = try await store.moveToManaged(
          stagedURL: staged,
          externalID: normalized.itemID.externalID
        )
      }
      let artworkIDsToPersist = Set(sourceAwareImport.transaction.mutations.compactMap {
        mutation -> ArtworkID? in
        guard case .upsert(.artwork(let artwork)) = mutation else { return nil }
        return artwork.id
      })
      if let artworkID = normalized.artworkID,
         artworkIDsToPersist.contains(artworkID),
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

  private func existingCUEState(
    required: Bool
  ) async throws -> ExistingCUEState {
    guard required else { return ExistingCUEState(tracks: [], variants: [:]) }
    do {
      var tracks: [Track] = []
      var variants: [MediaItemID: TrackVariant] = [:]
      var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
      while true {
        let page = try await libraryRepository.tracks(
          matching: TrackQuery(sourceID: .local),
          page: request
        )
        let cueTracks = page.elements.filter {
          Self.isCUEItemID($0.id)
        }
        tracks.append(contentsOf: cueTracks)
        for track in cueTracks {
          if let variant = try await libraryRepository.trackVariant(id: track.id) {
            variants[track.id] = variant
          }
        }
        guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else {
          return ExistingCUEState(tracks: tracks, variants: variants)
        }
        request = next
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LocalMediaError.persistenceFailed
    }
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
          artistIDs: Self.mergedArtistIDs(
            existing: counts.existingAlbums[value.id]?.artistIDs ?? [],
            incoming: value.artistIDs
          ),
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
      var existingAlbums: [AlbumID: Album] = [:]

      for albumID in albumIDs.sorted() {
        if let album = try await libraryRepository.album(id: albumID) {
          existingAlbums[albumID] = album
          if let count = album.trackCount {
            albumFallbackCounts[albumID] = count
          }
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
        existingDiscs: existingDiscs,
        existingAlbums: existingAlbums
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

  private static func mergedArtistIDs(
    existing: [ArtistID],
    incoming: [ArtistID]
  ) -> [ArtistID] {
    var seen = Set<ArtistID>()
    return (existing + incoming).filter { seen.insert($0).inserted }
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

  private static func isCUEItemID(_ itemID: MediaItemID) -> Bool {
    itemID.sourceID == .local && itemID.externalID.hasPrefix("cue-")
  }

  private static func needsAudioSelectionRepair(_ track: Track?) -> Bool {
    guard let track,
          track.playbackSelection.audioStream != nil,
          let streams = track.technicalInfo?.audioStreams,
          streams.count > 1
    else { return false }
    return !streams.contains(where: \.isDefault)
  }

  private static func shouldAttemptSourceMetadataRepair(
    existingTrack: Track?,
    existingAlbum: Album?,
    hint: MediaImportMetadataHint?
  ) -> Bool {
    guard let existingTrack else { return false }
    if isLikelyMojibake(existingTrack.title)
      || isLikelyMojibake(existingTrack.comment)
      || isLikelyMojibake(existingTrack.lyrics?.rawText)
      || isLikelyMojibake(existingAlbum?.title)
    {
      return true
    }
    guard isPrivateStagingTitle(existingTrack.title),
          let hint,
          let hintedTitle = hint.title ?? hint.displayName.map({
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
          }),
          !isPrivateStagingTitle(hintedTitle),
          hintedTitle.caseInsensitiveCompare(existingTrack.title) != .orderedSame
    else { return false }
    return true
  }

  private static func needsSourceMetadataRepair(
    existingTrack: Track?,
    sourceTrack: Track,
    existingAlbum: Album?,
    sourceAlbum: Album?
  ) -> Bool {
    guard let existingTrack else { return false }
    return (isPrivateStagingTitle(existingTrack.title)
      && !isPrivateStagingTitle(sourceTrack.title))
      || isMojibakeTransition(
        existing: existingTrack.title,
        source: sourceTrack.title
      )
      || isMojibakeTransition(
        existing: existingAlbum?.title,
        source: sourceAlbum?.title
      )
      || isMojibakeTransition(
        existing: existingTrack.comment,
        source: sourceTrack.comment
      )
      || isMojibakeTransition(
        existing: existingTrack.lyrics?.rawText,
        source: sourceTrack.lyrics?.rawText
      )
  }

  private static func isLikelyMojibake(_ value: String?) -> Bool {
    guard let value else { return false }
    return MetadataTextRepair.isLikelyMojibake(value)
  }

  private static func isMojibakeTransition(
    existing: String?,
    source: String?
  ) -> Bool {
    guard let existing,
          let source,
          existing.caseInsensitiveCompare(source) != .orderedSame
    else { return false }
    return isLikelyMojibake(existing) && !isLikelyMojibake(source)
  }

  private static func repairsLegacyAlbum(
    existingTrack: Track,
    sourceTrack: Track,
    existingAlbum: Album?,
    sourceAlbum: Album?
  ) -> Bool {
    if existingTrack.albumID == nil {
      return sourceTrack.albumID != nil
    }
    return isMojibakeTransition(
      existing: existingAlbum?.title,
      source: sourceAlbum?.title
    )
  }

  private static func shouldRepairAlbumIdentity(
    existingTrack: Track?,
    existingAlbum: Album?,
    previousSource: TrackSourceMetadataSnapshot?,
    sourceTrack: Track,
    sourceAlbum: Album?,
    legacyAlbumIDs: Set<AlbumID>
  ) -> Bool {
    guard let existingTrack,
          let existingAlbum,
          let existingAlbumID = existingTrack.albumID,
          let sourceAlbumID = sourceTrack.albumID,
          existingAlbumID != sourceAlbumID,
          legacyAlbumIDs.contains(existingAlbumID),
          existingAlbum.title.caseInsensitiveCompare(sourceAlbum?.title ?? "") == .orderedSame
    else { return false }

    if let previousSource, previousSource.albumID != existingAlbumID {
      return false
    }
    return true
  }

  private static func isPrivateStagingTitle(_ value: String) -> Bool {
    let lastPathComponent = URL(fileURLWithPath: value).lastPathComponent
    let stem = URL(fileURLWithPath: lastPathComponent)
      .deletingPathExtension()
      .lastPathComponent
    return UUID(uuidString: stem) != nil
  }

  private static func applyingSourceMetadataPolicy(
    to transaction: LibraryTransaction,
    plannedTracks: [Track],
    existingTracks: [MediaItemID: Track],
    existingVariants: [MediaItemID: TrackVariant],
    existingAlbums: [AlbumID: Album],
    artworkRepairItemIDs: Set<MediaItemID>,
    audioSelectionRepairItemIDs: Set<MediaItemID>,
    sourceMetadataRepairItemIDs: Set<MediaItemID>,
    albumIdentityRepairItemIDs: Set<MediaItemID>
  ) throws -> SourceAwareImport {
    var tracksByItemID: [MediaItemID: Track] = [:]
    var protectedAlbumIDs = Set<AlbumID>()
    var protectedArtistIDs = Set<ArtistID>()
    var protectedGenreIDs = Set<GenreID>()
    let sourceAlbumsByID = transaction.mutations.reduce(into: [AlbumID: Album]()) {
      result, mutation in
      guard case .upsert(.album(let album)) = mutation else { return }
      result[album.id] = album
    }

    for sourceTrack in plannedTracks {
      guard let existingTrack = existingTracks[sourceTrack.id] else {
        tracksByItemID[sourceTrack.id] = sourceTrack
        continue
      }
      let sourceAlbum = Self.sourceAlbum(
        for: sourceTrack.albumID,
        in: sourceAlbumsByID
      )
      let repairsLegacyAlbum = albumIdentityRepairItemIDs.contains(sourceTrack.id)
        || (sourceMetadataRepairItemIDs.contains(sourceTrack.id) && Self.repairsLegacyAlbum(
          existingTrack: existingTrack,
          sourceTrack: sourceTrack,
          existingAlbum: existingTrack.albumID.flatMap { existingAlbums[$0] },
          sourceAlbum: sourceAlbum
        ))
      let merged = mergingSourceMetadata(
        sourceTrack: sourceTrack,
        existingTrack: existingTrack,
        previousSource: existingVariants[sourceTrack.id]?.sourceMetadata,
        existingAlbum: existingTrack.albumID.flatMap { existingAlbums[$0] },
        sourceAlbum: sourceAlbum,
        forceSourceArtwork: artworkRepairItemIDs.contains(sourceTrack.id),
        forceSourceAudioSelection: audioSelectionRepairItemIDs.contains(sourceTrack.id),
        repairLegacyMetadata: sourceMetadataRepairItemIDs.contains(sourceTrack.id),
        repairAlbumIdentity: albumIdentityRepairItemIDs.contains(sourceTrack.id)
      )
      tracksByItemID[sourceTrack.id] = merged
      let previousSource = existingVariants[sourceTrack.id]?.sourceMetadata
      let protectsAlbumEntity = (
        previousSource == nil
          || existingTrack.albumID.flatMap { existingAlbums[$0] }
            .map(AlbumSourceMetadataSnapshot.init(album:)) != previousSource?.album
      ) && !repairsLegacyAlbum
      if protectsAlbumEntity,
         merged.albumID == existingTrack.albumID,
         let albumID = merged.albumID
      {
        protectedAlbumIDs.insert(albumID)
      }
      protectedArtistIDs.formUnion(Set(merged.artistIDs).intersection(existingTrack.artistIDs))
      protectedGenreIDs.formUnion(Set(merged.genreIDs).intersection(existingTrack.genreIDs))
    }

    let albumIDs = Set(tracksByItemID.values.compactMap(\.albumID))
    let releaseIDs = Set(albumIDs.map(AlbumReleaseID.init(legacyAlbumID:)))
    let discIDs = Set(tracksByItemID.values.compactMap { $0.discProjection?.id })
    let sourceAlbums = transaction.mutations.reduce(into: [AlbumID: Album]()) { result, mutation in
      guard case .upsert(.album(let album)) = mutation,
            albumIDs.contains(album.id)
      else { return }
      if protectedAlbumIDs.contains(album.id) {
        result[album.id] = existingAlbums[album.id]
      } else {
        result[album.id] = album
      }
    }
    var artistIDs = Set(tracksByItemID.values.flatMap(\.artistIDs))
    artistIDs.formUnion(sourceAlbums.values.flatMap(\.artistIDs))
    let genreIDs = Set(tracksByItemID.values.flatMap(\.genreIDs))
    var artworkIDs = Set(tracksByItemID.values.compactMap(\.artworkID))
    artworkIDs.formUnion(sourceAlbums.values.compactMap(\.artworkID))
    let sourceReleases = transaction.mutations.compactMap { mutation -> AlbumRelease? in
      guard case .upsert(.albumRelease(let release)) = mutation,
            releaseIDs.contains(release.id)
      else { return nil }
      return release
    }
    let groupIDs = Set(sourceReleases.compactMap(\.groupID))
    let collectionIDs = Set(transaction.mutations.compactMap { mutation -> LibraryCollectionID? in
      guard case .upsert(.collectionMember(let member)) = mutation,
            releaseIDs.contains(member.releaseID)
      else { return nil }
      return member.collectionID
    })
    let tracksByLogicalID = Dictionary(uniqueKeysWithValues: tracksByItemID.values.map {
      ($0.logicalTrackID, $0)
    })

    var mutations: [LibraryMutation] = []
    for mutation in transaction.mutations {
      switch mutation {
      case .upsert(.track(let track)):
        guard let merged = tracksByItemID[track.id] else { continue }
        mutations.append(.upsert(.track(merged)))
      case .upsert(.logicalTrack(let logicalTrack)):
        guard let merged = tracksByLogicalID[logicalTrack.id] else { continue }
        mutations.append(.upsert(.logicalTrack(merged.logicalTrackProjection)))
      case .upsert(.trackVariant(let variant)):
        guard let merged = tracksByItemID[variant.id] else { continue }
        mutations.append(.upsert(.trackVariant(TrackVariant(
          id: merged.id,
          logicalTrackID: merged.logicalTrackID,
          assetID: merged.assetID,
          selection: merged.playbackSelection,
          availability: variant.availability,
          sourceIdentityHint: variant.sourceIdentityHint,
          sourceMetadataRevision: variant.sourceMetadataRevision,
          sourceMetadata: variant.sourceMetadata
        ))))
      case .upsert(.album(let album)):
        guard let mergedAlbum = sourceAlbums[album.id] else { continue }
        mutations.append(.upsert(.album(mergedAlbum)))
      case .upsert(.artist(let artist)):
        guard artistIDs.contains(artist.id), !protectedArtistIDs.contains(artist.id) else { continue }
        mutations.append(mutation)
      case .upsert(.genre(let genre)):
        guard genreIDs.contains(genre.id), !protectedGenreIDs.contains(genre.id) else { continue }
        mutations.append(mutation)
      case .upsert(.artwork(let artwork)):
        guard artworkIDs.contains(artwork.id) else { continue }
        mutations.append(mutation)
      case .upsert(.albumRelease(let release)):
        guard releaseIDs.contains(release.id) else { continue }
        if let albumID = release.legacyAlbumID,
           protectedAlbumIDs.contains(albumID),
           let existingAlbum = existingAlbums[albumID]
        {
          mutations.append(.upsert(.albumRelease(existingAlbum.releaseProjection)))
        } else {
          mutations.append(mutation)
        }
      case .upsert(.disc(let disc)):
        guard discIDs.contains(disc.id) else { continue }
        mutations.append(mutation)
      case .upsert(.albumGroup(let group)):
        guard groupIDs.contains(group.id) else { continue }
        mutations.append(mutation)
      case .upsert(.collection(let collection)):
        guard collectionIDs.contains(collection.id) else { continue }
        mutations.append(mutation)
      case .upsert(.collectionMember(let member)):
        guard collectionIDs.contains(member.collectionID),
              releaseIDs.contains(member.releaseID)
        else { continue }
        mutations.append(mutation)
      case .relation(.setAlbum(let trackID, _)):
        guard let track = tracksByItemID[trackID] else { continue }
        mutations.append(.relation(.setAlbum(trackID: trackID, albumID: track.albumID)))
      case .relation(.setArtists(let trackID, _)):
        guard let track = tracksByItemID[trackID] else { continue }
        mutations.append(.relation(.setArtists(trackID: trackID, artistIDs: track.artistIDs)))
      case .relation(.setGenres(let trackID, _)):
        guard let track = tracksByItemID[trackID] else { continue }
        mutations.append(.relation(.setGenres(trackID: trackID, genreIDs: track.genreIDs)))
      case .relation(.setArtwork(let trackID, _)):
        guard let track = tracksByItemID[trackID] else { continue }
        mutations.append(.relation(.setArtwork(trackID: trackID, artworkID: track.artworkID)))
      default:
        mutations.append(mutation)
      }
    }
    return SourceAwareImport(
      transaction: try LibraryTransaction(
        idempotencyKey: transaction.idempotencyKey,
        expectedRevision: transaction.expectedRevision,
        mutations: mutations
      ),
      tracksByItemID: tracksByItemID
    )
  }

  private static func sourceAlbum(
    for albumID: AlbumID?,
    in transaction: LibraryTransaction
  ) -> Album? {
    guard let albumID else { return nil }
    return sourceAlbum(for: albumID, in: transaction.mutations)
  }

  private static func sourceAlbum(
    for albumID: AlbumID?,
    in albums: [AlbumID: Album]
  ) -> Album? {
    guard let albumID else { return nil }
    return albums[albumID]
  }

  private static func sourceAlbum(
    for albumID: AlbumID,
    in mutations: [LibraryMutation]
  ) -> Album? {
    mutations.compactMap { mutation -> Album? in
      guard case .upsert(.album(let album)) = mutation,
            album.id == albumID
      else { return nil }
      return album
    }.first
  }

  private static func mergingSourceMetadata(
    sourceTrack: Track,
    existingTrack: Track,
    previousSource: TrackSourceMetadataSnapshot?,
    existingAlbum: Album?,
    sourceAlbum: Album?,
    forceSourceArtwork: Bool,
    forceSourceAudioSelection: Bool,
    repairLegacyMetadata: Bool,
    repairAlbumIdentity: Bool
  ) -> Track {
    let repairsLegacyTitle = repairLegacyMetadata && (
      (isPrivateStagingTitle(existingTrack.title)
        && !isPrivateStagingTitle(sourceTrack.title))
      || (MetadataTextRepair.isLikelyMojibake(existingTrack.title)
        && !MetadataTextRepair.isLikelyMojibake(sourceTrack.title))
    )
    let repairsLegacyAlbum = repairAlbumIdentity || (repairLegacyMetadata
      && Self.repairsLegacyAlbum(
        existingTrack: existingTrack,
        sourceTrack: sourceTrack,
        existingAlbum: existingAlbum,
        sourceAlbum: sourceAlbum
      ))
    let repairsLegacyArtists = repairsLegacyTitle
      && existingTrack.artistIDs.isEmpty
      && !sourceTrack.artistIDs.isEmpty
    let preserveExistingAlbum: Bool
    if let previousSource {
      preserveExistingAlbum = existingAlbum.map(AlbumSourceMetadataSnapshot.init(album:))
        != previousSource.album
    } else {
      preserveExistingAlbum = true
    }
    let audioSelection: AudioStreamSelection?
    if forceSourceAudioSelection {
      audioSelection = sourceTrack.playbackSelection.audioStream
    } else if let previousSource {
      audioSelection = existingTrack.playbackSelection.audioStream
        == previousSource.playbackSelection.audioStream
        ? sourceTrack.playbackSelection.audioStream
        : existingTrack.playbackSelection.audioStream
    } else {
      audioSelection = existingTrack.playbackSelection.audioStream
    }
    let playbackSelection = PlaybackSelection(
      range: sourceTrack.playbackSelection.range,
      audioStream: audioSelection
    )

    guard let previousSource else {
      return Track(
        id: sourceTrack.id,
        logicalTrackID: sourceTrack.logicalTrackID,
        assetID: sourceTrack.assetID,
        playbackSelection: playbackSelection,
        title: repairsLegacyTitle ? sourceTrack.title : existingTrack.title,
        sortTitle: repairsLegacyTitle ? sourceTrack.sortTitle : existingTrack.sortTitle,
        albumID: repairsLegacyAlbum ? sourceTrack.albumID : existingTrack.albumID,
        artistIDs: repairsLegacyArtists ? sourceTrack.artistIDs : existingTrack.artistIDs,
        genreIDs: existingTrack.genreIDs,
        trackNumber: existingTrack.trackNumber,
        trackTotal: existingTrack.trackTotal,
        discNumber: existingTrack.discNumber,
        discTotal: existingTrack.discTotal,
        fileName: sourceTrack.fileName,
        folderPath: sourceTrack.folderPath,
        duration: sourceTrack.duration,
        technicalInfo: sourceTrack.technicalInfo,
        year: existingTrack.year,
        comment: existingTrack.comment,
        lyrics: existingTrack.lyrics,
        artwork: forceSourceArtwork ? sourceTrack.artwork : existingTrack.artwork,
        isFavorite: existingTrack.isFavorite,
        statistics: existingTrack.statistics
      )
    }

    return Track(
      id: sourceTrack.id,
      logicalTrackID: sourceTrack.logicalTrackID,
      assetID: sourceTrack.assetID,
      playbackSelection: playbackSelection,
      title: repairsLegacyTitle
        ? sourceTrack.title
        : (existingTrack.title == previousSource.title ? sourceTrack.title : existingTrack.title),
      sortTitle: repairsLegacyTitle
        ? sourceTrack.sortTitle
        : (
          existingTrack.sortTitle == previousSource.sortTitle
            ? sourceTrack.sortTitle : existingTrack.sortTitle
        ),
      albumID: repairsLegacyAlbum
        ? sourceTrack.albumID
        : (
          !preserveExistingAlbum && existingTrack.albumID == previousSource.albumID
            ? sourceTrack.albumID : existingTrack.albumID
        ),
      artistIDs: repairsLegacyArtists
        ? sourceTrack.artistIDs
        : (
          existingTrack.artistIDs == previousSource.artistIDs
            ? sourceTrack.artistIDs : existingTrack.artistIDs
        ),
      genreIDs: existingTrack.genreIDs == previousSource.genreIDs
        ? sourceTrack.genreIDs : existingTrack.genreIDs,
      trackNumber: existingTrack.trackNumber == previousSource.trackNumber
        ? sourceTrack.trackNumber : existingTrack.trackNumber,
      trackTotal: existingTrack.trackTotal == previousSource.trackTotal
        ? sourceTrack.trackTotal : existingTrack.trackTotal,
      discNumber: existingTrack.discNumber == previousSource.discNumber
        ? sourceTrack.discNumber : existingTrack.discNumber,
      discTotal: existingTrack.discTotal == previousSource.discTotal
        ? sourceTrack.discTotal : existingTrack.discTotal,
      fileName: sourceTrack.fileName,
      folderPath: sourceTrack.folderPath,
      duration: sourceTrack.duration,
      technicalInfo: sourceTrack.technicalInfo,
      year: existingTrack.year == previousSource.year ? sourceTrack.year : existingTrack.year,
      comment: existingTrack.comment == previousSource.comment
        ? sourceTrack.comment : existingTrack.comment,
      lyrics: existingTrack.lyrics == previousSource.lyrics
        ? sourceTrack.lyrics : existingTrack.lyrics,
      artwork: forceSourceArtwork || existingTrack.artwork == previousSource.artwork
        ? sourceTrack.artwork : existingTrack.artwork,
      isFavorite: existingTrack.isFavorite,
      statistics: existingTrack.statistics
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

  private static func applyingMetadataHint(
    _ hint: MediaImportMetadataHint?,
    to embedded: RawMediaMetadata,
    parsedFileURL: URL
  ) -> RawMediaMetadata {
    guard let hint else { return embedded }
    let parsedFileNames = [
      parsedFileURL.lastPathComponent,
      parsedFileURL.deletingPathExtension().lastPathComponent,
    ]
    let embeddedTitleIsParserFileName = embedded.title.map { title in
      parsedFileNames.contains {
        $0.caseInsensitiveCompare(title) == .orderedSame
      }
    } ?? false
    let hintedDisplayTitle = hint.displayName.map {
      URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
    }
    let resolvedTitle = embeddedTitleIsParserFileName
      ? (hint.title ?? hintedDisplayTitle ?? embedded.title)
      : (embedded.title ?? hint.title ?? hintedDisplayTitle)
    return RawMediaMetadata(
      title: resolvedTitle,
      artist: embedded.artist ?? hint.artist,
      album: embedded.album ?? hint.album,
      albumArtist: embedded.albumArtist,
      composer: embedded.composer,
      genre: embedded.genre,
      comment: embedded.comment,
      lyrics: embedded.lyrics,
      trackNumber: embedded.trackNumber,
      discNumber: embedded.discNumber,
      year: embedded.year,
      duration: embedded.duration ?? hint.duration,
      artworks: embedded.artworks
    )
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

  private static func hasRecognizedAudioExtension(_ url: URL) -> Bool {
    switch url.pathExtension.lowercased() {
    case "aac", "ac3", "aif", "aiff", "alac", "ape", "caf", "dts", "flac",
      "m4a", "m4b", "mka", "mp3", "mpc", "oga", "ogg", "opus", "wav", "webm", "wma", "wv":
      return true
    default:
      return false
    }
  }
}
