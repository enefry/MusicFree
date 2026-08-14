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

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var favoriteMutationIDs: Set<MediaItemID> = []
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var pendingDeletionTrack: Track?
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackID: MediaItemID?
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
                List {
                    Section {
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
                        .padding(.vertical, MusicFreeSpacingTokens.medium)
                        .listRowSeparator(.hidden)
                    }

                    if isAlbum {
                        Section {
                            detailTrackRows
                        }
                    } else {
                        Section(L("歌曲")) {
                            detailTrackRows
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
        .toolbar {
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
            }
        }
        .task(id: kind) { await load() }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: deletingTrackID != nil,
            delete: deleteTrack
        )
    }

    @ViewBuilder
    private var detailTrackRows: some View {
        ForEach(Array(orderedTracks.enumerated()), id: \.element.id) { index, track in
            LibraryDetailTrackRow(
                track: track,
                subtitle: trackSubtitle(track),
                trackNumberText: isAlbum ? LibraryAlbumTrackOrdering.displayNumber(for: track) : nil,
                accessibilityPrefix: "library.collection.track",
                playAction: { play(track) },
                detailAction: { navigate(.track(track.id)) },
                favoriteAction: { toggleFavorite(track) },
                requestDelete: { pendingDeletionTrack = track },
                isDeleting: deletingTrackID == track.id,
                enqueueNextTracks: enqueueNextTracks,
                enqueueTracks: enqueueTracks,
                addToPlaylist: addTracksToPlaylist,
                isPlayEnabled: playTrack != nil || playTracks != nil,
                isFavoriteEnabled: !favoriteMutationIDs.contains(track.id)
            )
            .accessibilityValue(
                Text(
                    LibraryAlbumTrackOrdering.displayNumber(for: track)
                        .map { L("曲目 %d", $0) }
                        ?? L("第 %d 首", index + 1)
                )
            )
        }
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
        album?.artworkID ?? tracks.first?.artworkID
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

    private var collectionTitle: String {
        album?.title ?? title ?? kind.title
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
            if let releaseYear = album?.releaseYear {
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
        guard let album else { return nil }
        let names = album.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var albumTypeTitle: String? {
        guard let albumType = album?.albumType else { return nil }
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
        isLoading = true
        failureMessage = nil
        do {
            let page = try await library.browseTracks(
                matching: query,
                page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            )
            tracks = page.elements
            let artistIDs = Set(page.elements.flatMap(\.artistIDs) + (album?.artistIDs ?? []))
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: artistIDs,
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

    private func deleteTrack(_ track: Track) {
        guard deletingTrackID == nil else { return }
        let itemID = track.id
        deletingTrackID = itemID
        Task { @MainActor in
            defer { deletingTrackID = nil }
            do {
                _ = try await library.delete([itemID])
                tracks.removeAll { $0.id == itemID }
                favoriteMutationIDs.remove(itemID)
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
/// Missing disc values sort after every track with a real disc position; missing
/// track values sort last within the same disc group and never produce fabricated labels.
enum LibraryAlbumTrackOrdering {
    static func ordered(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            switch (lhs.discNumber, rhs.discNumber) {
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

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var favoriteMutationIDs: Set<MediaItemID> = []
    @State private var artistNames: [ArtistID: String] = [:]
    @State private var pendingDeletionTrack: Track?
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackID: MediaItemID?

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
                List {
                    Section {
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
                        .padding(.vertical, MusicFreeSpacingTokens.medium)
                        .listRowSeparator(.hidden)
                    }

                    Section(L("歌曲")) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            LibraryDetailTrackRow(
                                track: track,
                                subtitle: trackSubtitle(track),
                                trackNumberText: nil,
                                accessibilityPrefix: "library.folder.track",
                                playAction: { play(track) },
                                detailAction: { navigate(.track(track.id)) },
                                favoriteAction: { toggleFavorite(track) },
                                requestDelete: { pendingDeletionTrack = track },
                                isDeleting: deletingTrackID == track.id,
                                enqueueNextTracks: enqueueNextTracks,
                                enqueueTracks: enqueueTracks,
                                addToPlaylist: nil,
                                isPlayEnabled: playTrack != nil || playTracks != nil,
                                isFavoriteEnabled: !favoriteMutationIDs.contains(track.id)
                            )
                            .accessibilityValue(Text(L("第 %d 首", index + 1)))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(MusicFreeColorTokens.backgroundPrimary)
            }
        }
        .accessibilityIdentifier("library.folderDetail")
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            }
        }
        .task(id: path) { await load() }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: deletingTrackID != nil,
            delete: deleteTrack
        )
    }

    private var collectionQueueTarget: LibraryCollectionQueueTarget {
        .folder(path)
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

    private func deleteTrack(_ track: Track) {
        guard deletingTrackID == nil else { return }
        let itemID = track.id
        deletingTrackID = itemID
        Task { @MainActor in
            defer { deletingTrackID = nil }
            do {
                _ = try await library.delete([itemID])
                tracks.removeAll { $0.id == itemID }
                favoriteMutationIDs.remove(itemID)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct LibraryDetailTrackRow: View {
    let track: Track
    let subtitle: String?
    let trackNumberText: String?
    let accessibilityPrefix: String
    let playAction: () -> Void
    let detailAction: () -> Void
    let favoriteAction: () -> Void
    let requestDelete: () -> Void
    let isDeleting: Bool
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?
    let isPlayEnabled: Bool
    let isFavoriteEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let trackNumberText {
                Text(trackNumberText)
                    .font(MusicFreeTypographyTokens.body.monospacedDigit())
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                    .frame(width: 30, alignment: .leading)
                    .accessibilityIdentifier("\(accessibilityPrefix).number.\(track.id.externalID)")
            }
            Button(action: playAction) {
                MediaRow(
                    title: track.title,
                    subtitle: subtitle,
                    showsArtwork: false
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isPlayEnabled)
            .accessibilityIdentifier("\(accessibilityPrefix).play.\(track.id.externalID)")
            .accessibilityHint(L("播放歌曲"))

            Menu {
                Button(L("播放"), systemImage: "play.fill", action: playAction)
                    .disabled(!isPlayEnabled)
                    .accessibilityIdentifier("\(accessibilityPrefix).menu.play.\(track.id.externalID)")
                Button(L("查看歌曲详情"), systemImage: "info.circle", action: detailAction)
                    .accessibilityIdentifier("\(accessibilityPrefix).menu.detail.\(track.id.externalID)")
                TrackQueueMenuActions(
                    trackID: track.id,
                    accessibilityPrefix: "\(accessibilityPrefix).menu",
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addToPlaylist
                )
                Button(
                    track.isFavorite ? L("取消收藏") : L("收藏"),
                    systemImage: track.isFavorite ? "star.slash" : "star",
                    action: favoriteAction
                )
                .disabled(!isFavoriteEnabled)
                .accessibilityIdentifier("\(accessibilityPrefix).menu.favorite.\(track.id.externalID)")
                Divider()
                Button(role: .destructive, action: requestDelete) {
                    Label(L("删除歌曲"), systemImage: "trash")
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("\(accessibilityPrefix).menu.delete.\(track.id.externalID)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(
                        width: MusicFreeLayoutMetrics.minimumHitTarget,
                        height: MusicFreeLayoutMetrics.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            .accessibilityLabel(L("歌曲选项"))
            .accessibilityIdentifier("\(accessibilityPrefix).menu.\(track.id.externalID)")
            .padding(.trailing, MusicFreeSpacingTokens.contentInset)
        }
    }

}
