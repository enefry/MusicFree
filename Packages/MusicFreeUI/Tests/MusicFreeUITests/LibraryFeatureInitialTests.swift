@testable import LibraryFeature
import Combine
import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing
import UIKit

@MainActor
@Test("Album refresh keeps loaded pages until one atomic replacement")
func albumRefreshPreservesLoadedWindow() async throws {
    let service = FakeLibraryService()
    let albums = (0..<6).map { makeAlbum("Album \($0)") }
    service.albumResponses = [
        .success(LibraryPage(elements: Array(albums.prefix(3)), nextCursor: LibraryCursor("p2"))),
        .success(LibraryPage(elements: Array(albums.suffix(3)), nextCursor: LibraryCursor("p3"))),
        .success(LibraryPage(elements: Array(albums[1...3]), nextCursor: LibraryCursor("new2"))),
        .success(LibraryPage(elements: Array(albums[4...5])))
    ]
    let model = LibraryViewModel(library: service, selection: .albums, pageSize: 3)
    model.load(section: .albums, reset: true)
    await settle()
    model.loadNextPage(for: .albums)
    await settle()
    #expect(model.albums.count == 6)
    var publishedCounts: [Int] = []
    let observation = model.$albums.sink { publishedCounts.append($0.count) }
    model.refresh(section: .albums)
    #expect(model.albums.count == 6)
    #expect(model.state(for: .albums) == .loaded)
    await settle()
    #expect(model.albums == Array(albums.dropFirst()))
    #expect(publishedCounts == [6, 5])
    #expect(service.albumPageRequests.last?.cursor == LibraryCursor("new2"))
    observation.cancel()
}

@MainActor
@Test("Batch album deletion gathers all pages and makes one deduplicated removal")
func albumBatchDeletionUsesOneTransaction() async throws {
    let service = FakeLibraryService()
    service.allowsDeletion = true
    let a = Track(id: makeTrack("a").id, title: "a", albumID: AlbumID("one"))
    let b = Track(id: makeTrack("b").id, title: "b", albumID: AlbumID("two"))
    let other = Track(id: makeTrack("c").id, title: "c", albumID: AlbumID("other"))
    service.trackResponses = [
        .success(LibraryPage(elements: [a, other], nextCursor: LibraryCursor("p2"))),
        .success(LibraryPage(elements: [a, b]))
    ]
    let model = LibraryViewModel(library: service)
    try await model.deleteAlbums([AlbumID("one"), AlbumID("two")])
    #expect(service.deletedBatches == [Set([a.id, b.id])])
    #expect(service.trackRequests.count == 2)
    #expect(service.albumRequests.isEmpty)
}

@MainActor
@Test("Successful album deletion immediately removes the displayed album without a change event")
func albumDeletionUpdatesDisplayedAlbumsWithoutEvent() async throws {
    let service = FakeLibraryService()
    service.allowsDeletion = true
    let removed = makeAlbum("Removed")
    let retained = makeAlbum("Retained")
    service.defaultAlbums = [removed, retained]
    let model = LibraryViewModel(library: service)
    model.load(section: .albums, reset: true)
    await settle()
    let track = Track(id: makeTrack("removed-track").id, title: "Song", albumID: removed.id)
    service.trackResponses = [.success(LibraryPage(elements: [track]))]
    try await model.deleteAlbums([removed.id])
    #expect(model.albums == [retained])
    #expect(model.state(for: .albums) == .loaded)
    #expect(service.deletedBatches == [Set([track.id])])
    let lastTrack = Track(id: makeTrack("last-track").id, title: "Last", albumID: retained.id)
    service.trackResponses = [.success(LibraryPage(elements: [lastTrack]))]
    try await model.deleteAlbums([retained.id])
    #expect(model.albums.isEmpty)
    #expect(model.state(for: .albums) == .empty)
    #expect(service.albumRequests.count == 1)
}

@MainActor
@Test("A stale album page cannot resurrect an album after deletion")
func albumDeletionRejectsInflightStalePage() async throws {
    let service = FakeLibraryService()
    service.allowsDeletion = true
    let removed = makeAlbum("Removed")
    let retained = makeAlbum("Retained")
    service.defaultAlbums = [removed, retained]
    let model = LibraryViewModel(library: service)
    model.load(section: .albums, reset: true)
    await settle()
    service.holdNextAlbumPage = true
    model.refresh(section: .albums)
    await settleUntil { service.heldAlbumPage != nil }
    #expect(service.heldAlbumPage != nil)
    defer { service.releaseHeldAlbumPage() }
    service.defaultAlbums = [retained]
    let track = Track(id: makeTrack("removed-track").id, title: "Song", albumID: removed.id)
    service.trackResponses = [.success(LibraryPage(elements: [track]))]
    try await model.deleteAlbums([removed.id])
    #expect(model.albums == [retained])
    await settle()
    service.releaseHeldAlbumPage()
    await settle()
    #expect(model.albums == [retained])
    #expect(model.state(for: .albums) == .loaded)
    #expect(!model.isLoading(.albums))
}

@MainActor
@Test("A failed album deletion leaves the displayed album intact")
func failedAlbumDeletionPreservesDisplayedAlbums() async throws {
    let service = FakeLibraryService()
    let album = makeAlbum("Retained")
    service.defaultAlbums = [album]
    let model = LibraryViewModel(library: service)
    model.load(section: .albums, reset: true)
    await settle()
    let track = Track(id: makeTrack("song").id, title: "Song", albumID: album.id)
    service.trackResponses = [.success(LibraryPage(elements: [track]))]
    await #expect(throws: LibraryTestError.self) { try await model.deleteAlbums([album.id]) }
    #expect(model.albums == [album])
    #expect(model.state(for: .albums) == .loaded)
}

@MainActor
@Test("Album refresh retains the visible surviving cell in grid and list")
func albumCollectionRefreshKeepsScrollAnchor() async throws {
    let service = FakeLibraryService()
    service.defaultAlbums = (0..<80).map { makeAlbum(String(format: "Album %03d", $0)) }
    let model = LibraryViewModel(library: service)
    model.load(section: .albums, reset: true)
    await settle()
    let controller = LibraryCollectionsViewController(viewModel: model, section: .albums)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = UINavigationController(rootViewController: controller)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    controller.loadViewIfNeeded()
    await settle(100_000_000)
    #expect(model.selection == .albums)
    let collection = try #require(controller.contentScrollView(for: .top) as? UICollectionView)
    for list in [false, true] {
        controller.setAlbumDisplayMode(list ? .list : .grid)
        collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        collection.layoutIfNeeded()
        let cell = try #require(collection.visibleCells.sorted { $0.frame.minY < $1.frame.minY }.first)
        let identifier = cell.accessibilityIdentifier
        let distance = cell.frame.minY - collection.contentOffset.y
        service.defaultAlbums.removeFirst(2)
        service.publish(LibraryChange(
            revision: LibraryRevision(list ? 2 : 1),
            categories: [.albums, .deletions], affectedIDs: LibraryAffectedIDs()
        ))
        await settle(150_000_000)
        collection.layoutIfNeeded()
        #expect(model.albums == service.defaultAlbums)
        #expect(collection.numberOfItems(inSection: 0) == service.defaultAlbums.count)
        let surviving = try #require(collection.visibleCells.first { $0.accessibilityIdentifier == identifier })
        #expect(abs(surviving.frame.minY - collection.contentOffset.y - distance) < 2)
        #expect(collection.contentOffset.y > 500)
    }
    service.allowsDeletion = true
    let visibleCell = try #require(collection.visibleCells.first)
    let removedAlbum = try #require(model.albums.first {
        visibleCell.accessibilityIdentifier == "library.album.open.\($0.id.rawValue)"
    })
    let deletedIdentifier = visibleCell.accessibilityIdentifier
    let deletedTrack = Track(id: makeTrack("visible-track").id, title: "Song", albumID: removedAlbum.id)
    service.trackResponses = [.success(LibraryPage(elements: [deletedTrack]))]
    try await model.deleteAlbums([removedAlbum.id])
    service.defaultAlbums.removeAll { $0.id == removedAlbum.id }
    await settle(100_000_000)
    collection.layoutIfNeeded()
    #expect(!model.albums.contains { $0.id == removedAlbum.id })
    #expect(collection.numberOfItems(inSection: 0) == service.defaultAlbums.count)
    #expect(!collection.visibleCells.contains { $0.accessibilityIdentifier == deletedIdentifier })
    #expect(collection.contentOffset.y > 500)
    // Returning from another section must restore the active query target.
    model.select(.tracks)
    controller.viewWillAppear(false)
    #expect(model.selection == .albums)
    controller.setAlbumSelection(true)
    let index = try #require(collection.indexPathsForVisibleItems.sorted().first)
    collection.delegate?.collectionView?(collection, didSelectItemAt: index)
    #expect(controller.title == "已选择 1 张专辑" || controller.title?.contains("1") == true)
    #expect(collection.cellForItem(at: index)?.accessibilityTraits.contains(.selected) == true)
    collection.delegate?.collectionView?(collection, didSelectItemAt: index)
    #expect(collection.cellForItem(at: index)?.accessibilityTraits.contains(.selected) == false)
    controller.viewWillDisappear(false)
    model.stopObservingChanges()
}

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
@Test("Library refresh replaces a stale item with richer relationships")
func libraryRefreshReplacesStaleTrackMetadata() async {
    let artistID = ArtistID("artist-enriched")
    let stale = Track(
        id: MediaItemID(sourceID: .local, externalID: "same-track"),
        title: "Tone"
    )
    let enriched = Track(
        id: stale.id,
        title: "Tone",
        artistIDs: [artistID]
    )
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(
            LibraryPage(
                elements: [stale],
                nextCursor: LibraryCursor("page-2")
            )
        ),
        .success(LibraryPage(elements: [enriched]))
    ]
    let viewModel = LibraryViewModel(library: service, pageSize: 1)

    viewModel.load(section: .tracks, reset: true)
    await settle()
    viewModel.loadNextPage(for: .tracks)
    await settle()

    #expect(viewModel.tracks.count == 1)
    #expect(viewModel.tracks.first?.artistIDs == [artistID])
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
@Test("Album name lookup follows every page and returns only requested albums")
func libraryAlbumNameLookupFollowsPagination() async throws {
    let firstID = AlbumID("first-requested-album")
    let secondID = AlbumID("second-requested-album")
    let service = FakeLibraryService()
    service.albumResponses = [
        .success(
            LibraryPage(
                elements: [
                    Album(id: AlbumID("unrelated-album"), title: "Unrelated"),
                    Album(id: firstID, title: "First Requested"),
                ],
                nextCursor: LibraryCursor("album-names-page-2")
            )
        ),
        .success(
            LibraryPage(elements: [Album(id: secondID, title: "Second Requested")])
        ),
    ]

    let names = try await LibraryAlbumLoader.load(
        albumIDs: [firstID, secondID],
        sourceID: .local,
        from: service
    )

    #expect(names == [
        firstID: "First Requested",
        secondID: "Second Requested",
    ])
    #expect(service.albumPageRequests.map(\.cursor) == [
        nil,
        LibraryCursor("album-names-page-2"),
    ])
}

@Test("Albums present the no-album collection before regular albums")
func libraryAlbumCollectionPresentsNoAlbumFirst() {
    let firstAlbumID = AlbumID("first-album")
    let secondAlbumID = AlbumID("second-album")

    #expect(
        LibraryAlbumCollectionDisplayItem.ordered(
            albumIDs: [firstAlbumID, secondAlbumID],
            includesNoAlbum: true
        ) == [
            .noAlbum,
            .album(firstAlbumID),
            .album(secondAlbumID),
        ]
    )
    #expect(
        LibraryAlbumCollectionDisplayItem.ordered(
            albumIDs: [firstAlbumID],
            includesNoAlbum: false
        ) == [.album(firstAlbumID)]
    )
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
@Test("Merged artist album target loads tracks from every underlying album")
func mergedAlbumTargetLoadsAllTracks() async throws {
    let firstAlbumID = AlbumID("merged-first")
    let secondAlbumID = AlbumID("merged-second")
    let firstTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "merged-first-track"),
        title: "First track",
        albumID: firstAlbumID
    )
    let secondTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "merged-second-track"),
        title: "Second track",
        albumID: secondAlbumID
    )
    let unrelatedTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "unrelated-track"),
        title: "Unrelated track",
        albumID: AlbumID("unrelated")
    )
    let service = FakeLibraryService()
    service.trackResponsesByQuery[TrackQuery(sourceID: .local)] = [
        .success(LibraryPage(elements: [firstTrack, secondTrack, unrelatedTrack]))
    ]

    let tracks = try await LibraryCollectionTrackLoader.tracks(
        for: .albums([firstAlbumID, secondAlbumID]),
        from: service
    )

    #expect(tracks.map(\.id) == [firstTrack.id, secondTrack.id])
}

@MainActor
@Test("No-album collection keeps tracks with missing album records visible")
func noAlbumCollectionIncludesUnassignedAndOrphanedTracks() async throws {
    let knownAlbumID = AlbumID("known-album")
    let orphanAlbumID = AlbumID("missing-album")
    let allTracksQuery = TrackQuery(sourceID: .local)
    let service = FakeLibraryService()
        service.trackResponsesByQuery[allTracksQuery] = [
            .success(
                LibraryPage(
                    elements: [
                        Track(
                            id: MediaItemID(sourceID: .local, externalID: "assigned"),
                            title: "Assigned",
                            albumID: knownAlbumID
                        ),
                        Track(
                            id: MediaItemID(sourceID: .local, externalID: "unassigned"),
                            title: "Unassigned"
                        ),
                    ],
                    nextCursor: LibraryCursor("tracks-page-2")
                )
            ),
            .success(
                LibraryPage(elements: [
                    Track(
                        id: MediaItemID(sourceID: .local, externalID: "orphaned"),
                        title: "Orphaned",
                        albumID: orphanAlbumID
                    )
                ])
            ),
        ]
        service.albumResponses = [
            .success(
                LibraryPage(
                    elements: [Album(id: knownAlbumID, title: "Known")],
                    nextCursor: LibraryCursor("albums-page-2")
                )
            ),
            .success(LibraryPage(elements: [])),
        ]

        let content = try await LibraryCollectionTrackLoader.noAlbumContent(from: service)

        #expect(content.tracks.map(\.title) == ["Unassigned", "Orphaned"])
        #expect(content.knownAlbumIDs == [knownAlbumID])
        #expect(service.trackPageRequests.count == 2)
        #expect(service.albumPageRequests.count == 2)
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
@Test("Initial load and user refresh use distinct import preparations")
func initialLoadAndUserRefreshUseDistinctPreparations() async throws {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("initial")])),
        .success(LibraryPage(elements: [makeTrack("refreshed")]))
    ]
    let initialRecorder = RefreshPreparationRecorder()
    let refreshRecorder = RefreshPreparationRecorder()
    let viewModel = LibraryViewModel(
        library: service,
        initialPreparation: {
            await initialRecorder.record()
        },
        refreshPreparation: {
            await refreshRecorder.record()
        }
    )

    await viewModel.prepareForFirstLoad(of: .tracks)
    await settle()

    #expect(await initialRecorder.callCount == 1)
    #expect(await refreshRecorder.callCount == 0)
    #expect(viewModel.tracks.map(\.title) == ["initial"])

    await viewModel.refreshCheckingForImports(section: .tracks)
    await settle()

    #expect(await initialRecorder.callCount == 1)
    #expect(await refreshRecorder.callCount == 1)
    #expect(viewModel.tracks.map(\.title) == ["refreshed"])
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

@Test("Media sharing resolves physical assets, preserves order, and removes duplicate files")
func mediaSharingUsesPhysicalAssetsAndDeduplicatesFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFree-Share-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let firstURL = root.appendingPathComponent("first.flac")
    let secondURL = root.appendingPathComponent("second.flac")
    try Data("first".utf8).write(to: firstURL)
    try Data("second".utf8).write(to: secondURL)

    let firstAssetID = MediaAssetID(sourceID: .local, externalID: "physical-first")
    let secondAssetID = MediaAssetID(sourceID: .local, externalID: "physical-second")
    let source = FakeMediaSource(
        descriptor: MediaSourceDescriptor(
            sourceID: .local,
            kind: .local,
            displayName: "Local"
        ),
        resolveResults: [
            firstAssetID.mediaItemID: .resource(.localFile(firstURL)),
            secondAssetID.mediaItemID: .resource(.localFile(secondURL)),
        ]
    )
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "logical-cue-one"),
            assetID: firstAssetID,
            title: "First segment"
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "logical-cue-two"),
            assetID: firstAssetID,
            title: "Second segment"
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "logical-file-two"),
            assetID: secondAssetID,
            title: "Second file"
        ),
    ]

    let urls = try await LibraryMediaShareResolver(sourceResolver: source).urls(for: tracks)

    #expect(urls == [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    #expect(source.sourceLookupCalls == [.local])
    #expect(source.resolveCalls == [
        firstAssetID.mediaItemID,
        firstAssetID.mediaItemID,
        secondAssetID.mediaItemID,
    ])
}

@Test("Media sharing rejects remote, unavailable, and unreadable assets")
func mediaSharingRejectsUnavailableFiles() async throws {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFree-Missing-\(UUID().uuidString).flac")
    let remoteAssetID = MediaAssetID(sourceID: .local, externalID: "remote")
    let unavailableAssetID = MediaAssetID(sourceID: .local, externalID: "unavailable")
    let unreadableAssetID = MediaAssetID(sourceID: .local, externalID: "unreadable")
    let source = FakeMediaSource(
        descriptor: MediaSourceDescriptor(
            sourceID: .local,
            kind: .local,
            displayName: "Local"
        ),
        resolveResults: [
            remoteAssetID.mediaItemID: .resource(.remote(RemotePlaybackRequest(
                url: URL(string: "https://example.invalid/song.flac")!
            ))),
            unavailableAssetID.mediaItemID: .failure(.sourceNotFound(.local)),
            unreadableAssetID.mediaItemID: .resource(.localFile(missingURL)),
        ]
    )
    let resolver = LibraryMediaShareResolver(sourceResolver: source)

    await #expect(throws: LibraryMediaShareResolver.ShareError.nonLocalTrack("Remote")) {
        _ = try await resolver.urls(for: [Track(
            id: MediaItemID(sourceID: .local, externalID: "remote-track"),
            assetID: remoteAssetID,
            title: "Remote"
        )])
    }
    await #expect(throws: LibraryMediaShareResolver.ShareError.unavailableTrack("Unavailable")) {
        _ = try await resolver.urls(for: [Track(
            id: MediaItemID(sourceID: .local, externalID: "unavailable-track"),
            assetID: unavailableAssetID,
            title: "Unavailable"
        )])
    }
    await #expect(throws: LibraryMediaShareResolver.ShareError.unreadableTrack("Unreadable")) {
        _ = try await resolver.urls(for: [Track(
            id: MediaItemID(sourceID: .local, externalID: "unreadable-track"),
            assetID: unreadableAssetID,
            title: "Unreadable"
        )])
    }
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

@Test("UIKit track row identities disambiguate repeated playback tracks")
func libraryTrackRowIdentitiesDisambiguateRepeatedTracks() {
    let track = makeTrack("repeated UIKit row")
    let rows = LibraryTrackRowIdentity.rows(for: [track, track, track])

    #expect(rows.map(\.id.itemID) == [track.id, track.id, track.id])
    #expect(rows.map(\.id.occurrence) == [0, 1, 2])
    #expect(Set(rows.map(\.id)).count == 3)
}

@Test("Artist detail keeps multi-artist albums and groups missing albums")
func libraryArtistDetailContentKeepsRelationships() {
    let artistID = ArtistID("artist-detail")
    let secondaryArtistID = ArtistID("secondary-artist")
    let albumFromTrack = Album(id: AlbumID("album-from-track"), title: "From Track")
    let albumFromArtist = Album(
        id: AlbumID("album-from-artist"),
        title: "From Album Artist",
        artistIDs: [artistID, secondaryArtistID]
    )
    let unrelatedAlbum = Album(
        id: AlbumID("unrelated-album"),
        title: "Unrelated",
        artistIDs: [secondaryArtistID]
    )
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "direct-album-track"),
            title: "Direct Album Track",
            albumID: albumFromTrack.id,
            artistIDs: [artistID, secondaryArtistID]
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "album-artist-track"),
            title: "Album Artist Track",
            albumID: albumFromArtist.id,
            artistIDs: [secondaryArtistID]
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "no-album-track"),
            title: "No Album Track",
            artistIDs: [artistID]
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "missing-album-track"),
            title: "Missing Album Track",
            albumID: AlbumID("missing-album"),
            artistIDs: [artistID]
        ),
    ]

    let artistTracks = LibraryArtistDetailContent.tracks(
        for: artistID,
        from: tracks,
        albums: [albumFromTrack, albumFromArtist, unrelatedAlbum]
    )
    let artistAlbums = LibraryArtistDetailContent.albums(
        for: artistID,
        tracks: artistTracks,
        from: [albumFromTrack, albumFromTrack, albumFromArtist, unrelatedAlbum]
    )
    let mergedAlbumOne = Album(
        id: AlbumID("merged-album-1"),
        title: "Shared Release",
        artistIDs: [artistID],
        releaseYear: 2024,
        albumType: .album
    )
    let mergedAlbumTwo = Album(
        id: AlbumID("merged-album-2"),
        title: " shared release ",
        artistIDs: [artistID, secondaryArtistID],
        releaseYear: 2024,
        albumType: .album
    )
    let mergedGroups = LibraryArtistDetailContent.albumGroups(
        for: artistID,
        tracks: [
            Track(
                id: MediaItemID(sourceID: .local, externalID: "merged-track-1"),
                title: "Merged track 1",
                albumID: mergedAlbumOne.id,
                artistIDs: [artistID]
            ),
            Track(
                id: MediaItemID(sourceID: .local, externalID: "merged-track-2"),
                title: "Merged track 2",
                albumID: mergedAlbumTwo.id,
                artistIDs: [artistID]
            ),
        ],
        from: [mergedAlbumOne, mergedAlbumTwo]
    )
    let noAlbumTracks = LibraryArtistDetailContent.noAlbumTracks(
        from: artistTracks,
        knownAlbums: artistAlbums
    )

    #expect(artistTracks.map(\.title) == tracks.map(\.title))
    #expect(artistAlbums.map(\.id) == [albumFromTrack.id, albumFromArtist.id])
    #expect(mergedGroups.count == 1)
    #expect(mergedGroups[0].album.title == mergedAlbumOne.title)
    #expect(mergedGroups[0].albumIDs == [mergedAlbumOne.id, mergedAlbumTwo.id])
    #expect(noAlbumTracks.map(\.title) == ["No Album Track", "Missing Album Track"])
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
    #expect(viewModel.searchTracks.map(\.title) == ["new result"])
    #expect(viewModel.tracks.isEmpty)
    #expect(service.searchRequests.map(\.searchText) == ["old", "new"])
}

@MainActor
@Test("Library search loads albums and songs into one result state")
func librarySearchLoadsAlbumsAndTracks() async {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("matching song")]))
    ]
    service.albumResponses = [
        .success(LibraryPage(elements: [makeAlbum("matching album")]))
    ]
    let viewModel = LibraryViewModel(
        library: service,
        searchDebounceNanoseconds: 0
    )

    viewModel.updateSearchText("matching")
    await settleUntil { viewModel.searchState != .loading }

    #expect(viewModel.searchState == .loaded)
    #expect(viewModel.searchTracks.map(\.title) == ["matching song"])
    #expect(viewModel.searchAlbums.map(\.title) == ["matching album"])
    #expect(service.trackRequests.first?.searchText == "matching")
    #expect(service.trackRequests.first?.sourceID == .local)
    #expect(service.albumRequests.first?.searchText == "matching")
    #expect(service.albumRequests.first?.sourceID == .local)
    #expect(service.searchRequests.count == 1)
    #expect(service.searchRequests.first?.limit == 100)
}

@MainActor
@Test("Library changes refresh active search without cancelling the current query")
func libraryChangesCoalesceActiveSearchRefresh() async {
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [makeTrack("initial song")])),
        .success(LibraryPage(elements: [makeTrack("refreshed song")]))
    ]
    service.albumResponses = [
        .success(LibraryPage(elements: [makeAlbum("initial album")])),
        .success(LibraryPage(elements: [makeAlbum("refreshed album")]))
    ]
    let viewModel = LibraryViewModel(
        library: service,
        searchDebounceNanoseconds: 0
    )

    await viewModel.startObservingChanges()
    await settle()
    viewModel.updateSearchText("old")
    await settle()

    for revision in 1...3 {
        service.publish(
            LibraryChange(
                revision: LibraryRevision(UInt64(revision)),
                categories: [.tracks, .albums],
                affectedIDs: LibraryAffectedIDs()
            )
        )
    }

    await settleUntil {
        service.trackRequests.count == 2 && viewModel.searchState == .loaded
    }

    #expect(service.cancelledQueries.isEmpty)
    #expect(service.trackRequests.count == 2)
    #expect(service.albumRequests.count == 2)
    #expect(viewModel.searchTracks.map(\.title) == ["refreshed song"])
    #expect(viewModel.searchAlbums.map(\.title) == ["refreshed album"])
}

@MainActor
@Test("Clearing library search restores idle state without changing song lists")
func clearingLibrarySearchRestoresIdleState() async {
    let libraryTrack = makeTrack("library song")
    let service = FakeLibraryService()
    service.trackResponses = [
        .success(LibraryPage(elements: [libraryTrack])),
        .success(LibraryPage(elements: [makeTrack("search result")]))
    ]
    service.albumResponses = [
        .success(LibraryPage(elements: [makeAlbum("search album")]))
    ]
    let viewModel = LibraryViewModel(
        library: service,
        searchDebounceNanoseconds: 0
    )

    viewModel.load(section: .tracks, reset: true)
    await settle()
    viewModel.updateSearchText("search")
    await settleUntil { viewModel.searchState != .loading }
    #expect(viewModel.searchTracks.map(\.title) == ["search result"])
    #expect(viewModel.searchAlbums.map(\.title) == ["search album"])
    viewModel.updateSearchText("")

    #expect(viewModel.searchState == .idle)
    #expect(viewModel.searchTracks.isEmpty)
    #expect(viewModel.searchAlbums.isEmpty)
    #expect(viewModel.tracks.map(\.title) == ["library song"])
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

    progress = ImportEventMapper.apply(
        .confirmationRequired(importID: importID),
        to: progress
    )
    #expect(progress.phase == nil)
    #expect(LibraryImportState.awaitingConfirmation(progress).progress == progress)
    #expect(LibraryImportState.awaitingConfirmation(progress).confirmationProgress == progress)

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

@Test("Import status exposes an all-failed result and its file reason")
func importStatusExposesTerminalFailureReason() throws {
    let importID = UUID()
    let result = MediaImportResult(
        importID: importID,
        imported: 0,
        duplicate: 0,
        skipped: 0,
        failed: 1,
        cancelled: 0
    )
    let failure = LibraryImportFailure(
        itemName: "three-hour-sample.m4a",
        code: "corrupted_media",
        message: "The media appears to be damaged."
    )

    let presentation = try #require(LibraryImportStatusPresentation.make(
        state: .completed(result),
        failures: [failure]
    ))

    #expect(presentation.tone == .failure)
    #expect(presentation.title == L("import.failed.title"))
    #expect(presentation.primaryAction == .dismiss)
    #expect(presentation.detail?.contains("three-hour-sample.m4a") == true)
    #expect(presentation.detail?.contains("parser") != true)
}

@MainActor
@Test("Library ViewModel continues a folder import after confirmation")
func libraryViewModelContinuesImportAfterConfirmation() async {
    let importer = ConfirmationImportService()
    let viewModel = LibraryViewModel(
        library: FakeLibraryService(),
        importer: importer
    )

    await viewModel.startImport(urls: [URL(fileURLWithPath: "/fixture/folder")])
    for _ in 0..<100 {
        if case .awaitingConfirmation = viewModel.importState { break }
        await Task.yield()
    }

    if case .awaitingConfirmation(let progress) = viewModel.importState {
        #expect(progress.failures.map(\.itemName) == ["broken.wav"])
    } else {
        #expect(Bool(false), "the import did not pause for confirmation")
        return
    }

    viewModel.continueImport()
    for _ in 0..<100 {
        if case .completed = viewModel.importState { break }
        await Task.yield()
    }

    #expect(await importer.continueCallCount == 1)
    if case .completed(let result) = viewModel.importState {
        #expect(result.imported == 1)
        #expect(result.failed == 1)
        #expect(viewModel.importFailures.map(\.itemName) == ["broken.wav"])
    } else {
        #expect(Bool(false), "the import did not complete after confirmation")
    }
}

@MainActor
@Test("Library ViewModel cancellation closes a folder confirmation wait")
func libraryViewModelCancelsImportConfirmation() async {
    let importer = ConfirmationImportService()
    let viewModel = LibraryViewModel(
        library: FakeLibraryService(),
        importer: importer
    )

    await viewModel.startImport(urls: [URL(fileURLWithPath: "/fixture/folder")])
    for _ in 0..<100 {
        if case .awaitingConfirmation = viewModel.importState { break }
        await Task.yield()
    }

    viewModel.cancelImport()
    for _ in 0..<100 {
        if case .completed(let result) = viewModel.importState, result.isCancelled { break }
        await Task.yield()
    }

    #expect(await importer.cancelCallCount == 1)
    if case .completed(let result) = viewModel.importState {
        #expect(result.isCancelled)
    } else {
        #expect(Bool(false), "the import did not finish after cancellation")
    }
}

@MainActor
@Test("A terminal import can be retried before its old stream finishes")
func terminalImportCanBeRetriedBeforeOldStreamFinishes() async {
    let importer = TerminalThenHangingImportService()
    let viewModel = LibraryViewModel(
        library: FakeLibraryService(),
        importer: importer
    )

    await viewModel.startImport(urls: [URL(fileURLWithPath: "/fixture/first.mp3")])
    await settle()
    if case .completed = viewModel.importState {
        // The service intentionally keeps the first stream open after its
        // terminal event to reproduce the UI scheduling window.
    } else {
        #expect(Bool(false), "the first import did not reach a terminal state")
    }

    await viewModel.startImport(urls: [URL(fileURLWithPath: "/fixture/second.mp3")])
    #expect(await importer.requestCount == 2)

    await importer.finishAll()
    await settle()

    if case .completed(let result) = viewModel.importState {
        #expect(result.imported == 1)
        #expect(result.failed == 0)
    } else {
        #expect(Bool(false), "the retry did not complete")
    }
}

private actor TerminalThenHangingImportService: ImportServing {
    private(set) var requestCount = 0
    private var continuations: [UUID: AsyncThrowingStream<MediaImportEvent, Error>.Continuation] = [:]

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        requestCount += 1
        let pair = AsyncThrowingStream<MediaImportEvent, Error>.makeStream()
        continuations[request.importID] = pair.continuation
        pair.continuation.yield(
            .completed(
                importID: request.importID,
                result: MediaImportResult(
                    importID: request.importID,
                    imported: 1,
                    duplicate: 0,
                    skipped: 0,
                    failed: 0,
                    cancelled: 0
                )
            )
        )
        return pair.stream
    }

    func cancel(_ importID: UUID) async {}

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        nil
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func finishAll() {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.finish() }
    }
}

private actor ConfirmationImportService: ImportServing {
    private var continuations: [UUID: AsyncThrowingStream<MediaImportEvent, Error>.Continuation] = [:]
    private(set) var continueCallCount = 0
    private(set) var cancelCallCount = 0

    func start(
        _ request: MediaImportRequest
    ) async throws -> AsyncThrowingStream<MediaImportEvent, Error> {
        let pair = AsyncThrowingStream<MediaImportEvent, Error>.makeStream()
        continuations[request.importID] = pair.continuation
        let failedURL = URL(fileURLWithPath: "/fixture/broken.wav")
        pair.continuation.yield(
            .itemFailed(
                importID: request.importID,
                url: failedURL,
                error: .unsupportedFormat
            )
        )
        pair.continuation.yield(.confirmationRequired(importID: request.importID))
        return pair.stream
    }

    func continueImport(_ importID: UUID) async {
        continueCallCount += 1
        guard let continuation = continuations.removeValue(forKey: importID) else { return }
        continuation.yield(
            .completed(
                importID: importID,
                result: MediaImportResult(
                    importID: importID,
                    imported: 1,
                    duplicate: 0,
                    skipped: 0,
                    failed: 1,
                    cancelled: 0
                )
            )
        )
        continuation.finish()
    }

    func cancel(_ importID: UUID) async {
        cancelCallCount += 1
        guard let continuation = continuations.removeValue(forKey: importID) else { return }
        continuation.yield(
            .cancelled(
                importID: importID,
                result: MediaImportResult(
                    importID: importID,
                    imported: 0,
                    duplicate: 0,
                    skipped: 0,
                    failed: 1,
                    cancelled: 1,
                    status: .cancelled
                )
            )
        )
        continuation.finish()
    }

    func state(for importID: UUID) async -> ImportSessionSnapshot? {
        nil
    }

    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }
}

@MainActor
private final class FakeLibraryService: LibraryServing {
    var trackResponses: [Result<LibraryPage<Track>, Error>] = []
    var trackResponsesByQuery: [TrackQuery: [Result<LibraryPage<Track>, Error>]] = [:]
    var trackRequests: [TrackQuery] = []
    var trackPageRequests: [LibraryPageRequest] = []
    var defaultAlbums: [Album] = []
    var holdNextAlbumPage = false
    var heldAlbumPage: CheckedContinuation<Void, Never>?

    func releaseHeldAlbumPage() {
        heldAlbumPage?.resume()
        heldAlbumPage = nil
    }
    var deletedBatches: [Set<MediaItemID>] = []
    var allowsDeletion = false
    var albumResponses: [Result<LibraryPage<Album>, Error>] = []
    var albumRequests: [AlbumQuery] = []
    var albumPageRequests: [LibraryPageRequest] = []
    var searchRequests: [LibrarySearchRequest] = []
    var historyResponses: [Result<LibraryPage<PlaybackHistoryItem>, Error>] = []
    var clearHistoryError: Error?
    private(set) var clearHistoryCallCount = 0
    var cancelledQueries: [String] = []
    var changeContinuations: [AsyncStream<LibraryChange>.Continuation] = []
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
        let response: Result<LibraryPage<Album>, Error> = albumResponses.isEmpty
            ? .success(LibraryPage(elements: defaultAlbums)) : albumResponses.removeFirst()
        if holdNextAlbumPage {
            holdNextAlbumPage = false
            // Deliberately ignore cancellation to test the model's stale-token guard.
            await withCheckedContinuation { heldAlbumPage = $0 }
        }
        return try response.get()
    }

    func searchLibrary(
        _ request: LibrarySearchRequest
    ) async throws -> LibrarySearchResults {
        searchRequests.append(request)
        guard let searchText = request.searchText else {
            return LibrarySearchResults()
        }
        let page = try LibraryPageRequest(limit: request.limit)
        let tracks = try await browseTracks(
            matching: TrackQuery(searchText: searchText, sourceID: request.sourceID),
            page: page
        )
        try Task.checkCancellation()
        let albums = try await browseAlbums(
            matching: AlbumQuery(searchText: searchText, sourceID: request.sourceID),
            page: page
        )
        return LibrarySearchResults(
            tracks: tracks.elements,
            albums: albums.elements
        )
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
        guard allowsDeletion else { throw LibraryTestError.unavailable }
        deletedBatches.append(itemIDs)
        return LibraryDeletionResult(itemIDs: itemIDs, status: .committed)
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        throw LibraryTestError.unavailable
    }

    func makeChangeStream() async -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            changeContinuations.append(continuation)
        }
    }

    func publish(_ change: LibraryChange) {
        for continuation in changeContinuations { continuation.yield(change) }
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

@MainActor
private func settleUntil(
    maximumAttempts: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<maximumAttempts {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await Task.yield()
    }
}
