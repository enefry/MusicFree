import Foundation
import MediaSourceAPI
import MusicDomain
import Testing
@testable import AppServices

@MainActor
@Test("online download queue persists redacted state and round-trips through JSON")
func onlineDownloadQueuePersistenceStateRoundTripsWithoutSecrets() throws {
    let sourceID = MediaSourceID("queue.persistence")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "track-1")
    let state = OnlineDownloadQueuePersistenceState(
        downloads: [
            OnlineSourceDownloadSnapshot(
                itemID: itemID,
                displayName: "Track 1",
                phase: .downloading
            )
        ],
        pendingDownloads: [
            OnlineDownloadQueueDownloadTask(
                itemID: itemID,
                displayName: "Track 1",
                metadataHint: MediaImportMetadataHint(
                    displayName: "Track 1",
                    title: "Track 1",
                    artist: "Fixture Artist"
                )
            )
        ]
    )

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(
        OnlineDownloadQueuePersistenceState.self,
        from: data
    )
    let serialized = String(decoding: data, as: UTF8.self)

    #expect(decoded == state)
    #expect(!serialized.contains("https://nas.example.test/private/track-1"))
    #expect(!serialized.contains("Bearer secret-token"))
    #expect(!serialized.contains("DSM_SESSION_COOKIE"))
}

@MainActor
@Test("online download queue resumes a pending download when the source is available")
func onlineDownloadQueueRestoresAvailableDownload() async throws {
    let sourceID = MediaSourceID("queue.restore.available")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "track-1")
    let source = QueueFixtureOnlineSources(sourceID: sourceID)
    let importer = QueueImmediateImporter()
    let store = InMemoryOnlineDownloadQueueStore()
    store.save(
        OnlineDownloadQueuePersistenceState(
            downloads: [
                OnlineSourceDownloadSnapshot(
                    itemID: itemID,
                    displayName: "Track 1",
                    phase: .downloading
                )
            ],
            pendingDownloads: [
                OnlineDownloadQueueDownloadTask(
                    itemID: itemID,
                    displayName: "Track 1",
                    metadataHint: MediaImportMetadataHint(title: "Track 1")
                )
            ]
        )
    )

    let queue = OnlineDownloadQueue(
        onlineSources: source,
        importer: importer,
        persistence: store
    )
    queue.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))

    for _ in 0..<200 {
        if await source.downloadedItemIDs.count == 1,
           await importer.requests.count == 1,
           queue.snapshot.downloads[itemID]?.phase == .completed {
            break
        }
        await Task.yield()
    }

    #expect(await source.downloadedItemIDs == [itemID])
    #expect((await importer.requests).count == 1)
    #expect(queue.snapshot.downloads[itemID]?.phase == .completed)
    #expect(store.currentState().pendingDownloads.isEmpty)
}

@MainActor
@Test("online download queue cancels persisted work without network access when a source is unavailable")
func onlineDownloadQueueDoesNotResumeUnavailableDownload() async throws {
    let sourceID = MediaSourceID("queue.restore.unavailable")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "track-1")
    let source = QueueFixtureOnlineSources(sourceID: sourceID)
    let importer = QueueImmediateImporter()
    let store = InMemoryOnlineDownloadQueueStore()
    store.save(
        OnlineDownloadQueuePersistenceState(
            downloads: [
                OnlineSourceDownloadSnapshot(
                    itemID: itemID,
                    displayName: "Track 1",
                    phase: .downloading
                )
            ],
            pendingDownloads: [
                OnlineDownloadQueueDownloadTask(
                    itemID: itemID,
                    displayName: "Track 1",
                    metadataHint: MediaImportMetadataHint(title: "Track 1")
                )
            ]
        )
    )

    let queue = OnlineDownloadQueue(
        onlineSources: source,
        importer: importer,
        persistence: store
    )
    queue.restore(
        using: OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: false,
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: "Unavailable Fixture",
                    capabilities: [.browsing, .downloading],
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: false
                )
            ]
        )
    )

    #expect(await source.downloadedItemIDs.isEmpty)
    #expect((await importer.requests).isEmpty)
    #expect(queue.snapshot.downloads[itemID]?.phase == .cancelled)
    #expect(queue.snapshot.downloads[itemID]?.failureReason == "source_unavailable")
    #expect(store.currentState().pendingDownloads.isEmpty)
}

@MainActor
@Test("online download queue keeps interrupted work after shutdown and resumes it in a new queue")
func onlineDownloadQueueShutdownPreservesPendingWork() async throws {
    let sourceID = MediaSourceID("queue.restore.shutdown")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "track-1")
    let oldSource = QueueFixtureOnlineSources(sourceID: sourceID, suspendsDownloads: true)
    let oldImporter = QueueImmediateImporter()
    let store = InMemoryOnlineDownloadQueueStore()
    let oldQueue = OnlineDownloadQueue(
        onlineSources: oldSource,
        importer: oldImporter,
        persistence: store
    )

    oldQueue.startDownload(
        sourceID: sourceID,
        itemID: itemID,
        displayName: "Track 1"
    )
    for _ in 0..<200 {
        if await oldSource.downloadedItemIDs.count == 1 { break }
        await Task.yield()
    }

    await oldQueue.shutdown()

    #expect(store.currentState().pendingDownloads.map(\.itemID) == [itemID])
    #expect(store.currentState().downloads.first?.phase == .downloading)

    let newSource = QueueFixtureOnlineSources(sourceID: sourceID)
    let newImporter = QueueImmediateImporter()
    let newQueue = OnlineDownloadQueue(
        onlineSources: newSource,
        importer: newImporter,
        persistence: store
    )
    newQueue.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))

    for _ in 0..<200 {
        if newQueue.snapshot.downloads[itemID]?.phase == .completed { break }
        await Task.yield()
    }

    #expect(await newSource.downloadedItemIDs == [itemID])
    #expect(newQueue.snapshot.downloads[itemID]?.phase == .completed)
}

private actor QueueFixtureOnlineSources: OnlineSourceServing {
    let sourceID: MediaSourceID
    private let suspendsDownloads: Bool
    private(set) var downloadedItemIDs: [SourceObjectID] = []

    init(sourceID: MediaSourceID, suspendsDownloads: Bool = false) {
        self.sourceID = sourceID
        self.suspendsDownloads = suspendsDownloads
    }

    func snapshot() async -> OnlineSourceSnapshot {
        Self.readySnapshot(sourceID: sourceID)
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        let value = Self.readySnapshot(sourceID: sourceID)
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func authenticate(
        sourceID _: MediaSourceID,
        oneTimeCode _: String
    ) async throws {}

    func browse(
        sourceID _: MediaSourceID,
        request _: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        SourceCatalogPage(items: [])
    }

    func search(
        sourceID _: MediaSourceID,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        SourceCatalogPage(items: [])
    }

    func download(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        downloadedItemIDs.append(itemID)
        if suspendsDownloads {
            try await Task.sleep(for: .seconds(60))
        }
        return DownloadReceipt(
            sourceID: sourceID,
            itemID: itemID,
            fileURL: URL(fileURLWithPath: "/private/temporary/queue-\(itemID.externalID).m4a")
        )
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        .downloadRequired
    }

    static func readySnapshot(sourceID: MediaSourceID) -> OnlineSourceSnapshot {
        OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: true,
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: "Queue Fixture",
                    capabilities: [.browsing, .downloading],
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: true
                )
            ]
        )
    }
}

private actor QueueImmediateImporter: ImportServing {
    private(set) var requests: [MediaImportRequest] = []

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requests.append(request)
        let result = MediaImportResult(
            importID: request.importID,
            imported: 1,
            duplicate: 0,
            skipped: 0,
            failed: 0,
            cancelled: 0
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(importID: request.importID, result: result))
            continuation.finish()
        }
    }

    func continueImport(_: UUID) async {}

    func cancel(_: UUID) async {}

    func state(for _: UUID) async -> ImportSessionSnapshot? { nil }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private final class InMemoryOnlineDownloadQueueStore: OnlineDownloadQueueStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state: OnlineDownloadQueuePersistenceState?

    func load() -> OnlineDownloadQueuePersistenceState? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ state: OnlineDownloadQueuePersistenceState) {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    func currentState() -> OnlineDownloadQueuePersistenceState {
        lock.lock()
        defer { lock.unlock() }
        return state ?? OnlineDownloadQueuePersistenceState()
    }
}
