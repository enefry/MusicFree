import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import Observation

@MainActor
@Observable
final class LibraryAddToPlaylistViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let playlistServing: any PlaylistServing
    private let itemIDs: [MediaItemID]

    private(set) var playlists: [Playlist] = []
    private(set) var loadState: LoadState = .loading
    private(set) var isSubmitting = false
    var newPlaylistName = ""
    var isCreatingPlaylist = false
    var errorMessage: String?
    var noticeMessage: String?

    init(itemIDs: [MediaItemID], playlistServing: any PlaylistServing) {
        self.itemIDs = Self.unique(itemIDs)
        self.playlistServing = playlistServing
    }

    var canCreatePlaylist: Bool {
        !normalizedNewPlaylistName.isEmpty && !isSubmitting
    }

    func load() async {
        loadState = .loading

        do {
            playlists = try await loadAllPlaylists()
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(message(for: error))
        }
    }

    func add(to playlist: Playlist) async -> Bool {
        guard !isSubmitting else { return false }
        return await submit(to: playlist)
    }

    func createAndAdd() async -> Bool {
        guard !isSubmitting else { return false }

        let name = normalizedNewPlaylistName
        guard !name.isEmpty else {
            errorMessage = L("请输入播放列表名称。")
            return false
        }
        guard name.count <= 80 else {
            errorMessage = L("播放列表名称不能超过 80 个字符。")
            return false
        }
        guard !playlists.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            errorMessage = L("播放列表名称已存在。")
            return false
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let playlist = try await playlistServing.create(PlaylistDraft(name: name))
            playlists.append(playlist)
            playlists.sort(by: Self.playlistOrder)
            newPlaylistName = ""
            isCreatingPlaylist = false
            return try await appendItems(to: playlist)
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func submit(to playlist: Playlist) async -> Bool {
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            return try await appendItems(to: playlist)
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func appendItems(to playlist: Playlist) async throws -> Bool {
        let entries = try await playlistServing.entries(in: playlist.id)
        try Task.checkCancellation()

        let existingIDs = Set(entries.map(\.trackID))
        let newItemIDs = itemIDs.filter { !existingIDs.contains($0) }
        guard !newItemIDs.isEmpty else {
            noticeMessage = itemIDs.count == 1
                ? L("这首歌曲已在该播放列表中。")
                : L("这些歌曲已全部在该播放列表中。")
            return false
        }

        let startPosition = (entries.map(\.position).max() ?? -1) + 1
        let insertions = newItemIDs.enumerated().map { offset, itemID in
            PlaylistEntryInsertion(itemID: itemID, position: startPosition + offset)
        }
        try await playlistServing.apply(
            PlaylistEntriesMutation(
                playlistID: playlist.id,
                operation: .insert(insertions)
            )
        )
        try Task.checkCancellation()
        return true
    }

    private func loadAllPlaylists() async throws -> [Playlist] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var loaded: [Playlist] = []
        var seenIDs = Set<PlaylistID>()
        var seenCursors = Set<LibraryCursor>()

        while true {
            try Task.checkCancellation()
            let page = try await playlistServing.playlists(page: request)
            loaded.append(contentsOf: page.elements.filter { seenIDs.insert($0.id).inserted })

            guard let nextRequest = try page.nextPage(limit: request.limit) else { break }
            guard let cursor = nextRequest.cursor, seenCursors.insert(cursor).inserted else {
                throw LibraryAddToPlaylistError.repeatedCursor
            }
            request = nextRequest
        }

        return loaded.sorted(by: Self.playlistOrder)
    }

    private var normalizedNewPlaylistName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ itemIDs: [MediaItemID]) -> [MediaItemID] {
        var seen = Set<MediaItemID>()
        return itemIDs.filter { seen.insert($0).inserted }
    }

    private static func playlistOrder(_ lhs: Playlist, _ rhs: Playlist) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private func message(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L("无法添加到播放列表，请稍后重试。") : text
    }
}

private enum LibraryAddToPlaylistError: LocalizedError {
    case repeatedCursor

    var errorDescription: String? {
        L("播放列表分页状态无效，请稍后重试。")
    }
}
