import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

/// Artist details are album-first, matching the way Apple Music presents an
/// artist's catalog. Track loading is kept solely for the two playback actions.
struct LibraryArtistDetailView: View {
    let artistID: ArtistID
    let artist: Artist?
    let library: any LibraryServing
    let playTracks: (([MediaItemID], Bool) -> Void)?
    let playTrack: ((MediaItemID) -> Void)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let artworkServing: (any ArtworkServing)?
    let openAlbum: (Album) -> Void

    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failureMessage: String?
    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载艺人"))
            } else if let failureMessage {
                ErrorStateView(
                    title: L("艺人加载失败"),
                    message: failureMessage,
                    retryTitle: L("重试"),
                    retry: { Task { await load() } }
                )
            } else {
                ScrollView {
                    VStack(spacing: MusicFreeSpacingTokens.xLarge) {
                        artistHeader

                        if albums.isEmpty {
                            EmptyStateView(
                                title: L("暂无专辑"),
                                message: L("这个艺人暂时没有专辑。"),
                                systemImage: "square.stack"
                            )
                        } else {
                            albumGrid
                        }
                    }
                    .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                    .padding(.vertical, MusicFreeSpacingTokens.large)
                }
                .scrollIndicators(.hidden)
                .background(MusicFreeColorTokens.backgroundPrimary)
            }
        }
        .accessibilityIdentifier("library.artistDetail")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryCollectionQueueMenuActions(
                        target: artistQueueTarget,
                        accessibilityPrefix: "library.artistDetail.menu",
                        enqueueNext: enqueueNextCollection,
                        enqueue: enqueueCollection,
                        isPending: isCollectionQueueActionPending(artistQueueTarget)
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L("艺人选项"))
                .accessibilityIdentifier("library.artistDetail.menu")
            }
        }
        .task(id: artistID) { await load() }
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: artist?.artworkID,
                sourceID: .local,
                serving: artworkServing
            )
        }
    }

    private var artistHeader: some View {
        VStack(spacing: MusicFreeSpacingTokens.medium) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: L("%@ artist image", artistName),
                placeholderSystemImage: "person.fill",
                placeholderTitle: artistName,
                fillsAvailableWidth: true
            )
            .frame(width: 144, height: 144)
            .clipShape(Circle())
            .accessibilityIdentifier("library.artist.header.artwork")

            Text(artistName)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("library.artist.header.title")

            MusicFreeDetailActionBar(
                isEnabled: canPlay,
                playAccessibilityIdentifier: "library.artist.play",
                shuffleAccessibilityIdentifier: "library.artist.shuffle",
                playAction: { playAll(shuffle: false) },
                shuffleAction: { playAll(shuffle: true) }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var albumGrid: some View {
        LazyVGrid(
            columns: LibraryAlbumGridLayout.columns,
            alignment: .leading,
            spacing: MusicFreeSpacingTokens.xLarge
        ) {
            ForEach(albums) { album in
                Button {
                    openAlbum(album)
                } label: {
                    LibraryAlbumGridTile(
                        album: album,
                        subtitle: album.releaseYear.map { String($0) },
                        artworkServing: artworkServing
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.artist.album.\(album.id.rawValue)")
                .contextMenu {
                    let target = LibraryCollectionQueueTarget.album(album.id)
                    LibraryCollectionQueueMenuActions(
                        target: target,
                        accessibilityPrefix: "library.artist.album.menu",
                        enqueueNext: enqueueNextCollection,
                        enqueue: enqueueCollection,
                        isPending: isCollectionQueueActionPending(target)
                    )
                }
                .accessibilityHint(L("打开专辑，按住显示播放队列操作"))
            }
        }
        .accessibilityIdentifier("library.artist.albums")
    }

    private var artistName: String {
        artist?.name ?? L("艺人详情")
    }

    private var artworkKey: String {
        "\(artistID.rawValue):\(artist?.artworkID?.rawValue ?? "")"
    }

    private var artistQueueTarget: LibraryCollectionQueueTarget {
        .artist(artistID)
    }

    private var canPlay: Bool {
        !tracks.isEmpty && (playTracks != nil || playTrack != nil)
    }

    @MainActor
    private func load() async {
        isLoading = true
        failureMessage = nil
        do {
            let request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            async let albumPage = library.browseAlbums(
                matching: AlbumQuery(sourceID: .local, artistID: artistID),
                page: request
            )
            async let trackPage = library.browseTracks(
                matching: TrackQuery(sourceID: .local, artistID: artistID),
                page: request
            )
            let (loadedAlbums, loadedTracks) = try await (albumPage, trackPage)
            albums = loadedAlbums.elements
            tracks = loadedTracks.elements
        } catch is CancellationError {
            return
        } catch {
            albums = []
            tracks = []
            failureMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playAll(shuffle: Bool) {
        guard let firstTrack = tracks.first else { return }
        if let playTracks {
            playTracks(tracks.map(\.id), shuffle)
        } else {
            playTrack?(firstTrack.id)
        }
    }
}
