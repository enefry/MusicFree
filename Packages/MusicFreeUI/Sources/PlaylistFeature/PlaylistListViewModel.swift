import LibraryAPI
import MusicDomain
import Observation

@MainActor
@Observable
final class PlaylistListViewModel {
    let store: any PlaylistFeatureStore

    private(set) var playlists: [Playlist] = []
    var selection: PlaylistID?
    private(set) var loadState: PlaylistFeatureLoadState = .idle
    private(set) var mutationState: PlaylistFeatureMutationState = .idle
    private(set) var isLoading = false
    private(set) var isMutating = false
    var confirmation: PlaylistFeatureConfirmation?

    init(store: any PlaylistFeatureStore) {
        self.store = store
    }

    var selectedPlaylist: Playlist? {
        guard let selection else {
            return nil
        }
        return playlist(withID: selection)
    }

    func playlist(withID id: PlaylistID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func load() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        if playlists.isEmpty {
            loadState = .loading
        }
        defer {
            isLoading = false
        }

        do {
            let loadedPlaylists = try await store.loadPlaylists()
            try Task.checkCancellation()
            playlists = loadedPlaylists
            normalizeSelection()
            loadState = playlists.isEmpty ? .empty : .loaded
        } catch let error where playlistFeatureIsCancellation(error) {
            if playlists.isEmpty {
                loadState = .idle
            }
        } catch {
            loadState = .failed(playlistFeatureMessage(for: error))
        }
    }

    func select(_ playlistID: PlaylistID?) {
        guard let playlistID else {
            selection = nil
            return
        }
        guard playlist(withID: playlistID) != nil else {
            return
        }
        selection = playlistID
    }

    @discardableResult
    func createPlaylist(named name: String) async -> Bool {
        guard !isMutating else {
            return false
        }

        let normalizedName: String
        do {
            normalizedName = try PlaylistNameValidator.validatedName(
                name,
                existingPlaylists: playlists
            )
        } catch {
            mutationState = .failed(playlistFeatureMessage(for: error))
            return false
        }

        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        do {
            let created = try await store.createPlaylist(PlaylistDraft(name: normalizedName))
            try Task.checkCancellation()
            playlists.append(created)
            selection = created.id
            loadState = .loaded
            mutationState = .succeeded("已创建歌单")
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            mutationState = .idle
            return false
        } catch {
            mutationState = .failed(playlistFeatureMessage(for: error))
            return false
        }
    }

    @discardableResult
    func renamePlaylist(_ playlistID: PlaylistID, to name: String) async -> Bool {
        guard !isMutating, let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }

        let normalizedName: String
        do {
            normalizedName = try PlaylistNameValidator.validatedName(
                name,
                existingPlaylists: playlists,
                excludingID: playlistID
            )
        } catch {
            mutationState = .failed(playlistFeatureMessage(for: error))
            return false
        }

        let original = playlists[index]
        let optimistic = original.playlistFeatureRenamed(to: normalizedName)
        playlists[index] = optimistic
        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        do {
            let updated = try await store.updatePlaylist(
                PlaylistMutation(
                    playlistID: playlistID,
                    change: .rename(normalizedName)
                )
            )
            try Task.checkCancellation()
            playlists[index] = updated
            mutationState = .succeeded("已重命名歌单")
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            playlists[index] = original
            mutationState = .idle
            return false
        } catch {
            playlists[index] = original
            mutationState = .failed(playlistFeatureMessage(for: error))
            if playlistFeatureIsRevisionConflict(error) {
                await reloadAfterConflict()
            }
            return false
        }
    }

    func requestDelete(_ playlistID: PlaylistID) {
        guard playlist(withID: playlistID) != nil else {
            return
        }
        confirmation = .deletePlaylist(playlistID)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    @discardableResult
    func deletePlaylist(_ playlistID: PlaylistID) async -> Bool {
        guard !isMutating,
              let index = playlists.firstIndex(where: { $0.id == playlistID })
        else {
            return false
        }

        let original = playlists[index]
        let originalSelection = selection
        playlists.remove(at: index)
        if selection == playlistID {
            selection = nil
        }
        loadState = playlists.isEmpty ? .empty : .loaded
        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        do {
            try await store.deletePlaylist(playlistID)
            try Task.checkCancellation()
            mutationState = .succeeded("已删除歌单")
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            restore(original, at: index, selection: originalSelection)
            mutationState = .idle
            return false
        } catch {
            restore(original, at: index, selection: originalSelection)
            mutationState = .failed(playlistFeatureMessage(for: error))
            if playlistFeatureIsRevisionConflict(error) {
                await reloadAfterConflict()
            }
            return false
        }
    }

    func replace(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            playlists.append(playlist)
            loadState = .loaded
            return
        }
        playlists[index] = playlist
    }

    func clearMutationState() {
        mutationState = .idle
    }

    private func restore(_ playlist: Playlist, at index: Int, selection originalSelection: PlaylistID?) {
        let insertionIndex = min(index, playlists.count)
        playlists.insert(playlist, at: insertionIndex)
        selection = originalSelection
        loadState = .loaded
    }

    private func normalizeSelection() {
        guard let selection, playlist(withID: selection) != nil else {
            if selection != nil {
                selection = nil
            }
            return
        }
    }

    private func reloadAfterConflict() async {
        await load()
    }
}

extension PlaylistFeatureConfirmation {
    var deletePlaylistID: PlaylistID? {
        guard case .deletePlaylist(let playlistID) = self else {
            return nil
        }
        return playlistID
    }
}
