import AppServices
import DesignSystem
import MusicDomain
import SwiftUI

public struct LibraryScene: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel: LibraryViewModel
    @Binding private var externalSelection: LibrarySection
    private let navigationAction: (LibraryDestination) -> Void
    private let artworkServing: (any ArtworkServing)?
    private let playTrack: ((MediaItemID) -> Void)?
    private let playTracks: (([MediaItemID], Bool) -> Void)?
    private let enqueueNextTracks: (([MediaItemID]) -> Void)?
    private let enqueueTracks: (([MediaItemID]) -> Void)?
    private let playlistServing: (any PlaylistServing)?
    @State private var isImportPickerPresented = false
    @State private var compactPath: [LibraryCompactRoute] = []
    @State private var resolvedAlbums: [AlbumID: Album] = [:]
    @State private var pendingCollectionQueueTargets: Set<LibraryCollectionQueueTarget> = []
    @State private var pendingCollectionPlaylistTargets: Set<LibraryCollectionQueueTarget> = []
    @State private var collectionQueueErrorMessage: String?
    @State private var collectionPlaylistErrorMessage: String?
    @State private var addToPlaylistRequest: LibraryAddToPlaylistRequest?

    public init() {
        self.init(library: UnconfiguredLibraryServing())
    }

    public init(
        library: any LibraryServing,
        importer: (any ImportServing)? = nil,
        refreshPreparation: (@MainActor @Sendable () async -> Void)? = nil,
        artworkServing: (any ArtworkServing)? = nil,
        selection: Binding<LibrarySection> = .constant(.tracks),
        navigationAction: @escaping (LibraryDestination) -> Void = { _ in },
        playTrack: ((MediaItemID) -> Void)? = nil,
        playTracks: (([MediaItemID], Bool) -> Void)? = nil,
        enqueueNextTracks: (([MediaItemID]) -> Void)? = nil,
        enqueueTracks: (([MediaItemID]) -> Void)? = nil,
        playlistServing: (any PlaylistServing)? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: LibraryViewModel(
                library: library,
                importer: importer,
                refreshPreparation: refreshPreparation,
                selection: selection.wrappedValue
            )
        )
        _externalSelection = selection
        self.navigationAction = navigationAction
        self.artworkServing = artworkServing
        self.playTrack = playTrack
        self.playTracks = playTracks
        self.enqueueNextTracks = enqueueNextTracks
        self.enqueueTracks = enqueueTracks
        self.playlistServing = playlistServing
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularContent
            } else {
                compactContent
            }
        }
        .task(id: horizontalSizeClass) {
            await viewModel.startObservingChanges()
            guard !Task.isCancelled else { return }

            // Existing persisted content should not wait for a Documents hash
            // and metadata pass. The change stream refreshes these views if the
            // concurrent scan imports anything new.
            if horizontalSizeClass == .regular {
                viewModel.loadIfNeeded(for: externalSelection)
            } else {
                viewModel.loadOverviewIfNeeded()
            }
            await viewModel.prepareForInitialLoad()
        }
        .onDisappear {
            viewModel.stopObservingChanges()
        }
        .onChange(of: externalSelection) { _, value in
            if viewModel.selection != value {
                viewModel.select(value)
            }
        }
        .onChange(of: viewModel.selection) { _, value in
            if externalSelection != value {
                externalSelection = value
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0, content: importStatus)
        .mediaImportPicker(
            isPresented: $isImportPickerPresented,
            onSelection: { urls in
                await viewModel.startImport(urls: urls)
            },
            onFailure: viewModel.handlePickerFailure
        )
        .sheet(item: $addToPlaylistRequest) { request in
            if let playlistServing {
                LibraryAddToPlaylistSheet(
                    itemIDs: request.itemIDs,
                    playlistServing: playlistServing
                )
            }
        }
        .alert(
            L("无法更新播放队列"),
            isPresented: Binding(
                get: { collectionQueueErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { collectionQueueErrorMessage = nil }
                }
            )
        ) {
            Button(L("好"), role: .cancel) {
                collectionQueueErrorMessage = nil
            }
        } message: {
            Text(collectionQueueErrorMessage ?? L("请稍后重试。"))
        }
        .alert(
            L("无法添加到播放列表"),
            isPresented: Binding(
                get: { collectionPlaylistErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { collectionPlaylistErrorMessage = nil }
                }
            )
        ) {
            Button(L("好"), role: .cancel) {
                collectionPlaylistErrorMessage = nil
            }
        } message: {
            Text(collectionPlaylistErrorMessage ?? L("请稍后重试。"))
        }
    }

    private var regularContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
    }

    private var compactContent: some View {
        NavigationStack(path: $compactPath) {
            LibraryHomeView(
                viewModel: viewModel,
                openAlbum: { openCompact(.album($0)) },
                importAction: { isImportPickerPresented = true },
                artworkServing: artworkServing
            )
            .navigationDestination(for: LibraryCompactRoute.self) { route in
                compactDestination(route)
            }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            ForEach(LibrarySectionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        sectionRow(section)
                    }
                }
            }
        }
        .navigationTitle(L("资料库"))
        .searchable(text: searchBinding, prompt: L("搜索歌曲、专辑或艺人"))
        .toolbar { importToolbarItem }
    }

    private var sidebarSelectionBinding: Binding<LibrarySection?> {
        Binding(
            get: { viewModel.selection },
            set: { newValue in
                guard let newValue else { return }
                viewModel.select(newValue)
            }
        )
    }

    @ViewBuilder
    private var importToolbarItem: some View {
        if viewModel.canImport {
            Button {
                isImportPickerPresented = true
            } label: {
                Label(L("导入"), systemImage: "square.and.arrow.down")
            }
            .help(L("导入本地媒体"))
        }
    }

    private func sectionRow(_ section: LibrarySection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    private var detail: some View {
        NavigationStack(path: navigationPathBinding) {
            LibrarySearchView(
                viewModel: viewModel,
                section: viewModel.selection,
                navigate: open,
                playTrack: playTrack,
                playTracks: playTracks,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                artworkServing: artworkServing,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                addTracksToPlaylist: addTracksToPlaylist,
                addCollectionToPlaylist: addCollectionToPlaylist,
                isCollectionPlaylistActionPending: isCollectionPlaylistActionPending
                )
                .navigationTitle(viewModel.selection.title)
                .navigationDestination(for: LibraryDestination.self) { destination in
                    destinationView(destination, navigate: open)
                }
        }
    }

    private var navigationPathBinding: Binding<[LibraryDestination]> {
        Binding(
            get: { viewModel.navigationPath },
            set: { viewModel.updateNavigationPath($0) }
        )
    }

    @ViewBuilder
    private func importStatus() -> some View {
        if !viewModel.importState.isIdle {
            ImportProgressView(
                state: viewModel.importState,
                cancel: viewModel.cancelImport,
                dismiss: viewModel.dismissImport
            )
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { viewModel.updateSearchText($0) }
        )
    }

    private func open(_ destination: LibraryDestination) {
        viewModel.navigate(to: destination)
        navigationAction(destination)
    }

    private func openCompact(_ destination: LibraryDestination) {
        compactPath.append(.destination(destination))
        navigationAction(destination)
    }

    @ViewBuilder
    private func compactDestination(_ route: LibraryCompactRoute) -> some View {
        switch route {
        case .section(let section):
            LibrarySearchView(
                viewModel: viewModel,
                section: section,
                navigate: openCompact,
                playTrack: playTrack,
                playTracks: playTracks,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                artworkServing: artworkServing,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                addTracksToPlaylist: addTracksToPlaylist,
                addCollectionToPlaylist: addCollectionToPlaylist,
                isCollectionPlaylistActionPending: isCollectionPlaylistActionPending,
                compactRoute: { .destination($0) }
            )
            .navigationTitle(section.title)
            .searchable(text: searchBinding, prompt: L("搜索%@", section.title))
        case .destination(let destination):
            destinationView(destination, navigate: openCompact)
        }
    }

    @ViewBuilder
    private func destinationView(
        _ destination: LibraryDestination,
        navigate: @escaping (LibraryDestination) -> Void
    ) -> some View {
        switch destination {
        case .track(let trackID):
            LibraryTrackDetailView(
                trackID: trackID,
                library: viewModel.library,
                playTrack: playTrack,
                addToPlaylist: addTracksToPlaylist,
                artworkServing: artworkServing
            )
        case .album(let albumID):
            let album = resolvedAlbums[albumID]
                ?? viewModel.albums.first(where: { $0.id == albumID })
                ?? viewModel.recentAlbums.first(where: { $0.id == albumID })
            LibraryCollectionDetailView(
                kind: .album(albumID),
                title: album?.title,
                album: album,
                library: viewModel.library,
                playTracks: playTracks,
                playTrack: playTrack,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                addTracksToPlaylist: addTracksToPlaylist,
                addCollectionToPlaylist: addCollectionToPlaylist,
                isCollectionPlaylistActionPending: isCollectionPlaylistActionPending,
                artworkServing: artworkServing,
                navigate: navigate,
                removeDeletedTracks: { itemIDs in
                    viewModel.removeDeletedTracks(itemIDs)
                }
            )
        case .artist(let artistID):
            LibraryArtistDetailView(
                artistID: artistID,
                artist: viewModel.artists.first(where: { $0.id == artistID }),
                library: viewModel.library,
                playTracks: playTracks,
                playTrack: playTrack,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                artworkServing: artworkServing,
                openAlbum: { album in
                    resolvedAlbums[album.id] = album
                    navigate(.album(album.id))
                }
            )
        case .genre(let genreID):
            LibraryCollectionDetailView(
                kind: .genre(genreID),
                title: viewModel.genres.first(where: { $0.id == genreID })?.name,
                album: nil,
                library: viewModel.library,
                playTracks: playTracks,
                playTrack: playTrack,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                addTracksToPlaylist: addTracksToPlaylist,
                addCollectionToPlaylist: addCollectionToPlaylist,
                isCollectionPlaylistActionPending: isCollectionPlaylistActionPending,
                artworkServing: artworkServing,
                navigate: navigate,
                removeDeletedTracks: { itemIDs in
                    viewModel.removeDeletedTracks(itemIDs)
                }
            )
        case .folder(let path):
            LibraryFolderDetailView(
                path: path,
                library: viewModel.library,
                playTracks: playTracks,
                playTrack: playTrack,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                enqueueNextCollection: enqueueNextCollection,
                enqueueCollection: enqueueCollection,
                isCollectionQueueActionPending: isCollectionQueueActionPending,
                artworkServing: artworkServing,
                navigate: navigate,
                removeDeletedTracks: { itemIDs in
                    viewModel.removeDeletedTracks(itemIDs)
                }
            )
        }
    }

    private var enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? {
        guard enqueueNextTracks != nil else { return nil }
        return { target in
            performCollectionQueueAction(target, placement: .next)
        }
    }

    private var enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? {
        guard enqueueTracks != nil else { return nil }
        return { target in
            performCollectionQueueAction(target, placement: .end)
        }
    }

    private var isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool {
        { pendingCollectionQueueTargets.contains($0) }
    }

    private var addTracksToPlaylist: (([MediaItemID]) -> Void)? {
        guard playlistServing != nil else { return nil }
        return { itemIDs in
            let uniqueIDs = uniqueItemIDs(itemIDs)
            guard !uniqueIDs.isEmpty else { return }
            addToPlaylistRequest = LibraryAddToPlaylistRequest(itemIDs: uniqueIDs)
        }
    }

    private var addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)? {
        guard playlistServing != nil else { return nil }
        return { target in
            performCollectionPlaylistAction(target)
        }
    }

    private var isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool {
        { pendingCollectionPlaylistTargets.contains($0) }
    }

    private func performCollectionQueueAction(
        _ target: LibraryCollectionQueueTarget,
        placement: LibraryCollectionQueuePlacement
    ) {
        let action = placement == .next ? enqueueNextTracks : enqueueTracks
        guard let action,
              pendingCollectionQueueTargets.insert(target).inserted
        else { return }

        Task { @MainActor in
            defer { pendingCollectionQueueTargets.remove(target) }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: target,
                    from: viewModel.library
                )
                guard !itemIDs.isEmpty else {
                    collectionQueueErrorMessage = L("这个集合没有可加入播放队列的歌曲。")
                    return
                }
                action(itemIDs)
            } catch is CancellationError {
                return
            } catch {
                collectionQueueErrorMessage = error.localizedDescription
            }
        }
    }

    private func performCollectionPlaylistAction(_ target: LibraryCollectionQueueTarget) {
        guard playlistServing != nil,
              pendingCollectionPlaylistTargets.insert(target).inserted
        else { return }

        Task { @MainActor in
            defer { pendingCollectionPlaylistTargets.remove(target) }
            do {
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: target,
                    from: viewModel.library
                )
                guard !itemIDs.isEmpty else {
                    collectionPlaylistErrorMessage = L("这个集合没有可添加到播放列表的歌曲。")
                    return
                }
                addToPlaylistRequest = LibraryAddToPlaylistRequest(itemIDs: itemIDs)
            } catch is CancellationError {
                return
            } catch {
                collectionPlaylistErrorMessage = error.localizedDescription
            }
        }
    }

    private func uniqueItemIDs(_ itemIDs: [MediaItemID]) -> [MediaItemID] {
        var seen = Set<MediaItemID>()
        return itemIDs.filter { seen.insert($0).inserted }
    }
}
