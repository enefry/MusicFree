import Foundation
import MediaSourceAPI
import MusicDomain

public enum OnlineSourceDownloadPhase: String, Codable, Equatable, Sendable {
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
    public let phase: OnlineSourceDownloadPhase
    public let failureReason: String?

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
}

public enum OnlineSourceImportPhase: String, Codable, Equatable, Sendable {
    case discovering
    case downloading
    case importing
    case completed
    case cancelled
    case failed
}

public struct OnlineSourceImportSnapshot: Codable, Equatable, Sendable {
    public let rootItemID: SourceObjectID
    public let displayName: String
    public let phase: OnlineSourceImportPhase
    public let totalItems: Int
    public let processedItems: Int
    public let importedItems: Int
    public let duplicateItems: Int
    public let skippedItems: Int
    public let failedItems: Int
    public let currentItemName: String?
    public let failureReason: String?

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
        guard totalItems > 0 else { return nil }
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
            switch $0.phase {
            case .downloading, .importing:
                true
            case .completed, .alreadyImported, .skipped, .cancelled, .failed:
                false
            }
        }.count
        let activeImports = imports.values.filter {
            switch $0.phase {
            case .discovering, .downloading, .importing:
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
}

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
    public private(set) var snapshot = OnlineDownloadQueueSnapshot()

    private let persistence: (any OnlineDownloadQueueStore)?
    private var continuations: [UUID: AsyncStream<OnlineDownloadQueueSnapshot>.Continuation] = [:]
    private var downloadTasks: [SourceObjectID: Task<Void, Never>] = [:]
    private var downloadOperationIDs: [SourceObjectID: UUID] = [:]
    private var downloadImportIDs: [SourceObjectID: UUID] = [:]
    private var pendingDownloads: [SourceObjectID: OnlineDownloadQueueDownloadTask] = [:]
    private var importTasks: [SourceObjectID: Task<Void, Never>] = [:]
    private var importOperationIDs: [SourceObjectID: UUID] = [:]
    private var importActiveItemIDs: [SourceObjectID: Set<SourceObjectID>] = [:]
    private var pendingImports: [SourceObjectID: OnlineDownloadQueueImportTask] = [:]
    private var didRestorePersistence = false
    private var isShuttingDown = false
    private var isShutDown = false

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
            let cancelled = OnlineSourceDownloadSnapshot(
                itemID: value.itemID,
                displayName: value.displayName,
                phase: .cancelled,
                failureReason: "interrupted"
            )
            downloads[value.itemID] = cancelled
            cancelledDownloads[value.itemID] = cancelled
        }

        let pendingImportTasks = state.pendingImports.sorted { $0.rootItemID < $1.rootItemID }
        let pendingImportIDs = Set(pendingImportTasks.map(\.rootItemID))
        var cancelledImports: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
        for value in Array(imports.values)
            where isActive(value.phase) && !pendingImportIDs.contains(value.rootItemID) {
            let cancelled = OnlineSourceImportSnapshot(
                rootItemID: value.rootItemID,
                displayName: value.displayName,
                phase: .cancelled,
                totalItems: value.totalItems,
                processedItems: value.processedItems,
                importedItems: value.importedItems,
                duplicateItems: value.duplicateItems,
                skippedItems: value.skippedItems,
                failedItems: value.failedItems,
                failureReason: "interrupted"
            )
            imports[value.rootItemID] = cancelled
            cancelledImports[value.rootItemID] = cancelled
        }
        snapshot = OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports)

        for task in pendingDownloadTasks {
            guard canResume(sourceID: task.itemID.sourceID, using: sourceSnapshot) else {
                let cancelled = OnlineSourceDownloadSnapshot(
                    itemID: task.itemID,
                    displayName: task.displayName,
                    phase: .cancelled,
                    failureReason: "source_unavailable"
                )
                downloads[task.itemID] = cancelled
                cancelledDownloads[task.itemID] = cancelled
                continue
            }
            startDownload(
                sourceID: task.itemID.sourceID,
                itemID: task.itemID,
                displayName: task.displayName,
                metadataHint: task.metadataHint,
                supportingParentID: task.supportingParentID
            )
        }

        for task in pendingImportTasks {
            guard canResume(sourceID: task.rootItemID.sourceID, using: sourceSnapshot) else {
                let current = imports[task.rootItemID]
                let cancelled = OnlineSourceImportSnapshot(
                    rootItemID: task.rootItemID,
                    displayName: task.displayName,
                    phase: .cancelled,
                    totalItems: current?.totalItems ?? 0,
                    processedItems: current?.processedItems ?? 0,
                    importedItems: current?.importedItems ?? 0,
                    duplicateItems: current?.duplicateItems ?? 0,
                    skippedItems: current?.skippedItems ?? 0,
                    failedItems: current?.failedItems ?? 0,
                    failureReason: "source_unavailable"
                )
                imports[task.rootItemID] = cancelled
                cancelledImports[task.rootItemID] = cancelled
                continue
            }
            startImport(
                sourceID: task.rootItemID.sourceID,
                item: SourceCatalogItem(
                    id: task.rootItemID,
                    kind: .folder,
                    displayName: task.displayName
                )
            )
        }

        var finalDownloads = snapshot.downloads
        finalDownloads.merge(cancelledDownloads) { _, new in new }
        var finalImports = snapshot.imports
        finalImports.merge(cancelledImports) { _, new in new }
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: finalDownloads,
                imports: finalImports
            )
        )
    }

    public func makeSnapshotStream() -> AsyncStream<OnlineDownloadQueueSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
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
        case .downloading, .importing:
            true
        case .completed, .alreadyImported, .skipped, .cancelled, .failed:
            false
        }
    }

    private func isActive(_ phase: OnlineSourceImportPhase) -> Bool {
        switch phase {
        case .discovering, .downloading, .importing:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    public func startDownload(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        displayName: String,
        metadataHint: MediaImportMetadataHint? = nil,
        supportingParentID: SourceObjectID? = nil
    ) {
        guard !isShutDown, downloadTasks[itemID] == nil else { return }

        let operationID = UUID()
        pendingDownloads[itemID] = OnlineDownloadQueueDownloadTask(
            itemID: itemID,
            displayName: displayName,
            metadataHint: metadataHint
                ?? MediaImportMetadataHint(displayName: displayName),
            supportingParentID: supportingParentID
        )
        downloadOperationIDs[itemID] = operationID
        publishDownload(
            itemID: itemID,
            displayName: displayName,
            phase: .downloading,
            operationID: operationID
        )
        let resolvedMetadataHint = pendingDownloads[itemID]?.metadataHint
            ?? MediaImportMetadataHint(displayName: displayName)
        downloadTasks[itemID] = Task { @MainActor [weak self] in
            await self?.performDownload(
                sourceID: sourceID,
                itemID: itemID,
                displayName: displayName,
                metadataHint: resolvedMetadataHint,
                supportingParentID: supportingParentID,
                operationID: operationID
            )
        }
    }

    public func startImport(
        sourceID: MediaSourceID,
        item: SourceCatalogItem
    ) {
        guard item.id.sourceID == sourceID else { return }
        guard item.kind.isContainer else {
            startDownload(
                sourceID: sourceID,
                itemID: item.id,
                displayName: item.displayName,
                metadataHint: Self.importMetadataHint(for: item),
                supportingParentID: item.parentID
                    ?? SourceObjectID(sourceID: sourceID, externalID: Self.virtualRootExternalID)
            )
            return
        }
        guard !isShutDown, importTasks[item.id] == nil else { return }

        let operationID = UUID()
        pendingImports[item.id] = OnlineDownloadQueueImportTask(
            rootItemID: item.id,
            displayName: item.displayName
        )
        importOperationIDs[item.id] = operationID
        snapshotImports(
            rootItem: item,
            phase: .discovering,
            operationID: operationID
        )
        importTasks[item.id] = Task { @MainActor [weak self] in
            await self?.performBatchImport(
                sourceID: sourceID,
                rootItem: item,
                operationID: operationID
            )
        }
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

    public func cancelDownload(_ itemID: SourceObjectID) async {
        guard downloadOperationIDs[itemID] != nil else { return }
        let task = downloadTasks.removeValue(forKey: itemID)
        let importID = downloadImportIDs.removeValue(forKey: itemID)
        downloadOperationIDs.removeValue(forKey: itemID)
        pendingDownloads.removeValue(forKey: itemID)
        task?.cancel()
        if let importID {
            await importer?.cancel(importID)
        }
        publishDownload(
            itemID: itemID,
            displayName: snapshot.downloads[itemID]?.displayName ?? itemID.externalID,
            phase: .cancelled
        )
    }

    public func cancelImport(_ rootItemID: SourceObjectID) async {
        guard importOperationIDs[rootItemID] != nil else { return }
        let task = importTasks.removeValue(forKey: rootItemID)
        let activeItemIDs = importActiveItemIDs.removeValue(forKey: rootItemID) ?? []
        let importIDs = activeItemIDs.compactMap { downloadImportIDs[$0] }
        importOperationIDs.removeValue(forKey: rootItemID)
        pendingImports.removeValue(forKey: rootItemID)
        task?.cancel()
        for importID in importIDs {
            await importer?.cancel(importID)
        }
        for itemID in activeItemIDs {
            publishDownload(
                itemID: itemID,
                displayName: snapshot.downloads[itemID]?.displayName ?? itemID.externalID,
                phase: .cancelled
            )
        }

        guard let current = snapshot.imports[rootItemID] else { return }
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
    }

    public func stop(for sourceID: MediaSourceID? = nil) async {
        let itemIDs = downloadTasks.keys.filter {
            sourceID == nil || $0.sourceID == sourceID
        }
        for itemID in itemIDs {
            await cancelDownload(itemID)
        }

        let rootItemIDs = importTasks.keys.filter {
            sourceID == nil || $0.sourceID == sourceID
        }
        for rootItemID in rootItemIDs {
            await cancelImport(rootItemID)
        }
    }

    public func discardSnapshots(for sourceID: MediaSourceID) {
        let downloads = snapshot.downloads.filter { $0.key.sourceID != sourceID }
        let imports = snapshot.imports.filter { $0.key.sourceID != sourceID }
        pendingDownloads = pendingDownloads.filter { $0.key.sourceID != sourceID }
        pendingImports = pendingImports.filter { $0.key.sourceID != sourceID }
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: imports
            )
        )
    }

    public func stopUnavailable(using sourceSnapshot: OnlineSourceSnapshot) async {
        let itemIDs = downloadTasks.keys.filter { itemID in
            sourceSnapshot.sources.first(where: { $0.sourceID == itemID.sourceID })?.isRuntimeEnabled != true
        }
        for itemID in itemIDs {
            await cancelDownload(itemID)
        }

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
        downloadTasks.values.forEach { $0.cancel() }
        importTasks.values.forEach { $0.cancel() }
        let importIDs = Set(downloadImportIDs.values)
        for importID in importIDs {
            await importer?.cancel(importID)
        }
        persist()
        isShutDown = true
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    private func performDownload(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        displayName: String,
        metadataHint: MediaImportMetadataHint,
        supportingParentID: SourceObjectID?,
        operationID: UUID
    ) async {
        defer {
            if downloadOperationIDs[itemID] == operationID {
                downloadTasks.removeValue(forKey: itemID)
                downloadOperationIDs.removeValue(forKey: itemID)
                downloadImportIDs.removeValue(forKey: itemID)
                if !isShuttingDown {
                    pendingDownloads.removeValue(forKey: itemID)
                    persist()
                }
            }
        }

        guard let importer else {
            publishDownload(
                itemID: itemID,
                displayName: displayName,
                phase: .failed,
                failureReason: "importer_unavailable",
                operationID: operationID
            )
            return
        }

        do {
            let supportingItems: [SourceCatalogItem]
            if let supportingParentID {
                supportingItems = (try? await discoverSupportingItems(
                    sourceID: sourceID,
                    parentID: supportingParentID,
                    mediaDisplayName: displayName
                )) ?? []
            } else {
                supportingItems = []
            }
            let receipt = try await onlineSources.download(
                sourceID: sourceID,
                itemID: itemID,
                options: DownloadOptions(preferredFileName: displayName)
            )
            let bundleRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusicFreeOnlineImportBundles", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: bundleRoot) }
            let stagedURL = try Self.moveDownloadedFile(
                from: receipt.fileURL,
                preferredFileName: displayName,
                into: bundleRoot
            )
            var importURLs = [stagedURL]
            for supportingItem in supportingItems {
                try Task.checkCancellation()
                do {
                    let supportingReceipt = try await onlineSources.download(
                        sourceID: sourceID,
                        itemID: supportingItem.id,
                        options: DownloadOptions(preferredFileName: supportingItem.displayName)
                    )
                    do {
                        importURLs.append(try Self.moveDownloadedFile(
                            from: supportingReceipt.fileURL,
                            preferredFileName: supportingItem.displayName,
                            into: bundleRoot
                        ))
                    } catch {
                        try? FileManager.default.removeItem(at: supportingReceipt.fileURL)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            try Task.checkCancellation()

            let importID = UUID()
            downloadImportIDs[itemID] = importID
            let stream = try await importer.start(
                MediaImportRequest(
                    importID: importID,
                    urls: importURLs,
                    duplicatePolicy: .report,
                    metadataHints: [stagedURL: metadataHint]
                )
            )
            publishDownload(
                itemID: itemID,
                displayName: displayName,
                phase: .importing,
                operationID: operationID
            )

            var receivedTerminalEvent = false
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .completed(_, result):
                    receivedTerminalEvent = true
                    publishDownload(
                        itemID: itemID,
                        displayName: displayName,
                        phase: Self.downloadPhase(for: result),
                        failureReason: result.failed > 0 ? "import_failed" : nil,
                        operationID: operationID
                    )
                case .cancelled:
                    receivedTerminalEvent = true
                    publishDownload(
                        itemID: itemID,
                        displayName: displayName,
                        phase: .cancelled,
                        operationID: operationID
                    )
                default:
                    break
                }
            }

            if !receivedTerminalEvent,
               downloadOperationIDs[itemID] == operationID {
                publishDownload(
                    itemID: itemID,
                    displayName: displayName,
                    phase: .failed,
                    failureReason: "import_stream_ended",
                    operationID: operationID
                )
            }
        } catch is CancellationError {
            if !isShuttingDown {
                publishDownload(
                    itemID: itemID,
                    displayName: displayName,
                    phase: .cancelled,
                    operationID: operationID
                )
            }
        } catch {
            publishDownload(
                itemID: itemID,
                displayName: displayName,
                phase: .failed,
                failureReason: Self.redactedFailureReason(for: error),
                operationID: operationID
            )
        }
    }

    private func downloadAndImportItem(
        sourceID: MediaSourceID,
        item: DiscoveredImportItem
    ) async throws -> ImportedItemOutcome {
        guard let importer else { throw QueueError.importerUnavailable }

        let media = item.media

        publishDownload(
            itemID: media.id,
            displayName: media.displayName,
            phase: .downloading
        )
        let receipt = try await onlineSources.download(
            sourceID: sourceID,
            itemID: media.id,
            options: DownloadOptions(preferredFileName: media.displayName)
        )
        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFreeOnlineImportBundles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleRoot) }

        let stagedURL = try Self.moveDownloadedFile(
            from: receipt.fileURL,
            preferredFileName: media.displayName,
            into: bundleRoot
        )
        var importURLs = [stagedURL]
        for supportingItem in item.supportingItems {
            try Task.checkCancellation()
            do {
                let supportingReceipt = try await onlineSources.download(
                    sourceID: sourceID,
                    itemID: supportingItem.id,
                    options: DownloadOptions(preferredFileName: supportingItem.displayName)
                )
                let supportingURL: URL
                do {
                    supportingURL = try Self.moveDownloadedFile(
                        from: supportingReceipt.fileURL,
                        preferredFileName: supportingItem.displayName,
                        into: bundleRoot
                    )
                } catch {
                    try? FileManager.default.removeItem(at: supportingReceipt.fileURL)
                    throw error
                }
                importURLs.append(supportingURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A missing optional cover or lyric must not prevent the audio
                // itself from being imported.
                continue
            }
        }
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
                metadataHints: [stagedURL: Self.importMetadataHint(for: media)]
            )
        )
        publishDownload(
            itemID: media.id,
            displayName: media.displayName,
            phase: .importing
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
                    failureReason: result.failed > 0 ? "import_failed" : nil
                )
                return outcome
            case .cancelled:
                throw CancellationError()
            default:
                continue
            }
        }
        throw QueueError.importStreamEnded
    }

    private func batchItemResult(
        sourceID: MediaSourceID,
        item: DiscoveredImportItem
    ) async throws -> BatchItemResult {
        do {
            let outcome = try await downloadAndImportItem(
                sourceID: sourceID,
                item: item
            )
            return .completed(item.media, outcome)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnlineSourceAuthenticationError {
            throw error
        } catch {
            return .failed(item.media)
        }
    }

    private func performBatchImport(
        sourceID: MediaSourceID,
        rootItem: SourceCatalogItem,
        operationID: UUID
    ) async {
        defer {
            if importOperationIDs[rootItem.id] == operationID {
                importTasks.removeValue(forKey: rootItem.id)
                importOperationIDs.removeValue(forKey: rootItem.id)
                importActiveItemIDs.removeValue(forKey: rootItem.id)
                if !isShuttingDown {
                    pendingImports.removeValue(forKey: rootItem.id)
                    persist()
                }
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
            let items = try await discoverImportItems(
                sourceID: sourceID,
                rootItem: rootItem
            )
            try Task.checkCancellation()
            guard !items.isEmpty else {
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
            var skipped = 0
            var failed = 0
            var processed = 0
            let concurrencyLimit = min(Self.maxConcurrentDownloads, items.count)

            try await withThrowingTaskGroup(of: BatchItemResult.self) { group in
                var nextIndex = 0
                for _ in 0..<concurrencyLimit {
                    let item = items[nextIndex]
                    nextIndex += 1
                    importActiveItemIDs[rootItem.id, default: []].insert(item.media.id)
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.batchItemResult(
                            sourceID: sourceID,
                            item: item
                        )
                    }
                }

                snapshotImports(
                    rootItem: rootItem,
                    phase: .downloading,
                    totalItems: items.count,
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
                        publishDownload(
                            itemID: item.id,
                            displayName: item.displayName,
                            phase: .failed,
                            failureReason: "item_import_failed"
                        )
                    }
                    importActiveItemIDs[rootItem.id]?.remove(finishedItem.id)
                    processed += 1

                    if nextIndex < items.count {
                        let item = items[nextIndex]
                        nextIndex += 1
                        importActiveItemIDs[rootItem.id, default: []].insert(item.media.id)
                        group.addTask { [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.batchItemResult(
                                sourceID: sourceID,
                                item: item
                            )
                        }
                    }

                    snapshotImports(
                        rootItem: rootItem,
                        phase: .downloading,
                        totalItems: items.count,
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
                totalItems: items.count,
                processedItems: items.count,
                importedItems: imported,
                duplicateItems: duplicate,
                skippedItems: skipped,
                failedItems: failed,
                failureReason: failed > 0 ? "batch_import_failed" : nil,
                operationID: operationID
            )
        } catch is CancellationError {
            if !isShuttingDown {
                let activeItemIDs = importActiveItemIDs[rootItem.id] ?? []
                for itemID in activeItemIDs {
                    publishDownload(
                        itemID: itemID,
                        displayName: snapshot.downloads[itemID]?.displayName ?? itemID.externalID,
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
        rootItem: SourceCatalogItem
    ) async throws -> [DiscoveredImportItem] {
        guard rootItem.kind.isContainer else {
            return rootItem.isDownloadable
                ? [DiscoveredImportItem(media: rootItem, supportingItems: [])]
                : []
        }

        var pending: [(item: SourceCatalogItem, depth: Int)] = [(rootItem, 0)]
        var visitedContainers: Set<SourceObjectID> = [rootItem.id]
        var collectedIDs = Set<SourceObjectID>()
        var items: [DiscoveredImportItem] = []

        while !pending.isEmpty {
            try Task.checkCancellation()
            let next = pending.removeFirst()
            guard next.depth < Self.maxDepth else {
                throw QueueError.catalogDepthExceeded
            }

            var pageToken: MediaSourceCursor?
            var directoryFiles: [SourceCatalogItem] = []
            repeat {
                try Task.checkCancellation()
                let browseParentID = next.item.id.externalID == Self.virtualRootExternalID
                    ? nil
                    : next.item.id
                let page = try await onlineSources.browse(
                    sourceID: sourceID,
                    request: SourceBrowseRequest(
                        parentID: browseParentID,
                        pageSize: 500,
                        pageToken: pageToken
                    )
                )
                for child in page.items where child.id.sourceID == sourceID {
                    if child.kind.isContainer {
                        if visitedContainers.insert(child.id).inserted {
                            pending.append((child, next.depth + 1))
                        }
                    } else {
                        directoryFiles.append(child)
                    }
                }
                pageToken = page.nextPageToken
            } while pageToken != nil

            let supportingItems = directoryFiles.filter(Self.isImportSupportingItem)
            for media in directoryFiles where media.isDownloadable {
                guard collectedIDs.insert(media.id).inserted else { continue }
                items.append(DiscoveredImportItem(
                    media: media,
                    supportingItems: Self.supportingItems(
                        for: media,
                        candidates: supportingItems
                    )
                ))
                guard items.count <= Self.maxItems else {
                    throw QueueError.catalogTooLarge
                }
            }
        }
        return items
    }

    private static func isImportSupportingItem(_ item: SourceCatalogItem) -> Bool {
        let fileExtension = URL(fileURLWithPath: item.displayName).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "heic", "heif", "lrc", "srt"].contains(fileExtension)
    }

    private static func supportingItems(
        for media: SourceCatalogItem,
        candidates: [SourceCatalogItem]
    ) -> [SourceCatalogItem] {
        supportingItems(forMediaNamed: media.displayName, candidates: candidates)
    }

    private static func supportingItems(
        forMediaNamed mediaDisplayName: String,
        candidates: [SourceCatalogItem]
    ) -> [SourceCatalogItem] {
        let mediaStem = URL(fileURLWithPath: mediaDisplayName)
            .deletingPathExtension().lastPathComponent
        return candidates.filter { candidate in
            let url = URL(fileURLWithPath: candidate.displayName)
            switch url.pathExtension.lowercased() {
            case "lrc", "srt":
                return url.deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(mediaStem) == .orderedSame
            default:
                return true
            }
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func discoverSupportingItems(
        sourceID: MediaSourceID,
        parentID: SourceObjectID,
        mediaDisplayName: String
    ) async throws -> [SourceCatalogItem] {
        let browseParentID = parentID.externalID == Self.virtualRootExternalID ? nil : parentID
        var pageToken: MediaSourceCursor?
        var candidates: [SourceCatalogItem] = []
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
            candidates.append(contentsOf: page.items.filter {
                $0.id.sourceID == sourceID
                    && !$0.kind.isContainer
                    && Self.isImportSupportingItem($0)
            })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return Self.supportingItems(
            forMediaNamed: mediaDisplayName,
            candidates: candidates
        )
    }

    private static func moveDownloadedFile(
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
        let previous = snapshot.imports[rootItem.id]
        let value = OnlineSourceImportSnapshot(
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
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: snapshot.downloads,
                imports: snapshot.imports.merging([rootItem.id: value]) { _, new in new }
            )
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
        var downloads = snapshot.downloads
        downloads[itemID] = OnlineSourceDownloadSnapshot(
            itemID: itemID,
            displayName: displayName,
            phase: phase,
            failureReason: failureReason
        )
        publish(
            OnlineDownloadQueueSnapshot(
                downloads: downloads,
                imports: snapshot.imports
            )
        )
    }

    private func publish(_ nextSnapshot: OnlineDownloadQueueSnapshot) {
        snapshot = nextSnapshot
        persist()
        continuations.values.forEach { $0.yield(nextSnapshot) }
    }

    private func persist() {
        guard let persistence else { return }
        let state = OnlineDownloadQueuePersistenceState(
            downloads: snapshot.downloads.values.sorted { $0.itemID < $1.itemID },
            imports: snapshot.imports.values.sorted { $0.rootItemID < $1.rootItemID },
            pendingDownloads: pendingDownloads.values.sorted { $0.itemID < $1.itemID },
            pendingImports: pendingImports.values.sorted { $0.rootItemID < $1.rootItemID }
        )
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
