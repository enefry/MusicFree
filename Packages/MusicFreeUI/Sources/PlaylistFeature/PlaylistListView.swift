import DesignSystem
import MusicDomain
import SwiftUI

struct PlaylistListView: View {
    @Bindable var viewModel: PlaylistListViewModel

    @State private var editorMode: PlaylistEditorMode?

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading where viewModel.playlists.isEmpty:
                ProgressView("加载歌单")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where viewModel.playlists.isEmpty:
                ErrorStateView(
                    title: "歌单加载失败",
                    message: message,
                    retryTitle: "重试",
                    retry: reload
                )
            case .empty:
                EmptyStateView(
                    title: "还没有歌单",
                    message: "创建一个歌单，整理喜欢的歌曲。",
                    systemImage: "music.note.list",
                    actionTitle: "新建歌单",
                    action: presentCreateEditor
                )
            default:
                playlistList
            }
        }
        .overlay(alignment: .top) {
            if viewModel.isLoading, !viewModel.playlists.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(MusicFreeSpacingTokens.small)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(Text("正在刷新歌单"))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: presentCreateEditor) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("新建歌单"))
                .help("新建歌单")
            }
        }
        .sheet(item: $editorMode) { mode in
            PlaylistEditor(
                mode: mode,
                existingPlaylists: viewModel.playlists,
                excludingID: mode.excludingID,
                onSave: { name in
                    switch mode {
                    case .create:
                        return await viewModel.createPlaylist(named: name)
                    case .rename(let playlistID, _):
                        return await viewModel.renamePlaylist(playlistID, to: name)
                    }
                }
            )
        }
        .confirmationDialog(
            "删除歌单？",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard case .deletePlaylist(let playlistID) = viewModel.confirmation else {
                    return
                }
                viewModel.cancelConfirmation()
                Task { await viewModel.deletePlaylist(playlistID) }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelConfirmation()
            }
        } message: {
            Text("歌单和其中的排序关系会被删除。")
        }
        .alert(
            "操作失败",
            isPresented: mutationFailureBinding
        ) {
            Button("好", role: .cancel) {
                viewModel.clearMutationState()
            }
        } message: {
            Text(viewModel.mutationState.failureMessage ?? "请重试。")
        }
    }

    private var playlistList: some View {
        List(selection: $viewModel.selection) {
            ForEach(viewModel.playlists) { playlist in
                Button {
                    viewModel.select(playlist.id)
                } label: {
                    PlaylistListRow(playlist: playlist)
                }
                .buttonStyle(.plain)
                .tag(playlist.id)
                .contextMenu {
                    Button {
                        editorMode = .rename(playlist.id, initialName: playlist.name)
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.requestDelete(playlist.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .accessibilityIdentifier("playlists.list")
        .refreshable {
            await viewModel.load()
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.confirmation?.deletePlaylistID != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelConfirmation()
                }
            }
        )
    }

    private var mutationFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mutationState.failureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearMutationState()
                }
            }
        )
    }

    private func presentCreateEditor() {
        editorMode = .create
    }

    private func reload() {
        Task { await viewModel.load() }
    }
}

private struct PlaylistListRow: View {
    let playlist: Playlist

    var body: some View {
        MediaRow(
            title: playlist.name,
            subtitle: "歌单",
            placeholderSystemImage: "music.note.list",
            accessory: {
                Image(systemName: "chevron.forward")
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                    .accessibilityHidden(true)
            }
        )
        .accessibilityLabel(Text(playlist.name))
    }
}

private extension PlaylistEditorMode {
    var excludingID: PlaylistID? {
        switch self {
        case .create:
            return nil
        case .rename(let playlistID, _):
            return playlistID
        }
    }
}
