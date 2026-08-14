import DesignSystem
import AppServices
import Foundation
import LibraryAPI
import MusicDomain
import SwiftUI

struct TracksView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let section: LibrarySection
    let navigate: (LibraryDestination) -> Void
    let playTrack: ((MediaItemID) -> Void)?
    let playTracks: (([MediaItemID], Bool) -> Void)?
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?
    let artworkServing: (any ArtworkServing)?

    @State private var sortMode: TrackSortMode = .title
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var albumTitles: [AlbumID: String] = [:]
    @State private var pendingDeletionTrack: Track?
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackID: MediaItemID?

    private var visibleTracks: [Track] { viewModel.tracks(for: section) }

    private var orderedTracks: [Track] {
        visibleTracks.sorted { lhs, rhs in
            let left = TrackSectionIndex.normalizedSortValue(sortValue(for: lhs))
            let right = TrackSectionIndex.normalizedSortValue(sortValue(for: rhs))
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.externalID.localizedStandardCompare(rhs.id.externalID) == .orderedAscending
        }
    }

    private var lastTrackID: MediaItemID? {
        orderedTracks.last?.id
    }

    var body: some View {
        libraryContent
        .accessibilityIdentifier("library.tracks")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker(L("排序"), selection: $sortMode) {
                        ForEach(TrackSortMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(Text(L("排序歌曲")))
                .accessibilityIdentifier("library.tracks.sort")

                Menu {
                    Button {
                        Task { await viewModel.refreshCheckingForImports(section: section) }
                    } label: {
                        Label(L("刷新资料库"), systemImage: "arrow.clockwise")
                    }
                    if section == .tracks {
                        Button {
                            viewModel.updateSearchText("")
                        } label: {
                            Label(L("清除搜索"), systemImage: "xmark.circle")
                        }
                        .disabled(viewModel.searchText.isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text(L("歌曲选项")))
            }
        }
        .task(id: metadataKey) {
            await loadMetadata()
        }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: deletingTrackID != nil,
            delete: deleteTrack
        )
    }

    private var libraryContent: some View {
        LibraryContentState(
            state: viewModel.state(for: section),
            hasContent: !visibleTracks.isEmpty,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage,
            emptySystemImage: emptySystemImage,
            retry: { viewModel.retry(section: section) }
        ) {
            trackList
        }
    }

    private var trackList: some View {
        List {
            playbackActions

            ForEach(groupedTrackKeys, id: \.self) { key in
                Section {
                    ForEach(tracks(for: key)) { track in
                        TrackRow(
                            track: track,
                            subtitle: subtitle(for: track),
                            artworkServing: artworkServing,
                            action: {
                                if let playTrack {
                                    playTrack(track.id)
                                } else {
                                    navigate(.track(track.id))
                                }
                            },
                            detailAction: { navigate(.track(track.id)) },
                            favoriteAction: { viewModel.toggleFavorite(track) },
                            requestDelete: { requestedTrack in
                                pendingDeletionTrack = requestedTrack
                            },
                            isDeleting: deletingTrackID == track.id,
                            enqueueNextTracks: enqueueNextTracks,
                            enqueueTracks: enqueueTracks,
                            addToPlaylist: addToPlaylist
                        )
                        .listRowInsets(EdgeInsets())
                        .onAppear {
                            loadNextPageIfNeeded(for: track.id)
                        }
                    }
                } header: {
                    Text(key)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                        .textCase(nil)
                }
                .sectionIndexLabel(key)
            }
            LibraryPageFooter(section: section, viewModel: viewModel)
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(groupedTrackKeys.isEmpty ? .hidden : .visible)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundPrimary)
    }

    private var emptyTitle: String {
        switch section {
        case .favorites: return L("暂无收藏")
        case .recent: return L("暂无最近播放")
        default: return L("资料库为空")
        }
    }

    private var emptyMessage: String {
        switch section {
        case .favorites: return L("收藏的歌曲会显示在这里。")
        case .recent: return L("播放过的歌曲会显示在这里。")
        default: return L("导入本地音频后会显示在这里。")
        }
    }

    private var emptySystemImage: String {
        switch section {
        case .favorites: return "star"
        case .recent: return "clock"
        default: return "music.note.list"
        }
    }

    private var playbackIDs: [MediaItemID] {
        orderedTracks.map(\.id)
    }

    private var playbackActions: some View {
        MusicFreeDetailActionBar(
            isEnabled: !playbackIDs.isEmpty,
            playAction: { startPlayback(shuffle: false) },
            shuffleAction: { startPlayback(shuffle: true) }
        )
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.medium)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func startPlayback(shuffle: Bool) {
        guard !playbackIDs.isEmpty else { return }
        if let playTracks {
            playTracks(playbackIDs, shuffle)
        } else {
            playTrack?(playbackIDs[0])
        }
    }

    private var groupedTrackKeys: [String] {
        Array(Set(orderedTracks.map { groupKey(for: $0) }))
            .sorted(by: TrackSectionIndex.areInAscendingOrder)
    }

    private func tracks(for key: String) -> [Track] {
        orderedTracks.filter { groupKey(for: $0) == key }
    }

    private func groupKey(for track: Track) -> String {
        TrackSectionIndex.title(for: sortValue(for: track))
    }

    private var metadataKey: String {
        visibleTracks.map(\.id.externalID).joined(separator: "|")
    }

    private func loadMetadata() async {
        guard !visibleTracks.isEmpty else {
            artistNames = [:]
            albumTitles = [:]
            return
        }

        do {
            let request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            let service = viewModel.library
            async let artistNameTask = LibraryArtistNameLoader.load(
                artistIDs: Set(visibleTracks.flatMap(\.artistIDs)),
                from: service
            )
            async let albumsPage = service.browseAlbums(
                matching: AlbumQuery(sourceID: .local),
                page: request
            )
            let (loadedArtistNames, albums) = try await (artistNameTask, albumsPage.elements)
            guard !Task.isCancelled else { return }
            artistNames = loadedArtistNames
            albumTitles = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.title) })
        } catch {
            // Metadata is supplementary. The song list remains usable when a
            // source cannot resolve its related artist or album records.
        }
    }

    private func sortValue(for track: Track) -> String {
        switch sortMode {
        case .title:
            return track.sortTitle ?? track.title
        case .artist:
            return track.artistIDs.compactMap { artistNames[$0] }.first ?? track.title
        case .album:
            return track.albumID.flatMap { albumTitles[$0] } ?? track.title
        }
    }

    private func subtitle(for track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func loadNextPageIfNeeded(for trackID: MediaItemID) {
        guard trackID == lastTrackID else { return }
        viewModel.loadNextPage(for: section)
    }

    private func deleteTrack(_ track: Track) {
        guard deletingTrackID == nil else { return }
        let itemID = track.id
        deletingTrackID = itemID
        Task { @MainActor in
            defer { deletingTrackID = nil }
            do {
                _ = try await viewModel.library.delete([itemID])
                viewModel.removeDeletedTrack(itemID)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?
    let action: () -> Void
    let detailAction: () -> Void
    let favoriteAction: () -> Void
    let requestDelete: (Track) -> Void
    let isDeleting: Bool
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        HStack(spacing: 0) {
            // Keep the primary row action as a real Button. A gesture on a
            // List row competes with the nested Menu on iOS 26 and can leave
            // the playback snapshot unchanged when the title is tapped.
            Button(action: action) {
                MediaRow(
                    title: track.title,
                    subtitle: subtitle,
                    artwork: artworkLoader.image,
                    artworkAccessibilityLabel: L("%@ album artwork", track.title)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("library.track.play.\(track.id.externalID)")
            .accessibilityHint(L("播放歌曲"))

            Menu {
                Button(L("播放"), systemImage: "play.fill", action: action)
                    .accessibilityIdentifier("library.track.menu.play")
                Button(L("查看歌曲详情"), systemImage: "info.circle", action: detailAction)
                    .accessibilityIdentifier("library.track.menu.detail")
                TrackQueueMenuActions(
                    trackID: track.id,
                    accessibilityPrefix: "library.track.menu",
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addToPlaylist
                )
                Button(
                    track.isFavorite ? L("取消收藏") : L("收藏"),
                    systemImage: track.isFavorite ? "star.slash" : "star",
                    action: favoriteAction
                )
                .accessibilityIdentifier("library.track.menu.favorite")
                Divider()
                Button(role: .destructive, action: { requestDelete(track) }) {
                    Label(L("删除歌曲"), systemImage: "trash")
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("library.track.menu.delete")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(width: MusicFreeLayoutMetrics.minimumHitTarget,
                           height: MusicFreeLayoutMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            .accessibilityLabel(L("歌曲选项"))
            .accessibilityIdentifier("library.track.menu")
            .padding(.trailing, MusicFreeSpacingTokens.contentInset)
        }
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: track.artworkID,
                sourceID: track.id.sourceID,
                serving: artworkServing
            )
        }
    }

    private var artworkKey: String {
        "\(track.id.sourceID.rawValue):\(track.artworkID?.rawValue ?? "")"
    }
}

enum TrackSectionIndex {
    static let fallbackTitle = LibrarySortSupport.fallbackSectionTitle

    static func title(for value: String) -> String {
        LibrarySortSupport.sectionTitle(for: value)
    }

    static func normalizedSortValue(_ value: String) -> String {
        LibrarySortSupport.normalizedSortValue(value)
    }

    static func areInAscendingOrder(_ lhs: String, _ rhs: String) -> Bool {
        LibrarySortSupport.areSectionTitlesInAscendingOrder(lhs, rhs)
    }
}

private enum TrackSortMode: String, CaseIterable, Identifiable {
    case title
    case artist
    case album

    var id: Self { self }

    var title: String {
        switch self {
        case .title: return L("歌曲名称")
        case .artist: return L("艺人")
        case .album: return L("专辑")
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "person"
        case .album: return "square.stack"
        }
    }
}
