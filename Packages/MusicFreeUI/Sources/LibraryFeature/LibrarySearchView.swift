import DesignSystem
import AppServices
import MusicDomain
import SwiftUI

struct LibrarySearchView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let section: LibrarySection
    let navigate: (LibraryDestination) -> Void
    let playTrack: ((MediaItemID) -> Void)?
    let playTracks: (([MediaItemID], Bool) -> Void)?
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let artworkServing: (any ArtworkServing)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let addTracksToPlaylist: (([MediaItemID]) -> Void)?
    let addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool
    let compactRoute: ((LibraryDestination) -> LibraryCompactRoute)?

    init(
        viewModel: LibraryViewModel,
        section: LibrarySection,
        navigate: @escaping (LibraryDestination) -> Void,
        playTrack: ((MediaItemID) -> Void)?,
        playTracks: (([MediaItemID], Bool) -> Void)?,
        enqueueNextTracks: (([MediaItemID]) -> Void)?,
        enqueueTracks: (([MediaItemID]) -> Void)?,
        artworkServing: (any ArtworkServing)?,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        addTracksToPlaylist: (([MediaItemID]) -> Void)? = nil,
        addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionPlaylistActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        compactRoute: ((LibraryDestination) -> LibraryCompactRoute)? = nil
    ) {
        self.viewModel = viewModel
        self.section = section
        self.navigate = navigate
        self.playTrack = playTrack
        self.playTracks = playTracks
        self.enqueueNextTracks = enqueueNextTracks
        self.enqueueTracks = enqueueTracks
        self.artworkServing = artworkServing
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
        self.addTracksToPlaylist = addTracksToPlaylist
        self.addCollectionToPlaylist = addCollectionToPlaylist
        self.isCollectionPlaylistActionPending = isCollectionPlaylistActionPending
        self.compactRoute = compactRoute
    }

    var body: some View {
        Group {
            switch section {
            case .tracks, .favorites:
                TracksView(
                    viewModel: viewModel,
                    section: section,
                    navigate: navigate,
                    playTrack: playTrack,
                    playTracks: playTracks,
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addTracksToPlaylist,
                    artworkServing: artworkServing
                )
            case .recent:
                PlaybackHistoryView(
                    viewModel: viewModel,
                    playTrack: playTrack,
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addTracksToPlaylist,
                    artworkServing: artworkServing
                )
            case .albums:
                AlbumsView(
                    viewModel: viewModel,
                    navigate: navigate,
                    artworkServing: artworkServing,
                    enqueueNextCollection: enqueueNextCollection,
                    enqueueCollection: enqueueCollection,
                    isCollectionQueueActionPending: isCollectionQueueActionPending,
                    addCollectionToPlaylist: addCollectionToPlaylist,
                    isCollectionPlaylistActionPending: isCollectionPlaylistActionPending
                )
            case .artists:
                ArtistsView(
                    viewModel: viewModel,
                    navigate: navigate,
                    artworkServing: artworkServing,
                    enqueueNextCollection: enqueueNextCollection,
                    enqueueCollection: enqueueCollection,
                    isCollectionQueueActionPending: isCollectionQueueActionPending,
                    compactRoute: compactRoute
                )
            case .genres:
                GenresView(
                    viewModel: viewModel,
                    navigate: navigate,
                    enqueueNextCollection: enqueueNextCollection,
                    enqueueCollection: enqueueCollection,
                    isCollectionQueueActionPending: isCollectionQueueActionPending,
                    addCollectionToPlaylist: addCollectionToPlaylist,
                    isCollectionPlaylistActionPending: isCollectionPlaylistActionPending,
                    compactRoute: compactRoute
                )
            case .folders:
                FoldersView(
                    viewModel: viewModel,
                    navigate: navigate,
                    enqueueNextCollection: enqueueNextCollection,
                    enqueueCollection: enqueueCollection,
                    isCollectionQueueActionPending: isCollectionQueueActionPending
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: section) {
            if viewModel.selection != section {
                viewModel.select(section)
            }
            await viewModel.prepareForFirstLoad(of: section)
        }
        .refreshable {
            await viewModel.refreshCheckingForImports(section: section)
        }
    }
}

struct LibraryContentState<Content: View>: View {
    let state: LibraryLoadState
    let hasContent: Bool
    let emptyTitle: String
    let emptyMessage: String
    let emptySystemImage: String
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if hasContent {
            LoadingStateView(isLoading: state == .loading) {
                content()
            }
        } else {
            switch state {
            case .idle, .loading:
                ProgressView(L("正在加载"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                EmptyStateView(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: emptySystemImage
                )
            case .failed(let message):
                ErrorStateView(
                    title: L("资料库加载失败"),
                    message: message,
                    retryTitle: L("重试"),
                    retry: retry
                )
            case .loaded:
                EmptyStateView(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: emptySystemImage
                )
            }
        }
    }
}

struct LibraryPageFooter: View {
    let section: LibrarySection
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Group {
            if viewModel.isLoading(section) && viewModel.itemsCountForView(section) > 0 {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else if let error = viewModel.paginationError(for: section) {
                Button {
                    viewModel.retry(section: section)
                } label: {
                    Label(L("加载下一页失败"), systemImage: "arrow.clockwise")
                }
                .foregroundStyle(MusicFreeColorTokens.destructive)
                .accessibilityHint(Text(error))
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            } else if viewModel.hasNextPage(for: section) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .onAppear { viewModel.loadNextPage(for: section) }
            }
        }
    }
}

extension LibraryViewModel {
    fileprivate func itemsCountForView(_ section: LibrarySection) -> Int {
        switch section {
        case .tracks: return tracks.count
        case .favorites: return favoriteTracks.count
        case .recent: return playbackHistory.count
        case .albums: return albums.count
        case .artists: return artists.count
        case .genres: return genres.count
        case .folders: return folders.count
        }
    }
}
