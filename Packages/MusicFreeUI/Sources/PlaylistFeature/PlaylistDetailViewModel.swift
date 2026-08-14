import Foundation
import DesignSystem
import LibraryAPI
import MusicDomain
import Observation

@MainActor
@Observable
final class PlaylistDetailViewModel {
    let store: any PlaylistFeatureStore
    let playback: any PlaylistFeaturePlaybackServing
    let playlistID: PlaylistID

    private(set) var playlist: Playlist
    private(set) var entries: [PlaylistEntry] = []
    var draftOrder: [MediaItemID] = []
    var selectedTrackIDs = Set<MediaItemID>()
    var isEditing = false
    private(set) var loadState: PlaylistFeatureLoadState = .idle
    private(set) var mutationState: PlaylistFeatureMutationState = .idle
    private(set) var commandState: PlaylistFeatureCommandState = .idle
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isSendingCommand = false
    var confirmation: PlaylistFeatureConfirmation?
    @ObservationIgnored private var loadCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        playlist: Playlist,
        store: any PlaylistFeatureStore,
        playback: any PlaylistFeaturePlaybackServing
    ) {
        self.playlist = playlist
        self.playlistID = playlist.id
        self.store = store
        self.playback = playback
    }

    var orderedEntries: [PlaylistEntry] {
        guard isEditing else {
            return entries
        }
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.trackID, $0) })
        return draftOrder.compactMap { entryByID[$0] }
    }

    var itemIDs: [MediaItemID] {
        entries.map(\.trackID)
    }

    func updatePlaylist(_ playlist: Playlist) {
        guard playlist.id == playlistID else {
            return
        }
        self.playlist = playlist
    }

    func load() async {
        await performLoad(ignoringInteractionState: false)
    }

    private func performLoad(ignoringInteractionState: Bool) async {
        guard !isLoading else {
            return
        }
        guard ignoringInteractionState || (!isMutating && !isEditing) else {
            return
        }

        isLoading = true
        if entries.isEmpty {
            loadState = .loading
        }
        defer {
            isLoading = false
            let waiters = loadCompletionWaiters
            loadCompletionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        do {
            let loadedEntries = try await store.loadEntries(in: playlistID)
            try Task.checkCancellation()
            entries = Self.normalizedEntries(loadedEntries, playlistID: playlistID)
            draftOrder = itemIDs
            selectedTrackIDs.removeAll()
            loadState = entries.isEmpty ? .empty : .loaded
        } catch let error where playlistFeatureIsCancellation(error) {
            if entries.isEmpty {
                loadState = .idle
            }
        } catch {
            loadState = .failed(playlistFeatureMessage(for: error))
        }
    }

    func loadIfNeeded() async {
        guard !Task.isCancelled else { return }

        while isLoading {
            await withCheckedContinuation { continuation in
                loadCompletionWaiters.append(continuation)
            }
            guard !Task.isCancelled else { return }
        }

        guard loadState == .idle else { return }
        await load()
    }

    func beginEditing() {
        guard !isLoading, !isMutating else {
            return
        }
        draftOrder = itemIDs
        selectedTrackIDs.removeAll()
        isEditing = true
    }

    func cancelEditing() {
        guard !isMutating else {
            return
        }
        draftOrder = itemIDs
        selectedTrackIDs.removeAll()
        isEditing = false
    }

    func move(from source: IndexSet, to destination: Int) {
        guard isEditing, !isLoading, !isMutating else {
            return
        }
        var updatedOrder = draftOrder
        updatedOrder.move(fromOffsets: source, toOffset: destination)
        draftOrder = updatedOrder
    }

    func toggleSelection(for trackID: MediaItemID) {
        guard isEditing, !isLoading, !isMutating else {
            return
        }
        if !selectedTrackIDs.insert(trackID).inserted {
            selectedTrackIDs.remove(trackID)
        }
    }

    @discardableResult
    func saveReorder() async -> Bool {
        guard isEditing else {
            return false
        }
        guard !isLoading, !isMutating else {
            return false
        }
        guard draftOrder != itemIDs else {
            isEditing = false
            selectedTrackIDs.removeAll()
            return true
        }

        let originalEntries = entries
        let originalOrder = itemIDs
        let updatedEntries = Self.makeEntries(from: draftOrder, playlistID: playlistID)
        entries = updatedEntries
        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        do {
            try await store.applyEntries(
                PlaylistEntriesMutation(
                    playlistID: playlistID,
                    operation: .reorder(draftOrder)
                )
            )
            try Task.checkCancellation()
            isEditing = false
            selectedTrackIDs.removeAll()
            mutationState = .succeeded(L("已保存排序"))
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            entries = originalEntries
            draftOrder = originalOrder
            mutationState = .idle
            return false
        } catch {
            entries = originalEntries
            draftOrder = originalOrder
            mutationState = .failed(playlistFeatureMessage(for: error))
            if playlistFeatureIsRevisionConflict(error) {
                await reloadAfterConflict()
            }
            return false
        }
    }

    func requestRemoveSelected() {
        guard isEditing, !isLoading, !isMutating, !selectedTrackIDs.isEmpty else {
            return
        }
        confirmation = .removeTracks(selectedTrackIDs)
    }

    func requestRemove(_ trackID: MediaItemID) {
        guard !isLoading, !isMutating else {
            return
        }
        confirmation = .removeTracks([trackID])
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    @discardableResult
    func remove(trackIDs: Set<MediaItemID>) async -> Bool {
        guard !isLoading, !isMutating, !trackIDs.isEmpty else {
            return false
        }

        let originalEntries = entries
        let originalOrder = isEditing ? draftOrder : itemIDs
        let originalSelection = selectedTrackIDs
        let originalLoadState = loadState
        let updatedOrder = originalOrder.filter { !trackIDs.contains($0) }
        entries = Self.makeEntries(from: updatedOrder, playlistID: playlistID)
        draftOrder = updatedOrder
        selectedTrackIDs.subtract(trackIDs)
        loadState = entries.isEmpty ? .empty : .loaded
        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        do {
            try await store.applyEntries(
                PlaylistEntriesMutation(
                    playlistID: playlistID,
                    operation: .remove(trackIDs)
                )
            )
            try Task.checkCancellation()
            loadState = entries.isEmpty ? .empty : .loaded
            mutationState = .succeeded(L("已移除歌曲"))
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            entries = originalEntries
            draftOrder = originalOrder
            selectedTrackIDs = originalSelection
            loadState = originalLoadState
            mutationState = .idle
            return false
        } catch {
            entries = originalEntries
            draftOrder = originalOrder
            selectedTrackIDs = originalSelection
            loadState = originalLoadState
            mutationState = .failed(playlistFeatureMessage(for: error))
            if playlistFeatureIsRevisionConflict(error) {
                await reloadAfterConflict()
            }
            return false
        }
    }

    /// Appending uses one insert mutation even when several tracks are picked.
    @discardableResult
    func addTracks(_ trackIDs: [MediaItemID]) async -> Bool {
        guard !isLoading, !isMutating else {
            return false
        }

        let existingIDs = Set(itemIDs)
        var seen = Set<MediaItemID>()
        let additions = trackIDs.filter {
            !existingIDs.contains($0) && seen.insert($0).inserted
        }
        guard !additions.isEmpty else {
            return false
        }

        let originalEntries = entries
        let originalOrder = draftOrder
        let insertionStart = itemIDs.count
        let updatedOrder = itemIDs + additions
        entries = Self.makeEntries(from: updatedOrder, playlistID: playlistID)
        draftOrder = updatedOrder
        isMutating = true
        mutationState = .submitting
        defer {
            isMutating = false
        }

        let insertions = additions.enumerated().map {
            PlaylistEntryInsertion(itemID: $0.element, position: insertionStart + $0.offset)
        }
        do {
            try await store.applyEntries(
                PlaylistEntriesMutation(
                    playlistID: playlistID,
                    operation: .insert(insertions)
                )
            )
            try Task.checkCancellation()
            loadState = .loaded
            mutationState = .succeeded(L("已添加 %d 首歌曲", additions.count))
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            entries = originalEntries
            draftOrder = originalOrder
            mutationState = .idle
            return false
        } catch {
            entries = originalEntries
            draftOrder = originalOrder
            mutationState = .failed(playlistFeatureMessage(for: error))
            if playlistFeatureIsRevisionConflict(error) {
                await reloadAfterConflict()
            }
            return false
        }
    }

    @discardableResult
    func sendPlayback(_ intent: PlaylistPlaybackIntent) async -> Bool {
        guard !isSendingCommand else {
            return false
        }
        guard let command = PlaylistPlaybackCommand.make(
            playlistID: playlistID,
            itemIDs: itemIDs,
            intent: intent
        ) else {
            commandState = .failed(PlaylistFeatureError.emptyPlaylist.localizedDescription)
            return false
        }

        return await sendPlaybackCommand(command)
    }

    @discardableResult
    func play(itemID: MediaItemID) async -> Bool {
        guard entries.contains(where: { $0.trackID == itemID }) else {
            commandState = .failed(PlaylistFeatureError.emptyPlaylist.localizedDescription)
            return false
        }

        // Start at the selected song while retaining the rest of this playlist
        // as the playback queue, matching the list's primary play behavior.
        let orderedIDs = [itemID] + itemIDs.filter { $0 != itemID }
        guard let command = PlaylistPlaybackCommand.make(
            playlistID: playlistID,
            itemIDs: orderedIDs,
            intent: .playAll
        ) else {
            commandState = .failed(PlaylistFeatureError.emptyPlaylist.localizedDescription)
            return false
        }
        return await sendPlaybackCommand(command)
    }

    private func sendPlaybackCommand(_ command: PlaylistPlaybackCommand) async -> Bool {
        guard !isSendingCommand else {
            return false
        }

        isSendingCommand = true
        commandState = .submitting
        defer {
            isSendingCommand = false
        }

        do {
            try await playback.send(command)
            try Task.checkCancellation()
            commandState = .succeeded
            return true
        } catch let error where playlistFeatureIsCancellation(error) {
            commandState = .idle
            return false
        } catch {
            commandState = .failed(playlistFeatureMessage(for: error))
            return false
        }
    }

    func clearMutationState() {
        mutationState = .idle
    }

    func clearCommandState() {
        commandState = .idle
    }

    private func reloadAfterConflict() async {
        await performLoad(ignoringInteractionState: true)
    }

    private static func normalizedEntries(
        _ entries: [PlaylistEntry],
        playlistID: PlaylistID
    ) -> [PlaylistEntry] {
        let orderedIDs = entries
            .filter { $0.playlistID == playlistID }
            .sorted { left, right in
                if left.position != right.position {
                    return left.position < right.position
                }
                return left.trackID < right.trackID
            }
            .map(\.trackID)
        return makeEntries(from: orderedIDs, playlistID: playlistID)
    }

    private static func makeEntries(
        from itemIDs: [MediaItemID],
        playlistID: PlaylistID
    ) -> [PlaylistEntry] {
        itemIDs.enumerated().map {
            PlaylistEntry(playlistID: playlistID, trackID: $0.element, position: $0.offset)
        }
    }
}
