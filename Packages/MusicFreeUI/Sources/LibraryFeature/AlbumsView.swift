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
            emptyTitle: "暂无专辑",
            emptyMessage: "导入带有专辑信息的本地音频后会显示在这里。",
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
                            navigate(.album(album.id))
                        } label: {
                            LibraryAlbumGridTile(
                                album: album,
                                subtitle: albumSubtitle(album),
                                artworkServing: artworkServing
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
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
                        .accessibilityHint("打开专辑，按住显示播放队列操作")
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
                if horizontalSizeClass == .compact {
                    Color.clear
                        .frame(height: MusicFreeLayoutMetrics.compactTabAccessoryClearance)
                        .accessibilityHidden(true)
                }
            }
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.albums")
        }
        .task(id: artistMetadataKey) {
            await loadArtistNames()
        }
        .onChange(of: sortMode) { _, mode in
            viewModel.setAlbumSort(mode.descriptor)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sortMode) {
                        ForEach(AlbumSortMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("排序专辑")
                .accessibilityIdentifier("library.albums.sort")
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
        case .title: return "专辑名称"
        case .artist: return "艺人"
        case .dateAdded: return "最近添加"
        case .year: return "发行年份"
        case .trackCount: return "歌曲数量"
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
                    accessibilityLabel: "\(album.title)的专辑封面",
                    placeholderTitle: album.title,
                    fillsAvailableWidth: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}
