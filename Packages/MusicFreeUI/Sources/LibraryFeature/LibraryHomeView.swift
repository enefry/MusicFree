import AppServices
import DesignSystem
import MusicDomain
import SwiftUI

enum LibraryCompactRoute: Hashable {
    case section(LibrarySection)
    case destination(LibraryDestination)
}

enum LibraryHomeItem: String, CaseIterable, Identifiable {
    case artists
    case albums
    case tracks
    case favorites
    case recent
    case genres
    case folders

    var id: Self { self }

    var title: String {
        switch self {
        case .artists: return LibrarySection.artists.title
        case .albums: return LibrarySection.albums.title
        case .tracks: return LibrarySection.tracks.title
        case .favorites: return LibrarySection.favorites.title
        case .recent: return LibrarySection.recent.title
        case .genres: return LibrarySection.genres.title
        case .folders: return LibrarySection.folders.title
        }
    }

    var systemImage: String {
        switch self {
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .tracks: return "music.note"
        case .favorites: return "star"
        case .recent: return LibrarySection.recent.systemImage
        case .genres: return LibrarySection.genres.systemImage
        case .folders: return LibrarySection.folders.systemImage
        }
    }

    var section: LibrarySection {
        switch self {
        case .artists: return .artists
        case .albums: return .albums
        case .tracks: return .tracks
        case .favorites: return .favorites
        case .recent: return .recent
        case .genres: return .genres
        case .folders: return .folders
        }
    }
}

struct LibraryHomeView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let openAlbum: (AlbumID) -> Void
    let importAction: () -> Void
    let artworkServing: (any ArtworkServing)?

    @State private var artistNames: [ArtistID: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach(LibraryHomeItem.allCases) { item in
                    homeRow(item)
                }
            }

            Section {
                overviewContent
            } header: {
                Text("最近添加")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .textCase(nil)
                    .padding(.top, MusicFreeSpacingTokens.small)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundPrimary)
        .navigationTitle("资料库")
        .toolbarTitleDisplayMode(.inlineLarge)
        .accessibilityIdentifier("library.home")
        .toolbar { libraryToolbar }
        .refreshable {
            await viewModel.refreshOverviewCheckingForImports()
        }
        .task { viewModel.loadOverviewIfNeeded() }
        .task(id: recentArtistMetadataKey) {
            await loadRecentArtistNames()
        }
    }

    private func homeRow(_ item: LibraryHomeItem) -> some View {
        NavigationLink(value: LibraryCompactRoute.section(item.section)) {
            rowLabel(item)
        }
        .accessibilityHint("打开\(item.title)")
        .listRowInsets(
            EdgeInsets(
                top: MusicFreeSpacingTokens.xSmall,
                leading: MusicFreeSpacingTokens.contentInset,
                bottom: MusicFreeSpacingTokens.xSmall,
                trailing: MusicFreeSpacingTokens.contentInset
            )
        )
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(MusicFreeColorTokens.separator.opacity(0.72))
    }

    private func rowLabel(_ item: LibraryHomeItem) -> some View {
        Label {
            Text(item.title)
                .font(MusicFreeTypographyTokens.rowTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
        } icon: {
            Image(systemName: item.systemImage)
                .font(.title3)
                .foregroundStyle(MusicFreeColorTokens.accent)
                .frame(width: MusicFreeSpacingTokens.xxLarge, alignment: .center)
        }
        .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var overviewContent: some View {
        if !viewModel.recentAlbums.isEmpty {
            LazyVGrid(
                columns: LibraryAlbumGridLayout.columns,
                alignment: .leading,
                spacing: MusicFreeSpacingTokens.xLarge
            ) {
                ForEach(viewModel.recentAlbums) { album in
                    Button {
                        openAlbum(album.id)
                    } label: {
                        RecentAlbumTile(
                            album: album,
                            subtitle: albumSubtitle(album),
                            artworkServing: artworkServing
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开专辑")
                }
            }
            .padding(.vertical, MusicFreeSpacingTokens.small)
            .listRowSeparator(.hidden)
        } else {
            overviewPlaceholder
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var overviewPlaceholder: some View {
        switch viewModel.overviewState {
        case .idle, .loading:
            HStack(spacing: MusicFreeSpacingTokens.small) {
                ProgressView()
                Text("正在载入最近添加")
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        case .empty, .loaded:
            HStack(spacing: MusicFreeSpacingTokens.medium) {
                Image(systemName: "square.stack")
                    .font(.title2)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

                VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                    Text("暂无最近添加")
                        .font(MusicFreeTypographyTokens.sectionTitle)
                        .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    Text("导入本地音乐后，最近加入的专辑会显示在这里。")
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        case .failed:
            Button {
                viewModel.refreshOverview()
            } label: {
                Label("无法载入最近添加，点击重试", systemImage: "arrow.clockwise")
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumSubtitle(_ album: Album) -> String? {
        let names = album.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var recentArtistMetadataKey: String {
        viewModel.recentAlbums.flatMap(\.artistIDs).map(\.rawValue).joined(separator: "|")
    }

    private func loadRecentArtistNames() async {
        let artistIDs = Set(viewModel.recentAlbums.flatMap(\.artistIDs))
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

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.canImport {
                ControlGroup {
                    Button(action: importAction) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入本地媒体")

                    libraryMenu
                }
            } else {
                libraryMenu
            }
        }
    }

    private var libraryMenu: some View {
        Menu {
            Button {
                Task {
                    await viewModel.refreshOverviewCheckingForImports()
                }
            } label: {
                Label("刷新资料库", systemImage: "arrow.clockwise")
            }

            if viewModel.canImport {
                Button(action: importAction) {
                    Label("导入本地媒体", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("资料库选项")
    }
}

private struct RecentAlbumTile: View {
    let album: Album
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: "\(album.title)的专辑封面",
                placeholderSystemImage: "music.note",
                placeholderTitle: album.title,
                fillsAvailableWidth: true
            )

            Text(album.title)
                .font(MusicFreeTypographyTokens.rowTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
