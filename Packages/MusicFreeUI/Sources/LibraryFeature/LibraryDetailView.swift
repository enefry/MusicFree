import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

/// Detail screens keep the query boundary in LibraryServing and expose only
/// stable domain values to the view. They intentionally do not reach into
/// SwiftData or the local media adapter.
struct LibraryTrackDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let trackID: MediaItemID
    let library: any LibraryServing
    let playTrack: ((MediaItemID) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?
    let artworkServing: (any ArtworkServing)?

    @State private var track: Track?
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var albumTitle: String?
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var isSavingFavorite = false
    @State private var pendingDeletionTrack: Track?
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackID: MediaItemID?
    @State private var isMetadataEditorPresented = false
    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载歌曲"))
            } else if let failureMessage {
                ErrorStateView(
                    title: L("歌曲加载失败"),
                    message: failureMessage,
                    retryTitle: L("重试"),
                    retry: { Task { await load() } }
                )
            } else if let track {
                ScrollView {
                    VStack(spacing: MusicFreeSpacingTokens.large) {
                        ArtworkView(
                            image: artworkLoader.image,
                            accessibilityLabel: L("%@ album artwork", track.title),
                            placeholderTitle: track.title,
                            fillsAvailableWidth: true
                        )
                        .frame(maxWidth: 310)
                        .aspectRatio(1, contentMode: .fit)

                        VStack(spacing: MusicFreeSpacingTokens.xSmall) {
                            Text(track.title)
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("library.trackDetail.title")
                            if let trackArtistNames {
                                Text(trackArtistNames)
                                    .font(.title3)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                                    .multilineTextAlignment(.center)
                                    .accessibilityIdentifier("library.trackDetail.artist")
                            }
                            if let albumTitle {
                                Text(albumTitle)
                                    .font(MusicFreeTypographyTokens.body)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                                    .multilineTextAlignment(.center)
                                    .accessibilityIdentifier("library.trackDetail.album")
                            }
                            if let duration = track.duration {
                                Text(L("时长 %@", format(duration)))
                                    .font(.caption)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                                    .accessibilityIdentifier("library.trackDetail.duration")
                            }
                        }

                        HStack(spacing: MusicFreeSpacingTokens.small) {
                            MusicFreePillActionButton(
                                title: L("播放歌曲"),
                                systemImage: "play.fill",
                                isEnabled: playTrack != nil,
                                action: { playTrack?(track.id) }
                            )

                            Button {
                                toggleFavorite(track)
                            } label: {
                                Label(
                                    track.isFavorite ? L("取消收藏") : L("收藏"),
                                    systemImage: track.isFavorite ? "star.fill" : "star"
                                )
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MusicFreeColorTokens.accent)
                                .frame(minHeight: 48)
                                .frame(maxWidth: .infinity)
                                .background(
                                    MusicFreeColorTokens.accentSoft,
                                    in: Capsule(style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isSavingFavorite)
                            .accessibilityIdentifier("library.trackDetail.favorite")
                        }

                        TrackTechnicalDetailsView(track: track)

                        if let lyrics = track.lyrics {
                            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                                Text(L("歌词"))
                                    .font(.headline)
                                Text(lyrics.displayText)
                                    .font(.body)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                                    .lineLimit(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(MusicFreeSpacingTokens.medium)
                            .background(MusicFreeColorTokens.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                    .padding(.vertical, MusicFreeSpacingTokens.large)
                }
                .background(MusicFreeColorTokens.backgroundPrimary)
                .task(id: artworkKey) {
                    await artworkLoader.load(
                        artworkID: track.artworkID,
                        sourceID: track.id.sourceID,
                        serving: artworkServing
                    )
                }
            } else {
                EmptyStateView(title: L("找不到歌曲"), systemImage: "music.note")
            }
        }
        .accessibilityIdentifier("library.trackDetail")
        .navigationTitle(track?.title ?? L("歌曲详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    pendingDeletionTrack = track
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(track == nil || deletingTrackID != nil)
                .accessibilityLabel(L("删除歌曲"))
                .accessibilityIdentifier("library.trackDetail.delete")

                Button {
                    isMetadataEditorPresented = true
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(track == nil || deletingTrackID != nil)
                .accessibilityLabel(L("编辑歌曲"))
                .accessibilityIdentifier("library.trackDetail.edit")

                Button {
                    if let track { addToPlaylist?([track.id]) }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .disabled(track == nil || addToPlaylist == nil)
                .accessibilityLabel(L("添加到播放列表"))
                .accessibilityIdentifier("library.trackDetail.addToPlaylist")
            }
        }
        .task(id: trackID) { await load() }
        .sheet(isPresented: $isMetadataEditorPresented) {
            if let track {
                NavigationStack {
                    TrackMetadataEditorView(
                        track: track,
                        library: library,
                        onSaved: { updated in
                            self.track = updated
                            Task { await loadRelatedMetadata(for: updated) }
                        }
                    )
                }
            }
        }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: deletingTrackID != nil,
            delete: deleteTrack
        )
    }

    private var artworkKey: String {
        "\(track?.id.sourceID.rawValue ?? ""):\(track?.artworkID?.rawValue ?? "")"
    }

    private var trackArtistNames: String? {
        guard let track else { return nil }
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    @MainActor
    private func load() async {
        isLoading = true
        failureMessage = nil
        artistNames = [:]
        albumTitle = nil
        do {
            let loadedTrack = try await library.track(id: trackID)
            track = loadedTrack
            isLoading = false
            if let loadedTrack {
                await loadRelatedMetadata(for: loadedTrack)
            }
        } catch {
            track = nil
            failureMessage = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadRelatedMetadata(for track: Track) async {
        async let resolvedArtistNames = resolveArtistNames(for: track)
        async let resolvedAlbumTitle = resolveAlbumTitle(for: track)
        let (names, title) = await (resolvedArtistNames, resolvedAlbumTitle)
        guard !Task.isCancelled, self.track?.id == track.id else { return }
        artistNames = names
        albumTitle = title
    }

    private func resolveArtistNames(for track: Track) async -> [ArtistID: String] {
        (try? await LibraryArtistNameLoader.load(
            artistIDs: Set(track.artistIDs),
            sourceID: track.id.sourceID,
            from: library
        )) ?? [:]
    }

    private func resolveAlbumTitle(for track: Track) async -> String? {
        guard let albumID = track.albumID else { return nil }

        do {
            var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            var seenCursors = Set<LibraryCursor>()

            while true {
                try Task.checkCancellation()
                let page = try await library.browseAlbums(
                    matching: AlbumQuery(sourceID: track.id.sourceID),
                    page: request
                )
                try Task.checkCancellation()

                if let album = page.elements.first(where: { $0.id == albumID }) {
                    return album.title
                }

                guard let nextRequest = try page.nextPage(limit: request.limit) else {
                    return nil
                }
                guard let cursor = nextRequest.cursor,
                      seenCursors.insert(cursor).inserted
                else {
                    return nil
                }
                request = nextRequest
            }
        } catch {
            // Artist and album values are supplementary. The track remains
            // usable when a source cannot resolve one of its relationships.
            return nil
        }
    }

    private func format(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggleFavorite(_ track: Track) {
        guard !isSavingFavorite else { return }
        isSavingFavorite = true
        Task { @MainActor in
            defer { isSavingFavorite = false }
            do {
                self.track = try await library.setFavorite(!track.isFavorite, for: track.id)
            } catch {
                // Keep the last loaded state when the mutation fails; the page
                // still exposes the retry path through the normal reload action.
            }
        }
    }

    private func deleteTrack(_ track: Track) {
        guard deletingTrackID == nil else { return }
        let itemID = track.id
        deletingTrackID = itemID
        Task { @MainActor in
            defer { deletingTrackID = nil }
            do {
                _ = try await library.delete([itemID])
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

struct LibraryCollectionDetailView: View {
    enum Kind: Hashable {
        case album(AlbumID)
        case genre(GenreID)

        var title: String {
            switch self {
            case .album: return L("专辑详情")
            case .genre: return L("流派详情")
            }
        }
    }

    let kind: Kind
    let title: String?
    let album: Album?
    let onAlbumUpdated: ((Album) -> Void)?
    let library: any LibraryServing
    let playTracks: (([MediaItemID], Bool) -> Void)?
    let playTrack: ((MediaItemID) -> Void)?
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let addTracksToPlaylist: (([MediaItemID]) -> Void)?
    let addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool
    let artworkServing: (any ArtworkServing)?
    let navigate: (LibraryDestination) -> Void
    let removeDeletedTracks: (Set<MediaItemID>) -> Void

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var favoriteMutationIDs: Set<MediaItemID> = []
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var pendingDeletionTrack: Track?
    @State private var pendingDeletionTrackIDs: Set<MediaItemID> = []
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackIDs: Set<MediaItemID> = []
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<MediaItemID> = []
    @State private var currentAlbum: Album?
    @State private var isAlbumMetadataEditorPresented = false
    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载歌曲"))
            } else if let failureMessage {
                ErrorStateView(
                    title: L("详情加载失败"),
                    message: failureMessage,
                    retryTitle: L("重试"),
                    retry: { Task { await load() } }
                )
            } else if tracks.isEmpty {
                EmptyStateView(
                    title: title ?? kind.title,
                    message: L("这个条目暂时没有可播放的歌曲。"),
                    systemImage: kind.systemImage
                )
            } else {
                NativeTrackCollectionView(
                    sections: [
                        NativeTrackCollectionSection(
                            id: "library.collection.tracks",
                            headerTitle: isAlbum ? nil : L("歌曲"),
                            tracks: orderedTracks
                        )
                    ],
                    header: AnyView(collectionHeader),
                    footer: nil,
                    optionsAccessibilityPrefix: "library.collection.track",
                    isEditing: isEditing,
                    selectedIDs: selectedTrackIDs,
                    isDisabled: isLoading || isDeleting,
                    contentRevision: "",
                    accessibilityValue: nil,
                    rowContent: { track, editing, selected in
                        AnyView(
                            LibraryDetailTrackRow(
                                track: track,
                                subtitle: trackSubtitle(track),
                                trackNumberText: isAlbum
                                    ? LibraryAlbumTrackOrdering.displayNumber(
                                        for: track,
                                        in: orderedTracks
                                    )
                                    : nil,
                                accessibilityPrefix: "library.collection.track",
                                isSelected: selected,
                                isEditing: editing
                            )
                        )
                    },
                    playAction: { track in play(track) },
                    detailAction: { track in navigate(.track(track.id)) },
                    favoriteAction: { track in toggleFavorite(track) },
                    requestDelete: { track in pendingDeletionTrack = track },
                    shareText: { track in shareText(for: track) },
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addTracksToPlaylist,
                    isPlayEnabled: { _ in playTrack != nil || playTracks != nil },
                    isFavoriteEnabled: { track in !favoriteMutationIDs.contains(track.id) },
                    isDeleting: { track in deletingTrackIDs.contains(track.id) },
                    onSelectionChanged: { selectedTrackIDs = $0 },
                    onEditingChanged: { editing in
                        if editing {
                            isEditing = true
                        } else {
                            finishEditing()
                        }
                    },
                    onLastTrackDisplayed: { _ in }
                )
                .background(MusicFreeColorTokens.backgroundPrimary)
                .task(id: artworkKey) {
                    await artworkLoader.load(
                        artworkID: artworkID,
                        sourceID: .local,
                        serving: artworkServing
                    )
                }
            }
        }
        .accessibilityIdentifier("library.collectionDetail")
        .navigationTitle(isAlbum ? "" : (title ?? kind.title))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedTrackIDs.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedTrackIDs.count,
                    scope: .tracks,
                    accessibilityIdentifier: "library.collection.deleteSelected",
                    isDisabled: isDeleting,
                    action: requestDeleteSelected
                )
            }
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择歌曲")))
                    .accessibilityIdentifier("library.collection.finishSelection")
                    .disabled(isDeleting)
                }
            }
            if isAlbum {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAlbumMetadataEditorPresented = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(L("编辑专辑"))
                    .accessibilityIdentifier("library.collection.editAlbum")
                    .disabled(activeAlbum == nil || isEditing || isDeleting)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryCollectionQueueMenuActions(
                        target: collectionQueueTarget,
                        accessibilityPrefix: "library.collection.menu",
                        enqueueNext: enqueueNextCollection,
                        enqueue: enqueueCollection,
                        addToPlaylist: addCollectionToPlaylist,
                        isPending: isCollectionQueueActionPending(collectionQueueTarget)
                            || isCollectionPlaylistActionPending(collectionQueueTarget)
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L("集合选项"))
                .accessibilityIdentifier("library.collection.menu")
                .disabled(isEditing || isDeleting)
            }
        }
        .task(id: kind) { await load() }
        .sheet(isPresented: $isAlbumMetadataEditorPresented) {
            if let activeAlbum {
                NavigationStack {
                    AlbumMetadataEditorView(
                        album: activeAlbum,
                        library: library,
                        onSaved: { updated in
                            currentAlbum = updated
                            onAlbumUpdated?(updated)
                            Task { @MainActor in
                                if let names = try? await LibraryArtistNameLoader.load(
                                    artistIDs: Set(updated.artistIDs),
                                    sourceID: .local,
                                    from: library
                                ) {
                                    artistNames.merge(names) { _, new in new }
                                }
                            }
                        }
                    )
                }
            }
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
    }

    @ViewBuilder
    private var collectionHeader: some View {
        VStack(spacing: MusicFreeSpacingTokens.medium) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: L("%@ collection artwork", title ?? kind.title),
                placeholderSystemImage: kind.systemImage,
                placeholderTitle: title ?? kind.title,
                fillsAvailableWidth: true
            )
            .frame(maxWidth: 250)
            .aspectRatio(1, contentMode: .fit)

            Text(collectionTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("library.collection.header.title")
            collectionMetadata

            MusicFreeDetailActionBar(
                isEnabled: playTracks != nil || playTrack != nil,
                presentation: isAlbum ? .albumHero : .splitPills,
                playAccessibilityIdentifier: "library.collection.play",
                shuffleAccessibilityIdentifier: "library.collection.shuffle",
                playAction: { playAll(shuffle: false) },
                shuffleAction: { playAll(shuffle: true) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.medium)
    }

    private var query: TrackQuery {
        switch kind {
        case .album(let id):
            return TrackQuery(sourceID: .local, albumID: id)
        case .genre(let id):
            return TrackQuery(sourceID: .local, genreID: id)
        }
    }

    private var collectionQueueTarget: LibraryCollectionQueueTarget {
        switch kind {
        case .album(let albumID): return .album(albumID)
        case .genre(let genreID): return .genre(genreID)
        }
    }

    private var artworkID: ArtworkID? {
        activeAlbum?.artworkID ?? tracks.first?.artworkID
    }

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    private var artworkKey: String {
        "\(kind):\(artworkID?.rawValue ?? "")"
    }

    private var orderedTracks: [Track] {
        isAlbum ? LibraryAlbumTrackOrdering.ordered(tracks) : tracks
    }

    private var isDeleting: Bool {
        !deletingTrackIDs.isEmpty
    }

    private var collectionTitle: String {
        activeAlbum?.title ?? title ?? kind.title
    }

    private var activeAlbum: Album? {
        currentAlbum ?? album
    }

    @ViewBuilder
    private var collectionMetadata: some View {
        if case .album = kind {
            if let albumArtistNames {
                Text(albumArtistNames)
                    .font(.title3)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("library.collection.header.artist")
            }
            if let albumTypeTitle {
                Text(albumTypeTitle)
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .accessibilityIdentifier("library.collection.header.type")
            }
            if let releaseYear = activeAlbum?.releaseYear {
                Text(String(releaseYear))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .accessibilityIdentifier("library.collection.header.year")
            }
        } else {
            Text(L("%d tracks", tracks.count))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
    }

    private var albumArtistNames: String? {
        guard let album = activeAlbum else { return nil }
        let names = album.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var albumTypeTitle: String? {
        guard let albumType = activeAlbum?.albumType else { return nil }
        switch albumType {
        case .album: return L("专辑")
        case .single: return L("单曲")
        case .extendedPlay: return "EP"
        case .compilation: return L("精选集")
        case .soundtrack: return L("原声带")
        case .live: return L("现场录音")
        case .unknown: return nil
        }
    }

    private func load() async {
        currentAlbum = album
        isLoading = true
        failureMessage = nil
        do {
            let page = try await library.browseTracks(
                matching: query,
                page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            )
            tracks = isAlbum
                ? LibraryAlbumTrackOrdering.ordered(page.elements)
                : page.elements
            let artistIDs = Set(page.elements.flatMap(\.artistIDs) + (activeAlbum?.artistIDs ?? []))
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: artistIDs,
                sourceID: .local,
                from: library
            )) ?? [:]
        } catch {
            tracks = []
            artistNames = [:]
            failureMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playAll(shuffle: Bool) {
        guard !orderedTracks.isEmpty else { return }
        if let playTracks {
            playTracks(orderedTracks.map(\.id), shuffle)
        } else {
            playTrack?(orderedTracks[0].id)
        }
    }

    private func trackSubtitle(_ track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func shareText(for track: Track) -> String {
        guard let subtitle = trackSubtitle(track) else { return track.title }
        return "\(track.title) - \(subtitle)"
    }

    private func play(_ track: Track) {
        if let playTrack {
            playTrack(track.id)
        } else {
            playTracks?([track.id], false)
        }
    }

    private func toggleFavorite(_ track: Track) {
        guard !favoriteMutationIDs.contains(track.id) else { return }
        favoriteMutationIDs.insert(track.id)
        Task { @MainActor in
            defer { favoriteMutationIDs.remove(track.id) }
            guard let updated = try? await library.setFavorite(!track.isFavorite, for: track.id),
                  let index = tracks.firstIndex(where: { $0.id == updated.id })
            else { return }
            tracks[index] = updated
        }
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedTrackIDs.removeAll()
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
                _ = try await library.delete([itemID])
                tracks.removeAll { $0.id == itemID }
                favoriteMutationIDs.remove(itemID)
                selectedTrackIDs.remove(itemID)
                removeDeletedTracks([itemID])
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
                _ = try await library.delete(itemIDs)
                tracks.removeAll { itemIDs.contains($0.id) }
                favoriteMutationIDs.subtract(itemIDs)
                selectedTrackIDs.subtract(itemIDs)
                removeDeletedTracks(itemIDs)
                if tracks.isEmpty {
                    isEditing = false
                    selectedTrackIDs.removeAll()
                }
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

private extension LibraryCollectionDetailView.Kind {
    var systemImage: String {
        switch self {
        case .album: return "square.stack"
        case .genre: return "guitars"
        }
    }
}

/// Keeps album pages aligned with source-provided disc and track positions.
/// If an album has exactly one explicit disc value, missing values are treated
/// as belonging to that disc for ordering only. The display never fabricates a
/// disc prefix for tracks whose source metadata omitted it.
enum LibraryAlbumTrackOrdering {
    static func ordered(_ tracks: [Track]) -> [Track] {
        let shouldUseDiscNumbers = usesDiscNumbers(in: tracks)
        let explicitDiscNumbers = Set(tracks.compactMap(\.discNumber))
        let inferredDiscNumber = shouldUseDiscNumbers && explicitDiscNumbers.count == 1
            ? explicitDiscNumbers.first
            : nil

        func effectiveDiscNumber(for track: Track) -> Int? {
            guard shouldUseDiscNumbers else { return nil }
            return track.discNumber ?? inferredDiscNumber
        }

        return tracks.sorted { lhs, rhs in
            switch (effectiveDiscNumber(for: lhs), effectiveDiscNumber(for: rhs)) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let leftTrack = lhs.trackNumber ?? Int.max
            let rightTrack = rhs.trackNumber ?? Int.max
            if leftTrack != rightTrack {
                return leftTrack < rightTrack
            }

            let leftTitle = lhs.sortTitle ?? lhs.title
            let rightTitle = rhs.sortTitle ?? rhs.title
            let titleOrder = leftTitle.localizedStandardCompare(rightTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    static func displayNumber(for track: Track) -> String? {
        guard let trackNumber = track.trackNumber else { return nil }
        guard let discNumber = track.discNumber, discNumber > 1 else {
            return String(trackNumber)
        }
        return "\(discNumber)-\(trackNumber)"
    }

    static func displayNumber(for track: Track, in tracks: [Track]) -> String? {
        guard let trackNumber = track.trackNumber else { return nil }
        guard usesDiscNumbers(in: tracks),
              let discNumber = track.discNumber,
              discNumber > 1
        else {
            return String(trackNumber)
        }
        return "\(discNumber)-\(trackNumber)"
    }

    private static func usesDiscNumbers(in tracks: [Track]) -> Bool {
        let numberedTracks = tracks.filter { $0.trackNumber != nil }
        guard !numberedTracks.isEmpty else { return false }

        let explicitDiscNumbers = Set(numberedTracks.compactMap(\.discNumber))
        guard !explicitDiscNumbers.isEmpty else { return false }

        // A single explicit disc value can safely fill in missing values. With
        // multiple disc values, every numbered track must carry a disc value;
        // otherwise an isolated bad tag can move one track to another disc and
        // destroy the album's track-number order.
        return explicitDiscNumbers.count == 1
            || numberedTracks.allSatisfy { $0.discNumber != nil }
    }
}

struct LibraryFolderDetailView: View {
    let path: String
    let library: any LibraryServing
    let playTracks: (([MediaItemID], Bool) -> Void)?
    let playTrack: ((MediaItemID) -> Void)?
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let artworkServing: (any ArtworkServing)?
    let navigate: (LibraryDestination) -> Void
    let removeDeletedTracks: (Set<MediaItemID>) -> Void

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var favoriteMutationIDs: Set<MediaItemID> = []
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var pendingDeletionTrack: Track?
    @State private var pendingDeletionTrackIDs: Set<MediaItemID> = []
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackIDs: Set<MediaItemID> = []
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<MediaItemID> = []

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载歌曲"))
            } else if let failureMessage {
                ErrorStateView(
                    title: L("文件夹加载失败"),
                    message: failureMessage,
                    retryTitle: L("重试"),
                    retry: { Task { await load() } }
                )
            } else if tracks.isEmpty {
                EmptyStateView(
                    title: path,
                    message: L("这个文件夹暂时没有可播放的歌曲。"),
                    systemImage: "folder"
                )
            } else {
                NativeTrackCollectionView(
                    sections: [
                        NativeTrackCollectionSection(
                            id: "library.folder.tracks",
                            headerTitle: L("歌曲"),
                            tracks: tracks
                        )
                    ],
                    header: AnyView(folderHeader),
                    footer: nil,
                    optionsAccessibilityPrefix: "library.folder.track",
                    isEditing: isEditing,
                    selectedIDs: selectedTrackIDs,
                    isDisabled: isLoading || isDeleting,
                    contentRevision: "",
                    accessibilityValue: nil,
                    rowContent: { track, editing, selected in
                        AnyView(
                            LibraryDetailTrackRow(
                                track: track,
                                subtitle: trackSubtitle(track),
                                trackNumberText: nil,
                                accessibilityPrefix: "library.folder.track",
                                isSelected: selected,
                                isEditing: editing
                            )
                        )
                    },
                    playAction: { track in play(track) },
                    detailAction: { track in navigate(.track(track.id)) },
                    favoriteAction: { track in toggleFavorite(track) },
                    requestDelete: { track in pendingDeletionTrack = track },
                    shareText: { track in shareText(for: track) },
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: nil,
                    isPlayEnabled: { _ in playTrack != nil || playTracks != nil },
                    isFavoriteEnabled: { track in !favoriteMutationIDs.contains(track.id) },
                    isDeleting: { track in deletingTrackIDs.contains(track.id) },
                    onSelectionChanged: { selectedTrackIDs = $0 },
                    onEditingChanged: { editing in
                        if editing {
                            isEditing = true
                        } else {
                            finishEditing()
                        }
                    },
                    onLastTrackDisplayed: { _ in }
                )
                .background(MusicFreeColorTokens.backgroundPrimary)
            }
        }
        .accessibilityIdentifier("library.folderDetail")
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedTrackIDs.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedTrackIDs.count,
                    scope: .tracks,
                    accessibilityIdentifier: "library.folderDetail.deleteSelected",
                    isDisabled: isDeleting,
                    action: requestDeleteSelected
                )
            }
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择歌曲")))
                    .accessibilityIdentifier("library.folderDetail.finishSelection")
                    .disabled(isDeleting)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryCollectionQueueMenuActions(
                        target: collectionQueueTarget,
                        accessibilityPrefix: "library.folderDetail.menu",
                        enqueueNext: enqueueNextCollection,
                        enqueue: enqueueCollection,
                        isPending: isCollectionQueueActionPending(collectionQueueTarget)
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L("文件夹选项"))
                .accessibilityIdentifier("library.folderDetail.menu")
                .disabled(isEditing || isDeleting)
            }
        }
        .task(id: path) { await load() }
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
    }

    private var collectionQueueTarget: LibraryCollectionQueueTarget {
        .folder(path)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            Label(path, systemImage: "folder.fill")
                .font(.title2.weight(.bold))
            Text(L("%d tracks", tracks.count))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            MusicFreeDetailActionBar(
                isEnabled: playTracks != nil || playTrack != nil,
                playAction: { playAll(shuffle: false) },
                shuffleAction: { playAll(shuffle: true) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.medium)
    }

    private var isDeleting: Bool {
        !deletingTrackIDs.isEmpty
    }

    private func load() async {
        isLoading = true
        failureMessage = nil
        do {
            let page = try await library.browseTracks(
                matching: TrackQuery(sourceID: .local),
                page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            )
            tracks = page.elements.filter { $0.folderPath == path }
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(tracks.flatMap(\.artistIDs)),
                sourceID: .local,
                from: library
            )) ?? [:]
        } catch {
            tracks = []
            artistNames = [:]
            failureMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playAll(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        if let playTracks {
            playTracks(tracks.map(\.id), shuffle)
        } else {
            playTrack?(tracks[0].id)
        }
    }

    private func trackSubtitle(_ track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func shareText(for track: Track) -> String {
        guard let subtitle = trackSubtitle(track) else { return track.title }
        return "\(track.title) - \(subtitle)"
    }

    private func play(_ track: Track) {
        if let playTrack {
            playTrack(track.id)
        } else {
            playTracks?([track.id], false)
        }
    }

    private func toggleFavorite(_ track: Track) {
        guard !favoriteMutationIDs.contains(track.id) else { return }
        favoriteMutationIDs.insert(track.id)
        Task { @MainActor in
            defer { favoriteMutationIDs.remove(track.id) }
            guard let updated = try? await library.setFavorite(!track.isFavorite, for: track.id),
                  let index = tracks.firstIndex(where: { $0.id == updated.id })
            else { return }
            tracks[index] = updated
        }
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedTrackIDs.removeAll()
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
                _ = try await library.delete([itemID])
                tracks.removeAll { $0.id == itemID }
                favoriteMutationIDs.remove(itemID)
                selectedTrackIDs.remove(itemID)
                removeDeletedTracks([itemID])
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
                _ = try await library.delete(itemIDs)
                tracks.removeAll { itemIDs.contains($0.id) }
                favoriteMutationIDs.subtract(itemIDs)
                selectedTrackIDs.subtract(itemIDs)
                removeDeletedTracks(itemIDs)
                if tracks.isEmpty {
                    isEditing = false
                    selectedTrackIDs.removeAll()
                }
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

struct LibraryBatchDeletionBar: View {
    let count: Int
    let scope: LibraryBatchDeletionScope
    let accessibilityIdentifier: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: MusicFreeSpacingTokens.small) {
                Label(scope.actionTitle, systemImage: "trash")
                Spacer(minLength: MusicFreeSpacingTokens.small)
                Text(scope.countLabel(count))
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
            .font(.headline)
            .frame(
                maxWidth: .infinity,
                minHeight: MusicFreeLayoutMetrics.minimumHitTarget
            )
        }
        .buttonStyle(.bordered)
        .tint(MusicFreeColorTokens.destructive)
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(Text(scope.countLabel(count)))
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct LibraryDetailTrackRow: View {
    let track: Track
    let subtitle: String?
    let trackNumberText: String?
    let accessibilityPrefix: String
    let isSelected: Bool
    let isEditing: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let trackNumberText {
                Text(trackNumberText)
                    .font(MusicFreeTypographyTokens.body.monospacedDigit())
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 56, alignment: .leading)
                    .accessibilityIdentifier("\(accessibilityPrefix).number.\(track.id.externalID)")
            }

            rowContent
        }
        .frame(minHeight: 56)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).\(isEditing ? "select" : "play").\(track.id.externalID)"
        )
        .accessibilityHint(L(isEditing ? "选择歌曲" : "播放歌曲，按住显示更多歌曲操作"))
        .accessibilityValue(
            isEditing
                ? Text(isSelected ? L("已选择") : L("未选择"))
                : Text("")
        )
    }

    private var rowContent: some View {
        MediaRow(
            title: track.title,
            subtitle: subtitle,
            showsArtwork: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
