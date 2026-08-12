import Foundation
import LibraryAPI
import MusicDomain
import MusicTestSupport
import Testing

@Test("Library page requests enforce a bounded page size")
func libraryPageRequestEnforcesBounds() {
    do {
        _ = try LibraryPageRequest(limit: 0)
        Issue.record("A zero-sized page request should fail")
    } catch let error as LibraryError {
        #expect(error == .query(.invalidPageSize(requested: 0, maximum: LibraryPageRequest.maximumLimit)))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit + 1)
        Issue.record("A page larger than the maximum should fail")
    } catch let error as LibraryError {
        #expect(error == .query(.invalidPageSize(
            requested: LibraryPageRequest.maximumLimit + 1,
            maximum: LibraryPageRequest.maximumLimit
        )))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Library pages preserve opaque cursor continuation")
func libraryPagePreservesCursorContinuation() throws {
    let cursor = LibraryCursor("fixture-cursor-value")
    let page = LibraryPage(elements: [1, 2, 3], nextCursor: cursor)

    #expect(page.items == [1, 2, 3])
    #expect(page.hasNextPage)

    let nextRequestValue = try page.nextPage(limit: 25)
    let nextRequest = try #require(nextRequestValue)
    #expect(nextRequest.limit == 25)
    #expect(nextRequest.cursor == cursor)

    let finalPage = LibraryPage(elements: [4])
    #expect(!finalPage.hasNextPage)
    let noNextRequest = try finalPage.nextPage(limit: 25)
    #expect(noNextRequest == nil)
}

@Test("Structured queries normalize blank search text and retain stable sorting")
func structuredQueriesNormalizeSearchText() {
    let query = TrackQuery(
        searchText: "  \n  ",
        favorite: .favorite,
        sort: TrackSortDescriptor(key: .playCount, direction: .descending)
    )

    #expect(query.searchText == nil)
    #expect(query.favorite == .favorite)
    #expect(query.sort.key == .playCount)
    #expect(query.sort.direction == .descending)
    #expect(query.sort.tieBreaker == .stableIdentifier)
}

@Test("Library collection sorting uses pinyin initials and stable folder labels")
func libraryCollectionSortSupportUsesPinyinAndFolderHierarchy() {
    #expect(LibrarySortSupport.normalizedSortValue("  阿里  ") == "A LI")
    #expect(LibrarySortSupport.sectionTitle(for: "阿里") == "A")
    #expect(LibrarySortSupport.sectionTitle(for: "Beyond") == "B")
    #expect(LibrarySortSupport.sectionTitle(for: " 123") == "#")
    #expect(LibrarySortSupport.leafName(of: "Imported/演出/Live") == "Live")
    #expect(LibrarySortSupport.parentPath(of: "Imported/演出/Live") == "Imported/演出")
    #expect(LibrarySortSupport.parentPath(of: "Live") == nil)

    let sections = ["#", "Z", "A", "B"].sorted(
        by: LibrarySortSupport.areSectionTitlesInAscendingOrder
    )
    #expect(sections == ["A", "B", "Z", "#"])
}

@Test("In-memory collection pages preserve global pinyin order")
func inMemoryCollectionPagesPreservePinyinOrder() async throws {
    let repository = InMemoryLibraryRepository(
        artists: [
            Artist(id: ArtistID("zhong"), name: "中文"),
            Artist(id: ArtistID("ali"), name: "阿里"),
            Artist(id: ArtistID("beyond"), name: "Beyond")
        ]
    )
    let firstPage = try await repository.artists(
        matching: ArtistQuery(),
        page: try LibraryPageRequest(limit: 2)
    )
    let cursor = try #require(firstPage.nextCursor)
    let secondPage = try await repository.artists(
        matching: ArtistQuery(),
        page: try LibraryPageRequest(limit: 2, cursor: cursor)
    )

    #expect(firstPage.elements.map(\.name) == ["阿里", "Beyond"])
    #expect(secondPage.elements.map(\.name) == ["中文"])
}

@Test("Library pages and query descriptors are Codable")
func libraryAPIValuesRoundTripThroughCodable() throws {
    let page = LibraryPage(elements: ["first", "second"], nextCursor: LibraryCursor("next"))
    let encodedPage = try JSONEncoder().encode(page)
    let decodedPage = try JSONDecoder().decode(LibraryPage<String>.self, from: encodedPage)
    #expect(decodedPage == page)

    let query = AlbumQuery(searchText: "  album  ", sort: AlbumSortDescriptor(key: .year))
    let encodedQuery = try JSONEncoder().encode(query)
    let decodedQuery = try JSONDecoder().decode(AlbumQuery.self, from: encodedQuery)
    #expect(decodedQuery == query)
}

@Test("Library errors expose safe retry semantics")
func libraryErrorsExposeRetrySemantics() {
    let retryable = LibraryError.conflict(.transactionInProgress)
    #expect(retryable.isRetryable)
    #expect(!retryable.diagnosticCode.isEmpty)

    let terminal = LibraryError.conflict(.transactionAlreadyApplied)
    #expect(!terminal.isRetryable)
    #expect(!terminal.failureReason.contains("/"))
    #expect(retryable.diagnosticContext?.operation == "library.repository")
}

@Test("Library transactions carry typed mutations and idempotency")
func libraryTransactionsCarryTypedMutations() throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let track = Track(id: itemID, title: "Song")
    let transaction = try LibraryTransaction(
        idempotencyKey: "  import-track-1  ",
        expectedRevision: LibraryRevision(7),
        mutations: [
            .upsert(.track(track)),
            .relation(.setArtists(trackID: itemID, artistIDs: [ArtistID("artist-1")])),
            .statistics(.increment(
                trackID: itemID,
                delta: PlaybackStatisticsDelta(completionCount: 1, totalListeningDuration: .seconds(2))
            ))
        ]
    )

    #expect(transaction.idempotencyKey == "import-track-1")
    #expect(transaction.expectedRevision == LibraryRevision(7))
    #expect(transaction.mutations.count == 3)

    let encoded = try JSONEncoder().encode(transaction)
    let decoded = try JSONDecoder().decode(LibraryTransaction.self, from: encoded)
    #expect(decoded.idempotencyKey == transaction.idempotencyKey)
    #expect(decoded.expectedRevision == transaction.expectedRevision)
    #expect(decoded.mutations.count == transaction.mutations.count)
}

@Test("Playlist member changes express complete stable ordering")
func playlistMemberChangesExpressStableOrdering() {
    let playlistID = PlaylistID("playlist-1")
    let first = MediaItemID(sourceID: .local, externalID: "first")
    let second = MediaItemID(sourceID: .local, externalID: "second")
    let draft = PlaylistDraft(name: "  Mix  ", sortName: "  mix  ")
    let mutation = PlaylistEntriesMutation(
        playlistID: playlistID,
        expectedRevision: LibraryRevision(3),
        operation: .reorder([second, first])
    )

    #expect(draft.name == "Mix")
    #expect(draft.sortName == "mix")
    #expect(mutation.expectedRevision == LibraryRevision(3))
    if case .reorder(let orderedIDs) = mutation.operation {
        #expect(orderedIDs == [second, first])
    } else {
        Issue.record("Expected a complete reorder operation")
    }

    #expect(!PlaylistEntryInsertion(itemID: first, position: -1).hasValidPosition)
    #expect(PlaylistEntryMove(itemID: second, position: 0).hasValidPosition)
}

@Test("Playback history and change payloads preserve stable IDs")
func playbackHistoryAndChangesPreserveStableIDs() throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
    let event = PlaybackHistoryEvent.completed(
        PlaybackCompletion(
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            itemID: itemID,
            occurredAt: Date(timeIntervalSince1970: 10),
            reason: .ended
        )
    )
    let eventData = try JSONEncoder().encode(event)
    let decodedEvent = try JSONDecoder().decode(PlaybackHistoryEvent.self, from: eventData)

    if case .completed(let completion) = decodedEvent {
        #expect(completion.itemID == itemID)
        #expect(completion.reason == .ended)
    } else {
        Issue.record("Expected a completed playback event")
    }

    let playlistID = PlaylistID("playlist-1")
    let change = LibraryChange(
        revision: LibraryRevision(8),
        categories: [.tracks, .playlistEntries],
        affectedIDs: LibraryAffectedIDs(trackIDs: [itemID], playlistIDs: [playlistID])
    )
    let changeData = try JSONEncoder().encode(change)
    let decodedChange = try JSONDecoder().decode(LibraryChange.self, from: changeData)
    #expect(decodedChange == change)
    #expect(!decodedChange.affectedIDs.isEmpty)
}
