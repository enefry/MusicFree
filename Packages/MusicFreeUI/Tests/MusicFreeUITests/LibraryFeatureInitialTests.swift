@testable import LibraryFeature
import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import Testing
import UIKit

@Test("Track metadata editor preserves, edits, and clears relationship lists")
func trackMetadataEditorRelationshipNames() {
    #expect(
        TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: ["Artist One", "Artist Two"],
            currentValue: "Artist One / Artist Two"
        ) == ["Artist One", "Artist Two"]
    )
    #expect(
        TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: ["Album Artist"],
            currentValue: ""
        ) == []
    )
    #expect(
        TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: ["Old"],
            currentValue: "New One / New Two / New One"
        ) == ["New One", "New Two"]
    )
    #expect(
        TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: nil,
            currentValue: ""
        ) == nil
    )
}

@MainActor
@Test("Library view model transitions through loading, empty, error, retry, and loaded")
func libraryStateTransitions() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [])),
        .failure(LibraryTestError.unavailable),
        .success(LibraryPage(elements: [makeTrack("recovered")]))
    ]
    let viewModel = LibraryViewModel(
        library: service,
        searchDebounceNanoseconds: 0
    )

    #expect(viewModel.state(for: .tracks) == .idle)
    viewModel.load(section: .tracks, reset: true)
    #expect(viewModel.state(for: .tracks) == .loading)
    await settle()
    #expect(viewModel.state(for: .tracks) == .empty)

    viewModel.refreshCurrentSection()
    await settle()
    #expect(viewModel.state(for: .tracks) == .failed(message: "The library is unavailable."))

    viewModel.retry(section: .tracks)
    await settle()
    #expect(viewModel.state(for: .tracks) == .loaded)
    #expect(viewModel.tracks.map(\.title) == ["recovered"])
}

@MainActor
@Test("Library pagination keeps stable order and removes duplicates")
func libraryPaginationDeduplicatesItems() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(
            LibraryPage(
                elements: [makeTrack("one"), makeTrack("two")],
                nextCursor: LibraryCursor("page-2")
            )
        ),
        .success(LibraryPage(elements: [makeTrack("two"), makeTrack("three")]))
    ]
    let viewModel = LibraryViewModel(library: service, pageSize: 2)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    #expect(viewModel.hasNextPage(for: .tracks))

    viewModel.loadNextPage(for: .tracks)
    viewModel.loadNextPage(for: .tracks)
    await settle()

    #expect(viewModel.tracks.map(\.title) == ["one", "two", "three"])
    #expect(service.trackRequests.count == 2)
}

@MainActor
@Test("Album lookup follows opaque continuation pages")
func libraryAlbumLookupFollowsPagination() async throws {
    let targetID = AlbumID("target-album")
    let service = FakeLibraryService()
    service.albumResponses = [
        .success(
            LibraryPage(
                elements: [Album(id: AlbumID("first-album"), title: "First")],
                nextCursor: LibraryCursor("albums-page-2")
            )
        ),
        .success(LibraryPage(elements: [Album(id: targetID, title: "Target")]))
    ]

    let album = try await LibraryAlbumLoader.load(
        albumID: targetID,
        sourceID: .local,
        from: service
    )

    #expect(album?.title == "Target")
    #expect(service.albumPageRequests.count == 2)
    #expect(service.albumPageRequests[1].cursor == LibraryCursor("albums-page-2"))
}

@MainActor
@Test("Library favorite writes serialize and preserve rapid stale-row intent")
func libraryFavoritePreservesRapidIntent() async {
    let track = makeTrack("favorite rapid")
    let service = FakeLibraryService()
    service.trackResponses = [.success(LibraryPage(elements: [track]))]
    service.storedTracks[track.id] = track
    service.blocksFirstFavoriteMutation = true
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    let staleRowValue = viewModel.tracks[0]

    viewModel.toggleFavorite(staleRowValue)
    await service.waitUntilFirstFavoriteMutationStarts()
    for _ in 0..<4 {
        viewModel.toggleFavorite(staleRowValue)
    }
    service.releaseFirstFavoriteMutation()
    await viewModel.waitForFavoriteMutations()

    #expect(service.favoriteWrites == [true, true])
    #expect(service.storedTracks[track.id]?.isFavorite == true)
    #expect(viewModel.tracks.first?.isFavorite == true)
}

@MainActor
@Test("Removing a track clears loaded library caches and preserves unqueried sections")
func removingTrackClearsLoadedCaches() async {
    let track = makeTrack("removed")
    let favoriteTrack = Track(
        id: track.id,
        title: track.title,
        isFavorite: true
    )
    let history = makeHistoryItem(
        sessionID: UUID(),
        track: track,
        eventTime: 1_700_000_000
    )
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [track])),
        .success(LibraryPage(elements: [favoriteTrack]))
    ]
    service.historyResponses = [.success(LibraryPage(elements: [history]))]
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    viewModel.load(section: .favorites, reset: true)
    await settle()
    viewModel.load(section: .recent, reset: true)
    await settle()

    #expect(viewModel.state(for: .tracks) == .loaded)
    #expect(viewModel.state(for: .favorites) == .loaded)
    #expect(viewModel.state(for: .recent) == .loaded)

    viewModel.removeDeletedTrack(track.id)

    #expect(viewModel.tracks.isEmpty)
    #expect(viewModel.favoriteTracks.isEmpty)
    #expect(viewModel.recentTracks.isEmpty)
    #expect(viewModel.playbackHistory.isEmpty)
    #expect(viewModel.state(for: .tracks) == .empty)
    #expect(viewModel.state(for: .favorites) == .empty)
    #expect(viewModel.state(for: .recent) == .empty)
}

@MainActor
@Test("Removing a track does not mark an unqueried section empty")
func removingTrackPreservesUnqueriedSectionState() async {
    let track = makeTrack("removed before favorites load")
    let service = FakeLibraryService()
    service.trackResponses = [.success(LibraryPage(elements: [track]))]
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    viewModel.removeDeletedTrack(track.id)

    #expect(viewModel.state(for: .tracks) == .empty)
    #expect(viewModel.state(for: .favorites) == .idle)
    #expect(viewModel.state(for: .recent) == .idle)
}

@MainActor
@Test("Removing multiple tracks clears every loaded library cache")
func removingMultipleTracksClearsLoadedCaches() async {
    let first = makeTrack("batch removed one")
    let second = makeTrack("batch removed two")
    let retained = makeTrack("batch retained")
    let retainedFavorite = Track(
        id: retained.id,
        title: retained.title,
        isFavorite: true
    )
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [first, second, retained])),
        .success(LibraryPage(elements: [first, second, retainedFavorite]))
    ]
    service.historyResponses = [
        .success(
            LibraryPage(
                elements: [
                    makeHistoryItem(sessionID: UUID(), track: first, eventTime: 100),
                    makeHistoryItem(sessionID: UUID(), track: second, eventTime: 200),
                    makeHistoryItem(sessionID: UUID(), track: retained, eventTime: 300)
                ]
            )
        )
    ]
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    viewModel.load(section: .favorites, reset: true)
    await settle()
    viewModel.load(section: .recent, reset: true)
    await settle()

    viewModel.removeDeletedTracks([first.id, second.id])

    #expect(viewModel.tracks.map(\.id) == [retained.id])
    #expect(viewModel.favoriteTracks.map(\.id) == [retained.id])
    #expect(viewModel.recentTracks.map(\.id) == [retained.id])
    #expect(viewModel.playbackHistory.map(\.track.id) == [retained.id])
    #expect(viewModel.state(for: .tracks) == .loaded)
    #expect(viewModel.state(for: .favorites) == .loaded)
    #expect(viewModel.state(for: .recent) == .loaded)
}

@MainActor
@Test("Collection batch loader merges album and artist tracks without duplicates")
func collectionBatchLoaderMergesTrackIDs() async throws {
    let albumID = AlbumID(rawValue: "batch-album")
    let artistID = ArtistID(rawValue: "batch-artist")
    let albumTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "album-track"),
        title: "Album track",
        albumID: albumID,
        artistIDs: [artistID]
    )
    let sharedTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "shared-track"),
        title: "Shared track",
        albumID: albumID,
        artistIDs: [artistID]
    )
    let artistTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "artist-track"),
        title: "Artist track",
        artistIDs: [artistID]
    )
    let service = FakeLibraryService()
    service.trackResponsesByQuery[TrackQuery(sourceID: .local, albumID: albumID)] = [
        .success(LibraryPage(elements: [albumTrack, sharedTrack]))
    ]
    service.trackResponsesByQuery[TrackQuery(sourceID: .local, artistID: artistID)] = [
        .success(LibraryPage(elements: [sharedTrack, artistTrack]))
    ]
    let targets: Set<LibraryCollectionQueueTarget> = [
        .album(albumID),
        .artist(artistID)
    ]

    let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
        for: targets,
        from: service
    )

    #expect(itemIDs == Set([albumTrack.id, sharedTrack.id, artistTrack.id]))
    #expect(service.trackRequests.count == 2)
}

@MainActor
@Test("Library overview loads recently added albums in descending date order")
func libraryOverviewLoadsRecentAlbums() async throws {
    let service = FakeLibraryService()
    service.albumResponses = [
        .success(LibraryPage(elements: [makeAlbum("recent")]))
    ]
    let viewModel = LibraryViewModel(library: service)

    viewModel.loadOverviewIfNeeded()
    #expect(viewModel.overviewState == .loading)
    await settle()

    #expect(viewModel.overviewState == .loaded)
    #expect(viewModel.recentAlbums.map(\.title) == ["recent"])
    #expect(service.albumRequests.count == 1)
    #expect(service.albumRequests.first?.sort.key == .dateAdded)
    #expect(service.albumRequests.first?.sort.direction == .descending)

    viewModel.loadOverviewIfNeeded()
    await settle()
    #expect(service.albumRequests.count == 1)
}

@MainActor
@Test("Album sort changes restart the repository query from the first page")
func albumSortChangesReloadFromFirstPage() async throws {
    let service = FakeLibraryService()
    service.albumResponses = [
        .success(LibraryPage(elements: [makeAlbum("initial")], nextCursor: LibraryCursor("page-2"))),
        .success(LibraryPage(elements: [makeAlbum("artist sorted")]))
    ]
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .albums, reset: true)
    await settle()
    #expect(viewModel.state(for: .albums) == .loaded)
    #expect(viewModel.hasNextPage(for: .albums))

    viewModel.setAlbumSort(AlbumSortDescriptor(key: .artistName))
    await settle()

    #expect(viewModel.albumSortDescriptor.key == .artistName)
    #expect(service.albumRequests.map(\.sort.key) == [.title, .artistName])
    #expect(service.albumPageRequests.map(\.cursor) == [nil, nil])
    #expect(viewModel.albums.map(\.title) == ["artist sorted"])
}

@MainActor
@Test("User refresh checks for external imports before reloading the library")
func userRefreshPreparesImportsBeforeReloading() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("after refresh")]))
    ]
    let refreshRecorder = RefreshPreparationRecorder()
    let viewModel = LibraryViewModel(
        library: service,
        refreshPreparation: {
            await refreshRecorder.record()
        }
    )

    await viewModel.refreshCheckingForImports(section: .tracks)
    await settle()

    #expect(await refreshRecorder.callCount == 1)
    #expect(service.trackRequests.count == 1)
    #expect(viewModel.tracks.map(\.title) == ["after refresh"])
}

@MainActor
@Test("First section load prepares external imports before its query")
func firstSectionLoadPreparesExternalImports() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("imported before first query")]))
    ]
    let refreshRecorder = RefreshPreparationRecorder()
    let viewModel = LibraryViewModel(
        library: service,
        refreshPreparation: {
            await refreshRecorder.record()
        }
    )

    await viewModel.prepareForFirstLoad(of: .tracks)
    await settle()

    #expect(await refreshRecorder.callCount == 1)
    #expect(service.trackRequests.count == 1)
    #expect(viewModel.tracks.map(\.title) == ["imported before first query"])

    await viewModel.prepareForFirstLoad(of: .tracks)
    await settle()
    #expect(await refreshRecorder.callCount == 1)
    #expect(service.trackRequests.count == 1)
}

@MainActor
@Test("Selecting a section does not query until initial preparation finishes")
func sectionSelectionWaitsForInitialPreparation() async {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("prepared selection")]))
    ]
    let preparation = BlockingRefreshPreparation()
    let viewModel = LibraryViewModel(
        library: service,
        refreshPreparation: {
            await preparation.prepare()
        },
        selection: .albums
    )

    viewModel.select(.tracks)
    #expect(service.trackRequests.isEmpty)

    let firstLoad = Task { @MainActor in
        await viewModel.prepareForFirstLoad(of: .tracks)
    }
    await preparation.waitUntilStarted()
    await settle()

    #expect(await preparation.callCount == 1)
    #expect(service.trackRequests.isEmpty)

    await preparation.release()
    await firstLoad.value
    await settle()

    #expect(service.trackRequests.count == 1)
    #expect(viewModel.tracks.map(\.title) == ["prepared selection"])
}

@MainActor
@Test("Concurrent first-load callers share preparation and one section query")
func concurrentFirstLoadsAreCoalesced() async {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("coalesced")]))
    ]
    let preparation = BlockingRefreshPreparation()
    let viewModel = LibraryViewModel(
        library: service,
        refreshPreparation: {
            await preparation.prepare()
        }
    )

    let firstLoad = Task { @MainActor in
        await viewModel.prepareForFirstLoad(of: .tracks)
    }
    await preparation.waitUntilStarted()
    let secondLoad = Task { @MainActor in
        await viewModel.prepareForFirstLoad(of: .tracks)
    }
    await settle()

    #expect(await preparation.callCount == 1)
    #expect(service.trackRequests.isEmpty)

    await preparation.release()
    await firstLoad.value
    await secondLoad.value
    await settle()

    #expect(await preparation.callCount == 1)
    #expect(service.trackRequests.count == 1)
    #expect(viewModel.tracks.map(\.title) == ["coalesced"])
}

@Test("Album track ordering uses disc and track numbers with stable fallbacks")
func albumTrackOrderingUsesSourcePositions() {
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "disc-2"),
            title: "Disc 2",
            trackNumber: 1,
            discNumber: 2
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "disc-1-track-2"),
            title: "Second",
            trackNumber: 2,
            discNumber: 1
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "disc-1-track-1"),
            title: "First",
            trackNumber: 1,
            discNumber: 1
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "unknown"),
            title: "Unknown"
        )
    ]

    #expect(LibraryAlbumTrackOrdering.ordered(tracks).map(\.id.externalID) == [
        "disc-1-track-1",
        "disc-1-track-2",
        "disc-2",
        "unknown"
    ])
    #expect(LibraryAlbumTrackOrdering.displayNumber(for: tracks[0]) == "2-1")
    #expect(LibraryAlbumTrackOrdering.displayNumber(for: tracks[2]) == "1")
    #expect(LibraryAlbumTrackOrdering.displayNumber(for: tracks[3]) == nil)

    let partiallyNumberedSingleDisc = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "single-disc-track-3"),
            title: "Third",
            trackNumber: 3,
            discNumber: 2
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "single-disc-track-1"),
            title: "First",
            trackNumber: 1
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "single-disc-track-2"),
            title: "Second",
            trackNumber: 2,
            discNumber: 2
        )
    ]
    #expect(LibraryAlbumTrackOrdering.ordered(partiallyNumberedSingleDisc).map(\.id.externalID) == [
        "single-disc-track-1",
        "single-disc-track-2",
        "single-disc-track-3"
    ])
    #expect(LibraryAlbumTrackOrdering.displayNumber(for: partiallyNumberedSingleDisc[1]) == "1")

    let sparseDiscMetadata = Array(1...20).map { number in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "sparse-\(number)"),
            title: "Track \(number)",
            trackNumber: number,
            discNumber: number == 10 ? 1 : (number == 20 ? 4 : nil)
        )
    }
    #expect(LibraryAlbumTrackOrdering.ordered(sparseDiscMetadata).map(\.trackNumber) == Array(1...20))
    #expect(
        LibraryAlbumTrackOrdering.displayNumber(
            for: sparseDiscMetadata[19],
            in: sparseDiscMetadata
        ) == "20"
    )
}

@Test("Track sections use Latin initials for Chinese and English titles")
func trackSectionIndexUsesLatinInitials() {
    #expect(TrackSectionIndex.title(for: "阿里") == "A")
    #expect(TrackSectionIndex.title(for: "北京") == "B")
    #expect(TrackSectionIndex.title(for: "中文") == "Z")
    #expect(TrackSectionIndex.title(for: "Beyond") == "B")
    #expect(TrackSectionIndex.title(for: "Éclair") == "E")
    #expect(TrackSectionIndex.title(for: "  123") == "#")
    #expect(TrackSectionIndex.title(for: "") == "#")
}

@Test("Fallback track section sorts after alphabetic sections")
func fallbackTrackSectionSortsLast() {
    let sectionTitles = ["#", "Z", "A", "B"]
        .sorted(by: TrackSectionIndex.areInAscendingOrder)

    #expect(sectionTitles == ["A", "B", "Z", "#"])
}

@MainActor
@Test("Collection queue loading traverses every page, preserves album order, and filters folders")
func collectionQueueLoadingUsesCompleteCollection() async throws {
    let service = FakeLibraryService()
    let albumID = AlbumID("queue-album")
    let secondTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "album-second"),
        title: "Second",
        albumID: albumID,
        trackNumber: 2,
        discNumber: 1
    )
    let firstTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "album-first"),
        title: "First",
        albumID: albumID,
        trackNumber: 1,
        discNumber: 1
    )
    service.trackResponses = [
        .success(LibraryPage(
            elements: [secondTrack],
            nextCursor: LibraryCursor("album-page-2")
        )),
        .success(LibraryPage(elements: [firstTrack, secondTrack])),
    ]

    let albumItemIDs = try await LibraryCollectionTrackLoader.itemIDs(
        for: .album(albumID),
        from: service
    )

    #expect(albumItemIDs == [firstTrack.id, secondTrack.id])
    #expect(service.trackRequests.map(\.albumID) == [albumID, albumID])
    #expect(service.trackPageRequests.map(\.cursor) == [nil, LibraryCursor("album-page-2")])

    let firstFolderTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "folder-first"),
        title: "Folder First",
        folderPath: "Imported/Album"
    )
    let otherFolderTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "folder-other"),
        title: "Other Folder",
        folderPath: "Imported/Other"
    )
    let secondFolderTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "folder-second"),
        title: "Folder Second",
        folderPath: "Imported/Album"
    )
    service.trackResponses = [
        .success(LibraryPage(
            elements: [firstFolderTrack, otherFolderTrack],
            nextCursor: LibraryCursor("folder-page-2")
        )),
        .success(LibraryPage(elements: [secondFolderTrack])),
    ]
    service.trackRequests = []
    service.trackPageRequests = []

    let folderItemIDs = try await LibraryCollectionTrackLoader.itemIDs(
        for: .folder("Imported/Album"),
        from: service
    )

    #expect(folderItemIDs == [firstFolderTrack.id, secondFolderTrack.id])
    #expect(service.trackRequests.allSatisfy { $0.sourceID == .local })
    #expect(service.trackPageRequests.map(\.cursor) == [nil, LibraryCursor("folder-page-2")])
}

@MainActor
@Test("Committed library changes refresh content that was previously empty")
func libraryChangesRefreshLoadedContent() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [])),
        .success(LibraryPage(elements: [makeTrack("imported")]))
    ]
    let viewModel = LibraryViewModel(library: service)

    await viewModel.startObservingChanges()
    await settle()
    viewModel.load(section: .tracks, reset: true)
    await settle()
    #expect(viewModel.state(for: .tracks) == .empty)

    service.publish(
        LibraryChange(
            revision: LibraryRevision(1),
            categories: [.tracks],
            affectedIDs: LibraryAffectedIDs()
        )
    )
    await settle()

    #expect(viewModel.state(for: .tracks) == .loaded)
    #expect(viewModel.tracks.map(\.title) == ["imported"])
    viewModel.stopObservingChanges()
}

@MainActor
@Test("Playback history preserves repeated tracks as distinct sessions")
func playbackHistoryPreservesRepeatedSessions() async throws {
    let service = FakeLibraryService()
    let track = makeTrack("repeated")
    let older = makeHistoryItem(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
        track: track,
        eventTime: 100
    )
    let newer = makeHistoryItem(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
        track: track,
        eventTime: 200
    )
    service.historyResponses = [
        .success(LibraryPage(elements: [newer, older]))
    ]
    let viewModel = LibraryViewModel(library: service)

    viewModel.load(section: .recent, reset: true)
    await settle()

    #expect(viewModel.playbackHistory.map(\.sessionID) == [newer.sessionID, older.sessionID])
    #expect(viewModel.recentTracks.map(\.id) == [track.id, track.id])
}

@MainActor
@Test("Playback history clear retains rows on failure and empties them on retry")
func playbackHistoryClearFailureAndRetry() async throws {
    let service = FakeLibraryService()
    let item = makeHistoryItem(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000603")!,
        track: makeTrack("clear me"),
        eventTime: 100
    )
    service.historyResponses = [.success(LibraryPage(elements: [item]))]
    service.clearHistoryError = LibraryTestError.unavailable
    let viewModel = LibraryViewModel(library: service)
    viewModel.load(section: .recent, reset: true)
    await settle()

    await viewModel.clearPlaybackHistory()
    #expect(viewModel.playbackHistory == [item])
    #expect(viewModel.playbackHistoryClearError == "The library is unavailable.")

    service.clearHistoryError = nil
    viewModel.dismissPlaybackHistoryClearError()
    await viewModel.clearPlaybackHistory()
    #expect(viewModel.playbackHistory.isEmpty)
    #expect(viewModel.state(for: .recent) == .empty)
    #expect(service.clearHistoryCallCount == 2)
}

@Test("Playback history groups today and yesterday with newest sessions first")
func playbackHistoryPresentationGroupsDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let todayStart = calendar.startOfDay(for: now)
    let yesterdayStart = try #require(calendar.date(byAdding: .day, value: -1, to: todayStart))
    let track = makeTrack("dated")
    let items = [
        makeHistoryItem(sessionID: UUID(), track: track, date: todayStart.addingTimeInterval(10)),
        makeHistoryItem(sessionID: UUID(), track: track, date: yesterdayStart.addingTimeInterval(20)),
        makeHistoryItem(sessionID: UUID(), track: track, date: todayStart.addingTimeInterval(30)),
    ]

    let sections = PlaybackHistoryPresentation.sections(
        from: items,
        now: now,
        calendar: calendar
    )

    #expect(sections.map(\.title) == ["Today", "Yesterday"])
    #expect(sections[0].items.map(\.lastEventAt) == [
        todayStart.addingTimeInterval(30),
        todayStart.addingTimeInterval(10),
    ])
}

@Test("Library home follows the Apple Music information hierarchy")
func libraryHomeItemOrder() {
    #expect(
        LibraryHomeItem.allCases == [
            .artists,
            .albums,
            .tracks,
            .favorites,
            .recent,
            .genres,
            .folders
        ]
    )
}

@MainActor
@Test("A newer library artwork request wins over an older failure")
func libraryArtworkLoaderIgnoresOlderFailure() async {
    let service = LibraryArtworkRaceService()
    let loader = ArtworkImageLoader()
    let oldRequest = Task {
        await loader.load(
            artworkID: ArtworkID("old"),
            sourceID: .local,
            serving: service
        )
    }

    await service.waitForOldRequest()
    await loader.load(
        artworkID: ArtworkID("new"),
        sourceID: .local,
        serving: service
    )
    await oldRequest.value

    #expect(loader.image != nil)
}

@MainActor
@Test("Cancelling a library artwork request reaches its service operation")
func libraryArtworkLoaderPropagatesCancellation() async {
    let service = LibraryArtworkCancellationService()
    let loader = ArtworkImageLoader()
    let request = Task {
        await loader.load(
            artworkID: ArtworkID("slow"),
            sourceID: .local,
            serving: service
        )
    }

    await service.waitForRequest()
    request.cancel()
    await request.value

    #expect(await service.wasCancelled)
}

@Test("Library artwork decoding rejects local files larger than 20 MiB")
func libraryArtworkDecodingRejectsOversizedLocalFiles() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFree-library-artwork-\(UUID().uuidString).bin")
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(20 * 1_024 * 1_024 + 1))
    try handle.close()

    await #expect(throws: ArtworkImageLoaderError.self) {
        _ = try await ArtworkImageDecoding.image(from: .localFile(url))
    }
}

@MainActor
@Test("Library artwork decoding downsamples images to a 2048 pixel longest edge")
func libraryArtworkDecodingBoundsPixelDimensions() async throws {
    let decoded = try #require(
        try await ArtworkImageDecoding.image(from: .inMemory(wideArtworkData()))
    )
    let cgImage = try #require(decoded.cgImage)

    #expect(max(cgImage.width, cgImage.height) <= 2_048)
    #expect(cgImage.width == 2_048)
}

@MainActor
@Test("Cancelling after library artwork decode starts prevents publication")
func libraryArtworkLoaderChecksCancellationAfterDecode() async throws {
    let service = LibraryArtworkRaceService()
    let decoder = LibraryControlledArtworkDecoder()
    let loader = ArtworkImageLoader { resource in
        await decoder.decode(resource)
    }
    let request = Task {
        await loader.load(
            artworkID: ArtworkID("new"),
            sourceID: .local,
            serving: service
        )
    }

    await decoder.waitForDecode()
    request.cancel()
    await decoder.complete(with: UIImage(data: testArtworkData()))
    await request.value

    #expect(loader.image == nil)
}

@MainActor
@Test("A newer search cancels the old query and wins the result race")
func searchCancelsOlderQuery() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("new result")] ))
    ]
    let viewModel = LibraryViewModel(
        library: service,
        searchDebounceNanoseconds: 0
    )

    viewModel.updateSearchText("old")
    await settle(20_000_000)
    viewModel.updateSearchText("new")
    await settle(150_000_000)

    #expect(service.cancelledQueries == ["old"])
    #expect(service.trackRequests.compactMap(\.searchText) == ["old", "new"])
    #expect(viewModel.tracks.map(\.title) == ["new result"])
}

@Test("Import event mapping exposes progress and redacted failure summaries")
func importEventMapping() {
    let importID = UUID()
    let firstURL = URL(fileURLWithPath: "/fixture/first.mp3")
    let secondURL = URL(fileURLWithPath: "/fixture/broken.wav")
    let request = MediaImportRequest(importID: importID, urls: [firstURL, secondURL])
    var progress = ImportEventMapper.initialSnapshot(for: request)

    progress = ImportEventMapper.apply(
        .hashing(importID: importID, url: firstURL),
        to: progress
    )
    #expect(progress.phase == .hashing)
    #expect(progress.currentItemName == "first.mp3")

    progress = ImportEventMapper.apply(
        .itemFailed(importID: importID, url: secondURL, error: .unsupportedFormat),
        to: progress
    )
    #expect(progress.failedItems == 1)
    #expect(progress.failures.first?.itemName == "broken.wav")
    #expect(progress.failures.first?.code == "unsupported_format")

    let result = MediaImportResult(
        importID: importID,
        imported: 1,
        duplicate: 0,
        skipped: 0,
        failed: 1,
        cancelled: 0
    )
    progress = ImportEventMapper.apply(
        .completed(importID: importID, result: result),
        to: progress
    )
    #expect(progress.result == result)
    #expect(progress.processedItems == 2)
}

@MainActor
private final class FakeLibraryService: LibraryServing {
    var trackResponses: [Result<LibraryPage<Track>, Error>] = []
    var trackResponsesByQuery: [TrackQuery: [Result<LibraryPage<Track>, Error>]] = [:]
    var trackRequests: [TrackQuery] = []
    var trackPageRequests: [LibraryPageRequest] = []
    var albumResponses: [Result<LibraryPage<Album>, Error>] = []
    var albumRequests: [AlbumQuery] = []
    var albumPageRequests: [LibraryPageRequest] = []
    var historyResponses: [Result<LibraryPage<PlaybackHistoryItem>, Error>] = []
    var clearHistoryError: Error?
    private(set) var clearHistoryCallCount = 0
    var cancelledQueries: [String] = []
    var changeContinuation: AsyncStream<LibraryChange>.Continuation?
    var storedTracks: [MediaItemID: Track] = [:]
    var blocksFirstFavoriteMutation = false
    private(set) var favoriteWrites: [Bool] = []
    private var firstFavoriteMutationStarted = false
    private var firstFavoriteMutationContinuation: CheckedContinuation<Void, Never>?
    private var firstFavoriteMutationStartWaiters: [CheckedContinuation<Void, Never>] = []

    func track(id: MediaItemID) async throws -> Track? {
        storedTracks[id]
    }

    func browseTracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        trackRequests.append(query)
        trackPageRequests.append(page)

        if query.searchText == "old" {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                cancelledQueries.append("old")
                throw error
            }
        }

        if var responses = trackResponsesByQuery[query], !responses.isEmpty {
            let response = responses.removeFirst()
            trackResponsesByQuery[query] = responses
            return try response.get()
        }

        guard !trackResponses.isEmpty else { return LibraryPage(elements: []) }
        return try trackResponses.removeFirst().get()
    }

    func browseAlbums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        albumRequests.append(query)
        albumPageRequests.append(page)
        guard !albumResponses.isEmpty else { return LibraryPage(elements: []) }
        return try albumResponses.removeFirst().get()
    }

    func browseArtists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        LibraryPage(elements: [])
    }

    func searchTracks(
        text: String,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func recentHistory(
        page _: LibraryPageRequest
    ) async throws -> LibraryPage<PlaybackHistoryItem> {
        guard !historyResponses.isEmpty else { return LibraryPage(elements: []) }
        return try historyResponses.removeFirst().get()
    }

    func clearPlaybackHistory() async throws {
        clearHistoryCallCount += 1
        if let clearHistoryError { throw clearHistoryError }
    }

    func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
        guard let existing = storedTracks[itemID] else {
            throw LibraryTestError.unavailable
        }
        favoriteWrites.append(isFavorite)
        if blocksFirstFavoriteMutation, favoriteWrites.count == 1 {
            firstFavoriteMutationStarted = true
            let waiters = firstFavoriteMutationStartWaiters
            firstFavoriteMutationStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstFavoriteMutationContinuation = continuation
            }
        }
        let updated = Track(
            id: existing.id,
            title: existing.title,
            sortTitle: existing.sortTitle,
            albumID: existing.albumID,
            artistIDs: existing.artistIDs,
            genreIDs: existing.genreIDs,
            folderPath: existing.folderPath,
            duration: existing.duration,
            technicalInfo: existing.technicalInfo,
            artwork: existing.artwork,
            isFavorite: isFavorite,
            statistics: existing.statistics
        )
        storedTracks[itemID] = updated
        return updated
    }

    func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
        throw LibraryTestError.unavailable
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        throw LibraryTestError.unavailable
    }

    func makeChangeStream() async -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            changeContinuation = continuation
        }
    }

    func publish(_ change: LibraryChange) {
        changeContinuation?.yield(change)
    }

    func waitUntilFirstFavoriteMutationStarts() async {
        guard !firstFavoriteMutationStarted else { return }
        await withCheckedContinuation { continuation in
            firstFavoriteMutationStartWaiters.append(continuation)
        }
    }

    func releaseFirstFavoriteMutation() {
        firstFavoriteMutationContinuation?.resume()
        firstFavoriteMutationContinuation = nil
    }
}

private enum LibraryTestError: Error, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        "The library is unavailable."
    }
}

private enum ArtworkLoaderTestError: Error, Sendable {
    case unavailable
}

private actor LibraryArtworkRaceService: ArtworkServing {
    private var oldRequestStarted = false
    private var oldRequestContinuation: CheckedContinuation<Void, Never>?

    func artwork(
        for artworkID: ArtworkID,
        sourceID _: MediaSourceID
    ) async throws -> ArtworkResource? {
        if artworkID == ArtworkID("old") {
            oldRequestStarted = true
            oldRequestContinuation?.resume()
            oldRequestContinuation = nil
            try await Task.sleep(nanoseconds: 50_000_000)
            throw ArtworkLoaderTestError.unavailable
        }

        return .inMemory(testArtworkData())
    }

    func waitForOldRequest() async {
        guard !oldRequestStarted else { return }
        await withCheckedContinuation { continuation in
            oldRequestContinuation = continuation
        }
    }
}

private actor LibraryArtworkCancellationService: ArtworkServing {
    private var requestStarted = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func artwork(
        for _: ArtworkID,
        sourceID _: MediaSourceID
    ) async throws -> ArtworkResource? {
        requestStarted = true
        requestContinuation?.resume()
        requestContinuation = nil

        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return .inMemory(testArtworkData())
        } catch {
            wasCancelled = true
            throw error
        }
    }

    func waitForRequest() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }
}

private actor LibraryControlledArtworkDecoder {
    private var didStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<UIImage?, Never>?

    func decode(_ resource: ArtworkResource?) async -> UIImage? {
        _ = resource
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitForDecode() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func complete(with image: UIImage?) {
        resultContinuation?.resume(returning: image)
        resultContinuation = nil
    }
}

private func testArtworkData() -> Data {
    Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JgV0AAAAASUVORK5CYII="
    )!
}

@MainActor
private func wideArtworkData() -> Data {
    let size = CGSize(width: 4_096, height: 16)
    return UIGraphicsImageRenderer(size: size).pngData { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

private actor RefreshPreparationRecorder {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private actor BlockingRefreshPreparation {
    private(set) var callCount = 0
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async {
        callCount += 1
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func makeTrack(_ title: String) -> Track {
    Track(
        id: MediaItemID(sourceID: .local, externalID: title),
        title: title
    )
}

private func makeAlbum(_ title: String) -> Album {
    Album(
        id: AlbumID(rawValue: title),
        title: title
    )
}

private func makeHistoryItem(
    sessionID: UUID,
    track: Track,
    eventTime: TimeInterval
) -> PlaybackHistoryItem {
    makeHistoryItem(
        sessionID: sessionID,
        track: track,
        date: Date(timeIntervalSince1970: eventTime)
    )
}

private func makeHistoryItem(
    sessionID: UUID,
    track: Track,
    date: Date
) -> PlaybackHistoryItem {
    PlaybackHistoryItem(
        sessionID: sessionID,
        track: track,
        lastStartedAt: date,
        lastEventAt: date,
        totalPlayedDuration: .seconds(10),
        lastPosition: .seconds(10),
        lastCompletionReason: .ended
    )
}

private func settle(_ nanoseconds: UInt64 = 20_000_000) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
    await Task.yield()
}
