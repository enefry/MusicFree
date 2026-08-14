import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import Observation
import SwiftUI

struct LibraryAddToPlaylistRequest: Identifiable {
    let id = UUID()
    let itemIDs: [MediaItemID]
}

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

struct LibraryAddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: LibraryAddToPlaylistViewModel
    @State private var searchText = ""

    init(itemIDs: [MediaItemID], playlistServing: any PlaylistServing) {
        _viewModel = State(
            initialValue: LibraryAddToPlaylistViewModel(
                itemIDs: itemIDs,
                playlistServing: playlistServing
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            Group {
                switch viewModel.loadState {
                case .loading:
                    ProgressView(L("加载播放列表"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ErrorStateView(
                        title: L("播放列表加载失败"),
                        message: message,
                        retryTitle: L("重试"),
                        retry: { Task { await viewModel.load() } }
                    )
                case .loaded:
                    playlistList
                }
            }
            .navigationTitle(L("添加到播放列表"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: L("搜索播放列表"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(viewModel.isSubmitting)
                }
            }
            .overlay {
                if viewModel.isSubmitting {
                    ProgressView(L("正在添加"))
                        .padding(MusicFreeSpacingTokens.large)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .task { await viewModel.load() }
            .alert(L("无法添加"), isPresented: errorBinding) {
                Button(L("好"), role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? L("请稍后重试。"))
            }
            .alert(L("无需重复添加"), isPresented: noticeBinding) {
                Button(L("好"), role: .cancel) { viewModel.noticeMessage = nil }
            } message: {
                Text(viewModel.noticeMessage ?? L("歌曲已在该播放列表中。"))
            }
            .accessibilityIdentifier("library.addToPlaylist")
        }
    }

    private var playlistList: some View {
        List {
            Section {
                Button {
                    withAnimation { viewModel.isCreatingPlaylist.toggle() }
                } label: {
                    Label(L("新建播放列表"), systemImage: "plus.circle.fill")
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier("library.addToPlaylist.create")
            }

            if viewModel.isCreatingPlaylist {
                Section(L("新建播放列表")) {
                    TextField(L("播放列表名称"), text: $viewModel.newPlaylistName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(createAndAdd)
                        .accessibilityIdentifier("library.addToPlaylist.name")

                    Button(action: createAndAdd) {
                        Label(L("创建并添加"), systemImage: "checkmark")
                    }
                    .disabled(!viewModel.canCreatePlaylist)
                    .accessibilityIdentifier("library.addToPlaylist.createAndAdd")
                }
            }

            Section(L("现有播放列表")) {
                if filteredPlaylists.isEmpty {
                    Text(searchText.isEmpty ? L("暂无播放列表") : L("没有匹配的播放列表"))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else {
                    ForEach(filteredPlaylists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .disabled(viewModel.isSubmitting)
                        .accessibilityIdentifier(
                            "library.addToPlaylist.playlist.\(playlist.id.rawValue)"
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filteredPlaylists: [Playlist] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.playlists }
        return viewModel.playlists.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.noticeMessage != nil },
            set: { if !$0 { viewModel.noticeMessage = nil } }
        )
    }

    private func add(to playlist: Playlist) {
        Task { @MainActor in
            if await viewModel.add(to: playlist) { dismiss() }
        }
    }

    private func createAndAdd() {
        guard viewModel.canCreatePlaylist else { return }
        Task { @MainActor in
            if await viewModel.createAndAdd() { dismiss() }
        }
    }
}
