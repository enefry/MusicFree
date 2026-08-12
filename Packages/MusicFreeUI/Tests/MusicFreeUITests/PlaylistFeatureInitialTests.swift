import Foundation
import LibraryAPI
import MusicDomain
@testable import PlaylistFeature
import Testing

@MainActor
private final class PlaylistFeatureTestStore: PlaylistFeatureStore {
    var playlistValues: [Playlist]
    var entryValues: [PlaylistID: [MediaItemID]]
    var failNextMutation = false
    var failNextDelete = false
    var entryMutations: [PlaylistEntriesMutation] = []
    var metadataMutations: [PlaylistMutation] = []
    var deletedPlaylistIDs: [PlaylistID] = []
    var loadEntriesCallCount = 0
    var waitsForFirstLoadCancellation = false
    var observedLoadCancellation = false
    var loadEntriesGate: PlaylistFeatureTestGate?
    var entryMutationGate: PlaylistFeatureTestGate?
    private var nextID = 1
    private var loadEntriesCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        playlists: [Playlist] = [],
        entries: [PlaylistID: [MediaItemID]] = [:]
    ) {
        self.playlistValues = playlists
        self.entryValues = entries
    }

    func loadPlaylists() async throws -> [Playlist] {
        playlistValues
    }

    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        loadEntriesCallCount += 1
        resumeLoadEntriesCallWaiters()
        let loadedEntries = (entryValues[playlistID] ?? []).enumerated().map {
            PlaylistEntry(playlistID: playlistID, trackID: $0.element, position: $0.offset)
        }
        if waitsForFirstLoadCancellation, loadEntriesCallCount == 1 {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                observedLoadCancellation = true
                throw error
            }
        }
        if let loadEntriesGate {
            await loadEntriesGate.wait()
        }
        return loadedEntries
    }

    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        let playlist = Playlist(id: PlaylistID("playlist-\(nextID)"), name: draft.name)
        nextID += 1
        playlistValues.append(playlist)
        entryValues[playlist.id] = []
        return playlist
    }

    func updatePlaylist(_ mutation: PlaylistMutation) async throws -> Playlist {
        metadataMutations.append(mutation)
        guard let index = playlistValues.firstIndex(where: { $0.id == mutation.playlistID }) else {
            throw PlaylistFeatureError.serviceUnavailable
        }
        let current = playlistValues[index]
        let name: String
        switch mutation.change {
        case .rename(let value):
            name = value
        case .replace(let value, _, _):
            name = value
        case .setSortName, .setArtwork:
            name = current.name
        }
        let updated = Playlist(
            id: current.id,
            name: name,
            sortName: current.sortName,
            artwork: current.artwork,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt
        )
        playlistValues[index] = updated
        return updated
    }

    func applyEntries(_ mutation: PlaylistEntriesMutation) async throws {
        if let entryMutationGate {
            await entryMutationGate.wait()
        }
        if failNextMutation {
            failNextMutation = false
            throw PlaylistFeatureError.serviceUnavailable
        }
        entryMutations.append(mutation)
        var order = entryValues[mutation.playlistID] ?? []
        switch mutation.operation {
        case .insert(let insertions):
            for insertion in insertions.sorted(by: { $0.position < $1.position }) {
                order.insert(insertion.itemID, at: min(insertion.position, order.count))
            }
        case .move(let moves):
            for move in moves {
                guard let index = order.firstIndex(of: move.itemID) else { continue }
                let item = order.remove(at: index)
                order.insert(item, at: min(move.position, order.count))
            }
        case .remove(let itemIDs):
            order.removeAll { itemIDs.contains($0) }
        case .reorder(let desiredOrder):
            order = desiredOrder
        }
        entryValues[mutation.playlistID] = order
    }

    func deletePlaylist(_ playlistID: PlaylistID) async throws {
        if failNextDelete {
            failNextDelete = false
            throw PlaylistFeatureError.serviceUnavailable
        }
        guard let index = playlistValues.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistFeatureError.serviceUnavailable
        }
        playlistValues.remove(at: index)
        entryValues.removeValue(forKey: playlistID)
        deletedPlaylistIDs.append(playlistID)
    }

    func waitForLoadEntriesCallCount(_ expectedCount: Int) async {
        guard loadEntriesCallCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            loadEntriesCallWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeLoadEntriesCallWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in loadEntriesCallWaiters {
            if loadEntriesCallCount >= expectedCount {
                continuation.resume()
            } else {
                pending.append((expectedCount, continuation))
            }
        }
        loadEntriesCallWaiters = pending
    }
}

@MainActor
private final class PlaylistFeatureTestGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                precondition(releaseWaiter == nil)
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class PlaylistFeatureTestPlayback: PlaylistFeaturePlaybackServing {
    var commands: [PlaylistPlaybackCommand] = []

    func send(_ command: PlaylistPlaybackCommand) async throws {
        commands.append(command)
    }
}

private func testTrack(_ value: String) -> MediaItemID {
    MediaItemID(sourceID: .local, externalID: value)
}

@MainActor
@Test("Playlist list view model performs CRUD and keeps selection stable")
func playlistListViewModelPerformsCRUD() async {
    let store = PlaylistFeatureTestStore()
    let viewModel = PlaylistListViewModel(store: store)

    await viewModel.load()
    #expect(viewModel.loadState == .empty)

    let created = await viewModel.createPlaylist(named: "  晚间 Mix  ")
    #expect(created)
    let playlistID = viewModel.playlists[0].id
    #expect(viewModel.selection == playlistID)
    #expect(viewModel.playlists[0].name == "晚间 Mix")

    let duplicate = await viewModel.createPlaylist(named: "晚间 mix")
    #expect(!duplicate)
    #expect(viewModel.playlists.count == 1)

    let renamed = await viewModel.renamePlaylist(playlistID, to: "通勤 Mix")
    #expect(renamed)
    #expect(viewModel.selectedPlaylist?.name == "通勤 Mix")

    viewModel.requestDelete(playlistID)
    #expect(viewModel.confirmation == .deletePlaylist(playlistID))
    viewModel.cancelConfirmation()
    #expect(viewModel.confirmation == nil)

    let deleted = await viewModel.deletePlaylist(playlistID)
    #expect(deleted)
    #expect(viewModel.playlists.isEmpty)
    #expect(viewModel.selection == nil)
    #expect(store.deletedPlaylistIDs == [playlistID])
}

@MainActor
@Test("Playlist detail batches additions, removals, and reorder into typed mutations")
func playlistDetailAppliesMemberMutations() async {
    let playlist = Playlist(id: PlaylistID("playlist-1"), name: "Favorites")
    let first = testTrack("first")
    let second = testTrack("second")
    let third = testTrack("third")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [first, second]]
    )
    let playback = PlaylistFeatureTestPlayback()
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: playback
    )

    await viewModel.load()
    #expect(viewModel.itemIDs == [first, second])

    let played = await viewModel.play(itemID: second)
    #expect(played)
    #expect(playback.commands == [
        PlaylistPlaybackCommand(
            playlistID: playlist.id,
            itemIDs: [second, first],
            intent: .playAll
        )
    ])

    let added = await viewModel.addTracks([third, second])
    #expect(added)
    #expect(viewModel.itemIDs == [first, second, third])
    #expect(store.entryMutations.count == 1)
    if case .insert(let insertions) = store.entryMutations[0].operation {
        #expect(insertions.map(\.itemID) == [third])
        #expect(insertions[0].position == 2)
    } else {
        Issue.record("Expected one batched insert mutation")
    }

    viewModel.beginEditing()
    viewModel.move(from: IndexSet(integer: 0), to: 3)
    let reordered = await viewModel.saveReorder()
    #expect(reordered)
    #expect(viewModel.itemIDs == [second, third, first])

    let removed = await viewModel.remove(trackIDs: [third])
    #expect(removed)
    #expect(viewModel.itemIDs == [second, first])
    #expect(store.entryMutations.count == 3)
    if case .reorder(let desiredOrder) = store.entryMutations[1].operation {
        #expect(desiredOrder == [second, third, first])
    } else {
        Issue.record("Expected one complete reorder mutation")
    }
    if case .remove(let itemIDs) = store.entryMutations[2].operation {
        #expect(itemIDs == [third])
    } else {
        Issue.record("Expected one remove mutation")
    }
}

@MainActor
@Test("Playlist detail loadIfNeeded preserves a completed empty state")
func playlistDetailLoadIfNeededPreservesEmptyState() async {
    let playlist = Playlist(id: PlaylistID("playlist-reentry"), name: "Review")
    let track = testTrack("only-track")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [track]]
    )
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistFeatureTestPlayback()
    )

    await viewModel.loadIfNeeded()
    #expect(store.loadEntriesCallCount == 1)

    let removed = await viewModel.remove(trackIDs: [track])
    #expect(removed)
    #expect(viewModel.loadState == .empty)

    await viewModel.loadIfNeeded()
    #expect(store.loadEntriesCallCount == 1)
    #expect(viewModel.loadState == .empty)
}

@MainActor
@Test("Playlist detail retries after an in-flight initial load is cancelled")
func playlistDetailRetriesAfterCancelledInitialLoad() async {
    let playlist = Playlist(id: PlaylistID("playlist-cancelled-load"), name: "Retry")
    let track = testTrack("recovered-track")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [track]]
    )
    store.waitsForFirstLoadCancellation = true
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistFeatureTestPlayback()
    )

    let firstLoad = Task {
        await viewModel.loadIfNeeded()
    }
    await store.waitForLoadEntriesCallCount(1)
    #expect(viewModel.isLoading)
    #expect(viewModel.loadState == .loading)

    firstLoad.cancel()
    await viewModel.loadIfNeeded()
    await firstLoad.value

    #expect(store.observedLoadCancellation)
    #expect(store.loadEntriesCallCount == 2)
    #expect(viewModel.itemIDs == [track])
    #expect(viewModel.loadState == .loaded)
    #expect(!viewModel.isLoading)
}

@MainActor
@Test("Removing the last playlist entry publishes the optimistic empty state")
func playlistDetailLastEntryRemovalPublishesEmptyState() async {
    let playlist = Playlist(id: PlaylistID("playlist-last-entry"), name: "Solo")
    let track = testTrack("only-track")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [track]]
    )
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistFeatureTestPlayback()
    )
    await viewModel.load()

    let gate = PlaylistFeatureTestGate()
    store.entryMutationGate = gate
    let removalTask = Task {
        await viewModel.remove(trackIDs: [track])
    }

    await gate.waitUntilStarted()
    #expect(viewModel.entries.isEmpty)
    #expect(viewModel.loadState == .empty)
    #expect(viewModel.isMutating)

    gate.release()
    let removed = await removalTask.value
    #expect(removed)
    #expect(viewModel.loadState == .empty)
    #expect(!viewModel.isMutating)
}

@MainActor
@Test("Playlist detail serializes refreshes with member mutations")
func playlistDetailSerializesRefreshesWithMemberMutations() async {
    let playlist = Playlist(id: PlaylistID("playlist-refresh-mutation"), name: "Serialized")
    let track = testTrack("only-track")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [track]]
    )
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistFeatureTestPlayback()
    )
    await viewModel.load()

    let refreshGate = PlaylistFeatureTestGate()
    store.loadEntriesGate = refreshGate
    let refreshTask = Task {
        await viewModel.load()
    }
    await refreshGate.waitUntilStarted()

    let removalDuringRefresh = await viewModel.remove(trackIDs: [track])
    #expect(!removalDuringRefresh)
    #expect(!viewModel.isMutating)
    #expect(store.entryMutations.isEmpty)

    refreshGate.release()
    await refreshTask.value
    #expect(viewModel.itemIDs == [track])
    #expect(store.loadEntriesCallCount == 2)

    store.loadEntriesGate = nil
    let mutationGate = PlaylistFeatureTestGate()
    store.entryMutationGate = mutationGate
    let removalTask = Task {
        await viewModel.remove(trackIDs: [track])
    }
    await mutationGate.waitUntilStarted()
    #expect(viewModel.isMutating)
    #expect(viewModel.loadState == .empty)

    await viewModel.load()
    #expect(store.loadEntriesCallCount == 2)

    mutationGate.release()
    let removed = await removalTask.value
    #expect(removed)
    #expect(viewModel.itemIDs.isEmpty)
    #expect(viewModel.loadState == .empty)
}

@MainActor
@Test("Playlist detail rolls back optimistic member edits after a store failure")
func playlistDetailRollsBackFailedMemberEdit() async {
    let playlist = Playlist(id: PlaylistID("playlist-2"), name: "Road")
    let first = testTrack("first")
    let second = testTrack("second")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlist.id: [first, second]]
    )
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: PlaylistFeatureTestPlayback()
    )

    await viewModel.load()
    viewModel.beginEditing()
    viewModel.move(from: IndexSet(integer: 0), to: 2)
    store.failNextMutation = true

    let saved = await viewModel.saveReorder()
    #expect(!saved)
    #expect(viewModel.itemIDs == [first, second])
    #expect(viewModel.draftOrder == [first, second])
    #expect(viewModel.mutationState.failureMessage != nil)
    #expect(store.entryMutations.isEmpty)

    store.failNextMutation = true
    let removed = await viewModel.remove(trackIDs: [first, second])
    #expect(!removed)
    #expect(viewModel.itemIDs == [first, second])
    #expect(viewModel.loadState == .loaded)
}

@MainActor
@Test("Playlist playback intents map to ordered commands without editing the queue")
func playlistPlaybackIntentMapping() async {
    let playlistID = PlaylistID("playlist-3")
    let first = testTrack("first")
    let second = testTrack("second")

    let command = PlaylistPlaybackCommand.make(
        playlistID: playlistID,
        itemIDs: [first, second, first],
        intent: .shuffle
    )
    #expect(command?.playlistID == playlistID)
    #expect(command?.itemIDs == [first, second])
    #expect(command?.intent == .shuffle)
    #expect(command?.appServicesCommands == [
        .playItems(itemIDs: [first, second], shuffle: true)
    ])

    let playlist = Playlist(id: playlistID, name: "Queue")
    let store = PlaylistFeatureTestStore(
        playlists: [playlist],
        entries: [playlistID: [first, second]]
    )
    let playback = PlaylistFeatureTestPlayback()
    let viewModel = PlaylistDetailViewModel(
        playlist: playlist,
        store: store,
        playback: playback
    )
    await viewModel.load()

    let sent = await viewModel.sendPlayback(.enqueue)
    #expect(sent)
    #expect(playback.commands == [
        PlaylistPlaybackCommand(playlistID: playlistID, itemIDs: [first, second], intent: .enqueue)
    ])
}
