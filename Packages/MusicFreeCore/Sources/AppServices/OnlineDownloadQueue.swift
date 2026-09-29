import Foundation
import MediaSourceAPI
import MusicDomain

public enum OnlineSourceDownloadPhase: String, Codable, Equatable, Sendable {
    case waiting
    case downloading
    case importing
    case completed
    case alreadyImported
    case skipped
    case cancelled
    case failed
}

public struct OnlineSourceDownloadSnapshot: Codable, Equatable, Sendable {
    public let itemID: SourceObjectID
    public let displayName: String
    public var phase: OnlineSourceDownloadPhase
    public var failureReason: String?
    public var taskID: SourceObjectID?
    public var relativePath: String?
    public var receivedBytes: Int64?
    public var totalBytes: Int64?
    public var bytesPerSecond: Double?
    public var isSupportingFile: Bool?
    public var createdAt: Date?

    public init(
        itemID: SourceObjectID,
        displayName: String,
        phase: OnlineSourceDownloadPhase,
        failureReason: String? = nil
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.phase = phase
        self.failureReason = failureReason
    }

    public var isActive: Bool { phase == .downloading || phase == .importing }
    public var isSuccessful: Bool { [.completed, .alreadyImported, .skipped].contains(phase) }
    public var progress: Double? {
        guard let totalBytes, totalBytes > 0, let receivedBytes else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

public struct OnlineSourceDirectorySnapshot: Codable, Equatable, Sendable {
    public let itemID: SourceObjectID
    public let path: String
    public var isExpanded: Bool
    public init(itemID: SourceObjectID, path: String, isExpanded: Bool = false) {
        self.itemID = itemID
        self.path = path
        self.isExpanded = isExpanded
    }
}

public enum OnlineSourceImportPhase: String, Codable, Equatable, Sendable {
    case waiting
    case discovering
    case downloading
    case importing
    case completed
    case cancelled
    case failed

    public var isActive: Bool {
        switch self {
        case .waiting, .discovering, .downloading, .importing: true
        case .completed, .cancelled, .failed: false
        }
    }
}

public struct OnlineSourceImportSnapshot: Codable, Equatable, Sendable {
    public let rootItemID: SourceObjectID
    public let displayName: String
    public var phase: OnlineSourceImportPhase
    public var totalItems: Int
    public let processedItems: Int
    public let importedItems: Int
    public let duplicateItems: Int
    public let skippedItems: Int
    public let failedItems: Int
    public let currentItemName: String?
    public var failureReason: String?
    public var directories: [OnlineSourceDirectorySnapshot]?
    public var createdAt: Date?
    public var isSelection: Bool?
    public var files: [OnlineSourceDownloadSnapshot]?
    public var catalogRootItemID: SourceObjectID?
    public var isSingleFile: Bool?

    public init(
        rootItemID: SourceObjectID,
        displayName: String,
        phase: OnlineSourceImportPhase,
        totalItems: Int = 0,
        processedItems: Int = 0,
        importedItems: Int = 0,
        duplicateItems: Int = 0,
        skippedItems: Int = 0,
        failedItems: Int = 0,
        currentItemName: String? = nil,
        failureReason: String? = nil
    ) {
        self.rootItemID = rootItemID
        self.displayName = displayName
        self.phase = phase
        self.totalItems = max(0, totalItems)
        self.processedItems = max(0, processedItems)
        self.importedItems = max(0, importedItems)
        self.duplicateItems = max(0, duplicateItems)
        self.skippedItems = max(0, skippedItems)
        self.failedItems = max(0, failedItems)
        self.currentItemName = currentItemName
        self.failureReason = failureReason
    }

    public var progress: Double? {
        guard phase != .discovering, totalItems > 0 else { return nil }
        return min(1, Double(processedItems) / Double(totalItems))
    }
}

public struct OnlineDownloadQueueSnapshot: Equatable, Sendable {
    public let downloads: [SourceObjectID: OnlineSourceDownloadSnapshot]
    public let imports: [SourceObjectID: OnlineSourceImportSnapshot]

    public init(
        downloads: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:],
        imports: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
    ) {
        self.downloads = downloads
        self.imports = imports
    }

    public var activeTaskCount: Int {
        let activeDownloads = downloads.values.filter {
            guard $0.taskID == nil else { return false }
            return switch $0.phase {
            case .waiting, .downloading, .importing:
                true
            case .completed, .alreadyImported, .skipped, .cancelled, .failed:
                false
            }
        }.count
        let activeImports = imports.values.filter {
            switch $0.phase {
            case .waiting, .discovering, .downloading, .importing:
                true
            case .completed, .cancelled, .failed:
                false
            }
        }.count
        return activeDownloads + activeImports
    }
}

/// Redacted request information needed to recreate one interrupted download
/// after the application process is restarted. It intentionally contains no
/// resolved URL, HTTP header, credential, session, or player state.
public struct OnlineDownloadQueueDownloadTask: Codable, Equatable, Sendable {
    public let itemID: SourceObjectID
    public let displayName: String
    public let metadataHint: MediaImportMetadataHint
    public let supportingParentID: SourceObjectID?

    public init(
        itemID: SourceObjectID,
        displayName: String,
        metadataHint: MediaImportMetadataHint,
        supportingParentID: SourceObjectID? = nil
    ) {
        self.itemID = itemID
        self.displayName = displayName
        self.metadataHint = metadataHint
        self.supportingParentID = supportingParentID
    }
}

/// Redacted request information needed to recreate one interrupted recursive
/// import. The root is resolved from the source again after restart.
public struct OnlineDownloadQueueImportTask: Codable, Equatable, Sendable {
    public let rootItemID: SourceObjectID
    public let displayName: String
    public var selectedItems: [SourceCatalogItem]?
    public var catalogRootItem: SourceCatalogItem?
    public var singleDownload: OnlineDownloadQueueDownloadTask?

    public init(rootItemID: SourceObjectID, displayName: String) {
        self.rootItemID = rootItemID
        self.displayName = displayName
    }
}

public struct OnlineDownloadQueuePersistenceState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let downloads: [OnlineSourceDownloadSnapshot]
    public let imports: [OnlineSourceImportSnapshot]
    public let pendingDownloads: [OnlineDownloadQueueDownloadTask]
    public let pendingImports: [OnlineDownloadQueueImportTask]
    public var resumableDownloads: [OnlineDownloadQueueDownloadTask]?
    public var resumableImports: [OnlineDownloadQueueImportTask]?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        downloads: [OnlineSourceDownloadSnapshot] = [],
        imports: [OnlineSourceImportSnapshot] = [],
        pendingDownloads: [OnlineDownloadQueueDownloadTask] = [],
        pendingImports: [OnlineDownloadQueueImportTask] = []
    ) {
        self.schemaVersion = schemaVersion
        self.downloads = downloads
        self.imports = imports
        self.pendingDownloads = pendingDownloads
        self.pendingImports = pendingImports
    }
}

/// Persistence port for redacted online download/import state. The app owns
/// the concrete store; AppServices only depends on this capability.
public protocol OnlineDownloadQueueStore: Sendable {
    func load() -> OnlineDownloadQueuePersistenceState?
    func save(_ state: OnlineDownloadQueuePersistenceState)
    func flush() async
}

public extension OnlineDownloadQueueStore { func flush() async {} }

/// App-owned download/import work for online sources.
///
/// The queue deliberately owns only transient tasks and redacted state. It
/// never stores remote URLs, request headers, credentials, sessions, tokens,
/// or player objects. A task remains alive while the application service graph
/// is alive, independent of whether a source detail view is currently shown.
@MainActor
public final class OnlineDownloadQueue {
    private static let virtualRootExternalID = "__online_source_root__"
    private static let maxItems = 10_000
    private static let maxDepth = 64
    private static let maxConcurrentDownloads = 3

    private struct ImportedItemOutcome: Sendable {
        let imported: Int
        let duplicate: Int
        let skipped: Int
        let failed: Int

        var total: Int {
            imported + duplicate + skipped + failed
        }
    }

    private struct DiscoveredImportItem: Sendable {
        let media: SourceCatalogItem
        let supportingItems: [SourceCatalogItem]
    }

    private struct DiscoveryResult: Sendable {
        let items: [DiscoveredImportItem]
        let missingItemCount: Int
    }

    private struct SupportingFileIndex: Sendable {
        let commonArtwork: [SourceCatalogItem]
        let lyricsByStem: [String: [SourceCatalogItem]]

        func items(for media: SourceCatalogItem) -> [SourceCatalogItem] {
            let stem = Self.normalizedStem(media.displayName)
            return Self.mergeSorted(
                commonArtwork,
                lyricsByStem[stem] ?? []
            )
        }

        private static func normalizedStem(_ name: String) -> String {
            URL(fileURLWithPath: name)
                .deletingPathExtension()
                .lastPathComponent
                .folding(options: .caseInsensitive, locale: nil)
        }

        private static func mergeSorted(
            _ left: [SourceCatalogItem],
            _ right: [SourceCatalogItem]
        ) -> [SourceCatalogItem] {
            var result: [SourceCatalogItem] = []
            result.reserveCapacity(left.count + right.count)
            var leftIndex = 0
            var rightIndex = 0
            while leftIndex < left.count, rightIndex < right.count {
                if left[leftIndex].displayName.localizedStandardCompare(
                    right[rightIndex].displayName
                ) == .orderedAscending {
                    result.append(left[leftIndex])
                    leftIndex += 1
                } else {
                    result.append(right[rightIndex])
                    rightIndex += 1
                }
            }
            if leftIndex < left.count {
                result.append(contentsOf: left[leftIndex...])
            }
            if rightIndex < right.count {
                result.append(contentsOf: right[rightIndex...])
            }
            return result
        }
    }

    private struct DirectoryDiscoveryEntry: Sendable {
        let items: [SourceCatalogItem]
        let supportingFiles: SupportingFileIndex
    }

    private struct SupportingTransferKey: Hashable, Sendable {
        let operationID: UUID
        let itemID: SourceObjectID
    }

    private enum BatchItemResult: Sendable {
        case completed(SourceCatalogItem, ImportedItemOutcome)
        case failed(SourceCatalogItem)
    }

    private enum QueueError: Error {
        case importerUnavailable
        case emptyCatalog
        case catalogTooLarge
        case catalogDepthExceeded
        case importStreamEnded
    }

    public let onlineSources: any OnlineSourceServing
    public let importer: (any ImportServing)?
    private var stateSnapshot = OnlineDownloadQueueSnapshot()
    private var fileProgress: [SourceObjectID: DownloadProgress] = [:]

    public var snapshot: OnlineDownloadQueueSnapshot {
        guard !fileProgress.isEmpty else { return stateSnapshot }
        var downloads = stateSnapshot.downloads
        for id in fileProgress.keys { downloads[id] = fileSnapshot(for: id) }
        return OnlineDownloadQueueSnapshot(downloads: downloads, imports: stateSnapshot.imports)
    }

    public func fileSnapshot(for itemID: SourceObjectID) -> OnlineSourceDownloadSnapshot? {
        guard var file = stateSnapshot.downloads[itemID] else { return nil }
        if let progress = fileProgress[itemID] {
            file.receivedBytes = progress.receivedBytes
            file.totalBytes = progress.totalBytes
            file.bytesPerSecond = progress.bytesPerSecond
        }
        return file
    }

    private let persistence: (any OnlineDownloadQueueStore)?
    private var continuations: [UUID: AsyncStream<OnlineDownloadQueueSnapshot>.Continuation] = [:]
    private var downloadOperationIDs: [SourceObjectID: UUID] = [:]
    private var downloadImportIDs: [SourceObjectID: UUID] = [:]
    private var importTasks: [SourceObjectID: Task<Void, Never>] = [:]
    private var importOperationIDs: [SourceObjectID: UUID] = [:]
    private var importActiveItemIDs: [SourceObjectID: Set<SourceObjectID>] = [:]
    private var pendingImports: [SourceObjectID: OnlineDownloadQueueImportTask] = [:]
    private var resumableDownloads: [SourceObjectID: OnlineDownloadQueueDownloadTask] = [:]
    private var resumableImports: [SourceObjectID: OnlineDownloadQueueImportTask] = [:]
    private var batchFileTasks: [SourceObjectID: Task<BatchItemResult, Error>] = [:]
    private var supportingTransfers: [SupportingTransferKey: Task<URL, Error>] = [:]
    private var supportingTemporaryURLs: [SupportingTransferKey: URL] = [:]
    private var cancelledFileIDs: [SourceObjectID: Set<SourceObjectID>] = [:]
    private var progressContinuations: [UUID: AsyncStream<SourceObjectID>.Continuation] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var didRestorePersistence = false
    private var isShuttingDown = false
    private var isShutDown = false
    // One user operation at a time; recursive operations still download three files concurrently.
    private var operationTail: Task<Void, Never>?

    public init(
        onlineSources: any OnlineSourceServing,
        importer: (any ImportServing)?,
        persistence: (any OnlineDownloadQueueStore)? = nil
    ) {
        self.onlineSources = onlineSources
        self.importer = importer
        self.persistence = persistence
    }

    /// Restores redacted task history and recreates interrupted work after the
    /// online-source authorization gate has been applied. A source that is no
    /// longer available is recorded as cancelled instead of issuing an
    /// unauthorized request.
    public func restore(using sourceSnapshot: OnlineSourceSnapshot) {
        guard !didRestorePersistence else { return }
        didRestorePersistence = true
        guard let persistence,
              let state = persistence.load(),
              state.schemaVersion == OnlineDownloadQueuePersistenceState.currentSchemaVersion
        else {
            return
        }

        for request in (state.resumableDownloads ?? []) + state.pendingDownloads {
            resumableDownloads[request.itemID] = request
        }
        for request in (state.resumableImports ?? []) + state.pendingImports {
            resumableImports[request.rootItemID] = request
        }
        var downloads: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:]
        for value in state.downloads where downloads[value.itemID] == nil {
            downloads[value.itemID] = value
        }
        var imports: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
        for value in state.imports where imports[value.rootItemID] == nil {
            imports[value.rootItemID] = value
        }

        let pendingDownloadTasks = state.pendingDownloads.sorted { $0.itemID < $1.itemID }
        let pendingDownloadIDs = Set(pendingDownloadTasks.map(\.itemID))
        var cancelledDownloads: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:]
        for value in Array(downloads.values)
            where isActive(value.phase) && !pendingDownloadIDs.contains(value.itemID) {
            var cancelled = value
            cancelled.phase = .cancelled
            cancelled.failureReason = "interrupted"
            downloads[value.itemID] = cancelled
            cancelledDownloads[value.itemID] = cancelled
        }

        let pendingImportTasks = state.pendingImports.sorted { $0.rootItemID < $1.rootItemID }
        let pendingImportIDs = Set(pendingImportTasks.map(\.rootItemID))
        var cancelledImports: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
        for value in Array(imports.values)
            where isActive(value.phase) && !pendingImportIDs.contains(value.rootItemID) {
            var cancelled = value
            cancelled.phase = .cancelled
            cancelled.failureReason = "interrupted"
            imports[value.rootItemID] = cancelled
            cancelledImports[value.rootItemID] = cancelled
        }
        stateSnapshot = OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports)

        for task in pendingDownloadTasks {
            guard canResume(sourceID: task.itemID.sourceID, using: sourceSnapshot) else {
                var cancelled = downloads[task.itemID] ?? OnlineSourceDownloadSnapshot(itemID: task.itemID, displayName: task.displayName, phase: .cancelled)
                cancelled.phase = .cancelled
                cancelled.failureReason = "source_unavailable"
                downloads[task.itemID] = cancelled
                cancelledDownloads[task.itemID] = cancelled
                continue
            }
            enqueueSingleDownload(task, taskID: task.itemID)
        }

        for task in pendingImportTasks {
            guard canResume(sourceID: task.rootItemID.sourceID, using: sourceSnapshot) else {
                var cancelled = imports[task.rootItemID] ?? OnlineSourceImportSnapshot(rootItemID: task.rootItemID, displayName: task.displayName, phase: .cancelled)
                cancelled.phase = .cancelled
                cancelled.failureReason = "source_unavailable"
                imports[task.rootItemID] = cancelled
                cancelledImports[task.rootItemID] = cancelled
                continue
            }
            enqueueImport(
                sourceID: task.rootItemID.sourceID,
                taskItem: SourceCatalogItem(
                    id: task.rootItemID,
                    kind: .folder,
                    displayName: task.displayName
                ),
                catalogRootItem: task.catalogRootItem,
                selectedItems: task.selectedItems,
                singleDownload: task.singleDownload
            )
        }

        var finalDownloads = stateSnapshot.downloads
        finalDownloads.merge(cancelledDownloads) { _, new in new }
        var finalImports = stateSnapshot.imports
        finalImports.merge(cancelledImports) { _, new in new }
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: finalDownloads,
                imports: finalImports
            ),
            persistImmediately: true
        )
    }

    public func makeSnapshotStream() -> AsyncStream<OnlineDownloadQueueSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Byte updates bypass the catalog/state stream and never persist every chunk.
    public func makeProgressStream() -> AsyncStream<SourceObjectID> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            progressContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.progressContinuations.removeValue(forKey: id) }
            }
        }
    }

    private func downloadOptions(for itemID: SourceObjectID, name: String, operationID: UUID) -> DownloadOptions {
        DownloadOptions(preferredFileName: name, progress: { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateProgress(progress, itemID: itemID, operationID: operationID)
            }
        })
    }

    private func updateProgress(_ progress: DownloadProgress, itemID: SourceObjectID, operationID: UUID) {
        guard downloadOperationIDs[itemID] == operationID,
              stateSnapshot.downloads[itemID]?.phase == .downloading else { return }
        fileProgress[itemID] = progress
        progressContinuations.values.forEach { $0.yield(itemID) }
    }

    public func resumeTask(_ taskID: SourceObjectID) {
        guard !isShutDown, canResumeTask(taskID) else { return }
        if let request = resumableImports[taskID] {
            enqueueImport(sourceID: taskID.sourceID, taskItem: SourceCatalogItem(id: taskID, kind: .folder, displayName: request.displayName), catalogRootItem: request.catalogRootItem, selectedItems: request.selectedItems, singleDownload: request.singleDownload)
        } else if let request = resumableDownloads[taskID] {
            enqueueSingleDownload(request, taskID: taskID)
        }
    }

    public func canResumeTask(_ taskID: SourceObjectID) -> Bool {
        guard importTasks[taskID] == nil,
              resumableDownloads[taskID] != nil || resumableImports[taskID] != nil
        else {
            return false
        }
        if let task = stateSnapshot.imports[taskID] {
            return task.phase != .completed
        }
        if let file = stateSnapshot.downloads[taskID], file.taskID == nil {
            return !file.isSuccessful
        }
        return true
    }

    public func clearCompletedTasks() {
        let completedTasks = Set(stateSnapshot.tasks.filter { $0.phase == .completed }.map(\.id))
        let downloads = stateSnapshot.downloads.filter { id, file in
            return !completedTasks.contains(file.taskID ?? id) || downloadOperationIDs[id] != nil
        }
        for id in completedTasks { resumableImports.removeValue(forKey: id) }
        for id in stateSnapshot.downloads.keys where downloads[id] == nil { resumableDownloads.removeValue(forKey: id) }
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: stateSnapshot.imports.filter { !completedTasks.contains($0.key) }
            ),
            persistImmediately: true
        )
    }

    private func canResume(
        sourceID: MediaSourceID,
        using sourceSnapshot: OnlineSourceSnapshot
    ) -> Bool {
        guard sourceSnapshot.isApplicationPrivacyAccepted,
              sourceSnapshot.isGloballyEnabled
        else {
            return false
        }
        return sourceSnapshot.sources.first {
            $0.sourceID == sourceID
        }?.isRuntimeEnabled == true
    }

    private func isActive(_ phase: OnlineSourceDownloadPhase) -> Bool {
        switch phase {
        case .waiting, .downloading, .importing:
            true
        case .completed, .alreadyImported, .skipped, .cancelled, .failed:
            false
        }
    }

    private func isActive(_ phase: OnlineSourceImportPhase) -> Bool {
        switch phase {
        case .waiting, .discovering, .downloading, .importing:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    @discardableResult
    public func startDownload(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        displayName: String,
        metadataHint: MediaImportMetadataHint? = nil,
        supportingParentID: SourceObjectID? = nil
    ) -> SourceObjectID? {
        guard !isShutDown, itemID.sourceID == sourceID else { return nil }
        let taskID = SourceObjectID(sourceID: sourceID, externalID: "__download_" + UUID().uuidString)
        let request = OnlineDownloadQueueDownloadTask(
            itemID: itemID,
            displayName: displayName,
            metadataHint: metadataHint
                ?? MediaImportMetadataHint(displayName: displayName),
            supportingParentID: supportingParentID
        )
        enqueueSingleDownload(request, taskID: taskID)
        return taskID
    }

    private func enqueueSingleDownload(_ request: OnlineDownloadQueueDownloadTask, taskID: SourceObjectID) {
        // Legacy standalone tasks keep their original ID when moving into the shared runner.
        if taskID == request.itemID, stateSnapshot.imports[taskID] == nil {
            var downloads = stateSnapshot.downloads
            var imports = stateSnapshot.imports
            archiveTaskFiles([taskID], downloads: &downloads, imports: &imports)
            stateSnapshot = OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports)
        }
        resumableDownloads.removeValue(forKey: taskID)
        let hint = request.metadataHint
        let media = SourceCatalogItem(id: request.itemID, kind: .audioFile, displayName: request.displayName, parentID: request.supportingParentID, title: hint.title, artist: hint.artist, album: hint.album, duration: hint.duration)
        enqueueImport(sourceID: taskID.sourceID, taskItem: SourceCatalogItem(id: taskID, kind: .folder, displayName: request.displayName), catalogRootItem: nil, selectedItems: [media], singleDownload: request)
    }

    @discardableResult
    public func startImport(
        sourceID: MediaSourceID,
        item: SourceCatalogItem,
        selectedItems: [SourceCatalogItem]? = nil
    ) -> SourceObjectID? {
        guard item.id.sourceID == sourceID, !isShutDown else { return nil }
        guard item.kind.isContainer else {
            return startDownload(
                sourceID: sourceID,
                itemID: item.id,
                displayName: item.displayName,
                metadataHint: Self.importMetadataHint(for: item),
                supportingParentID: item.parentID
                    ?? SourceObjectID(sourceID: sourceID, externalID: Self.virtualRootExternalID)
            )
        }
        let prefix = selectedItems == nil ? "__import_" : "__selection_"
        let taskItem = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: prefix + UUID().uuidString), kind: .folder, displayName: item.displayName)
        enqueueImport(sourceID: sourceID, taskItem: taskItem, catalogRootItem: selectedItems == nil ? item : nil, selectedItems: selectedItems)
        return taskItem.id
    }

    private func enqueueImport(
        sourceID: MediaSourceID,
        taskItem item: SourceCatalogItem,
        catalogRootItem: SourceCatalogItem?,
        selectedItems: [SourceCatalogItem]?,
        singleDownload: OnlineDownloadQueueDownloadTask? = nil
    ) {
        guard !isShutDown, importTasks[item.id] == nil else { return }

        cancelledFileIDs.removeValue(forKey: item.id)

        let operationID = UUID()
        pendingImports[item.id] = OnlineDownloadQueueImportTask(
            rootItemID: item.id,
            displayName: item.displayName
        )
        pendingImports[item.id]?.selectedItems = selectedItems
        pendingImports[item.id]?.catalogRootItem = catalogRootItem
        pendingImports[item.id]?.singleDownload = singleDownload
        resumableImports[item.id] = pendingImports[item.id]
        importOperationIDs[item.id] = operationID
        snapshotImports(
            rootItem: item,
            phase: .waiting,
            operationID: operationID
        )
        let previous = operationTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.performBatchImport(
                sourceID: sourceID,
                rootItem: item,
                operationID: operationID,
                catalogRootItem: catalogRootItem,
                selectedItems: selectedItems
            )
        }
        importTasks[item.id] = task
        operationTail = task
    }

    public func startBatchImport(sourceID: MediaSourceID, items: [SourceCatalogItem], displayName: String) {
        let selection = items.filter { $0.id.sourceID == sourceID && ($0.kind.isContainer || $0.isDownloadable) }
        guard !selection.isEmpty else { return }
        let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "__selection__"), kind: .folder, displayName: displayName)
        startImport(sourceID: sourceID, item: root, selectedItems: selection)
    }

    public func startImportFromRoot(
        sourceID: MediaSourceID,
        displayName: String
    ) {
        let rootItem = SourceCatalogItem(
            id: SourceObjectID(
                sourceID: sourceID,
                externalID: Self.virtualRootExternalID
            ),
            kind: .folder,
            displayName: displayName
        )
        startImport(sourceID: sourceID, item: rootItem)
    }

    public func cancelTask(_ taskID: SourceObjectID) async {
        if importTasks[taskID] != nil { await cancelImport(taskID) }
    }

    public func cancelDownload(_ itemID: SourceObjectID, taskID: SourceObjectID? = nil) async {
        guard let owner = taskID ?? stateSnapshot.downloads[itemID]?.taskID,
              importOperationIDs[owner] != nil else { return }
        if pendingImports[owner]?.singleDownload?.itemID == itemID {
            await cancelImport(owner)
            return
        }
        guard let file = stateSnapshot.downloads[itemID], file.taskID == owner,
              file.isActive || file.phase == .waiting else { return }
        cancelledFileIDs[owner, default: []].insert(itemID)
        guard downloadOperationIDs[itemID] != nil else {
            publishDownload(itemID: itemID, displayName: file.displayName, phase: .cancelled)
            return
        }
        let batchTask = batchFileTasks.removeValue(forKey: itemID)
        let importID = downloadImportIDs.removeValue(forKey: itemID)
        downloadOperationIDs.removeValue(forKey: itemID)
        batchTask?.cancel()
        publishDownload(
            itemID: itemID,
            displayName: stateSnapshot.downloads[itemID]?.displayName ?? itemID.externalID,
            phase: .cancelled
        )
        if let importID { await importer?.cancel(importID) }
    }

    public func cancelImport(_ rootItemID: SourceObjectID) async {
        guard let operationID = importOperationIDs[rootItemID] else { return }
        let task = importTasks.removeValue(forKey: rootItemID)
        let activeItemIDs = (importActiveItemIDs.removeValue(forKey: rootItemID) ?? []).union(stateSnapshot.downloads.values.filter { $0.taskID == rootItemID && ($0.isActive || $0.phase == .waiting) }.map(\.itemID))
        let importIDs = activeItemIDs.compactMap { downloadImportIDs[$0] }
        importOperationIDs.removeValue(forKey: rootItemID)
        pendingImports.removeValue(forKey: rootItemID)
        task?.cancel()
        for itemID in activeItemIDs {
            downloadOperationIDs.removeValue(forKey: itemID)
            batchFileTasks.removeValue(forKey: itemID)?.cancel()
        }
        discardSupportingTransfers(operationID: operationID)
        var downloads = stateSnapshot.downloads
        for itemID in activeItemIDs {
            if let file = fileSnapshot(for: itemID), file.isActive || file.phase == .waiting {
                downloads[itemID] = file
                downloads[itemID]?.phase = .cancelled
                downloads[itemID]?.bytesPerSecond = nil
            }
        }
        var imports = stateSnapshot.imports
        let cancelledFiles = imports[rootItemID]?.files?.map { file in
            var file = file
            if file.isActive || file.phase == .waiting { file.phase = .cancelled; file.bytesPerSecond = nil }
            return file
        }
        imports[rootItemID]?.files = cancelledFiles
        publish(OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports))

        guard let current = stateSnapshot.imports[rootItemID] else { return }
        snapshotImports(
            rootItem: SourceCatalogItem(
                id: current.rootItemID,
                kind: .folder,
                displayName: current.displayName
            ),
            phase: .cancelled,
            totalItems: current.totalItems,
            processedItems: current.processedItems,
            importedItems: current.importedItems,
            duplicateItems: current.duplicateItems,
            skippedItems: current.skippedItems,
            failedItems: current.failedItems,
            operationID: nil
        )
        for importID in importIDs { await importer?.cancel(importID) }
    }

    public func stop(for sourceID: MediaSourceID? = nil) async {
        let rootItemIDs = importTasks.keys.filter {
            sourceID == nil || $0.sourceID == sourceID
        }
        for rootItemID in rootItemIDs {
            await cancelImport(rootItemID)
        }
    }

    public func discardSnapshots(for sourceID: MediaSourceID) {
        let downloads = stateSnapshot.downloads.filter { $0.key.sourceID != sourceID }
        let imports = stateSnapshot.imports.filter { $0.key.sourceID != sourceID }
        pendingImports = pendingImports.filter { $0.key.sourceID != sourceID }
        resumableDownloads = resumableDownloads.filter { $0.key.sourceID != sourceID }
        resumableImports = resumableImports.filter { $0.key.sourceID != sourceID }
        cancelledFileIDs = cancelledFileIDs.filter { $0.key.sourceID != sourceID }
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: imports
            )
        )
    }

    public func stopUnavailable(using sourceSnapshot: OnlineSourceSnapshot) async {
        let rootItemIDs = importTasks.keys.filter { rootItemID in
            sourceSnapshot.sources.first(where: { $0.sourceID == rootItemID.sourceID })?.isRuntimeEnabled != true
        }
        for rootItemID in rootItemIDs {
            await cancelImport(rootItemID)
        }
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShuttingDown = true
        importTasks.values.forEach { $0.cancel() }
        supportingTransfers.values.forEach { $0.cancel() }
        let importIDs = Set(downloadImportIDs.values)
        for importID in importIDs {
            await importer?.cancel(importID)
        }
        persistenceTask?.cancel()
        persistenceTask = nil
        persistNow()
        await persistence?.flush()
        isShutDown = true
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
        progressContinuations.values.forEach { $0.finish() }
        progressContinuations.removeAll()
    }

    private func downloadAndImportItem(
        sourceID: MediaSourceID,
        item: DiscoveredImportItem,
        rootItemID: SourceObjectID,
        operationID: UUID
    ) async throws -> ImportedItemOutcome {
        guard let importer else { throw QueueError.importerUnavailable }

        let media = item.media
        try Task.checkCancellation()
        guard importOperationIDs[rootItemID] == operationID else { throw CancellationError() }
        if let previous = stateSnapshot.downloads[media.id], previous.taskID == rootItemID, previous.isSuccessful {
            return ImportedItemOutcome(imported: previous.phase == .completed ? 1 : 0, duplicate: previous.phase == .alreadyImported ? 1 : 0, skipped: previous.phase == .skipped ? 1 : 0, failed: 0)
        }
        guard cancelledFileIDs[rootItemID]?.contains(media.id) != true else { throw CancellationError() }
        downloadOperationIDs[media.id] = operationID
        defer {
            if downloadOperationIDs[media.id] == operationID { downloadOperationIDs.removeValue(forKey: media.id) }
        }

        publishDownload(
            itemID: media.id,
            displayName: media.displayName,
            phase: .downloading,
            operationID: operationID
        )
        let receipt = try await onlineSources.download(
            sourceID: sourceID,
            itemID: media.id,
            options: downloadOptions(for: media.id, name: media.displayName, operationID: operationID)
        )
        try Task.checkCancellation()
        if let bytes = receipt.byteCount {
            updateProgress(DownloadProgress(receivedBytes: bytes, totalBytes: bytes), itemID: media.id, operationID: operationID)
        }
        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFreeOnlineImportBundles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleRoot) }

        let stagedURL = try await Self.stageDownloadedFile(
            from: receipt.fileURL,
            preferredFileName: media.displayName,
            into: bundleRoot
        )
        var importURLs = [stagedURL]
        importURLs += try await downloadSupportingItems(
            item.supportingItems,
            taskID: rootItemID,
            operationID: operationID,
            into: bundleRoot
        )
        try Task.checkCancellation()

        let importID = UUID()
        downloadImportIDs[media.id] = importID
        defer {
            if downloadImportIDs[media.id] == importID {
                downloadImportIDs.removeValue(forKey: media.id)
            }
        }

        let stream = try await importer.start(
            MediaImportRequest(
                importID: importID,
                urls: importURLs,
                duplicatePolicy: .report,
                metadataHints: [stagedURL: pendingImports[rootItemID]?.singleDownload?.metadataHint ?? Self.importMetadataHint(for: media)]
            )
        )
        publishDownload(
            itemID: media.id,
            displayName: media.displayName,
            phase: .importing,
            operationID: operationID
        )

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case let .completed(_, result):
                let outcome = ImportedItemOutcome(
                    imported: result.imported,
                    duplicate: result.duplicate,
                    skipped: result.skipped,
                    failed: result.failed
                )
                guard outcome.total > 0 else {
                    throw QueueError.importStreamEnded
                }
                publishDownload(
                    itemID: media.id,
                    displayName: media.displayName,
                    phase: Self.downloadPhase(for: result),
                    failureReason: result.failed > 0 ? "import_failed" : nil,
                    operationID: operationID
                )
                if result.failed == 0 { finishSupportingItems(item.supportingItems, operationID: operationID) }
                return outcome
            case .cancelled:
                throw CancellationError()
            default:
                continue
            }
        }
        throw QueueError.importStreamEnded
    }

    private func downloadSupportingItems(
        _ items: [SourceCatalogItem],
        taskID: SourceObjectID,
        operationID: UUID,
        into directory: URL
    ) async throws -> [URL] {
        var urls: [URL] = []
        for item in items {
            try Task.checkCancellation()
            let key = SupportingTransferKey(
                operationID: operationID,
                itemID: item.id
            )
            if supportingTransfers[key] == nil {
                var file = OnlineSourceDownloadSnapshot(itemID: item.id, displayName: item.displayName, phase: .waiting)
                file.taskID = taskID
                file.isSupportingFile = true
                file.totalBytes = item.byteSize
                file.createdAt = Date()
                file.relativePath = stateSnapshot.downloads[item.id]?.relativePath
                var downloads = stateSnapshot.downloads
                var imports = stateSnapshot.imports
                if let previous = downloads[item.id], let owner = previous.taskID, owner != taskID {
                    archiveTaskFiles([owner], downloads: &downloads, imports: &imports)
                }
                downloads[item.id] = file
                publish(OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports))
            }
            do {
                let transfer: Task<URL, Error>
                if let existing = supportingTransfers[key] {
                    transfer = existing
                } else {
                    downloadOperationIDs[item.id] = operationID
                    publishDownload(itemID: item.id, displayName: item.displayName, phase: .downloading, operationID: operationID)
                    transfer = Task { @MainActor in
                        let receipt = try await self.onlineSources.download(sourceID: item.id.sourceID, itemID: item.id, options: self.downloadOptions(for: item.id, name: item.displayName, operationID: operationID))
                        guard !Task.isCancelled else {
                            try? FileManager.default.removeItem(at: receipt.fileURL)
                            throw CancellationError()
                        }
                        guard self.importOperationIDs[taskID] == operationID else {
                            try? FileManager.default.removeItem(at: receipt.fileURL)
                            throw CancellationError()
                        }
                        self.supportingTemporaryURLs[key] = receipt.fileURL
                        if let bytes = receipt.byteCount { self.updateProgress(DownloadProgress(receivedBytes: bytes, totalBytes: bytes), itemID: item.id, operationID: operationID) }
                        self.publishDownload(itemID: item.id, displayName: item.displayName, phase: .importing, operationID: operationID)
                        return receipt.fileURL
                    }
                    supportingTransfers[key] = transfer
                }
                let fileURL = try await Self.waitForSupportingTransfer(transfer)
                try Task.checkCancellation()
                guard importOperationIDs[taskID] == operationID else {
                    throw CancellationError()
                }
                urls.append(try await Self.copySupportingFile(from: fileURL, preferredFileName: item.displayName, into: directory))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                publishDownload(itemID: item.id, displayName: item.displayName, phase: .skipped, failureReason: "optional_file_unavailable", operationID: operationID)
                if downloadOperationIDs[item.id] == operationID { downloadOperationIDs.removeValue(forKey: item.id) }
            }
        }
        return urls
    }

    private func discardSupportingTransfers(operationID: UUID) {
        let keys = supportingTransfers.keys.filter { $0.operationID == operationID }
        for key in keys {
            supportingTransfers.removeValue(forKey: key)?.cancel()
            if let url = supportingTemporaryURLs.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private nonisolated static func waitForSupportingTransfer(
        _ transfer: Task<URL, Error>
    ) async throws -> URL {
        let stream = AsyncThrowingStream<URL, Error>(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            let waiter = Task {
                do {
                    continuation.yield(try await transfer.value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in waiter.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else {
            throw CancellationError()
        }
        return value
    }

    private func finishSupportingItems(_ items: [SourceCatalogItem], operationID: UUID) {
        for item in items where downloadOperationIDs[item.id] == operationID {
            publishDownload(itemID: item.id, displayName: item.displayName, phase: .completed, operationID: operationID)
            downloadOperationIDs.removeValue(forKey: item.id)
        }
    }

    private func batchItemResult(
        sourceID: MediaSourceID,
        item: DiscoveredImportItem,
        rootItemID: SourceObjectID,
        operationID: UUID
    ) async throws -> BatchItemResult {
        do {
            let outcome = try await downloadAndImportItem(
                sourceID: sourceID,
                item: item,
                rootItemID: rootItemID,
                operationID: operationID
            )
            return .completed(item.media, outcome)
        } catch is CancellationError {
            guard !isShuttingDown, importOperationIDs[rootItemID] == operationID else { throw CancellationError() }
            publishDownload(itemID: item.media.id, displayName: item.media.displayName, phase: .cancelled)
            return .failed(item.media)
        } catch let error as OnlineSourceAuthenticationError {
            throw error
        } catch {
            if isShuttingDown { throw CancellationError() }
            return .failed(item.media)
        }
    }

    private func runBatchItem(sourceID: MediaSourceID, item: DiscoveredImportItem, rootItemID: SourceObjectID, operationID: UUID) async throws -> BatchItemResult {
        let task = Task { @MainActor in
            try await self.batchItemResult(sourceID: sourceID, item: item, rootItemID: rootItemID, operationID: operationID)
        }
        batchFileTasks[item.media.id] = task
        defer { if importOperationIDs[rootItemID] == operationID { batchFileTasks.removeValue(forKey: item.media.id) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performBatchImport(
        sourceID: MediaSourceID,
        rootItem: SourceCatalogItem,
        operationID: UUID,
        catalogRootItem: SourceCatalogItem?,
        selectedItems: [SourceCatalogItem]?
    ) async {
        defer {
            if importOperationIDs[rootItem.id] == operationID {
                discardSupportingTransfers(operationID: operationID)
                var downloads = stateSnapshot.downloads
                for id in downloads.keys where downloads[id]?.taskID == rootItem.id && (downloads[id]?.isActive == true || downloads[id]?.phase == .waiting) {
                    downloads[id] = fileSnapshot(for: id)
                    downloads[id]?.phase = Task.isCancelled ? .cancelled : .failed
                    downloads[id]?.bytesPerSecond = nil
                    downloadOperationIDs.removeValue(forKey: id)
                }
                if !isShuttingDown { publish(OnlineDownloadQueueSnapshot(downloads: downloads, imports: stateSnapshot.imports)) }
                importTasks.removeValue(forKey: rootItem.id)
                importOperationIDs.removeValue(forKey: rootItem.id)
                importActiveItemIDs.removeValue(forKey: rootItem.id)
                if !isShuttingDown {
                pendingImports.removeValue(forKey: rootItem.id)
                cancelledFileIDs.removeValue(forKey: rootItem.id)
                    persistenceTask?.cancel()
                    persistenceTask = nil
                    persistNow()
                }
            } else if Task.isCancelled {
                discardSupportingTransfers(operationID: operationID)
            }
        }

        guard importer != nil else {
            snapshotImports(
                rootItem: rootItem,
                phase: .failed,
                failureReason: "importer_unavailable",
                operationID: operationID
            )
            return
        }

        do {
            snapshotImports(rootItem: rootItem, phase: .discovering, operationID: operationID)
            let discovery = try await discoverImportItems(
                sourceID: sourceID,
                rootItem: rootItem,
                catalogRootItem: catalogRootItem,
                selectedItems: selectedItems,
                operationID: operationID
            )
            try Task.checkCancellation()
            let items = discovery.items
            let totalItems = items.count + discovery.missingItemCount
            guard !items.isEmpty else {
                if discovery.missingItemCount > 0 {
                    snapshotImports(
                        rootItem: rootItem,
                        phase: .completed,
                        totalItems: totalItems,
                        processedItems: totalItems,
                        skippedItems: discovery.missingItemCount,
                        operationID: operationID
                    )
                    return
                }
                snapshotImports(
                    rootItem: rootItem,
                    phase: .failed,
                    failureReason: "empty_catalog",
                    operationID: operationID
                )
                return
            }

            var imported = 0
            var duplicate = 0
            var skipped = discovery.missingItemCount
            var failed = 0
            var processed = discovery.missingItemCount
            let concurrencyLimit = min(Self.maxConcurrentDownloads, items.count)

            try await withThrowingTaskGroup(of: BatchItemResult.self) { group in
                var nextIndex = 0
                for _ in 0..<concurrencyLimit {
                    let item = items[nextIndex]
                    nextIndex += 1
                    importActiveItemIDs[rootItem.id, default: []].insert(item.media.id)
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.runBatchItem(
                            sourceID: sourceID,
                            item: item,
                            rootItemID: rootItem.id,
                            operationID: operationID
                        )
                    }
                }

                snapshotImports(
                    rootItem: rootItem,
                    phase: .downloading,
                    totalItems: totalItems,
                    processedItems: processed,
                    skippedItems: skipped,
                    operationID: operationID
                )

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    let finishedItem: SourceCatalogItem
                    switch result {
                    case let .completed(item, outcome):
                        finishedItem = item
                        imported += outcome.imported
                        duplicate += outcome.duplicate
                        skipped += outcome.skipped
                        failed += outcome.failed
                    case let .failed(item):
                        finishedItem = item
                        failed += 1
                        if stateSnapshot.downloads[item.id]?.phase != .cancelled { publishDownload(
                            itemID: item.id,
                            displayName: item.displayName,
                            phase: .failed,
                            failureReason: "item_import_failed"
                        ) }
                    }
                    importActiveItemIDs[rootItem.id]?.remove(finishedItem.id)
                    processed += 1

                    if nextIndex < items.count {
                        let item = items[nextIndex]
                        nextIndex += 1
                        importActiveItemIDs[rootItem.id, default: []].insert(item.media.id)
                        group.addTask { [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.runBatchItem(
                                sourceID: sourceID,
                                item: item,
                                rootItemID: rootItem.id,
                                operationID: operationID
                            )
                        }
                    }

                    snapshotImports(
                        rootItem: rootItem,
                        phase: .downloading,
                        totalItems: totalItems,
                        processedItems: processed,
                        importedItems: imported,
                        duplicateItems: duplicate,
                        skippedItems: skipped,
                        failedItems: failed,
                        operationID: operationID
                    )
                }
            }

            snapshotImports(
                rootItem: rootItem,
                phase: failed > 0 ? .failed : .completed,
                totalItems: totalItems,
                processedItems: totalItems,
                importedItems: imported,
                duplicateItems: duplicate,
                skippedItems: skipped,
                failedItems: failed,
                failureReason: failed > 0 ? "batch_import_failed" : nil,
                operationID: operationID
            )
        } catch is CancellationError {
            if !isShuttingDown, importOperationIDs[rootItem.id] == operationID {
                let activeItemIDs = importActiveItemIDs[rootItem.id] ?? []
                for itemID in activeItemIDs {
                    publishDownload(
                        itemID: itemID,
                        displayName: stateSnapshot.downloads[itemID]?.displayName ?? itemID.externalID,
                        phase: .cancelled
                    )
                }
                snapshotImports(
                    rootItem: rootItem,
                    phase: .cancelled,
                    operationID: operationID
                )
            }
        } catch let error as OnlineSourceAuthenticationError {
            snapshotImports(
                rootItem: rootItem,
                phase: .failed,
                failureReason: Self.redactedFailureReason(for: error),
                operationID: operationID
            )
        } catch {
            snapshotImports(
                rootItem: rootItem,
                phase: .failed,
                failureReason: Self.redactedFailureReason(for: error),
                operationID: operationID
            )
        }
    }

    private func discoverImportItems(
        sourceID: MediaSourceID,
        rootItem: SourceCatalogItem,
        catalogRootItem: SourceCatalogItem?,
        selectedItems: [SourceCatalogItem]?,
        operationID: UUID
    ) async throws -> DiscoveryResult {
        guard rootItem.kind.isContainer else {
            return DiscoveryResult(
                items: rootItem.isDownloadable
                    ? [DiscoveredImportItem(media: rootItem, supportingItems: [])]
                    : [],
                missingItemCount: 0
            )
        }

        let roots = selectedItems ?? [catalogRootItem ?? rootItem]
        var pending: [(item: SourceCatalogItem, depth: Int, path: String)] = roots.filter { $0.kind.isContainer }.map { ($0, 0, $0.displayName) }
        var visitedContainers = Set(pending.map { $0.item.id })
        var collectedIDs = Set<SourceObjectID>()
        var items: [DiscoveredImportItem] = roots.filter { $0.isDownloadable }.map { DiscoveredImportItem(media: $0, supportingItems: []) }
        var itemIndexes = Dictionary(items.enumerated().map { ($0.element.media.id, $0.offset) }, uniquingKeysWith: { old, _ in old })
        var directoryCache: [SourceObjectID: DirectoryDiscoveryEntry] = [:]
        var directIndicesByParent: [SourceObjectID: [Int]] = [:]
        var directParentOrder: [SourceObjectID] = []
        for index in items.indices {
            let parentID = items[index].media.parentID ?? SourceObjectID(
                sourceID: sourceID,
                externalID: Self.virtualRootExternalID
            )
            if directIndicesByParent[parentID] == nil {
                directParentOrder.append(parentID)
            }
            directIndicesByParent[parentID, default: []].append(index)
        }
        for parentID in directParentOrder {
            let entry: DirectoryDiscoveryEntry
            do {
                entry = try await loadDirectoryEntry(
                    sourceID: sourceID,
                    parentID: parentID,
                    rootItemID: rootItem.id,
                    operationID: operationID
                )
                directoryCache[parentID] = entry
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Supporting files are optional for a direct selection. One
                // failed parent lookup applies to every selected child.
                continue
            }
            for index in directIndicesByParent[parentID] ?? [] {
                let media = items[index].media
                items[index] = DiscoveredImportItem(
                    media: media,
                    supportingItems: entry.supportingFiles.items(for: media)
                )
            }
        }
        collectedIDs.formUnion(items.map { $0.media.id })
        var directories = pending.map { OnlineSourceDirectorySnapshot(itemID: $0.item.id, path: $0.path) }
        registerDiscoveredFiles(items, rootItem: rootItem, path: rootItem.displayName, directories: directories, operationID: operationID, isSelection: selectedItems != nil)

        while !pending.isEmpty {
            try Task.checkCancellation()
            let next = pending.removeFirst()
            guard next.depth < Self.maxDepth else {
                throw QueueError.catalogDepthExceeded
            }

            let entry: DirectoryDiscoveryEntry
            if let cached = directoryCache[next.item.id] {
                entry = cached
            } else {
                entry = try await loadDirectoryEntry(
                    sourceID: sourceID,
                    parentID: next.item.id,
                    rootItemID: rootItem.id,
                    operationID: operationID
                )
                directoryCache[next.item.id] = entry
            }
            for child in entry.items where child.id.sourceID == sourceID {
                if child.kind.isContainer {
                    if visitedContainers.insert(child.id).inserted {
                        let path = "\(next.path) / \(child.displayName)"
                        pending.append((child, next.depth + 1, path))
                        directories.append(OnlineSourceDirectorySnapshot(itemID: child.id, path: path))
                        guard directories.count <= Self.maxItems else {
                            throw QueueError.catalogTooLarge
                        }
                    }
                } else if child.isDownloadable,
                          collectedIDs.insert(child.id).inserted {
                    itemIndexes[child.id] = items.count
                    items.append(
                        DiscoveredImportItem(media: child, supportingItems: [])
                    )
                    guard items.count <= Self.maxItems else {
                        throw QueueError.catalogTooLarge
                    }
                }
            }

            let discovered = try await Self.associateSupportingFiles(
                in: entry.items,
                index: entry.supportingFiles
            )
            try Task.checkCancellation()
            guard importOperationIDs[rootItem.id] == operationID else { throw CancellationError() }
            for value in discovered {
                if let index = itemIndexes[value.media.id] { items[index] = value }
            }
            if let index = directories.firstIndex(where: { $0.itemID == next.item.id }) { directories[index].isExpanded = true }
            // Keep state updates bounded even when a provider returns a very large directory.
            for offset in stride(from: 0, to: discovered.count, by: 500) {
                try Task.checkCancellation()
                let chunk = Array(discovered[offset..<min(offset + 500, discovered.count)])
                registerDiscoveredFiles(chunk, rootItem: rootItem, path: next.path, directories: directories, operationID: operationID, isSelection: selectedItems != nil)
                await Task.yield()
            }
            if discovered.isEmpty { registerDiscoveredFiles([], rootItem: rootItem, path: next.path, directories: directories, operationID: operationID, isSelection: selectedItems != nil) }
        }
        let missingItemCount = reconcileMissingAudioFiles(
            taskID: rootItem.id,
            discoveredIDs: Set(items.map(\.media.id)),
            operationID: operationID
        )
        return DiscoveryResult(
            items: items,
            missingItemCount: missingItemCount
        )
    }

    private func loadDirectoryEntry(
        sourceID: MediaSourceID,
        parentID: SourceObjectID,
        rootItemID: SourceObjectID,
        operationID: UUID
    ) async throws -> DirectoryDiscoveryEntry {
        let browseParentID = parentID.externalID == Self.virtualRootExternalID
            ? nil
            : parentID
        var pageToken: MediaSourceCursor?
        var visitedCursors = Set<MediaSourceCursor>()
        var items: [SourceCatalogItem] = []
        repeat {
            try Task.checkCancellation()
            let page = try await onlineSources.browse(
                sourceID: sourceID,
                request: SourceBrowseRequest(
                    parentID: browseParentID,
                    pageSize: 500,
                    pageToken: pageToken
                )
            )
            try Task.checkCancellation()
            guard importOperationIDs[rootItemID] == operationID else {
                throw CancellationError()
            }
            items.append(contentsOf: page.items.filter { $0.id.sourceID == sourceID })
            guard items.count <= Self.maxItems else {
                throw QueueError.catalogTooLarge
            }
            pageToken = page.nextPageToken
            if let pageToken,
               !visitedCursors.insert(pageToken).inserted {
                throw QueueError.catalogTooLarge
            }
        } while pageToken != nil
        let index = try await Self.makeSupportingFileIndex(items)
        try Task.checkCancellation()
        guard importOperationIDs[rootItemID] == operationID else {
            throw CancellationError()
        }
        return DirectoryDiscoveryEntry(items: items, supportingFiles: index)
    }

    private func registerDiscoveredFiles(_ items: [DiscoveredImportItem], rootItem: SourceCatalogItem, path: String, directories: [OnlineSourceDirectorySnapshot], operationID: UUID, isSelection: Bool) {
        guard importOperationIDs[rootItem.id] == operationID else { return }
        var downloads = stateSnapshot.downloads
        var imports = stateSnapshot.imports
        let priorFiles = Dictionary(stateSnapshot.files(for: rootItem.id, sorted: false).map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
        let replacedIDs = Set(items.flatMap { [$0.media.id] + $0.supportingItems.map(\.id) })
        let previousOwners = Set(replacedIDs.compactMap { id -> SourceObjectID? in
            guard let previous = downloads[id] else { return nil }
            let owner = previous.taskID ?? previous.itemID
            return owner == rootItem.id ? nil : owner
        })
        archiveTaskFiles(previousOwners, downloads: &downloads, imports: &imports)
        for item in items {
            for file in [item.media] + item.supportingItems {
                if let previous = priorFiles[file.id], previous.isSuccessful {
                    var restored = previous
                    restored.taskID = rootItem.id
                    downloads[file.id] = restored
                    continue
                }
                var value = OnlineSourceDownloadSnapshot(itemID: file.id, displayName: file.displayName, phase: .waiting)
                value.taskID = rootItem.id
                value.relativePath = path
                value.totalBytes = file.byteSize
                value.isSupportingFile = file.id != item.media.id
                value.createdAt = downloads[file.id]?.createdAt ?? Date()
                downloads[file.id] = value
                if cancelledFileIDs[rootItem.id]?.contains(file.id) == true { downloads[file.id]?.phase = .cancelled }
            }
        }
        imports[rootItem.id]?.totalItems = downloads.values.filter { $0.taskID == rootItem.id && $0.isSupportingFile != true }.count
        imports[rootItem.id]?.directories = directories
        imports[rootItem.id]?.isSelection = isSelection
        publish(OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports))
    }

    private func reconcileMissingAudioFiles(
        taskID: SourceObjectID,
        discoveredIDs: Set<SourceObjectID>,
        operationID: UUID
    ) -> Int {
        guard importOperationIDs[taskID] == operationID else { return 0 }
        var downloads = stateSnapshot.downloads
        var imports = stateSnapshot.imports
        var records = Dictionary(
            (imports[taskID]?.files ?? []).map { ($0.itemID, $0) },
            uniquingKeysWith: { _, new in new }
        )
        for file in downloads.values where file.taskID == taskID {
            records[file.itemID] = file
        }

        var missingCount = 0
        for (itemID, file) in records
            where file.isSupportingFile != true
                && !file.isSuccessful
                && !discoveredIDs.contains(itemID) {
            var missing = file
            missing.phase = .skipped
            missing.failureReason = "remote_item_missing"
            missing.bytesPerSecond = nil
            records[itemID] = missing
            if downloads[itemID]?.taskID == taskID {
                downloads[itemID] = missing
            }
            missingCount += 1
        }
        guard missingCount > 0 else { return 0 }
        imports[taskID]?.files = Array(records.values)
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: imports
            )
        )
        return missingCount
    }

    private func archiveTaskFiles(_ taskIDs: Set<SourceObjectID>, downloads: inout [SourceObjectID: OnlineSourceDownloadSnapshot], imports: inout [SourceObjectID: OnlineSourceImportSnapshot]) {
        guard !taskIDs.isEmpty else { return }
        var groups: [SourceObjectID: [OnlineSourceDownloadSnapshot]] = [:]
        for file in downloads.values {
            let owner = file.taskID ?? file.itemID
            if taskIDs.contains(owner) { groups[owner, default: []].append(file) }
        }
        for taskID in taskIDs {
            var records = Dictionary((imports[taskID]?.files ?? []).map { ($0.itemID, $0) }, uniquingKeysWith: { _, new in new })
            for file in groups[taskID] ?? [] { records[file.itemID] = file }
            if imports[taskID] == nil, let main = downloads[taskID], main.taskID == nil {
                var history = OnlineSourceImportSnapshot(rootItemID: taskID, displayName: main.displayName, phase: main.isSuccessful ? .completed : main.phase == .cancelled ? .cancelled : .failed, totalItems: 1, processedItems: 1, importedItems: main.isSuccessful ? 1 : 0, failedItems: main.isSuccessful ? 0 : 1, failureReason: main.failureReason)
                history.createdAt = main.createdAt
                history.isSelection = true
                imports[taskID] = history
                downloads[taskID]?.taskID = taskID
                if let request = resumableDownloads.removeValue(forKey: taskID) {
                    var restored = OnlineDownloadQueueImportTask(rootItemID: taskID, displayName: request.displayName)
                    restored.selectedItems = [
                        SourceCatalogItem(
                            id: request.itemID,
                            kind: .audioFile,
                            displayName: request.displayName,
                            parentID: request.supportingParentID,
                            title: request.metadataHint.title,
                            artist: request.metadataHint.artist,
                            album: request.metadataHint.album,
                            duration: request.metadataHint.duration
                        )
                    ]
                    restored.singleDownload = request
                    resumableImports[taskID] = restored
                }
            }
            imports[taskID]?.files = Array(records.values)
        }
    }

    @concurrent
    private static func makeSupportingFileIndex(
        _ files: [SourceCatalogItem]
    ) async throws -> SupportingFileIndex {
        var artwork: [SourceCatalogItem] = []
        var lyricsByStem: [String: [SourceCatalogItem]] = [:]
        for file in files where Self.isImportSupportingItem(file) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: file.displayName)
            switch url.pathExtension.lowercased() {
            case "lrc", "srt":
                let stem = url.deletingPathExtension()
                    .lastPathComponent
                    .folding(options: .caseInsensitive, locale: nil)
                lyricsByStem[stem, default: []].append(file)
            default:
                artwork.append(file)
            }
        }
        artwork.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for stem in lyricsByStem.keys {
            lyricsByStem[stem]?.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
        return SupportingFileIndex(
            commonArtwork: artwork,
            lyricsByStem: lyricsByStem
        )
    }

    @concurrent
    private static func associateSupportingFiles(
        in files: [SourceCatalogItem],
        index: SupportingFileIndex
    ) async throws -> [DiscoveredImportItem] {
        var discovered: [DiscoveredImportItem] = []
        discovered.reserveCapacity(files.count)
        for media in files where media.isDownloadable {
            try Task.checkCancellation()
            discovered.append(
                DiscoveredImportItem(
                    media: media,
                    supportingItems: index.items(for: media)
                )
            )
        }
        return discovered
    }

    private nonisolated static func isImportSupportingItem(_ item: SourceCatalogItem) -> Bool {
        let fileExtension = URL(fileURLWithPath: item.displayName).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "heic", "heif", "lrc", "srt"].contains(fileExtension)
    }

    private nonisolated static func stageDownloadedFile(from sourceURL: URL, preferredFileName: String, into directory: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try moveDownloadedFile(from: sourceURL, preferredFileName: preferredFileName, into: directory)
        }.value
    }

    private nonisolated static func copySupportingFile(from sourceURL: URL, preferredFileName: String, into directory: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let destination = directory.appendingPathComponent(URL(fileURLWithPath: preferredFileName).lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }.value
    }

    private nonisolated static func moveDownloadedFile(
        from sourceURL: URL,
        preferredFileName: String,
        into directory: URL
    ) throws -> URL {
        let invalid = CharacterSet(charactersIn: "/\\:\0")
        let sanitized = preferredFileName.components(separatedBy: invalid).joined(separator: "_")
        let fileName = sanitized.isEmpty ? sourceURL.lastPathComponent : sanitized
        var destination = directory.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            let url = URL(fileURLWithPath: fileName)
            let suffix = UUID().uuidString.lowercased().prefix(8)
            let stem = url.deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent(
                url.pathExtension.isEmpty
                    ? "\(stem)-\(suffix)"
                    : "\(stem)-\(suffix).\(url.pathExtension)",
                isDirectory: false
            )
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return destination
    }

    private func snapshotImports(
        rootItem: SourceCatalogItem,
        phase: OnlineSourceImportPhase,
        totalItems: Int? = nil,
        processedItems: Int? = nil,
        importedItems: Int? = nil,
        duplicateItems: Int? = nil,
        skippedItems: Int? = nil,
        failedItems: Int? = nil,
        currentItemName: String? = nil,
        failureReason: String? = nil,
        operationID: UUID?
    ) {
        if let operationID,
           importOperationIDs[rootItem.id] != operationID {
            return
        }
        let previous = stateSnapshot.imports[rootItem.id]
        var value = OnlineSourceImportSnapshot(
            rootItemID: rootItem.id,
            displayName: rootItem.displayName,
            phase: phase,
            totalItems: totalItems ?? previous?.totalItems ?? 0,
            processedItems: processedItems ?? previous?.processedItems ?? 0,
            importedItems: importedItems ?? previous?.importedItems ?? 0,
            duplicateItems: duplicateItems ?? previous?.duplicateItems ?? 0,
            skippedItems: skippedItems ?? previous?.skippedItems ?? 0,
            failedItems: failedItems ?? previous?.failedItems ?? 0,
            currentItemName: currentItemName,
            failureReason: failureReason
        )
        value.directories = previous?.directories
        value.createdAt = previous?.createdAt ?? Date()
        value.isSelection = previous?.isSelection
        value.files = previous?.files
        value.isSingleFile = pendingImports[rootItem.id]?.singleDownload != nil || previous?.isSingleFile == true
        if value.files == nil, let request = pendingImports[rootItem.id]?.singleDownload {
            var file = OnlineSourceDownloadSnapshot(itemID: request.itemID, displayName: request.displayName, phase: .waiting)
            file.taskID = rootItem.id
            file.createdAt = value.createdAt
            value.files = [file]
        }
        value.catalogRootItemID = pendingImports[rootItem.id]?.catalogRootItem?.id ?? previous?.catalogRootItemID
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: stateSnapshot.downloads,
                imports: stateSnapshot.imports.merging([rootItem.id: value]) { _, new in new }
            ),
            persistImmediately: !phase.isActive
        )
    }

    private func publishDownload(
        itemID: SourceObjectID,
        displayName: String,
        phase: OnlineSourceDownloadPhase,
        failureReason: String? = nil,
        operationID: UUID? = nil
    ) {
        if let operationID,
           downloadOperationIDs[itemID] != operationID {
            return
        }
        var downloads = stateSnapshot.downloads
        let previous = fileSnapshot(for: itemID)
        fileProgress.removeValue(forKey: itemID)
        var value = OnlineSourceDownloadSnapshot(
            itemID: itemID,
            displayName: displayName,
            phase: phase,
            failureReason: failureReason
        )
        value.taskID = previous?.taskID
        value.relativePath = previous?.relativePath
        value.receivedBytes = previous?.receivedBytes
        value.totalBytes = previous?.totalBytes
        value.bytesPerSecond = phase == .downloading ? previous?.bytesPerSecond : nil
        value.isSupportingFile = previous?.isSupportingFile
        value.createdAt = previous?.createdAt ?? Date()
        downloads[itemID] = value
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: stateSnapshot.imports
            )
        )
    }

    private func publish(
        _ nextSnapshot: OnlineDownloadQueueSnapshot,
        persistImmediately: Bool = false
    ) {
        fileProgress = fileProgress.filter { nextSnapshot.downloads[$0.key]?.phase == .downloading }
        stateSnapshot = nextSnapshot
        schedulePersistence(immediately: persistImmediately)
        continuations.values.forEach { $0.yield(stateSnapshot) }
    }

    private func schedulePersistence(immediately: Bool) {
        guard persistence != nil else { return }
        persistenceTask?.cancel()
        persistenceTask = nil
        if immediately {
            persistNow()
            return
        }
        persistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.persistenceTask = nil
            self.persistNow()
        }
    }

    private func persistNow() {
        guard let persistence else { return }
        var state = OnlineDownloadQueuePersistenceState(
            downloads: Array(snapshot.downloads.values),
            imports: Array(stateSnapshot.imports.values),
            pendingImports: Array(pendingImports.values)
        )
        state.resumableDownloads = Array(resumableDownloads.values)
        state.resumableImports = Array(resumableImports.values)
        persistence.save(state)
    }

    private static func downloadPhase(
        for result: MediaImportResult
    ) -> OnlineSourceDownloadPhase {
        if result.failed > 0 { return .failed }
        if result.imported > 0 { return .completed }
        if result.duplicate > 0 { return .alreadyImported }
        if result.skipped > 0 { return .skipped }
        return .failed
    }

    private static func redactedFailureReason(for error: Error) -> String {
        if error is OnlineSourceAuthenticationError {
            return "authentication_required"
        }
        if error is OnlineSourceServingError {
            return "source_unavailable"
        }
        return "operation_failed"
    }

    private static func importMetadataHint(
        for item: SourceCatalogItem
    ) -> MediaImportMetadataHint {
        MediaImportMetadataHint(
            displayName: item.displayName,
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration
        )
    }
}
