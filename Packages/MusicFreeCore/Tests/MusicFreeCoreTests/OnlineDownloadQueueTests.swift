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
    var state = OnlineDownloadQueuePersistenceState(
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

    var single = OnlineDownloadQueueImportTask(rootItemID: SourceObjectID(sourceID: sourceID, externalID: "__download_fixture"), displayName: "Track 1")
    single.singleDownload = state.pendingDownloads.first
    single.selectedItems = [.init(id: itemID, kind: .audioFile, displayName: "Track 1")]
    state.resumableImports = [single]
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

    let taskID = try #require(oldQueue.startDownload(
        sourceID: sourceID,
        itemID: itemID,
        displayName: "Track 1"
    ))
    for _ in 0..<200 {
        if await oldSource.downloadedItemIDs.count == 1 { break }
        await Task.yield()
    }

    await oldQueue.shutdown()

    #expect(store.currentState().pendingImports.map(\.rootItemID) == [taskID])
    #expect(store.currentState().pendingImports.first?.singleDownload?.itemID == itemID)
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
        if newQueue.snapshot.imports[taskID]?.phase == .completed { break }
        await Task.yield()
    }

    #expect(await newSource.downloadedItemIDs == [itemID])
    #expect(newQueue.snapshot.downloads[itemID]?.phase == .completed)
    #expect(newQueue.snapshot.imports[taskID]?.phase == .completed)
}

@MainActor
private func waitForQueue(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Download queue did not reach its expected state")
}

@MainActor
@Test("batch cancellation and resume preserve successful recursive files")
func onlineDownloadQueueBatchResumeSkipsSuccessfulFiles() async throws {
    let sourceID = MediaSourceID("queue.batch.resume")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "root"), kind: .folder, displayName: "Album")
    let child = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "child"), kind: .folder, displayName: "Disc", parentID: root.id)
    let first = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "first"), kind: .audioFile, displayName: "First.m4a", parentID: child.id)
    let second = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "second"), kind: .audioFile, displayName: "Second.m4a", parentID: child.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [second.id], catalog: [root.id: [child], child.id: [first, second]])
    let importer = QueueImmediateImporter()
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer)
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.downloads[first.id]?.isSuccessful == true && queue.snapshot.downloads[second.id]?.receivedBytes == 50 }
    #expect(queue.snapshot.activeTaskCount == 1)
    #expect(queue.snapshot.tasks.count == 1)
    #expect(queue.snapshot.imports[taskID]?.directories?.count == 2)
    #expect(queue.snapshot.downloads[first.id]?.relativePath == "Album / Disc")
    await queue.cancelImport(taskID)
    #expect(queue.snapshot.imports[taskID]?.phase == .cancelled)
    #expect(queue.snapshot.downloads[first.id]?.isSuccessful == true)
    #expect(queue.snapshot.downloads[second.id]?.phase == .cancelled)
    #expect(queue.snapshot.downloads[second.id]?.receivedBytes == 50)
    await source.releaseDownloads()
    queue.resumeTask(taskID)
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }
    #expect((await source.downloadedItemIDs).filter { $0 == first.id }.count == 1)
    #expect((await source.downloadedItemIDs).filter { $0 == second.id }.count == 2)
    #expect(queue.snapshot.tasks.first?.completedFiles == 2)
}

@MainActor
@Test("cancelling a file leaves its sibling running and retry only downloads unfinished files")
func onlineDownloadQueueSingleFileCancellationKeepsParent() async throws {
    let sourceID = MediaSourceID("queue.batch.cancel.file")
    let first = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "first"), kind: .audioFile, displayName: "First.m4a")
    let second = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "second"), kind: .audioFile, displayName: "Second.m4a")
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [first.id])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    queue.startBatchImport(sourceID: sourceID, items: [first, second], displayName: "Selected")
    let rootID = try #require(queue.snapshot.imports.keys.first)
    try await waitForQueue { queue.snapshot.downloads[first.id]?.receivedBytes == 50 && queue.snapshot.downloads[second.id]?.isSuccessful == true }
    #expect(!queue.canResumeTask(rootID))
    await queue.cancelDownload(first.id)
    try await waitForQueue { queue.snapshot.imports[rootID]?.phase == .failed }
    #expect(queue.snapshot.tasks.first?.phase == .partialFailure)
    #expect(queue.snapshot.downloads[second.id]?.isSuccessful == true)
    await source.releaseDownloads()
    queue.resumeTask(rootID)
    try await waitForQueue { queue.snapshot.imports[rootID]?.phase == .completed }
    #expect((await source.downloadedItemIDs).filter { $0 == second.id }.count == 1)
}

@MainActor
@Test("old progress callbacks cannot update a resumed download")
func onlineDownloadQueueRejectsOldProgress() async throws {
    let sourceID = MediaSourceID("queue.progress.generation")
    let id = SourceObjectID(sourceID: sourceID, externalID: "track")
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendsDownloads: true)
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let taskID = try #require(queue.startDownload(sourceID: sourceID, itemID: id, displayName: "Track.m4a"))
    try await waitForQueue { queue.snapshot.downloads[id]?.receivedBytes == 50 }
    await queue.cancelDownload(id)
    queue.resumeTask(taskID)
    try await waitForQueue { await source.downloadedItemIDs.count == 2 }
    await source.emitOldProgress()
    try await Task.sleep(for: .milliseconds(20))
    #expect(queue.snapshot.downloads[id]?.receivedBytes == 50)
    #expect(queue.snapshot.downloads[id]?.phase == .downloading)
    await queue.cancelDownload(id)
}

@MainActor
@Test("tasks wait for earlier user operations and completed cleanup never cancels imports")
func onlineDownloadQueueSerializesOperationsAndCleansHistory() async throws {
    let sourceID = MediaSourceID("queue.operations")
    let first = SourceObjectID(sourceID: sourceID, externalID: "first")
    let second = SourceObjectID(sourceID: sourceID, externalID: "second")
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [first])
    let importer = QueueImmediateImporter()
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer)
    let firstTask = try #require(queue.startDownload(sourceID: sourceID, itemID: first, displayName: "First.m4a"))
    try await waitForQueue { queue.snapshot.downloads[first]?.receivedBytes == 50 }
    let secondTask = try #require(queue.startDownload(sourceID: sourceID, itemID: second, displayName: "Second.m4a"))
    #expect(queue.snapshot.files(for: secondTask).first?.phase == .waiting)
    #expect(await source.downloadedItemIDs == [first])
    await queue.cancelDownload(first)
    try await waitForQueue { queue.snapshot.imports[secondTask]?.phase == .completed }
    queue.clearCompletedTasks()
    #expect(queue.snapshot.downloads[first]?.phase == .cancelled)
    #expect(queue.snapshot.downloads[second] == nil)
    #expect((await importer.requests).count == 1)
    #expect(queue.canResumeTask(firstTask))
}

@MainActor
@Test("two selections of the same file keep independent task histories")
func onlineDownloadQueuePreservesOverlappingTaskHistories() async throws {
    let sourceID = MediaSourceID("queue.history")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a")
    let queue = OnlineDownloadQueue(onlineSources: QueueFixtureOnlineSources(sourceID: sourceID), importer: QueueImmediateImporter())
    queue.startBatchImport(sourceID: sourceID, items: [track], displayName: "First selection")
    let firstID = try #require(queue.snapshot.imports.keys.first)
    try await waitForQueue { queue.snapshot.imports[firstID]?.phase == .completed }
    queue.startBatchImport(sourceID: sourceID, items: [track], displayName: "Second selection")
    let secondID = try #require(queue.snapshot.imports.keys.first { $0 != firstID })
    try await waitForQueue { queue.snapshot.imports[secondID]?.phase == .completed }
    #expect(queue.snapshot.tasks.count == 2)
    #expect(queue.snapshot.files(for: firstID).first?.taskID == firstID)
    #expect(queue.snapshot.files(for: secondID).first?.taskID == secondID)
    #expect(queue.snapshot.files(for: firstID).first?.isSuccessful == true)
    queue.clearCompletedTasks()
    #expect(queue.snapshot.tasks.isEmpty)
    #expect(queue.snapshot.downloads.isEmpty)
}

@Test("legacy queue JSON and progress options remain compatible")
func onlineDownloadQueueLegacyJSONAndUnknownTotal() throws {
    let legacy = Data(#"{"schemaVersion":1,"downloads":[],"imports":[],"pendingDownloads":[],"pendingImports":[]}"#.utf8)
    let state = try JSONDecoder().decode(OnlineDownloadQueuePersistenceState.self, from: legacy)
    #expect(state.resumableImports == nil)
    let options = DownloadOptions(progress: { _ in })
    let decoded = try JSONDecoder().decode(DownloadOptions.self, from: JSONEncoder().encode(options))
    #expect(decoded.progress == nil)
    #expect(decoded == options)
    #expect(DownloadProgress(receivedBytes: 10, totalBytes: -1).totalBytes == nil)
}

@MainActor
@Test("a terminal import releases the next download even if its stream remains open")
func onlineDownloadQueueReleasesOperationOnTerminalEvent() async throws {
    let sourceID = MediaSourceID("queue.terminal")
    let first = SourceObjectID(sourceID: sourceID, externalID: "first")
    let second = SourceObjectID(sourceID: sourceID, externalID: "second")
    let importer = QueueImmediateImporter(leavesStreamOpen: true)
    let queue = OnlineDownloadQueue(onlineSources: QueueFixtureOnlineSources(sourceID: sourceID), importer: importer)
    queue.startDownload(sourceID: sourceID, itemID: first, displayName: "First.m4a")
    let secondTask = try #require(queue.startDownload(sourceID: sourceID, itemID: second, displayName: "Second.m4a"))
    try await waitForQueue { queue.snapshot.imports[secondTask]?.phase == .completed }
    #expect((await importer.requests).count == 2)
    #expect(queue.snapshot.activeTaskCount == 0)
}

@MainActor
@Test("shared artwork downloads once and standalone history survives a later batch")
func onlineDownloadQueueDeduplicatesSupportingFilesAndPreservesSingleHistory() async throws {
    let sourceID = MediaSourceID("queue.artwork")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "root"), kind: .folder, displayName: "Album")
    let first = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "first"), kind: .audioFile, displayName: "First.m4a", parentID: root.id)
    let second = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "second"), kind: .audioFile, displayName: "Second.m4a", parentID: root.id)
    let cover = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "cover"), kind: .unknown, displayName: "cover.jpg", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [first, second, cover]])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let singleID = try #require(queue.startDownload(sourceID: sourceID, itemID: first.id, displayName: first.displayName))
    try await waitForQueue { queue.snapshot.downloads[first.id]?.phase == .completed }
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }
    #expect((await source.downloadedItemIDs).filter { $0 == cover.id }.count == 1)
    #expect(queue.snapshot.files(for: taskID).count == 3)
    #expect(queue.snapshot.tasks.first { $0.id == taskID }?.completedFiles == 3)
    #expect(queue.snapshot.tasks.count == 2)
    #expect(queue.snapshot.files(for: singleID).first?.isSuccessful == true)
    #expect(queue.snapshot.downloads[cover.id]?.isSuccessful == true)
    queue.clearCompletedTasks()
    #expect(queue.snapshot.tasks.isEmpty)
}

@MainActor
@Test("cancelled selections remain resumable after process recreation")
func onlineDownloadQueueRestoresCancelledSelectionContext() async throws {
    let sourceID = MediaSourceID("queue.selection.persistence")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a")
    let store = InMemoryOnlineDownloadQueueStore()
    let oldQueue = OnlineDownloadQueue(onlineSources: QueueFixtureOnlineSources(sourceID: sourceID, suspendsDownloads: true), importer: QueueImmediateImporter(), persistence: store)
    oldQueue.startBatchImport(sourceID: sourceID, items: [track], displayName: "Selection")
    let id = try #require(oldQueue.snapshot.imports.keys.first)
    try await waitForQueue { oldQueue.snapshot.downloads[track.id]?.receivedBytes == 50 }
    await oldQueue.cancelImport(id)
    let newQueue = OnlineDownloadQueue(onlineSources: QueueFixtureOnlineSources(sourceID: sourceID), importer: QueueImmediateImporter(), persistence: store)
    newQueue.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))
    #expect(newQueue.snapshot.imports[id]?.phase == .cancelled)
    #expect(newQueue.snapshot.downloads[track.id]?.taskID == id)
    #expect(newQueue.canResumeTask(id))
    newQueue.resumeTask(id)
    try await waitForQueue { newQueue.snapshot.imports[id]?.phase == .completed }
}

@MainActor
@Test("sequential single downloads each import shared artwork and preserve both histories")
func onlineDownloadQueueSequentialSinglesIncludeSharedArtwork() async throws {
    let sourceID = MediaSourceID("queue.artwork.sequential")
    let folderID = SourceObjectID(sourceID: sourceID, externalID: "album")
    let first = SourceObjectID(sourceID: sourceID, externalID: "first")
    let second = SourceObjectID(sourceID: sourceID, externalID: "second")
    let cover = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "cover"), kind: .unknown, displayName: "cover.jpg", parentID: folderID)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [folderID: [cover]])
    let importer = QueueImmediateImporter()
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer)
    let firstTask = try #require(queue.startDownload(sourceID: sourceID, itemID: first, displayName: "First.m4a", supportingParentID: folderID))
    try await waitForQueue { queue.snapshot.downloads[first]?.isSuccessful == true }
    let secondTask = try #require(queue.startDownload(sourceID: sourceID, itemID: second, displayName: "Second.m4a", supportingParentID: folderID))
    try await waitForQueue { queue.snapshot.downloads[second]?.isSuccessful == true }
    let requests = await importer.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.urls.map(\.lastPathComponent).contains("cover.jpg") })
    #expect((await source.downloadedItemIDs).filter { $0 == cover.id }.count == 2)
    #expect(queue.snapshot.files(for: firstTask).count == 2)
    #expect(queue.snapshot.files(for: secondTask).count == 2)
    #expect(queue.snapshot.tasks.count == 2)
    queue.clearCompletedTasks()
    #expect(queue.snapshot.tasks.isEmpty)
}

@MainActor
@Test("a resumed batch reacquires shared artwork while skipping successful audio")
func onlineDownloadQueueBatchRetryReacquiresArtwork() async throws {
    let sourceID = MediaSourceID("queue.artwork.retry")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let first = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "first"), kind: .audioFile, displayName: "First.m4a", parentID: root.id)
    let second = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "second"), kind: .audioFile, displayName: "Second.m4a", parentID: root.id)
    let cover = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "cover"), kind: .unknown, displayName: "cover.jpg", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [first, second, cover]])
    let importer = QueueImmediateImporter(failureCounts: ["Second.m4a": 1])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer)
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .failed }
    #expect(queue.snapshot.downloads[cover.id]?.isSuccessful == true)
    queue.resumeTask(taskID)
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }
    let requests = await importer.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.urls.map(\.lastPathComponent).contains("cover.jpg") })
    #expect((await source.downloadedItemIDs).filter { $0 == first.id }.count == 1)
    #expect((await source.downloadedItemIDs).filter { $0 == second.id }.count == 2)
    #expect((await source.downloadedItemIDs).filter { $0 == cover.id }.count == 2)
    #expect(queue.snapshot.tasks.count == 1)
}

@MainActor
@Test("fresh directory imports download again with independent task histories")
func onlineDownloadQueueFreshDirectoryImportsAreIndependent() async throws {
    let sourceID = MediaSourceID("queue.fresh.directory")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [track]])
    let importer = QueueImmediateImporter()
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer)
    let first = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[first]?.phase == .completed }
    let second = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[second]?.phase == .completed }
    #expect(first != second)
    #expect(await source.downloadedItemIDs == [track.id, track.id])
    #expect((await importer.requests).count == 2)
    #expect(queue.snapshot.tasks.count == 2)
    #expect(queue.snapshot.files(for: first).first?.taskID == first)
    #expect(queue.snapshot.files(for: second).first?.taskID == second)
    #expect(queue.snapshot.imports[first]?.catalogRootItemID == root.id)
    #expect(queue.snapshot.imports[second]?.catalogRootItemID == root.id)
}

@MainActor
@Test("queued recursive imports can be cancelled without downloading their files")
func onlineDownloadQueueCancelsQueuedDirectory() async throws {
    let sourceID = MediaSourceID("queue.waiting.directory")
    let first = SourceObjectID(sourceID: sourceID, externalID: "first")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [first], catalog: [root.id: [track]])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    queue.startDownload(sourceID: sourceID, itemID: first, displayName: "First.m4a")
    try await waitForQueue { queue.snapshot.downloads[first]?.receivedBytes == 50 }
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    #expect(queue.snapshot.imports[taskID]?.phase == .waiting)
    #expect(queue.snapshot.imports[taskID]?.phase.isActive == true)
    await queue.cancelImport(taskID)
    #expect(queue.snapshot.imports[taskID]?.phase == .cancelled)
    await queue.cancelDownload(first)
    #expect(await source.downloadedItemIDs == [first])
    #expect(queue.canResumeTask(taskID))
    queue.resumeTask(taskID)
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }
    #expect(await source.downloadedItemIDs == [first, track.id])
}

@MainActor
@Test("recursive import recovery persists catalog identity separately from task identity")
func onlineDownloadQueueRestoresRecursiveCatalogIdentity() async throws {
    let sourceID = MediaSourceID("queue.recursive.identity")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let store = InMemoryOnlineDownloadQueueStore()
    let old = OnlineDownloadQueue(onlineSources: QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [track.id], catalog: [root.id: [track]]), importer: QueueImmediateImporter(), persistence: store)
    let taskID = try #require(old.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { old.snapshot.downloads[track.id]?.receivedBytes == 50 }
    await old.shutdown()
    let encoded = try JSONEncoder().encode(store.currentState())
    store.save(try JSONDecoder().decode(OnlineDownloadQueuePersistenceState.self, from: encoded))
    #expect(store.currentState().pendingImports.first?.catalogRootItem?.id == root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [track]])
    let restored = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter(), persistence: store)
    restored.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))
    try await waitForQueue { restored.snapshot.imports[taskID]?.phase == .completed }
    #expect(restored.snapshot.tasks.count == 1)
    #expect(await source.downloadedItemIDs == [track.id])
}

@MainActor
@Test("legacy recursive requests still recover their original provider root")
func onlineDownloadQueueRestoresLegacyRecursiveRequest() async throws {
    let sourceID = MediaSourceID("queue.recursive.legacy")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: rootID)
    let store = InMemoryOnlineDownloadQueueStore()
    store.save(OnlineDownloadQueuePersistenceState(pendingImports: [OnlineDownloadQueueImportTask(rootItemID: rootID, displayName: "Album")]))
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [rootID: [track]])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter(), persistence: store)
    queue.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))
    try await waitForQueue { queue.snapshot.imports[rootID]?.phase == .completed }
    #expect(await source.downloadedItemIDs == [track.id])
}

@Test("large task summaries merge archived history and the latest file status")
func onlineDownloadQueueLargeHistorySummaries() throws {
    let sourceID = MediaSourceID("queue.large.history")
    var downloads: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:]
    var imports: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
    for index in 0..<500 {
        let taskID = SourceObjectID(sourceID: sourceID, externalID: "task-\(index)")
        var archived: [OnlineSourceDownloadSnapshot] = []
        for fileIndex in 0..<20 {
            let id = SourceObjectID(sourceID: sourceID, externalID: "file-\(index)-\(fileIndex)")
            var file = OnlineSourceDownloadSnapshot(itemID: id, displayName: "Track.m4a", phase: .failed)
            file.taskID = taskID
            archived.append(file)
            file.phase = .completed
            downloads[id] = file
        }
        var task = OnlineSourceImportSnapshot(rootItemID: taskID, displayName: "Task", phase: .completed)
        task.files = archived
        imports[taskID] = task
    }
    let snapshot = OnlineDownloadQueueSnapshot(downloads: downloads, imports: imports)
    let tasks = snapshot.tasks
    #expect(tasks.count == 500)
    #expect(tasks.allSatisfy { $0.completedFiles == 20 && $0.failedFiles == 0 && $0.phase == .completed })
}

@MainActor
@Test("a file cancellation cannot cancel a fresh import of the same directory")
func onlineDownloadQueueScopesFileCancellationToItsTask() async throws {
    let sourceID = MediaSourceID("queue.cancel.scope")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendedIDs: [track.id], catalog: [root.id: [track]])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let firstID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.downloads[track.id]?.receivedBytes == 50 }
    await queue.cancelDownload(track.id, taskID: firstID)
    try await waitForQueue { queue.snapshot.imports[firstID]?.phase == .failed }
    await source.releaseDownloads()
    let secondID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[secondID]?.phase == .completed }
    #expect(await source.downloadedItemIDs == [track.id, track.id])
    #expect(queue.snapshot.files(for: firstID).first?.phase == .cancelled)
    #expect(queue.snapshot.files(for: secondID).first?.phase == .completed)
}

@MainActor
@Test("a single retry retains its task identity behind queued directory work")
func onlineDownloadQueueSingleResumeKeepsIdentity() async throws {
    let sourceID = MediaSourceID("queue.single.retry")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let other = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "other"), kind: .audioFile, displayName: "Other.m4a", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [other]])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter(failureCounts: [track.displayName: 1]))
    let singleID = try #require(queue.startImport(sourceID: sourceID, item: track))
    try await waitForQueue { queue.snapshot.imports[singleID]?.phase == .failed }
    let directoryID = try #require(queue.startImport(sourceID: sourceID, item: root))
    queue.resumeTask(singleID)
    #expect(queue.snapshot.imports.count == 2)
    #expect(queue.snapshot.imports[singleID]?.phase == .waiting)
    try await waitForQueue { queue.snapshot.imports[singleID]?.phase == .completed }
    #expect(queue.snapshot.imports[directoryID]?.phase == .completed)
    #expect(queue.snapshot.tasks.count == 2)
    #expect(queue.snapshot.downloads[track.id]?.taskID == singleID)
    #expect(queue.snapshot.tasks.first { $0.id == singleID }?.isRecursive == false)
    #expect((await source.downloadedItemIDs).filter { $0 == track.id }.count == 2)
}

@MainActor
@Test("repeated fresh single imports preserve independent completed histories")
func onlineDownloadQueueRepeatedSinglesKeepHistories() async throws {
    let sourceID = MediaSourceID("queue.single.history")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a")
    let source = QueueFixtureOnlineSources(sourceID: sourceID)
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let firstID = try #require(queue.startImport(sourceID: sourceID, item: track))
    try await waitForQueue { queue.snapshot.imports[firstID]?.phase == .completed }
    let firstCreatedAt = try #require(queue.snapshot.imports[firstID]?.createdAt)
    let secondID = try #require(queue.startImport(sourceID: sourceID, item: track))
    #expect(firstID != secondID)
    try await waitForQueue { queue.snapshot.imports[secondID]?.phase == .completed }
    #expect(await source.downloadedItemIDs == [track.id, track.id])
    #expect(queue.snapshot.tasks.count == 2)
    #expect(queue.snapshot.files(for: firstID).first?.taskID == firstID)
    #expect(queue.snapshot.files(for: secondID).first?.taskID == secondID)
    #expect(queue.snapshot.imports[firstID]?.createdAt == firstCreatedAt)
    #expect(queue.snapshot.imports[secondID]!.createdAt! > firstCreatedAt)
    queue.clearCompletedTasks()
    #expect(queue.snapshot.tasks.isEmpty)
}

@MainActor
@Test("a queued single can be cancelled without cancelling an earlier download of the same file")
func onlineDownloadQueueQueuedSingleCancellationKeepsEarlierFile() async throws {
    let sourceID = MediaSourceID("queue.single.cancel.queued")
    let trackID = SourceObjectID(sourceID: sourceID, externalID: "track")
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendsDownloads: true)
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let firstID = try #require(queue.startDownload(sourceID: sourceID, itemID: trackID, displayName: "Track.m4a"))
    try await waitForQueue { queue.snapshot.downloads[trackID]?.receivedBytes == 50 }
    let secondID = try #require(queue.startDownload(sourceID: sourceID, itemID: trackID, displayName: "Track.m4a"))
    await queue.cancelDownload(trackID, taskID: secondID)
    #expect(queue.snapshot.imports[secondID]?.phase == .cancelled)
    #expect(queue.snapshot.files(for: secondID).first?.phase == .cancelled)
    #expect(queue.snapshot.imports[firstID]?.phase.isActive == true)
    #expect(queue.snapshot.downloads[trackID]?.phase == .downloading)
    #expect(await source.downloadedItemIDs == [trackID])
    await queue.cancelTask(firstID)
}

@MainActor
@Test("legacy single requests retain their identity and metadata when resumed behind a directory")
func onlineDownloadQueueLegacySingleResumeKeepsIdentityAndMetadata() async throws {
    let sourceID = MediaSourceID("queue.single.legacy")
    let trackID = SourceObjectID(sourceID: sourceID, externalID: "track")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: trackID, kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let other = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "other"), kind: .audioFile, displayName: "Other.m4a", parentID: root.id)
    let hint = MediaImportMetadataHint(displayName: "Display Title", title: "Title", artist: "Artist", album: "Album", duration: .seconds(42))
    var saved = OnlineDownloadQueuePersistenceState(downloads: [.init(itemID: trackID, displayName: "Track.m4a", phase: .failed)])
    saved.resumableDownloads = [.init(itemID: trackID, displayName: "Track.m4a", metadataHint: hint)]
    let store = InMemoryOnlineDownloadQueueStore()
    store.save(saved)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [track, other]])
    let importer = QueueImmediateImporter()
    let queue = OnlineDownloadQueue(onlineSources: source, importer: importer, persistence: store)
    queue.restore(using: QueueFixtureOnlineSources.readySnapshot(sourceID: sourceID))
    let directoryID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[directoryID]?.phase == .completed }
    #expect(queue.canResumeTask(trackID))
    queue.resumeTask(trackID)
    try await waitForQueue { queue.snapshot.imports[trackID]?.phase == .completed }
    #expect(queue.snapshot.tasks.count == 2)
    let request = try #require((await importer.requests).last { $0.urls.first?.lastPathComponent == "Track.m4a" })
    #expect(request.metadataHints.values.first == hint)
    #expect(store.currentState().resumableImports?.first { $0.rootItemID == trackID }?.singleDownload?.metadataHint == hint)
    #expect(store.currentState().resumableImports?.first { $0.rootItemID == trackID }?.selectedItems?.first?.duration == hint.duration)
    #expect(store.currentState().resumableDownloads?.isEmpty == true)
}

@MainActor
@Test("same-directory selection scans each page once")
func onlineDownloadQueueSelectionReusesPagedDirectory() async throws {
    let sourceID = MediaSourceID("queue.discovery.selection")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let tracks = (0..<1_001).map {
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\($0)"),
            kind: .audioFile,
            displayName: "Track \($0).m4a",
            parentID: root.id
        )
    }
    let source = QueueFixtureOnlineSources(
        sourceID: sourceID,
        suspendsDownloads: true,
        catalog: [root.id: tracks]
    )
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())

    queue.startBatchImport(sourceID: sourceID, items: tracks, displayName: "Selection")
    let taskID = try #require(queue.snapshot.imports.keys.first)
    try await waitForQueue {
        await source.browseRequestCount(parentID: root.id) == 3
            && queue.snapshot.imports[taskID]?.totalItems == tracks.count
    }

    #expect(await source.browseRequestCount(parentID: root.id) == 3)
    #expect(queue.snapshot.imports[taskID]?.totalItems == tracks.count)
    await queue.cancelTask(taskID)
}

@MainActor
@Test("mixed directory and child selection shares one directory scan")
func onlineDownloadQueueMixedSelectionReusesPagedDirectory() async throws {
    let sourceID = MediaSourceID("queue.discovery.mixed")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let tracks = (0..<1_001).map {
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\($0)"),
            kind: .audioFile,
            displayName: "Track \($0).m4a",
            parentID: root.id
        )
    }
    let source = QueueFixtureOnlineSources(
        sourceID: sourceID,
        suspendsDownloads: true,
        catalog: [root.id: tracks]
    )
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())

    queue.startBatchImport(sourceID: sourceID, items: [root] + tracks, displayName: "Mixed selection")
    let taskID = try #require(queue.snapshot.imports.keys.first)
    try await waitForQueue { queue.snapshot.imports[taskID]?.totalItems == tracks.count }

    #expect(await source.browseRequestCount(parentID: root.id) == 3)
    #expect(queue.snapshot.files(for: taskID, sorted: false).filter { $0.isSupportingFile != true }.count == tracks.count)
    await queue.cancelTask(taskID)
}

@MainActor
@Test("large lyric directories build one association index")
func onlineDownloadQueueIndexesLargeLyricDirectory() async throws {
    let sourceID = MediaSourceID("queue.discovery.lyrics")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let tracks = (0..<1_000).map {
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\($0)"),
            kind: .audioFile,
            displayName: "Track \($0).m4a",
            parentID: root.id
        )
    }
    let lyrics = (0..<1_000).map {
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "lyric-\($0)"),
            kind: .unknown,
            displayName: "Track \($0).lrc",
            parentID: root.id
        )
    }
    let source = QueueFixtureOnlineSources(
        sourceID: sourceID,
        suspendedIDs: Set(tracks.prefix(3).map(\.id)),
        catalog: [root.id: tracks + lyrics]
    )
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.files(for: taskID, sorted: false).count == 2_000 }

    #expect(await source.browseRequestCount(parentID: root.id) == 4)
    #expect(queue.snapshot.files(for: taskID, sorted: false).filter { $0.isSupportingFile == true }.count == lyrics.count)
    await queue.cancelTask(taskID)
}

@MainActor
@Test("cancelling the last audio waiting for artwork releases the next task")
func onlineDownloadQueueCancellationReleasesSupportingWait() async throws {
    let sourceID = MediaSourceID("queue.supporting.cancel")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let track = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track"), kind: .audioFile, displayName: "Track.m4a", parentID: root.id)
    let cover = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "cover"), kind: .unknown, displayName: "cover.jpg", parentID: root.id)
    let next = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "next"), kind: .audioFile, displayName: "Next.m4a")
    let source = QueueFixtureOnlineSources(
        sourceID: sourceID,
        suspendedIDs: [cover.id],
        catalog: [root.id: [track, cover]]
    )
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let firstTaskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { await source.downloadedItemIDs.contains(cover.id) }
    let nextTaskID = try #require(queue.startImport(sourceID: sourceID, item: next))

    await queue.cancelDownload(track.id, taskID: firstTaskID)
    try await waitForQueue { queue.snapshot.imports[nextTaskID]?.phase == .completed }

    #expect(queue.snapshot.imports[firstTaskID]?.phase == .failed)
    #expect(queue.snapshot.downloads[track.id]?.phase == .cancelled)
    #expect(await source.downloadedItemIDs.contains(next.id))
}

@MainActor
@Test("resume marks a removed failed audio as skipped and allows cleanup")
func onlineDownloadQueueReconcilesRemovedFailedAudio() async throws {
    let sourceID = MediaSourceID("queue.resume.removed")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let kept = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "kept"), kind: .audioFile, displayName: "Kept.m4a", parentID: root.id)
    let removed = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "removed"), kind: .audioFile, displayName: "Removed.m4a", parentID: root.id)
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: [kept, removed]])
    let queue = OnlineDownloadQueue(
        onlineSources: source,
        importer: QueueImmediateImporter(failureCounts: [removed.displayName: 1])
    )
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .failed }

    await source.setCatalog([kept], for: root.id)
    queue.resumeTask(taskID)
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }

    #expect(queue.snapshot.downloads[removed.id]?.phase == .skipped)
    #expect(queue.snapshot.downloads[removed.id]?.failureReason == "remote_item_missing")
    #expect(queue.snapshot.tasks.first { $0.id == taskID }?.phase == .completed)
    #expect(!queue.canResumeTask(taskID))
    queue.clearCompletedTasks()
    #expect(queue.snapshot.tasks.first { $0.id == taskID } == nil)
}

@MainActor
@Test("rapid file phases coalesce full persistence projections")
func onlineDownloadQueueCoalescesPersistenceDuringBatch() async throws {
    let sourceID = MediaSourceID("queue.persistence.coalescing")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let tracks = (0..<50).map {
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\($0)"),
            kind: .audioFile,
            displayName: "Track \($0).m4a",
            parentID: root.id
        )
    }
    let source = QueueFixtureOnlineSources(sourceID: sourceID, catalog: [root.id: tracks])
    let store = CountingOnlineDownloadQueueStore()
    let queue = OnlineDownloadQueue(
        onlineSources: source,
        importer: QueueImmediateImporter(),
        persistence: store
    )

    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { queue.snapshot.imports[taskID]?.phase == .completed }

    #expect(store.saveCount < 20)
    #expect(store.currentState().imports.first { $0.rootItemID == taskID }?.phase == .completed)
    #expect(store.currentState().pendingImports.isEmpty)
}

@MainActor
@Test("large paged directory discovery registers every file with the correct task")
func onlineDownloadQueueLargePagedDirectoryDiscovery() async throws {
    let sourceID = MediaSourceID("queue.large.discovery")
    let root = SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "album"), kind: .folder, displayName: "Album")
    let tracks = (0..<10_000).map { SourceCatalogItem(id: SourceObjectID(sourceID: sourceID, externalID: "track-\($0)"), kind: .audioFile, displayName: "Track\($0).m4a", parentID: root.id) }
    let source = QueueFixtureOnlineSources(sourceID: sourceID, suspendsDownloads: true, catalog: [root.id: tracks])
    let queue = OnlineDownloadQueue(onlineSources: source, importer: QueueImmediateImporter())
    let taskID = try #require(queue.startImport(sourceID: sourceID, item: root))
    try await waitForQueue { await source.downloadedItemIDs.count == 3 }
    #expect(queue.snapshot.imports[taskID]?.totalItems == tracks.count)
    #expect(queue.snapshot.imports[taskID]?.directories?.first?.isExpanded == true)
    #expect(queue.snapshot.files(for: taskID, sorted: false).count == tracks.count)
    #expect(queue.snapshot.downloads[tracks.last!.id]?.taskID == taskID)
    await queue.cancelTask(taskID)
}

private actor QueueFixtureOnlineSources: OnlineSourceServing {
    let sourceID: MediaSourceID
    private let suspendsDownloads: Bool
    private(set) var downloadedItemIDs: [SourceObjectID] = []
    private var suspendedIDs: Set<SourceObjectID>
    private var catalog: [SourceObjectID: [SourceCatalogItem]]
    private(set) var browseRequests: [SourceBrowseRequest] = []
    private var progressCallbacks: [@Sendable (DownloadProgress) -> Void] = []

    init(sourceID: MediaSourceID, suspendsDownloads: Bool = false, suspendedIDs: Set<SourceObjectID> = [], catalog: [SourceObjectID: [SourceCatalogItem]] = [:]) {
        self.sourceID = sourceID
        self.suspendsDownloads = suspendsDownloads
        self.suspendedIDs = suspendedIDs
        self.catalog = catalog
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
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        browseRequests.append(request)
        let items = request.parentID.flatMap { catalog[$0] } ?? []
        let offset = Int(request.pageToken?.rawValue ?? "0") ?? 0
        let end = min(items.count, offset + 500)
        return SourceCatalogPage(items: Array(items[offset..<end]), nextPageToken: end < items.count ? MediaSourceCursor(String(end)) : nil)
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
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        downloadedItemIDs.append(itemID)
        if let progress = options.progress {
            progressCallbacks.append(progress)
            progress(DownloadProgress(receivedBytes: 50, totalBytes: 100, bytesPerSecond: 10))
        }
        if suspendsDownloads || suspendedIDs.contains(itemID) {
            try await Task.sleep(for: .seconds(60))
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-fixture-\(UUID().uuidString).m4a")
        try Data("fixture-audio".utf8).write(to: fileURL, options: .atomic)
        return DownloadReceipt(
            sourceID: sourceID,
            itemID: itemID,
            fileURL: fileURL
        )
    }

    func releaseDownloads() { suspendedIDs.removeAll() }
    func emitOldProgress() { progressCallbacks.first?(DownloadProgress(receivedBytes: 99, totalBytes: 100)) }
    func setCatalog(_ items: [SourceCatalogItem], for parentID: SourceObjectID) {
        catalog[parentID] = items
    }
    func browseRequestCount(parentID: SourceObjectID?) -> Int {
        browseRequests.filter { $0.parentID == parentID }.count
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
    let leavesStreamOpen: Bool
    private var failureCounts: [String: Int]

    init(leavesStreamOpen: Bool = false, failureCounts: [String: Int] = [:]) {
        self.leavesStreamOpen = leavesStreamOpen
        self.failureCounts = failureCounts
    }

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requests.append(request)
        let name = request.urls.first?.lastPathComponent ?? ""
        let failed = (failureCounts[name] ?? 0) > 0
        if failed { failureCounts[name, default: 0] -= 1 }
        let result = MediaImportResult(
            importID: request.importID,
            imported: failed ? 0 : 1,
            duplicate: 0,
            skipped: 0,
            failed: failed ? 1 : 0,
            cancelled: 0
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(importID: request.importID, result: result))
            if !leavesStreamOpen { continuation.finish() }
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

private final class CountingOnlineDownloadQueueStore: OnlineDownloadQueueStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state = OnlineDownloadQueuePersistenceState()
    private var saves = 0

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() -> OnlineDownloadQueuePersistenceState? { nil }

    func save(_ state: OnlineDownloadQueuePersistenceState) {
        lock.lock()
        self.state = state
        saves += 1
        lock.unlock()
    }

    func currentState() -> OnlineDownloadQueuePersistenceState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
