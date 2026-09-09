@testable import SettingsFeature
import AppServices
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI
import Testing

private enum OnlineSourceSceneTestError: Error {
    case unsupported
}

private actor OnlineSourceSceneSettingsStore: SettingsServing {
    private var current: AppSettings

    init(settings: AppSettings) {
        current = settings
    }

    func load() async throws -> AppSettings { current }

    func update(_ settings: AppSettings) async throws {
        current = settings
    }

    func reset() async throws {
        current = .defaults
    }

    func effective() async throws -> EffectivePlaybackSettings {
        EffectivePlaybackSettings(
            settings: current,
            effects: .neutral,
            playbackCapabilities: [],
            systemCapabilities: .init()
        )
    }

    func makeChangeStream() async -> AsyncStream<AppSettings> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuation.finish()
        }
    }
}

private actor OnlineSourceSceneService: OnlineSourceServing {
    private let currentSnapshot: OnlineSourceSnapshot

    init(snapshot: OnlineSourceSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() async -> OnlineSourceSnapshot { currentSnapshot }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        AsyncStream { continuation in
            continuation.yield(currentSnapshot)
            continuation.finish()
        }
    }

    func authenticate(sourceID _: MediaSourceID, oneTimeCode _: String) async throws {
        throw OnlineSourceSceneTestError.unsupported
    }

    func browse(
        sourceID _: MediaSourceID,
        request _: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceSceneTestError.unsupported
    }

    func search(
        sourceID _: MediaSourceID,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceSceneTestError.unsupported
    }

    func download(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceSceneTestError.unsupported
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceSceneTestError.unsupported
    }
}

private actor OnlineSourceDownloadTestService: OnlineSourceServing {
    private let sourceID: MediaSourceID
    private let rootItemID: SourceObjectID
    private let items: [SourceCatalogItem]
    private var activeDownloads = 0
    private var maximumActiveDownloads = 0
    private var downloadedItemIDs: [SourceObjectID] = []

    init(
        sourceID: MediaSourceID,
        rootItemID: SourceObjectID,
        items: [SourceCatalogItem]
    ) {
        self.sourceID = sourceID
        self.rootItemID = rootItemID
        self.items = items
    }

    func snapshot() async -> OnlineSourceSnapshot { OnlineSourceSnapshot() }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        AsyncStream { continuation in
            continuation.yield(OnlineSourceSnapshot())
            continuation.finish()
        }
    }

    func authenticate(sourceID _: MediaSourceID, oneTimeCode _: String) async throws {
        throw OnlineSourceSceneTestError.unsupported
    }

    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        guard sourceID == self.sourceID else {
            throw OnlineSourceSceneTestError.unsupported
        }
        return request.parentID == rootItemID
            ? SourceCatalogPage(items: items)
            : SourceCatalogPage(items: [])
    }

    func search(
        sourceID _: MediaSourceID,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceSceneTestError.unsupported
    }

    func download(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        guard sourceID == self.sourceID else {
            throw OnlineSourceSceneTestError.unsupported
        }
        activeDownloads += 1
        maximumActiveDownloads = max(maximumActiveDownloads, activeDownloads)
        defer { activeDownloads -= 1 }
        try await Task.sleep(for: .milliseconds(40))
        let fileName = options.preferredFileName ?? "fixture.mp3"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "online-source-scene-\(UUID().uuidString)-\(fileName)"
        )
        try Data(itemID.externalID.utf8).write(to: fileURL)
        downloadedItemIDs.append(itemID)
        return DownloadReceipt(
            sourceID: sourceID,
            itemID: itemID,
            fileURL: fileURL
        )
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceSceneTestError.unsupported
    }

    func maximumConcurrentDownloads() -> Int {
        maximumActiveDownloads
    }

    func downloadedIDs() -> [SourceObjectID] {
        downloadedItemIDs
    }
}

private struct OnlineSourceImportTestOutcome: Sendable {
    let imported: Int
    let duplicate: Int
    let skipped: Int
    let failed: Int

    init(
        imported: Int = 0,
        duplicate: Int = 0,
        skipped: Int = 0,
        failed: Int = 0
    ) {
        self.imported = imported
        self.duplicate = duplicate
        self.skipped = skipped
        self.failed = failed
    }
}

private actor OnlineSourceImportTestService: ImportServing {
    private let outcomesByDisplayName: [String: OnlineSourceImportTestOutcome]
    private let blocksUntilCancelled: Bool
    private var requests: [MediaImportRequest] = []
    private var cancelledImportIDs: [UUID] = []

    init(
        outcomesByDisplayName: [String: OnlineSourceImportTestOutcome] = [:],
        blocksUntilCancelled: Bool = false
    ) {
        self.outcomesByDisplayName = outcomesByDisplayName
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requests.append(request)
        if blocksUntilCancelled {
            return AsyncThrowingStream { _ in }
        }
        let displayName = request.metadataHints.values.first?.displayName ?? ""
        let outcome = outcomesByDisplayName[displayName]
            ?? OnlineSourceImportTestOutcome(imported: 1)
        let result = MediaImportResult(
            importID: request.importID,
            imported: outcome.imported,
            duplicate: outcome.duplicate,
            skipped: outcome.skipped,
            failed: outcome.failed,
            cancelled: 0
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(importID: request.importID, result: result))
            continuation.finish()
        }
    }

    func continueImport(_: UUID) async {}

    func cancel(_ importID: UUID) async {
        cancelledImportIDs.append(importID)
    }

    func state(for _: UUID) async -> ImportSessionSnapshot? { nil }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { $0.finish() }
    }

    func capturedRequests() -> [MediaImportRequest] { requests }

    func cancelledIDs() -> [UUID] { cancelledImportIDs }
}

private final class OnlineSourceSceneAuditionService: OnlineAuditionServing {
    var snapshot: OnlineAuditionSnapshot
    private(set) var stopCallCount = 0

    init(snapshot: OnlineAuditionSnapshot = .idle) {
        self.snapshot = snapshot
    }

    func makeSnapshotStream() -> AsyncStream<OnlineAuditionSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func audition(sourceID _: MediaSourceID, item _: SourceCatalogItem) async throws {
        throw OnlineSourceSceneTestError.unsupported
    }

    func stop() async {
        stopCallCount += 1
        snapshot = .init(
            phase: .stopped,
            sourceID: snapshot.sourceID,
            itemID: snapshot.itemID,
            displayName: snapshot.displayName
        )
    }
}

private actor RemovedCredentialRecorder {
    private(set) var recordIDs: [String] = []

    func append(_ recordID: String) {
        recordIDs.append(recordID)
    }
}

private actor DSAudioAuthorizationRequestRecorder {
    private(set) var requests: [DSAudioSourceAuthorizationRequest] = []

    func append(_ request: DSAudioSourceAuthorizationRequest) {
        requests.append(request)
    }
}

private actor OnlineSourceCatalogPagingService: OnlineSourceServing {
    let sourceID: MediaSourceID
    private let pages: [String: SourceCatalogPage]
    private(set) var requestedPageTokens: [String?] = []

    init(sourceID: MediaSourceID, pages: [String: SourceCatalogPage]) {
        self.sourceID = sourceID
        self.pages = pages
    }

    func snapshot() async -> OnlineSourceSnapshot {
        OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: true,
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .googleDrive,
                    displayName: "Paging Drive",
                    capabilities: [.browsing, .downloading, .searching],
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: true
                )
            ]
        )
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        let value = await snapshot()
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func authenticate(sourceID _: MediaSourceID, oneTimeCode _: String) async throws {}

    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        guard sourceID == self.sourceID, request.parentID == nil else {
            throw OnlineSourceSceneTestError.unsupported
        }
        let token = request.pageToken?.rawValue
        requestedPageTokens.append(token)
        return pages[token ?? "first"] ?? SourceCatalogPage(items: [])
    }

    func search(
        sourceID _: MediaSourceID,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceSceneTestError.unsupported
    }

    func download(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceSceneTestError.unsupported
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceSceneTestError.unsupported
    }
}

private actor OnlineSourceCatalogPagingFailureService: OnlineSourceServing {
    let sourceID: MediaSourceID
    let firstItem: SourceCatalogItem

    init(sourceID: MediaSourceID, firstItem: SourceCatalogItem) {
        self.sourceID = sourceID
        self.firstItem = firstItem
    }

    func snapshot() async -> OnlineSourceSnapshot {
        OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: true,
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: "Paging Failure NAS",
                    capabilities: [.browsing],
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: true
                )
            ]
        )
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        let value = await snapshot()
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func authenticate(sourceID _: MediaSourceID, oneTimeCode _: String) async throws {}

    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        guard sourceID == self.sourceID, request.parentID == nil else {
            throw OnlineSourceSceneTestError.unsupported
        }
        if request.pageToken != nil {
            throw OnlineSourceSceneTestError.unsupported
        }
        return SourceCatalogPage(
            items: [firstItem],
            nextPageToken: MediaSourceCursor("next-page")
        )
    }

    func search(
        sourceID _: MediaSourceID,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceSceneTestError.unsupported
    }

    func download(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceSceneTestError.unsupported
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceSceneTestError.unsupported
    }
}

private actor OnlineSourceCatalogFailureService: OnlineSourceServing {
    let sourceID: MediaSourceID
    let rootID: SourceObjectID

    init(sourceID: MediaSourceID) {
        self.sourceID = sourceID
        rootID = SourceObjectID(sourceID: sourceID, externalID: "root-folder")
    }

    func snapshot() async -> OnlineSourceSnapshot {
        OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: true,
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: "Failure NAS",
                    capabilities: [.browsing, .searching],
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: true
                )
            ]
        )
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        let value = await snapshot()
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func authenticate(sourceID _: MediaSourceID, oneTimeCode _: String) async throws {}

    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        guard sourceID == self.sourceID else {
            throw OnlineSourceSceneTestError.unsupported
        }
        if request.parentID == rootID {
            throw OnlineSourceSceneTestError.unsupported
        }
        return SourceCatalogPage(
            items: [
                SourceCatalogItem(
                    id: rootID,
                    kind: .folder,
                    displayName: "Root folder"
                )
            ]
        )
    }

    func search(
        sourceID: MediaSourceID,
        request: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        guard sourceID == self.sourceID else {
            throw OnlineSourceSceneTestError.unsupported
        }
        if request.query == "bad" {
            throw OnlineSourceSceneTestError.unsupported
        }
        return SourceCatalogPage(items: [])
    }

    func download(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceSceneTestError.unsupported
    }

    func playbackAccess(
        sourceID _: MediaSourceID,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceSceneTestError.unsupported
    }
}

@MainActor
@Test("Removing an online source deletes its configuration and credential")
func removingOnlineSourceDeletesConfigurationAndCredential() async throws {
    let sourceID = MediaSourceID("dsaudio.delete.fixture")
    let credentialRecordID = "credential.delete.fixture"
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: "Delete Fixture",
        endpoint: try #require(URL(string: "https://nas.example.test")),
        credentialRecordID: credentialRecordID
    )
    let preferences = try OnlineSourcePreferences().adding(configuration)
    let settingsStore = OnlineSourceSceneSettingsStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                onlineSourcePreferences: preferences
            )
        )
    )
    let serving = OnlineSourceSceneService(
        snapshot: OnlineSourceSnapshot(
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: configuration.displayName,
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: false,
                    isEnabled: false,
                    isRuntimeEnabled: false
                )
            ]
        )
    )
    let credentialRecorder = RemovedCredentialRecorder()
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: settingsStore,
        removeCredential: { recordID in
            await credentialRecorder.append(recordID)
        }
    )

    await model.start()
    #expect(model.snapshot.sources.map(\.sourceID) == [sourceID])

    let removed = await model.removeSource(sourceID)

    #expect(removed)
    #expect(model.snapshot.sources.isEmpty)
    let saved = try await settingsStore.load()
    #expect(saved.importPreferences.onlineSourcePreferences.sources.isEmpty)
    #expect(await credentialRecorder.recordIDs == [credentialRecordID])
}

@MainActor
@Test("Stopping an online audition only affects its source")
func stoppingOnlineAuditionIsScopedToSource() async throws {
    let sourceID = MediaSourceID("dsaudio.audition.fixture")
    let otherSourceID = MediaSourceID("google-drive.other.fixture")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "track")
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: .dsAudio,
        displayName: "Audition Fixture",
        endpoint: try #require(URL(string: "https://nas.example.test"))
    )
    let preferences = try OnlineSourcePreferences().adding(configuration)
    let settingsStore = OnlineSourceSceneSettingsStore(
        settings: AppSettings(
            importPreferences: ImportPreferences(
                onlineSourcePreferences: preferences
            )
        )
    )
    let serving = OnlineSourceSceneService(
        snapshot: OnlineSourceSnapshot(
            sources: [
                OnlineSourceSummary(
                    sourceID: sourceID,
                    providerKind: .dsAudio,
                    displayName: configuration.displayName,
                    privacyPolicyVersion: "1.2.0",
                    isRegistered: true,
                    isPrivacyAccepted: true,
                    isEnabled: true,
                    isRuntimeEnabled: true
                )
            ]
        )
    )
    let audition = OnlineSourceSceneAuditionService(
        snapshot: OnlineAuditionSnapshot(
            phase: .playing,
            sourceID: sourceID,
            itemID: itemID,
            displayName: "Track"
        )
    )
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: audition,
        settingsServing: settingsStore
    )

    await model.start()
    for _ in 0..<20 {
        if model.auditionSnapshot.sourceID == sourceID,
           model.auditionSnapshot.isActive {
            break
        }
        await Task.yield()
    }
    #expect(model.auditionSnapshot.sourceID == sourceID)
    await model.stopAudition(for: otherSourceID)
    #expect(audition.stopCallCount == 0)

    await model.stopAudition(for: sourceID)
    #expect(audition.stopCallCount == 1)
    #expect(model.feedbackSourceID == sourceID)
}

@MainActor
@Test("Online downloads report duplicates and retain catalog metadata hints")
func onlineDownloadReportsDuplicateAndMetadataHint() async throws {
    let sourceID = MediaSourceID("dsaudio.download-metadata.fixture")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "root")
    let item = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "track-1"),
        kind: .track,
        displayName: "Remote Song.mp3",
        parentID: rootID,
        title: "Remote Song Title",
        artist: "Remote Artist",
        album: "Remote Album",
        duration: .seconds(72),
        mimeType: "audio/mpeg",
        isPlayable: true
    )
    let serving = OnlineSourceDownloadTestService(
        sourceID: sourceID,
        rootItemID: rootID,
        items: [item]
    )
    let importer = OnlineSourceImportTestService(
        outcomesByDisplayName: [
            item.displayName: OnlineSourceImportTestOutcome(duplicate: 1)
        ]
    )
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults),
        importer: importer
    )

    model.startDownload(
        sourceID: sourceID,
        itemID: item.id,
        displayName: item.displayName,
        metadataHint: MediaImportMetadataHint(
            displayName: item.displayName,
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration
        )
    )
    let finished = await waitUntil {
        model.downloadSnapshots[item.id]?.phase == .alreadyImported
    }
    let request = try #require(await importer.capturedRequests().first)
    let hint = try #require(request.metadataHints.values.first)

    #expect(finished)
    #expect(request.duplicatePolicy == .report)
    #expect(hint.displayName == item.displayName)
    #expect(hint.title == item.title)
    #expect(hint.artist == item.artist)
    #expect(hint.album == item.album)
    #expect(model.feedbackMessage == "媒体已存在，无需重复导入")
}

@MainActor
@Test("Folder imports use three bounded workers and report every outcome")
func folderImportUsesBoundedConcurrencyAndReportsOutcomes() async throws {
    let sourceID = MediaSourceID("dsaudio.batch.fixture")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "folder")
    let rootItem = SourceCatalogItem(
        id: rootID,
        kind: .folder,
        displayName: "Folder"
    )
    let items = (1...6).map { index in
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\(index)"),
            kind: .audioFile,
            displayName: "Track \(index).mp3",
            parentID: rootID,
            title: "Track \(index)",
            artist: "Artist",
            album: "Album",
            mimeType: "audio/mpeg",
            isPlayable: true
        )
    }
    let serving = OnlineSourceDownloadTestService(
        sourceID: sourceID,
        rootItemID: rootID,
        items: items
    )
    var outcomes: [String: OnlineSourceImportTestOutcome] = [:]
    for item in items.prefix(2) {
        outcomes[item.displayName] = OnlineSourceImportTestOutcome(imported: 1)
    }
    for item in items.dropFirst(2).prefix(2) {
        outcomes[item.displayName] = OnlineSourceImportTestOutcome(duplicate: 1)
    }
    for item in items.suffix(2) {
        outcomes[item.displayName] = OnlineSourceImportTestOutcome(skipped: 1)
    }
    let importer = OnlineSourceImportTestService(outcomesByDisplayName: outcomes)
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults),
        importer: importer
    )

    model.startImport(sourceID: sourceID, item: rootItem)
    let finished = await waitUntil {
        model.importSnapshots[rootID]?.phase == .completed
    }
    let progress = try #require(model.importSnapshots[rootID])
    let requests = await importer.capturedRequests()

    #expect(finished)
    #expect(progress.totalItems == 6)
    #expect(progress.processedItems == 6)
    #expect(progress.importedItems == 2)
    #expect(progress.duplicateItems == 2)
    #expect(progress.skippedItems == 2)
    #expect(progress.failedItems == 0)
    #expect(await serving.maximumConcurrentDownloads() == 3)
    #expect(requests.count == 6)
    #expect(requests.allSatisfy { $0.duplicatePolicy == .report })
    #expect(Set(requests.compactMap { $0.metadataHints.values.first?.displayName })
        == Set(items.map(\.displayName)))
}

@MainActor
@Test("Folder imports attach remote artwork and SRT lyrics to each audio import")
func folderImportIncludesRemoteArtworkAndSRTSidecars() async throws {
    let sourceID = MediaSourceID("drive.sidecars.fixture")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "album-folder")
    let rootItem = SourceCatalogItem(
        id: rootID,
        kind: .folder,
        displayName: "Album Folder"
    )
    let track = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "track"),
        kind: .audioFile,
        displayName: "Song.mp3",
        parentID: rootID,
        mimeType: "audio/mpeg",
        isPlayable: true
    )
    let cover = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "cover"),
        kind: .unknown,
        displayName: "cover.jpg",
        parentID: rootID,
        mimeType: "image/jpeg"
    )
    let lyrics = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "lyrics"),
        kind: .unknown,
        displayName: "Song.srt",
        parentID: rootID,
        mimeType: "application/x-subrip"
    )
    let serving = OnlineSourceDownloadTestService(
        sourceID: sourceID,
        rootItemID: rootID,
        items: [track, cover, lyrics]
    )
    let importer = OnlineSourceImportTestService()
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults),
        importer: importer
    )

    model.startImport(sourceID: sourceID, item: rootItem)
    let finished = await waitUntil {
        model.importSnapshots[rootID]?.phase == .completed
    }
    let request = try #require(await importer.capturedRequests().first)

    #expect(finished)
    #expect(request.urls.map(\.lastPathComponent).sorted() == ["Song.mp3", "Song.srt", "cover.jpg"])
    #expect(request.metadataHints.keys.map(\.lastPathComponent) == ["Song.mp3"])
    #expect(Set(await serving.downloadedIDs()) == Set([track.id, cover.id, lyrics.id]))
    #expect(model.importSnapshots[rootID]?.totalItems == 1)
    #expect(model.importSnapshots[rootID]?.importedItems == 1)
}

@MainActor
@Test("Single-track imports automatically attach sibling artwork and lyrics")
func singleTrackImportIncludesSiblingArtworkAndLyrics() async throws {
    let sourceID = MediaSourceID("drive.single-track-sidecars.fixture")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "album-folder")
    let track = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "track"),
        kind: .audioFile,
        displayName: "Song.mp3",
        parentID: rootID,
        mimeType: "audio/mpeg",
        isPlayable: true
    )
    let cover = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "cover"),
        kind: .unknown,
        displayName: "cover.jpg",
        parentID: rootID,
        mimeType: "image/jpeg"
    )
    let lyrics = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "lyrics"),
        kind: .unknown,
        displayName: "Song.srt",
        parentID: rootID,
        mimeType: "application/x-subrip"
    )
    let serving = OnlineSourceDownloadTestService(
        sourceID: sourceID,
        rootItemID: rootID,
        items: [track, cover, lyrics]
    )
    let importer = OnlineSourceImportTestService()
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults),
        importer: importer
    )

    model.startImport(sourceID: sourceID, item: track)
    let finished = await waitUntil {
        model.downloadSnapshots[track.id]?.phase == .completed
    }
    let request = try #require(await importer.capturedRequests().first)

    #expect(finished)
    #expect(request.urls.map(\.lastPathComponent).sorted() == ["Song.mp3", "Song.srt", "cover.jpg"])
    #expect(request.metadataHints.keys.map(\.lastPathComponent) == ["Song.mp3"])
    #expect(Set(await serving.downloadedIDs()) == Set([track.id, cover.id, lyrics.id]))
}

@MainActor
@Test("Cancelling a folder import cancels every active local import")
func cancellingFolderImportCancelsEveryActiveImport() async throws {
    let sourceID = MediaSourceID("dsaudio.batch-cancel.fixture")
    let rootID = SourceObjectID(sourceID: sourceID, externalID: "folder")
    let rootItem = SourceCatalogItem(
        id: rootID,
        kind: .folder,
        displayName: "Folder"
    )
    let items = (1...5).map { index in
        SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: "track-\(index)"),
            kind: .audioFile,
            displayName: "Track \(index).mp3",
            parentID: rootID,
            mimeType: "audio/mpeg",
            isPlayable: true
        )
    }
    let serving = OnlineSourceDownloadTestService(
        sourceID: sourceID,
        rootItemID: rootID,
        items: items
    )
    let importer = OnlineSourceImportTestService(blocksUntilCancelled: true)
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults),
        importer: importer
    )

    model.startImport(sourceID: sourceID, item: rootItem)
    let threeImportsStarted = await waitUntil {
        await importer.capturedRequests().count == 3
    }
    let startedIDs = Set(await importer.capturedRequests().map(\.importID))
    await model.cancelImport(rootID)
    let allCancelled = await waitUntil {
        Set(await importer.cancelledIDs()) == startedIDs
    }

    #expect(threeImportsStarted)
    #expect(startedIDs.count == 3)
    #expect(allCancelled)
    #expect(model.importSnapshots[rootID]?.phase == .cancelled)
}

@MainActor
@Test("UIKit DS Audio OTP completes the pending add flow with the original source name")
func dsAudioOneTimeCodeCompletesPendingAddFlow() async throws {
    let sourceID = MediaSourceID("dsaudio.otp-add.fixture")
    let endpoint = try #require(URL(string: "https://nas.example.test"))
    let settings = AppSettings(
        importPreferences: ImportPreferences(
            privacyPreferences: PrivacyPreferences(
                privacyPolicyVersion: PrivacyPreferences.currentPrivacyPolicyVersion
            )
        )
    )
    let settingsStore = OnlineSourceSceneSettingsStore(settings: settings)
    let serving = OnlineSourceSceneService(
        snapshot: OnlineSourceSnapshot(
            isGloballyEnabled: true,
            isApplicationPrivacyAccepted: true
        )
    )
    let recorder = DSAudioAuthorizationRequestRecorder()
    let authorizer: DSAudioSourceAuthorizer = { request in
        await recorder.append(request)
        if request.oneTimeCode == nil {
            return .verificationRequired(challengeToken: "fixture-challenge")
        }
        return .authorized
    }
    let model = OnlineSourcesSceneModel(
        serving: serving,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: settingsStore,
        authorizeDSAudioSource: authorizer
    )

    await model.start()
    let firstResult = await model.addSource(
        sourceID: sourceID,
        deviceName: "MusicFree-fixture-device",
        providerKind: .dsAudio,
        displayName: "家庭 NAS",
        endpointText: endpoint.absoluteString,
        account: "fixture-account",
        password: "fixture-password"
    )

    guard case let .verificationRequired(token) = firstResult else {
        Issue.record("The first DS Audio authorization should require an OTP")
        return
    }
    #expect(token == "fixture-challenge")
    #expect(model.authenticationChallengeSourceID == sourceID)

    let completed = await model.authenticateWithOneTimeCode(
        sourceID: sourceID,
        code: "123456"
    )
    let saved = try await settingsStore.load()
    let configuration = try #require(
        saved.importPreferences.onlineSourcePreferences.source(for: sourceID)
    )
    let requests = await recorder.requests

    #expect(completed)
    #expect(model.authenticationChallengeSourceID == nil)
    #expect(configuration.displayName == "家庭 NAS")
    #expect(configuration.endpoint == endpoint)
    #expect(configuration.credentialRecordID == sourceID.rawValue)
    #expect(requests.count == 2)
    #expect(requests[0].displayName == "家庭 NAS")
    #expect(requests[1].displayName == "家庭 NAS")
    #expect(requests[1].oneTimeCode == "123456")
    #expect(requests[1].challengeToken == "fixture-challenge")
}

@MainActor
@Test("Online catalog browsing exposes the next page to UIKit callers")
func onlineCatalogBrowsingSupportsPagination() async throws {
    let sourceID = MediaSourceID("google-drive.catalog-pagination.fixture")
    let firstItem = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "page-1"),
        kind: .audioFile,
        displayName: "Page 1.mp3",
        isPlayable: true
    )
    let secondItem = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "page-2"),
        kind: .audioFile,
        displayName: "Page 2.mp3",
        isPlayable: true
    )
    let service = OnlineSourceCatalogPagingService(
        sourceID: sourceID,
        pages: [
            "first": SourceCatalogPage(
                items: [firstItem],
                nextPageToken: MediaSourceCursor("next-page")
            ),
            "next-page": SourceCatalogPage(items: [secondItem])
        ]
    )
    let model = OnlineSourcesSceneModel(
        serving: service,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults)
    )

    await model.start()
    let firstPage = await model.loadCatalogPage(for: sourceID)
    let secondPage = await model.loadCatalogPage(
        for: sourceID,
        pageToken: firstPage?.nextPageToken
    )

    #expect(firstPage?.items == [firstItem])
    #expect(firstPage?.nextPageToken?.rawValue == "next-page")
    #expect(secondPage?.items == [secondItem])
    #expect(await service.requestedPageTokens == [nil, "next-page"])
}

@MainActor
@Test("Online catalog failures stay scoped to directory and search context")
func onlineCatalogFailuresStayScopedToRequestContext() async throws {
    let sourceID = MediaSourceID("dsaudio.catalog-failure-scope.fixture")
    let service = OnlineSourceCatalogFailureService(sourceID: sourceID)
    let model = OnlineSourcesSceneModel(
        serving: service,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults)
    )

    await model.start()
    let rootPage = await model.loadCatalogPage(for: sourceID)
    let rootItem = try #require(rootPage?.items.first)
    let childPage = await model.loadCatalogPage(
        for: sourceID,
        parentID: rootItem.id
    )
    let failedSearch = await model.searchCatalogPage(
        for: sourceID,
        query: " bad "
    )

    #expect(rootPage?.items.count == 1)
    #expect(childPage == nil)
    #expect(failedSearch == nil)
    #expect(model.catalogFailureMessage(
        for: sourceID,
        parentID: rootItem.id
    ) != nil)
    #expect(model.catalogFailureMessage(for: sourceID) == nil)
    #expect(model.catalogFailureMessage(
        for: sourceID,
        query: "bad"
    ) != nil)
    #expect(model.catalogFailureMessage(for: sourceID, query: "") == nil)
}

@MainActor
@Test("Online catalog pagination failures do not leak into the first-page state")
func onlineCatalogPaginationFailuresStayBoundToTheirCursor() async throws {
    let sourceID = MediaSourceID("dsaudio.catalog-page-failure.fixture")
    let firstItem = SourceCatalogItem(
        id: SourceObjectID(sourceID: sourceID, externalID: "first"),
        kind: .audioFile,
        displayName: "First.mp3",
        isPlayable: true
    )
    let service = OnlineSourceCatalogPagingFailureService(
        sourceID: sourceID,
        firstItem: firstItem
    )
    let model = OnlineSourcesSceneModel(
        serving: service,
        auditionServing: OnlineSourceSceneAuditionService(),
        settingsServing: OnlineSourceSceneSettingsStore(settings: .defaults)
    )

    await model.start()
    let firstPage = await model.loadCatalogPage(for: sourceID)
    let nextToken = try #require(firstPage?.nextPageToken)
    let failedPage = await model.loadCatalogPage(
        for: sourceID,
        pageToken: nextToken
    )

    #expect(firstPage?.items == [firstItem])
    #expect(failedPage == nil)
    #expect(model.catalogFailureMessage(for: sourceID) == nil)
    #expect(model.catalogFailureMessage(for: sourceID, pageToken: nextToken) != nil)

    let refreshedFirstPage = await model.loadCatalogPage(for: sourceID)
    #expect(refreshedFirstPage?.items == [firstItem])
    #expect(model.catalogFailureMessage(for: sourceID) == nil)
    #expect(model.catalogFailureMessage(for: sourceID, pageToken: nextToken) == nil)
}

@MainActor
private func waitUntil(
    attempts: Int = 300,
    condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
@Test("Renaming a source preserves all other settings and survives a stale runtime snapshot", arguments: [OnlineProviderKind.dsAudio, .googleDrive, .gateway])
func renamingOnlineSourcePreservesConfiguration(provider: OnlineProviderKind) async throws {
    let sourceID = MediaSourceID("rename.fixture")
    let configuration = try OnlineSourceConfiguration(
        sourceID: sourceID,
        providerKind: provider,
        displayName: "Original",
        endpoint: URL(string: "https://nas.example.test/audio"),
        rootObjectID: SourceObjectID(sourceID: sourceID, externalID: "music"),
        credentialRecordID: "existing-credential",
        privacyPolicyVersion: "1.2.0",
        isEnabled: false
    )
    let settings = AppSettings(importPreferences: ImportPreferences(
        onlineSourcePreferences: OnlineSourcePreferences(isEnabled: false, sources: [configuration])
    ))
    let store = OnlineSourceSceneSettingsStore(settings: settings)
    let service = OnlineSourceSceneService(snapshot: OnlineSourceSnapshot(sources: [
        OnlineSourceSummary(
            sourceID: sourceID, providerKind: provider, displayName: "Original",
            privacyPolicyVersion: "1.2.0", isRegistered: true,
            isPrivacyAccepted: true, isEnabled: false, isRuntimeEnabled: false
        )
    ]))
    let model = OnlineSourcesSceneModel(
        serving: service, auditionServing: OnlineSourceSceneAuditionService(), settingsServing: store
    )
    await model.start()
    #expect(await model.renameSource(sourceID, to: "  New name \n"))
    let saved = try await store.load()
    let renamed = try #require(saved.importPreferences.onlineSourcePreferences.source(for: sourceID))
    #expect(renamed.displayName == "New name")
    // Comparing the entire settings value catches changes to credentials, root,
    // provider, consent, enablement, and unrelated settings in this mutation.
    let restored = try saved.importPreferences.onlineSourcePreferences.updating(renamed.renaming(to: "Original"))
    let restoredSettings = AppSettings(
        importPreferences: saved.importPreferences.settingOnlineSourcePreferences(restored),
        playbackPreferences: saved.playbackPreferences,
        storagePreferences: saved.storagePreferences,
        loggingPreferences: saved.loggingPreferences
    )
    #expect(restoredSettings == settings)
    #expect(model.snapshot.sources.first?.displayName == "New name")
    await model.refreshPersistedState()
    #expect(model.snapshot.sources.first?.displayName == "New name")
    #expect(!(await model.renameSource(sourceID, to: " \n ")))
    #expect(try await store.load() == saved)
    #expect(!(await model.renameSource(MediaSourceID("missing"), to: "Another")))
    #expect(try await store.load() == saved)
    let reopened = OnlineSourcesSceneModel(
        serving: service, auditionServing: OnlineSourceSceneAuditionService(), settingsServing: store
    )
    await reopened.start()
    #expect(reopened.snapshot.sources.first?.displayName == "New name")
}
