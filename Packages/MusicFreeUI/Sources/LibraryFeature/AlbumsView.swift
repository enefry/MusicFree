import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI
import UIKit

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
    @State private var isEditing = false
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
            albumCollection
        }
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
        }
        .task(id: artistMetadataKey) {
            await loadArtistNames()
        }
        .onChange(of: sortMode) { _, mode in
            viewModel.setAlbumSort(mode.descriptor)
        }
        .navigationBarItems(
            trailing: HStack(spacing: MusicFreeSpacingTokens.medium) {
                if isEditing {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择专辑")))
                    .accessibilityIdentifier("library.albums.finishSelection")
                    .disabled(isDeleting)
                }

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
        )
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

    private var albumCollection: some View {
        NativeLibraryCollectionView(
            sections: [
                NativeLibraryCollectionSection(
                    id: "library.albums",
                    headerTitle: nil,
                    items: viewModel.albums.map { album in
                        NativeLibraryCollectionItem(
                            id: album.id.rawValue,
                            accessibilityLabel: album.title,
                            accessibilityHint: L("打开专辑，按住显示更多操作"),
                            accessibilityValue: albumSubtitle(album)
                        )
                    }
                )
            ],
            layout: .grid(columns: 2),
            header: nil,
            footer: viewModel.shouldShowPageFooter(for: .albums)
                ? AnyView(LibraryPageFooter(section: .albums, viewModel: viewModel))
                : nil,
            optionsAccessibilityPrefix: "library.album",
            isEditing: isEditing,
            selectedIDs: Set(selectedAlbumIDs.map(\.rawValue)),
            // Existing rows remain interactive while a later page is loading.
            // Disabling them here makes UIKit reject cells crossed by a fast
            // two-finger selection gesture at the pagination boundary.
            isDisabled: isDeleting,
            rowContent: { item, editing, selected in
                guard let album = album(for: item.id) else {
                    return AnyView(EmptyView())
                }
                return AnyView(
                    ZStack(alignment: .topLeading) {
                        LibraryAlbumGridTile(
                            album: album,
                            subtitle: albumSubtitle(album),
                            artworkServing: artworkServing
                        )
                        if editing {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(
                                    selected
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
                )
            },
            activateAction: { item in
                if let album = album(for: item.id) {
                    navigate(.album(album.id))
                }
            },
            contextMenu: { item in
                guard let album = album(for: item.id) else { return nil }
                return contextMenu(for: album)
            },
            shareText: { item in album(for: item.id)?.title },
            onSelectionChanged: { ids in
                selectedAlbumIDs = Set(ids.map { AlbumID($0) })
            },
            onEditingChanged: { editing in
                if editing {
                    isEditing = true
                } else {
                    finishEditing()
                }
            },
            onLastItemDisplayed: { itemID in
                guard itemID == viewModel.albums.last?.id.rawValue else { return }
                viewModel.loadNextPage(for: .albums)
            }
        )
        .background(MusicFreeColorTokens.backgroundPrimary)
        .accessibilityIdentifier("library.albums")
    }

    private var pendingAlbumDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingAlbumDeletionIDs.isEmpty },
            set: { isPresented in
                if !isPresented { pendingAlbumDeletionIDs.removeAll() }
            }
        )
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedAlbumIDs.removeAll()
    }

    private func album(for rawID: String) -> Album? {
        viewModel.albums.first { $0.id.rawValue == rawID }
    }

    private func requestDeleteSelected() {
        guard !isDeleting, !selectedAlbumIDs.isEmpty else { return }
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
                finishEditing()
                viewModel.load(section: .albums, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func contextMenu(for album: Album) -> NativeLibraryContextMenuContents {
        let target = LibraryCollectionQueueTarget.album(album.id)
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: isDeleting ? [.disabled, .destructive] : [.destructive]
        ) { _ in
            guard !isDeleting else { return }
            pendingAlbumDeletionIDs = [album.id]
        }

        var secondaryActions: [UIMenuElement] = [
            UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: enqueueNextCollection == nil
                    || isCollectionQueueActionPending(target)
                    ? [.disabled]
                    : []
            ) { _ in enqueueNextCollection?(target) },
            UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                attributes: enqueueCollection == nil
                    || isCollectionQueueActionPending(target)
                    ? [.disabled]
                    : []
            ) { _ in enqueueCollection?(target) }
        ]
        if addCollectionToPlaylist != nil {
            secondaryActions.append(
                UIAction(
                    title: L("添加到播放列表"),
                    image: UIImage(systemName: "text.badge.plus"),
                    attributes: isCollectionPlaylistActionPending(target) ? [.disabled] : []
                ) { _ in addCollectionToPlaylist?(target) }
            )
        }

        return NativeLibraryContextMenuContents(
            primaryActions: [delete],
            secondaryActions: secondaryActions
        )
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
                sourceID: .local,
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
