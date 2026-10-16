import DesignSystem
import AppServices
import Foundation
import LibraryAPI
import MusicDomain
@testable import PlaylistFeature
import Testing

@MainActor
@Test("Playlist candidates load every page and feed one add mutation")
func playlistCandidatesLoadEveryPageAndAdd() async {
    let firstArtistID = ArtistID("first-artist")
    let secondArtistID = ArtistID("second-artist")
    let first = candidateTestTrack(
        "first",
        title: "First",
        artistIDs: [firstArtistID],
        seconds: 61
    )
    let second = candidateTestTrack(
        "second",
        title: "Second",
        artistIDs: [secondArtistID],
        seconds: 125
    )
    let library = PlaylistCandidateTestLibrary(
        pages: [
            .success(
                LibraryPage(
                    elements: [first],
                    nextCursor: LibraryCursor("page-2")
                )
            ),
            .success(LibraryPage(elements: [first, second]))
        ],
        artistPages: [
            .success(
                LibraryPage(
                    elements: [Artist(id: firstArtistID, name: "First Artist")],
                    nextCursor: LibraryCursor("artist-page-2")
                )
            ),
            .success(
                LibraryPage(elements: [Artist(id: secondArtistID, name: "Second Artist")])
            )
        ]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()

    #expect(loader.loadState == .loaded)
    #expect(loader.candidates.map(\.id) == [first.id, second.id])
    #expect(loader.candidates.map(\.title) == ["First", "Second"])
    #expect(loader.candidates.map(\.subtitle) == ["First Artist", "Second Artist"])
    #expect(library.requests.map(\.cursor?.rawValue) == [nil, "page-2"])
    #expect(library.requests.allSatisfy { $0.limit == LibraryPageRequest.maximumLimit })
    #expect(library.artistRequests.map(\.cursor?.rawValue) == [nil, "artist-page-2"])
    #expect(library.artistRequests.allSatisfy { $0.limit == LibraryPageRequest.maximumLimit })
    #expect(library.artistSourceIDs == [.local, .local])

    let playlist = Playlist(id: PlaylistID("playlist-candidates"), name: "Candidates")
    let store = PlaylistCandidateMutationStore()
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistCandidateTestPlayback()
    )
    await viewModel.load()

    let added = await viewModel.addTracks(loader.candidates.map(\.id))

    #expect(added)
    #expect(viewModel.itemIDs == [first.id, second.id])
    #expect(store.mutations.count == 1)
    if case .insert(let insertions) = store.mutations[0].operation {
        #expect(insertions.map(\.itemID) == [first.id, second.id])
        #expect(insertions.map(\.position) == [0, 1])
    } else {
        Issue.record("Expected one batched insert mutation")
    }
}

@MainActor
@Test("Playlist candidates hide missing artists instead of using duration as subtitle")
func playlistCandidatesHideMissingArtists() async {
    let missingArtistID = ArtistID("missing-artist")
    let withMissingRelationship = candidateTestTrack(
        "missing-relationship",
        title: "Missing Relationship",
        artistIDs: [missingArtistID],
        seconds: 61
    )
    let withoutArtist = candidateTestTrack(
        "without-artist",
        title: "Without Artist",
        seconds: 125
    )
    let library = PlaylistCandidateTestLibrary(
        pages: [
            .success(LibraryPage(elements: [withMissingRelationship, withoutArtist]))
        ],
        artistPages: [.success(LibraryPage(elements: []))]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()

    #expect(loader.loadState == .loaded)
    #expect(loader.candidates.map(\.subtitle) == [nil, nil])
    #expect(!loader.candidates.contains { $0.subtitle == "1:01" || $0.subtitle == "2:05" })
}

@MainActor
@Test("Playlist artist metadata failure does not block track candidates")
func playlistArtistMetadataFailureDoesNotBlockCandidates() async {
    let artistID = ArtistID("unavailable-artist")
    let track = candidateTestTrack(
        "artist-failure",
        title: "Still Available",
        artistIDs: [artistID],
        seconds: 61
    )
    let library = PlaylistCandidateTestLibrary(
        pages: [.success(LibraryPage(elements: [track]))],
        artistPages: [.failure(PlaylistFeatureError.serviceUnavailable)]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()

    #expect(loader.loadState == .loaded)
    #expect(loader.candidates == [
        PlaylistTrackCandidate(id: track.id, title: "Still Available")
    ])
}

@MainActor
@Test("Playlist candidate loading exposes errors and can retry")
func playlistCandidateLoadingExposesErrorsAndRetries() async {
    let recovered = candidateTestTrack("recovered", title: "Recovered")
    let library = PlaylistCandidateTestLibrary(
        pages: [
            .failure(PlaylistFeatureError.serviceUnavailable),
            .success(LibraryPage(elements: [recovered]))
        ]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()
    #expect(loader.loadState.failureMessage == PlaylistFeatureError.serviceUnavailable.localizedDescription)
    #expect(loader.candidates.isEmpty)

    await loader.load()
    #expect(loader.loadState == .loaded)
    #expect(loader.candidates.map(\.id) == [recovered.id])
}

@MainActor
@Test("Playlist candidate loading rejects a repeated cursor")
func playlistCandidateLoadingRejectsRepeatedCursor() async {
    let repeatedCursor = LibraryCursor("repeat")
    let library = PlaylistCandidateTestLibrary(
        pages: [
            .success(LibraryPage(elements: [], nextCursor: repeatedCursor)),
            .success(LibraryPage(elements: [], nextCursor: repeatedCursor)),
            .success(LibraryPage(elements: []))
        ]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()

    #expect(loader.loadState.failureMessage == L("资料库分页游标重复，无法继续加载歌曲。"))
    #expect(library.requests.map(\.cursor?.rawValue) == [nil, "repeat"])
    #expect(library.pages.count == 1)
    #expect(!loader.isLoading)
}

@MainActor
@Test("Playlist candidate loading rejects a cursor cycle before repeating a request")
func playlistCandidateLoadingRejectsCursorCycle() async {
    let cursorA = LibraryCursor("A")
    let cursorB = LibraryCursor("B")
    let library = PlaylistCandidateTestLibrary(
        pages: [
            .success(LibraryPage(elements: [], nextCursor: cursorA)),
            .success(LibraryPage(elements: [], nextCursor: cursorB)),
            .success(LibraryPage(elements: [], nextCursor: cursorA)),
            .success(LibraryPage(elements: []))
        ]
    )
    let loader = PlaylistTrackCandidateLoader(library: library)

    await loader.load()

    #expect(loader.loadState.failureMessage == L("资料库分页游标重复，无法继续加载歌曲。"))
    #expect(library.requests.map(\.cursor?.rawValue) == [nil, "A", "B"])
    #expect(library.pages.count == 1)
    #expect(!loader.isLoading)
}

@MainActor
@Test("Cancelling playlist candidate loading restores an idle state")
func cancellingPlaylistCandidateLoadingRestoresIdleState() async {
    let library = PlaylistCandidateTestLibrary(pages: [], waitsForCancellation: true)
    let loader = PlaylistTrackCandidateLoader(library: library)

    let task = Task { await loader.load() }
    await Task.yield()
    task.cancel()
    await task.value

    #expect(library.observedCancellation)
    #expect(loader.loadState == .idle)
    #expect(loader.candidates.isEmpty)
    #expect(!loader.isLoading)
}

@MainActor
private final class PlaylistCandidateTestLibrary: LibraryServing {
    var pages: [Result<LibraryPage<Track>, Error>]
    var requests: [LibraryPageRequest] = []
    var artistPages: [Result<LibraryPage<Artist>, Error>]
    var artistRequests: [LibraryPageRequest] = []
    var artistSourceIDs: [MediaSourceID] = []
    var waitsForCancellation: Bool
    var observedCancellation = false

    init(
        pages: [Result<LibraryPage<Track>, Error>],
        artistPages: [Result<LibraryPage<Artist>, Error>] = [],
        waitsForCancellation: Bool = false
    ) {
        self.pages = pages
        self.artistPages = artistPages
        self.waitsForCancellation = waitsForCancellation
    }

    var tracksByID: [MediaItemID: Track] = [:]
    var artistsByID: [ArtistID: Artist] = [:]
    var trackRequests: [MediaItemID] = []
    var directArtistRequests: [ArtistID] = []
    var suspendTrackReads = false
    var trackReadContinuation: CheckedContinuation<Void, Never>?

    func track(id: MediaItemID) async throws -> Track? {
        trackRequests.append(id)
        if suspendTrackReads {
            await withCheckedContinuation { trackReadContinuation = $0 }
        }
        return tracksByID[id]
    }

    func artist(id: ArtistID) async throws -> Artist? {
        directArtistRequests.append(id)
        return artistsByID[id]
    }

    func browseTracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        requests.append(page)
        if waitsForCancellation {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                observedCancellation = true
                throw error
            }
        }
        guard !pages.isEmpty else {
            return LibraryPage(elements: [])
        }
        return try pages.removeFirst().get()
    }

    func browseAlbums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        LibraryPage(elements: [])
    }

    func browseArtists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        artistRequests.append(page)
        if let sourceID = query.sourceID {
            artistSourceIDs.append(sourceID)
        }
        guard !artistPages.isEmpty else {
            return LibraryPage(elements: [])
        }
        return try artistPages.removeFirst().get()
    }

    func searchTracks(
        text: String,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func makeChangeStream() async -> AsyncStream<LibraryChange> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class PlaylistCandidateMutationStore: PlaylistFeatureStore {
    var mutations: [PlaylistEntriesMutation] = []
    var entryIDs: [MediaItemID] = []

    func loadPlaylists() async throws -> [Playlist] { [] }
    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        entryIDs.enumerated().map { PlaylistEntry(playlistID: playlistID, trackID: $0.element, position: $0.offset) }
    }

    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func updatePlaylist(_ mutation: PlaylistMutation) async throws -> Playlist {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func applyEntries(_ mutation: PlaylistEntriesMutation) async throws {
        mutations.append(mutation)
    }

    func deletePlaylist(_ playlistID: PlaylistID) async throws {
        throw PlaylistFeatureError.serviceUnavailable
    }
}

@MainActor
private final class PlaylistCandidateTestPlayback: PlaylistFeaturePlaybackServing {
    func send(_ command: PlaylistPlaybackCommand) async throws {}
}

private func candidateTestTrack(
    _ externalID: String,
    title: String,
    artistIDs: [ArtistID] = [],
    seconds: Int64? = nil
) -> Track {
    Track(
        id: MediaItemID(sourceID: .local, externalID: externalID),
        title: title,
        artistIDs: artistIDs,
        duration: seconds.map { Duration.seconds($0) }
    )
}


#if canImport(UIKit)
import DesignSystem
import MediaSourceAPI
import UIKit

private actor PlaylistCoverTestArtwork: ArtworkServing {
    let data: Data
    init(data: Data) { self.data = data }
    func artwork(for artworkID: ArtworkID, sourceID: MediaSourceID) async throws -> ArtworkResource? {
        .dataStream(AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}

@MainActor
@Test("Playlist covers fall back to song artwork and clear when the last song is removed")
func playlistCoverSongFallback() async throws {
    let artworkID = ArtworkID("fallback-\(UUID().uuidString)")
    let track = Track(id: MediaItemID(sourceID: .local, externalID: "cover-track"), title: "Cover", artwork: ArtworkReference(id: artworkID))
    let library = PlaylistCandidateTestLibrary(pages: [])
    library.tracksByID[track.id] = track
    let bytes = try #require(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }.pngData())
    let service = PlaylistCoverTestArtwork(data: bytes)
    let playlist = Playlist(id: PlaylistID("fallback"), name: "Auto cover")
    let view = MusicFreeUIKitArtworkView()
    let binding = PlaylistCoverBinding(view: view)
    binding.configure(playlist: playlist, trackIDs: [track.id], dimension: 160, revision: 0,
        store: PlaylistCandidateMutationStore(), library: library, artwork: service)
    for _ in 0..<200 where view.image == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(view.image != nil)
    binding.configure(playlist: playlist, trackIDs: [], dimension: 160, revision: 1,
        store: PlaylistCandidateMutationStore(), library: library, artwork: service)
    for _ in 0..<200 where view.image != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(view.image == nil)
    #expect(!view.isLoading)
}

@MainActor
@Test("Custom playlist artwork works without library access and reuse cancels old requests")
func playlistCoverCustomAndReuse() async throws {
    let artworkID = ArtworkID("custom-\(UUID().uuidString)")
    let data = try #require(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }.pngData())
    let view = MusicFreeUIKitArtworkView()
    let binding = PlaylistCoverBinding(view: view)
    binding.configure(playlist: Playlist(id: PlaylistID("custom"), name: "Custom", artwork: ArtworkReference(id: artworkID)),
        dimension: 160, revision: 0, store: PlaylistCandidateMutationStore(), library: nil,
        artwork: PlaylistCoverTestArtwork(data: data))
    for _ in 0..<200 where view.image == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(view.image != nil)
    binding.reset()
    #expect(view.image == nil)
    #expect(!view.isLoading)
    #expect(await PlaylistArtworkPreparation.prepare(Data("invalid image".utf8)) == nil)
    #expect(await PlaylistArtworkPreparation.prepare(data) != nil)
}
#endif


#if canImport(UIKit)
@MainActor
@Suite("Playlist row metadata")
struct PlaylistRowMetadataTests {
    @Test("Entry metadata uses only playlist tracks and deduplicates artist lookups")
    func scopedLookup() async {
        let artist = Artist(id: ArtistID("scoped-artist"), name: "Visible Artist")
        let first = candidateTestTrack("first", title: "First Song", artistIDs: [artist.id])
        let second = candidateTestTrack("second", title: "Second Song", artistIDs: [artist.id])
        let library = PlaylistCandidateTestLibrary(pages: [])
        library.tracksByID = [first.id: first, second.id: second]
        library.artistsByID[artist.id] = artist
        let loader = PlaylistTrackCandidateLoader(library: library)
        await loader.load(trackIDs: [second.id, first.id, second.id])
        #expect(loader.candidates.map(\.title) == ["Second Song", "First Song"])
        #expect(loader.candidates.map(\.subtitle) == ["Visible Artist", "Visible Artist"])
        #expect(library.trackRequests == [second.id, first.id])
        #expect(library.directArtistRequests == [artist.id])
        #expect(library.requests.isEmpty && library.artistRequests.isEmpty)
        await loader.load(trackIDs: [first.id])
        #expect(library.trackRequests.count == 2)
    }

    @Test("Rows stay hidden until metadata is ready and never display the storage UUID", arguments: [false, true])
    func slowMetadataDoesNotFlashUUID(returnDuringLoad: Bool) async throws {
        let track = candidateTestTrack(UUID().uuidString, title: "A Readable Song")
        let library = PlaylistCandidateTestLibrary(pages: [])
        library.tracksByID[track.id] = track
        library.suspendTrackReads = true
        let store = PlaylistCandidateMutationStore()
        store.entryIDs = [track.id]
        let controller = PlaylistDetailViewController(
            playlist: Playlist(id: PlaylistID("slow-metadata"), name: "Songs"),
            store: store, playback: PlaylistCandidateTestPlayback(), libraryServing: library
        )
        controller.loadViewIfNeeded()
        let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        for _ in 0..<100 where library.trackReadContinuation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(library.trackReadContinuation)
        #expect(table.isHidden)
        let unresolvedCell = controller.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        #expect(unresolvedCell.accessibilityLabel == L("歌曲信息不可用"))
        if returnDuringLoad {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
        }
        library.suspendTrackReads = false
        continuation.resume()
        for _ in 0..<100 where table.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!table.isHidden)
        let loadedCell = controller.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        #expect(loadedCell.accessibilityLabel == track.title)
        #expect(library.requests.isEmpty)
    }

    @Test("A missing track uses a readable unavailable label and can recover on metadata refresh")
    func unavailableThenRecovered() async throws {
        let id = MediaItemID(sourceID: .local, externalID: UUID().uuidString)
        let library = PlaylistCandidateTestLibrary(pages: [])
        let loader = PlaylistTrackCandidateLoader(library: library)
        await loader.load(trackIDs: [id])
        #expect(loader.candidates.isEmpty)
        library.tracksByID[id] = Track(id: id, title: "Recovered Song")
        let refreshed = await loader.refresh(trackIDs: [id])
        #expect(refreshed == [id])
        #expect(loader.candidates.first?.title == "Recovered Song")
    }
}
#endif
