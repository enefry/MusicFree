import AppServices
import DesignSystem
import MusicDomain
import SwiftUI

public struct PlaylistScene: View {
    private let store: any PlaylistFeatureStore
    private let playback: any PlaylistFeaturePlaybackServing
    private let onRoute: PlaylistRouteAction?

    @State private var listViewModel: PlaylistListViewModel
    @State private var trackCandidateLoader: PlaylistTrackCandidateLoader
    @State private var detailViewModel: PlaylistDetailViewModel?

    @MainActor
    public init(
        store: any PlaylistFeatureStore,
        playback: any PlaylistFeaturePlaybackServing,
        libraryServing: (any LibraryServing)? = nil,
        onRoute: PlaylistRouteAction? = nil
    ) {
        self.store = store
        self.playback = playback
        self.onRoute = onRoute
        _listViewModel = State(initialValue: PlaylistListViewModel(store: store))
        _trackCandidateLoader = State(
            initialValue: PlaylistTrackCandidateLoader(library: libraryServing)
        )
        _detailViewModel = State(initialValue: nil)
    }

    @MainActor
    public init(
        playlistServing: any PlaylistServing,
        playbackServing: any PlaybackServing,
        libraryServing: any LibraryServing,
        onRoute: PlaylistRouteAction? = nil
    ) {
        self.init(
            store: AppServicesPlaylistStore(serving: playlistServing),
            playback: AppServicesPlaybackBridge(serving: playbackServing),
            libraryServing: libraryServing,
            onRoute: onRoute
        )
    }

    /// Compatibility initializer for the package graph and previews. It does
    /// not create a repository, adapter, or playback engine.
    @MainActor
    public init() {
        self.init(
            store: UnconfiguredPlaylistStore(),
            playback: UnconfiguredPlaylistPlaybackServing()
        )
    }

    @MainActor
    public var body: some View {
        @Bindable var listViewModel = listViewModel

        NavigationSplitView {
            PlaylistListView(viewModel: listViewModel)
                .navigationTitle(L("播放列表"))
        } detail: {
            if let playlist = listViewModel.selectedPlaylist,
               let detailViewModel,
               detailViewModel.playlistID == playlist.id {
                PlaylistDetailView(
                    playlist: playlist,
                    store: store,
                    playback: playback,
                    viewModel: detailViewModel,
                    trackCandidates: trackCandidateLoader.candidates,
                    trackCandidateLoadState: trackCandidateLoader.loadState,
                    retryTrackCandidates: {
                        Task { await trackCandidateLoader.load() }
                    },
                    onPlaylistChanged: { updatedPlaylist in
                        listViewModel.replace(updatedPlaylist)
                    },
                    onRoute: onRoute
                )
                .id(playlist.id)
            } else if listViewModel.selectedPlaylist != nil {
                ProgressView(L("加载歌曲"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    title: L("选择一个歌单"),
                    message: L("歌单详情和播放操作会显示在这里。"),
                    systemImage: "music.note.list"
                )
            }
        }
        .task {
            await listViewModel.load()
        }
        .task(id: listViewModel.selection) {
            // Load candidates only after a playlist is opened. The local-media
            // scanner may still be importing while the playlist list appears;
            // starting this work earlier can leave the add flow stuck in an
            // in-flight empty result.
            guard listViewModel.selection != nil else { return }
            await trackCandidateLoader.load()
        }
        .onChange(of: listViewModel.selectedPlaylist, initial: true) { _, playlist in
            synchronizeDetailViewModel(with: playlist)
        }
    }

    private func synchronizeDetailViewModel(with playlist: Playlist?) {
        guard let playlist else {
            detailViewModel = nil
            return
        }
        if let detailViewModel, detailViewModel.playlistID == playlist.id {
            detailViewModel.updatePlaylist(playlist)
            return
        }
        detailViewModel = PlaylistDetailViewModel(
            playlist: playlist,
            store: store,
            playback: playback
        )
    }
}
