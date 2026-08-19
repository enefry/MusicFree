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
    @State private var pendingDeletionTrackIDs: Set<MediaItemID> = []
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackIDs: Set<MediaItemID> = []
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<MediaItemID> = []

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

    private var visibleTrackIDs: Set<MediaItemID> {
        Set(visibleTracks.map(\.id))
    }

    private var isDeleting: Bool {
        !deletingTrackIDs.isEmpty
    }

    private var areAllVisibleTracksSelected: Bool {
        !visibleTrackIDs.isEmpty && visibleTrackIDs.isSubset(of: selectedTrackIDs)
    }

    var body: some View {
        libraryContent
        .accessibilityIdentifier("library.tracks")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择歌曲")))
                    .accessibilityIdentifier("library.tracks.finishSelection")
                    .disabled(isDeleting)

                    Button {
                        toggleSelectAll()
                    } label: {
                        Image(
                            systemName: areAllVisibleTracksSelected
                                ? "checkmark.circle.fill"
                                : "checkmark.circle"
                        )
                    }
                    .accessibilityLabel(
                        Text(
                            areAllVisibleTracksSelected
                                ? L("取消全选歌曲")
                                : L("全选歌曲")
                        )
                    )
                    .accessibilityIdentifier("library.tracks.selectAll")
                    .disabled(orderedTracks.isEmpty || isDeleting)
                }

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
                .disabled(isEditing || isDeleting)

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
                .disabled(isEditing || isDeleting)
            }
        }
        .task(id: metadataKey) {
            await loadMetadata()
        }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: isDeleting,
            delete: deleteTrack
        )
        .batchTrackDeletionPresentation(
            pendingTrackIDs: $pendingDeletionTrackIDs,
            isDeleting: isDeleting,
            delete: deleteSelectedTracks
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedTrackIDs.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedTrackIDs.count,
                    scope: .tracks,
                    accessibilityIdentifier: "library.tracks.deleteSelected",
                    isDisabled: isDeleting,
                    action: requestDeleteSelected
                )
            }
        }
        .onChange(of: section) { _, _ in
            isEditing = false
            selectedTrackIDs.removeAll()
            pendingDeletionTrackIDs.removeAll()
        }
        .onChange(of: viewModel.searchText) { _, _ in
            isEditing = false
            selectedTrackIDs.removeAll()
            pendingDeletionTrackIDs.removeAll()
        }
        .onChange(of: metadataKey) { _, _ in
            selectedTrackIDs.formIntersection(visibleTrackIDs)
        }
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
        NativeTrackCollectionView(
            sections: groupedTrackKeys.map { key in
                NativeTrackCollectionSection(
                    id: key,
                    headerTitle: key,
                    tracks: tracks(for: key)
                )
            },
            header: AnyView(playbackActions),
            footer: viewModel.shouldShowPageFooter(for: section)
                ? AnyView(LibraryPageFooter(section: section, viewModel: viewModel))
                : nil,
            optionsAccessibilityPrefix: "library.track",
            isEditing: isEditing,
            selectedIDs: selectedTrackIDs,
            isDisabled: isDeleting,
            rowContent: { track, editing, selected in
                AnyView(
                    TrackRow(
                        track: track,
                        subtitle: subtitle(for: track),
                        artworkServing: artworkServing,
                        isSelected: selected,
                        isEditing: editing
                    )
                )
            },
            playAction: { track in
                if let playTrack {
                    playTrack(track.id)
                } else {
                    navigate(.track(track.id))
                }
            },
            detailAction: { track in navigate(.track(track.id)) },
            favoriteAction: { track in viewModel.toggleFavorite(track) },
            requestDelete: { track in pendingDeletionTrack = track },
            shareText: { track in shareText(for: track) },
            enqueueNextTracks: enqueueNextTracks,
            enqueueTracks: enqueueTracks,
            addToPlaylist: addToPlaylist,
            isPlayEnabled: { _ in true },
            isFavoriteEnabled: { _ in true },
            isDeleting: { track in deletingTrackIDs.contains(track.id) },
            onSelectionChanged: { selectedTrackIDs = $0 },
            onEditingChanged: { editing in
                if editing {
                    isEditing = true
                } else {
                    finishEditing()
                }
            },
            onLastTrackDisplayed: { trackID in
                loadNextPageIfNeeded(for: trackID)
            }
        )
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
                sourceID: .local,
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

    private func shareText(for track: Track) -> String {
        guard let subtitle = subtitle(for: track) else { return track.title }
        return "\(track.title) - \(subtitle)"
    }

    private func loadNextPageIfNeeded(for trackID: MediaItemID) {
        guard trackID == lastTrackID else { return }
        viewModel.loadNextPage(for: section)
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedTrackIDs.removeAll()
    }

    private func toggleSelectAll() {
        guard isEditing, !isDeleting else { return }
        let visibleIDs = visibleTrackIDs
        guard !visibleIDs.isEmpty else { return }

        if visibleIDs.isSubset(of: selectedTrackIDs) {
            selectedTrackIDs.subtract(visibleIDs)
        } else {
            selectedTrackIDs.formUnion(visibleIDs)
        }
    }

    private func toggleSelection(for trackID: MediaItemID) {
        guard isEditing, !isDeleting else { return }
        if !selectedTrackIDs.insert(trackID).inserted {
            selectedTrackIDs.remove(trackID)
        }
    }

    private func requestDeleteSelected() {
        guard isEditing, !isDeleting, !selectedTrackIDs.isEmpty else { return }
        pendingDeletionTrackIDs = selectedTrackIDs
    }

    private func deleteTrack(_ track: Track) {
        guard !isDeleting else { return }
        let itemID = track.id
        deletingTrackIDs = [itemID]
        Task { @MainActor in
            defer { deletingTrackIDs.remove(itemID) }
            do {
                _ = try await viewModel.library.delete([itemID])
                viewModel.removeDeletedTrack(itemID)
                continueLoadingAfterDeletionIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSelectedTracks(_ itemIDs: Set<MediaItemID>) {
        guard isEditing, !isDeleting, !itemIDs.isEmpty else { return }
        deletingTrackIDs = itemIDs
        Task { @MainActor in
            defer { deletingTrackIDs.subtract(itemIDs) }
            do {
                _ = try await viewModel.library.delete(itemIDs)
                viewModel.removeDeletedTracks(itemIDs)
                selectedTrackIDs.subtract(itemIDs)
                continueLoadingAfterDeletionIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func continueLoadingAfterDeletionIfNeeded() {
        guard viewModel.tracks(for: section).isEmpty else { return }

        if viewModel.hasNextPage(for: section) {
            viewModel.loadNextPage(for: section)
        } else {
            isEditing = false
            selectedTrackIDs.removeAll()
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?
    let isSelected: Bool
    let isEditing: Bool

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        rowContent
            .frame(minHeight: 56)
            .accessibilityIdentifier(
                "library.track.\(isEditing ? "select" : "play").\(track.id.externalID)"
        )
        .accessibilityHint(
            Text(isEditing ? L("选择歌曲") : L("播放歌曲，按住显示更多歌曲操作"))
        )
        .accessibilityValue(
            isEditing
                ? Text(isSelected ? L("已选择") : L("未选择"))
                : Text("")
        )
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

    private var rowContent: some View {
        MediaRow(
            title: track.title,
            subtitle: subtitle,
            artwork: artworkLoader.image,
            artworkAccessibilityLabel: L("%@ album artwork", track.title)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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
