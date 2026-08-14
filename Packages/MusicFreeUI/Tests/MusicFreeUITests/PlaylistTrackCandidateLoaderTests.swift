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

    func track(id: MediaItemID) async throws -> Track? { nil }

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

    func loadPlaylists() async throws -> [Playlist] { [] }
    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] { [] }

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
