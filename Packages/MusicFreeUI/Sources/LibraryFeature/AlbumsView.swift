import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

enum LibraryAlbumGridLayout {
    // Regression guard: album cards have different heights when a title wraps or
    // metadata is absent. SwiftUI's default grid-item alignment vertically centers
    // the shorter card and makes its artwork start lower than the neighboring one.
    // Keep every album-grid column explicitly top-aligned; do not remove `.top`.
    static let columns = [
        GridItem(.flexible(), spacing: MusicFreeSpacingTokens.large, alignment: .top),
        GridItem(.flexible(), spacing: MusicFreeSpacingTokens.large, alignment: .top),
    ]
}

struct AlbumsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let artworkServing: (any ArtworkServing)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool

    @State private var artistNames: [ArtistID: String] = [:]
    @State private var sortMode: AlbumSortMode = .title
    @State private var editMode: EditMode = .inactive
    @State private var selectedAlbumIDs: Set<AlbumID> = []
    @State private var pendingAlbumDeletionIDs: Set<AlbumID> = []
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        viewModel: LibraryViewModel,
        navigate: @escaping (LibraryDestination) -> Void,
        artworkServing: (any ArtworkServing)? = nil,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionPlaylistActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false }
    ) {
        self.viewModel = viewModel
        self.navigate = navigate
        self.artworkServing = artworkServing
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
        self.addCollectionToPlaylist = addCollectionToPlaylist
        self.isCollectionPlaylistActionPending = isCollectionPlaylistActionPending
    }

    var body: some View {
        LibraryContentState(
            state: viewModel.state(for: .albums),
            hasContent: !viewModel.albums.isEmpty,
            emptyTitle: L("暂无专辑"),
            emptyMessage: L("导入带有专辑信息的本地音频后会显示在这里。"),
            emptySystemImage: "square.stack",
            retry: { viewModel.retry(section: .albums) }
        ) {
            ScrollView {
                LazyVGrid(
                    columns: LibraryAlbumGridLayout.columns,
                    alignment: .leading,
                    spacing: MusicFreeSpacingTokens.xLarge
                ) {
                    ForEach(viewModel.albums) { album in
                        Button {
                            if isEditing {
                                toggleSelection(for: album.id)
                            } else {
                                navigate(.album(album.id))
                            }
                        } label: {
                            ZStack(alignment: .topLeading) {
                                LibraryAlbumGridTile(
                                    album: album,
                                    subtitle: albumSubtitle(album),
                                    artworkServing: artworkServing
                                )
                                if isEditing {
                                    Image(
                                        systemName: selectedAlbumIDs.contains(album.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .font(.title2)
                                    .foregroundStyle(
                                        selectedAlbumIDs.contains(album.id)
                                            ? MusicFreeColorTokens.accent
                                            : MusicFreeColorTokens.foregroundTertiary
                                    )
                                    .background(
                                        Circle()
                                            .fill(MusicFreeColorTokens.backgroundPrimary)
                                    )
                                    .padding(MusicFreeSpacingTokens.small)
                                    .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !isEditing {
                                let target = LibraryCollectionQueueTarget.album(album.id)
                                LibraryCollectionQueueMenuActions(
                                    target: target,
                                    accessibilityPrefix: "library.album.menu",
                                    enqueueNext: enqueueNextCollection,
                                    enqueue: enqueueCollection,
                                    addToPlaylist: addCollectionToPlaylist,
                                    isPending: isCollectionQueueActionPending(target)
                                        || isCollectionPlaylistActionPending(target)
                                )
                            }
                        }
                        .accessibilityLabel(Text(album.title))
                        .accessibilityValue(
                            Text(
                                isEditing
                                    ? (selectedAlbumIDs.contains(album.id)
                                        ? L("已选择")
                                        : L("未选择"))
                                    : L("专辑")
                            )
                        )
                        .accessibilityIdentifier(
                            "library.album.\(isEditing ? "select" : "open").\(album.id.rawValue)"
                        )
                        .accessibilityHint(
                            L(isEditing ? "选择专辑" : "打开专辑，按住显示播放队列操作")
                        )
                        .onAppear {
                            if album.id == viewModel.albums.last?.id {
                                viewModel.loadNextPage(for: .albums)
                            }
                        }
                    }

                    LibraryPageFooter(section: .albums, viewModel: viewModel)
                        .gridCellColumns(2)
                }
                .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                .padding(.vertical, MusicFreeSpacingTokens.medium)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isEditing, !selectedAlbumIDs.isEmpty {
                    LibraryBatchDeletionBar(
                        count: selectedAlbumIDs.count,
                        scope: .albums,
                        accessibilityIdentifier: "library.albums.deleteSelected",
                        isDisabled: isDeleting,
                        action: requestDeleteSelected
                    )
                }
                if horizontalSizeClass == .compact {
                    Color.clear
                        .frame(height: MusicFreeLayoutMetrics.compactTabAccessoryClearance)
                        .accessibilityHidden(true)
                }
            }
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.albums")
        }
        .environment(\.editMode, $editMode)
        .task(id: artistMetadataKey) {
            await loadArtistNames()
        }
        .onChange(of: sortMode) { _, mode in
            viewModel.setAlbumSort(mode.descriptor)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleEditing()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .accessibilityLabel(Text(isEditing ? L("完成编辑") : L("编辑专辑")))
                .help(isEditing ? L("完成编辑") : L("编辑专辑"))
                .accessibilityIdentifier("library.albums.edit")
                .disabled(viewModel.isLoading(.albums) || isDeleting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L("排序"), selection: $sortMode) {
                        ForEach(AlbumSortMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(L("排序专辑"))
                .accessibilityIdentifier("library.albums.sort")
                .disabled(isEditing || isDeleting)
            }
        }
        .batchDeletionPresentation(
            isPresented: pendingAlbumDeletionPresentation,
            count: pendingAlbumDeletionIDs.count,
            scope: .albums,
            isDeleting: isDeleting,
            action: {
                let albumIDs = pendingAlbumDeletionIDs
                pendingAlbumDeletionIDs.removeAll()
                deleteSelectedAlbums(albumIDs)
            }
        )
        .libraryDeletionErrorPresentation(errorMessage: $deletionErrorMessage)
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    private var pendingAlbumDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingAlbumDeletionIDs.isEmpty },
            set: { isPresented in
                if !isPresented { pendingAlbumDeletionIDs.removeAll() }
            }
        )
    }

    private func toggleEditing() {
        guard !viewModel.isLoading(.albums), !isDeleting else { return }
        if isEditing {
            editMode = .inactive
            selectedAlbumIDs.removeAll()
        } else {
            editMode = .active
        }
    }

    private func toggleSelection(for albumID: AlbumID) {
        guard isEditing, !isDeleting else { return }
        if !selectedAlbumIDs.insert(albumID).inserted {
            selectedAlbumIDs.remove(albumID)
        }
    }

    private func requestDeleteSelected() {
        guard isEditing, !isDeleting, !selectedAlbumIDs.isEmpty else { return }
        pendingAlbumDeletionIDs = selectedAlbumIDs
    }

    private func deleteSelectedAlbums(_ albumIDs: Set<AlbumID>) {
        guard !albumIDs.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                let targets = Set(albumIDs.map { LibraryCollectionQueueTarget.album($0) })
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: targets,
                    from: viewModel.library
                )
                if !itemIDs.isEmpty {
                    _ = try await viewModel.library.delete(itemIDs)
                    viewModel.removeDeletedTracks(itemIDs)
                }
                editMode = .inactive
                selectedAlbumIDs.removeAll()
                viewModel.load(section: .albums, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func albumSubtitle(_ album: Album) -> String? {
        let names = album.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var artistMetadataKey: String {
        viewModel.albums.flatMap(\.artistIDs).map(\.rawValue).joined(separator: "|")
    }

    private func loadArtistNames() async {
        let artistIDs = Set(viewModel.albums.flatMap(\.artistIDs))
        do {
            artistNames = try await LibraryArtistNameLoader.load(
                artistIDs: artistIDs,
                from: viewModel.library
            )
        } catch is CancellationError {
            return
        } catch {
            artistNames = [:]
        }
    }
}

private enum AlbumSortMode: String, CaseIterable, Identifiable {
    case title
    case artist
    case dateAdded
    case year
    case trackCount

    var id: Self { self }

    var title: String {
        switch self {
        case .title: return L("专辑名称")
        case .artist: return L("艺人")
        case .dateAdded: return L("最近添加")
        case .year: return L("发行年份")
        case .trackCount: return L("歌曲数量")
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "person"
        case .dateAdded: return "clock"
        case .year: return "calendar"
        case .trackCount: return "music.note.list"
        }
    }

    var descriptor: AlbumSortDescriptor {
        switch self {
        case .title:
            return AlbumSortDescriptor(key: .title)
        case .artist:
            return AlbumSortDescriptor(key: .artistName)
        case .dateAdded:
            return AlbumSortDescriptor(key: .dateAdded, direction: .descending)
        case .year:
            return AlbumSortDescriptor(key: .year, direction: .descending)
        case .trackCount:
            return AlbumSortDescriptor(key: .trackCount, direction: .descending)
        }
    }
}

struct LibraryAlbumGridTile: View {
    let album: Album
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            albumArtwork

            Text(album.title)
                .font(MusicFreeTypographyTokens.rowTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle {
                Text(subtitle)
                    .font(MusicFreeTypographyTokens.rowSubtitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: loadKey) {
            await artworkLoader.load(
                artworkID: album.artworkID,
                sourceID: .local,
                serving: artworkServing
            )
        }
    }

    private var loadKey: String {
        "\(MediaSourceID.local.rawValue):\(album.artworkID?.rawValue ?? "")"
    }

    private var albumArtwork: some View {
        Rectangle()
            .fill(.clear)
            .aspectRatio(MusicFreeLayoutMetrics.artworkAspectRatio, contentMode: .fit)
            .overlay {
                ArtworkView(
                    image: artworkLoader.image,
                    accessibilityLabel: L("%@ album artwork", album.title),
                    placeholderTitle: album.title,
                    fillsAvailableWidth: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}
