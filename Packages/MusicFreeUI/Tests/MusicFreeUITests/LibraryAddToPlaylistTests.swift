import AppServices
import Foundation
import LibraryAPI
import MusicDomain
@testable import LibraryFeature
import Testing

private actor LibraryPlaylistServingFake: PlaylistServing {
    struct Snapshot: Sendable {
        let createdDrafts: [PlaylistDraft]
        let entryMutations: [PlaylistEntriesMutation]
        let playlistPageRequests: [LibraryPageRequest]
    }

    private var playlistPages: [LibraryPage<Playlist>]
    private var entryValues: [PlaylistID: [PlaylistEntry]]
    private var createdDrafts: [PlaylistDraft] = []
    private var entryMutations: [PlaylistEntriesMutation] = []
    private var playlistPageRequests: [LibraryPageRequest] = []
    private var nextCreatedID = 1

    init(
        playlistPages: [LibraryPage<Playlist>] = [LibraryPage(elements: [])],
        entries: [PlaylistID: [PlaylistEntry]] = [:]
    ) {
        self.playlistPages = playlistPages
        self.entryValues = entries
    }

    func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist> {
        playlistPageRequests.append(page)
        guard !playlistPages.isEmpty else { return LibraryPage(elements: []) }
        return playlistPages.removeFirst()
    }

    func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        entryValues[playlistID] ?? []
    }

    func create(_ draft: PlaylistDraft) async throws -> Playlist {
        createdDrafts.append(draft)
        let playlist = Playlist(
            id: PlaylistID("created-\(nextCreatedID)"),
            name: draft.name
        )
        nextCreatedID += 1
        entryValues[playlist.id] = []
        return playlist
    }

    func update(_ mutation: PlaylistMutation) async throws -> Playlist {
        throw LibraryPlaylistServingFakeError.unsupported
    }

    func apply(_ mutation: PlaylistEntriesMutation) async throws {
        entryMutations.append(mutation)
    }

    func delete(_ playlistID: PlaylistID) async throws {
        throw LibraryPlaylistServingFakeError.unsupported
    }

    func snapshot() -> Snapshot {
        Snapshot(
            createdDrafts: createdDrafts,
            entryMutations: entryMutations,
            playlistPageRequests: playlistPageRequests
        )
    }
}

private enum LibraryPlaylistServingFakeError: Error {
    case unsupported
}

@MainActor
@Test("Add-to-playlist loads every playlist page and sorts names")
func addToPlaylistLoadsEveryPlaylistPage() async {
    let second = Playlist(id: PlaylistID("second"), name: "通勤")
    let first = Playlist(id: PlaylistID("first"), name: "安静")
    let service = LibraryPlaylistServingFake(
        playlistPages: [
            LibraryPage(elements: [second], nextCursor: LibraryCursor("page-2")),
            LibraryPage(elements: [first]),
        ]
    )
    let viewModel = LibraryAddToPlaylistViewModel(
        itemIDs: [libraryPlaylistTrack("one")],
        playlistServing: service
    )

    await viewModel.load()

    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.playlists.map(\.name) == ["安静", "通勤"])
    let snapshot = await service.snapshot()
    #expect(snapshot.playlistPageRequests.count == 2)
    #expect(snapshot.playlistPageRequests[1].cursor == LibraryCursor("page-2"))
}

@MainActor
@Test("Add-to-playlist filters duplicates and appends after the greatest position")
func addToPlaylistFiltersDuplicatesAndPreservesPositions() async {
    let playlist = Playlist(id: PlaylistID("existing"), name: "收藏")
    let first = libraryPlaylistTrack("first")
    let second = libraryPlaylistTrack("second")
    let third = libraryPlaylistTrack("third")
    let service = LibraryPlaylistServingFake(
        playlistPages: [LibraryPage(elements: [playlist])],
        entries: [
            playlist.id: [
                PlaylistEntry(playlistID: playlist.id, trackID: first, position: 4)
            ]
        ]
    )
    let viewModel = LibraryAddToPlaylistViewModel(
        itemIDs: [first, second, second, third],
        playlistServing: service
    )

    let succeeded = await viewModel.add(to: playlist)

    #expect(succeeded)
    let snapshot = await service.snapshot()
    #expect(snapshot.entryMutations.count == 1)
    guard case .insert(let insertions) = snapshot.entryMutations[0].operation else {
        Issue.record("Expected an insert mutation")
        return
    }
    #expect(insertions.map(\.itemID) == [second, third])
    #expect(insertions.map(\.position) == [5, 6])
}

@MainActor
@Test("Creating a playlist immediately adds the requested tracks")
func createPlaylistImmediatelyAddsTracks() async {
    let first = libraryPlaylistTrack("first")
    let second = libraryPlaylistTrack("second")
    let service = LibraryPlaylistServingFake()
    let viewModel = LibraryAddToPlaylistViewModel(
        itemIDs: [first, second],
        playlistServing: service
    )
    await viewModel.load()
    viewModel.newPlaylistName = "  晚间音乐  "

    let succeeded = await viewModel.createAndAdd()

    #expect(succeeded)
    let snapshot = await service.snapshot()
    #expect(snapshot.createdDrafts.map(\.name) == ["晚间音乐"])
    #expect(snapshot.entryMutations.count == 1)
    guard case .insert(let insertions) = snapshot.entryMutations[0].operation else {
        Issue.record("Expected an insert mutation")
        return
    }
    #expect(insertions.map(\.itemID) == [first, second])
    #expect(insertions.map(\.position) == [0, 1])
}

private func libraryPlaylistTrack(_ value: String) -> MediaItemID {
    MediaItemID(sourceID: .local, externalID: value)
}
