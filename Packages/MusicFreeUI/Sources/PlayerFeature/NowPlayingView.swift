import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SwiftUI

enum NowPlayingVerticalLayoutMode: Equatable {
    case pinnedQueue
    case scrolling
}

enum NowPlayingVerticalLayoutPolicy {
    static let minimumPinnedHeight: CGFloat = 500

    static func mode(
        availableHeight: CGFloat,
        verticalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize
    ) -> NowPlayingVerticalLayoutMode {
        guard availableHeight >= minimumPinnedHeight,
              verticalSizeClass != .compact,
              !dynamicTypeSize.isAccessibilitySize else {
            return .scrolling
        }
        return .pinnedQueue
    }
}

enum NowPlayingHeaderMetadata {
    static func artistSubtitle(_ artist: String?) -> String? {
        guard let artist else { return nil }
        let normalized = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func artistSubtitle(
        for track: Track?,
        artistNames: [ArtistID: String],
        fallback: String?
    ) -> String? {
        guard let track else {
            return artistSubtitle(fallback)
        }
        return artistSubtitle(
            QueueArtistNameLoader.subtitle(for: track, artistNames: artistNames)
        )
    }

    static func albumSubtitle(
        for track: Track?,
        albumNames: [AlbumID: String],
        fallback: String?
    ) -> String? {
        guard let track else {
            return fallback
        }
        guard let albumID = track.albumID else {
            return nil
        }
        return albumNames[albumID]
    }
}

struct NowPlayingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @ObservedObject private var viewModel: PlayerViewModel
    private let onShowQueue: () -> Void
    private let artworkServing: (any ArtworkServing)?
    private let library: (any LibraryServing)?

    @StateObject private var artworkLoader = ArtworkImageLoader()
    @State private var queueTracks: [MediaItemID: Track] = [:]
    @State private var queueArtistNames: [ArtistID: String] = [:]
    @State private var queueAlbumNames: [AlbumID: String] = [:]
    @State private var isLyricsPresented = false
    @StateObject private var favoriteController: PlayerFavoriteController

    init(
        viewModel: PlayerViewModel,
        onShowQueue: @escaping () -> Void,
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil
    ) {
        self.viewModel = viewModel
        self.onShowQueue = onShowQueue
        self.artworkServing = artworkServing
        self.library = library
        _favoriteController = StateObject(
            wrappedValue: PlayerFavoriteController(library: library)
        )
    }

    var body: some View {
        Group {
            switch viewModel.presentationState {
            case .empty:
                EmptyStateView(
                    title: L("当前没有播放内容"),
                    message: L("从资料库选择一首歌曲开始播放。"),
                    systemImage: "play.circle"
                )
            case .loading:
                LoadingStateView(isLoading: true, label: L("正在准备播放")) {
                    playbackContent
                }
            case .buffering:
                LoadingStateView(isLoading: true, label: L("正在缓冲")) {
                    playbackContent
                }
            case .playing, .paused, .stopped:
                playbackContent
            case .failed(let error):
                ErrorStateView(
                    title: L("播放失败"),
                    message: playerErrorMessage(error),
                    retryTitle: L("重试"),
                    retry: viewModel.play
                )
            case .unsupported:
                EmptyStateView(
                    title: L("暂不支持"),
                    message: L("当前播放引擎不支持此操作。"),
                    systemImage: "nosign"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: currentArtworkID,
                sourceID: viewModel.snapshot.currentItemID?.sourceID,
                serving: artworkServing
            )
        }
        .task(id: queueKey) {
            await loadQueueTracks()
        }
        .task {
            await observeLibraryChanges()
        }
        .task(id: viewModel.snapshot.currentItemID) {
            favoriteController.load(itemID: viewModel.snapshot.currentItemID)
        }
        .sheet(isPresented: $isLyricsPresented) {
            if let currentTrack, let lyrics = currentTrack.lyrics {
                NavigationStack {
                    LyricsView(
                        title: currentTrack.title,
                        lyrics: lyrics,
                        player: viewModel
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var playbackContent: some View {
        GeometryReader { geometry in
            let horizontalInset = MusicFreeSpacingTokens.large
            let contentWidth = max(0, geometry.size.width - (horizontalInset * 2))
            let topInset = MusicFreeSpacingTokens.xxLarge
            let bottomInset = MusicFreeSpacingTokens.large
            let contentHeight = max(0, geometry.size.height - topInset - bottomInset)
            let layoutMode = NowPlayingVerticalLayoutPolicy.mode(
                availableHeight: geometry.size.height,
                verticalSizeClass: verticalSizeClass,
                dynamicTypeSize: dynamicTypeSize
            )

            ZStack {
                playerBackdrop

                playbackLayout(
                    layoutMode,
                    contentWidth: contentWidth,
                    contentHeight: contentHeight,
                    viewportHeight: geometry.size.height,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func playbackLayout(
        _ mode: NowPlayingVerticalLayoutMode,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        switch mode {
        case .pinnedQueue:
            pinnedPlaybackContent(
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                topInset: topInset,
                bottomInset: bottomInset
            )
        case .scrolling:
            scrollingPlaybackContent(
                contentWidth: contentWidth,
                viewportHeight: viewportHeight,
                topInset: topInset,
                bottomInset: bottomInset
            )
        }
    }

    private func pinnedPlaybackContent(
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    header

                    modeControls
                        .padding(.top, MusicFreeSpacingTokens.xLarge)

                    continuePlayingContent(width: contentWidth)
                }
                .frame(width: contentWidth)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: contentWidth)
            .frame(maxHeight: .infinity)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.nowPlaying.upperScroll")

            bottomControls
        }
        .frame(width: contentWidth, height: contentHeight)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .clipped()
    }

    private func scrollingPlaybackContent(
        contentWidth: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                header

                modeControls
                    .padding(.top, MusicFreeSpacingTokens.xLarge)

                bottomControls
                    .padding(.top, MusicFreeSpacingTokens.xLarge)

                continuePlayingContent(width: contentWidth)
            }
            .frame(width: contentWidth)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: contentWidth, height: viewportHeight)
        .clipped()
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.nowPlaying.scroll")
    }

    private var playerBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: playerBackdropColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image = artworkLoader.image {
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 54)
                    .opacity(colorScheme == .dark ? 0.52 : 0.24)
                    .scaleEffect(1.18)

                LinearGradient(
                    colors: playerArtworkOverlayColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: MusicFreeSpacingTokens.medium) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: currentArtworkID == nil ? L("暂无封面") : L("封面"),
                fillsAvailableWidth: true
            )
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(currentTitle ?? L("正在播放"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(playerForegroundPrimary)
                    .lineLimit(2)

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(currentArtist) {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(playerForegroundSecondary)
                        .lineLimit(1)
                }

                if let album = currentAlbum {
                    Text(album)
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(playerForegroundTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button {
                favoriteController.toggle()
            } label: {
                Image(systemName: favoriteController.isFavorite ? "star.fill" : "star")
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(playerControlFill, in: Circle())
            }
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text(favoriteController.isFavorite ? L("取消收藏") : L("收藏")))

            Menu {
                ShareLink(item: shareText) {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
                if let itemID = viewModel.snapshot.currentItemID {
                    Button {
                        viewModel.send(.enqueue(itemID: itemID, at: nil))
                    } label: {
                        Label(L("加入播放队列"), systemImage: "text.append")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(playerControlFill, in: Circle())
            }
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text(L("更多操作")))
        }
    }

    private var modeControls: some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            Button {
                viewModel.setShuffle(
                    viewModel.snapshot.queue.shuffleMode == .on ? .off : .on
                )
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        viewModel.snapshot.queue.shuffleMode == .on
                            ? MusicFreeColorTokens.accent.opacity(0.82)
                            : playerControlFill,
                        in: Capsule()
                    )
            }
            .accessibilityLabel(Text(L("随机播放")))
            .accessibilityValue(
                Text(viewModel.snapshot.queue.shuffleMode == .on ? L("已开启") : L("已关闭"))
            )
            .accessibilityAddTraits(
                viewModel.snapshot.queue.shuffleMode == .on ? .isSelected : []
            )

            Menu {
                ForEach(PlaybackRepeatMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.setRepeatMode(mode)
                    } label: {
                        Label(repeatTitle(mode), systemImage: repeatIcon(mode))
                    }
                }
            } label: {
                Image(systemName: repeatIcon(viewModel.snapshot.queue.repeatMode))
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        viewModel.snapshot.queue.repeatMode == .off
                            ? playerControlFill
                            : MusicFreeColorTokens.accent.opacity(0.82),
                        in: Capsule()
                    )
            }
            .accessibilityLabel(Text(L("重复模式")))
            .accessibilityValue(Text(repeatTitle(viewModel.snapshot.queue.repeatMode)))
            .accessibilityAddTraits(
                viewModel.snapshot.queue.repeatMode == .off ? [] : .isSelected
            )

            Button {
                viewModel.setRepeatMode(
                    viewModel.snapshot.queue.repeatMode == .all ? .off : .all
                )
            } label: {
                Image(systemName: "infinity")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        viewModel.snapshot.queue.repeatMode == .all
                            ? MusicFreeColorTokens.accent.opacity(0.82)
                            : playerControlFill,
                        in: Capsule()
                    )
            }
            .accessibilityLabel(Text(L("连续播放")))
            .accessibilityValue(
                Text(viewModel.snapshot.queue.repeatMode == .all ? L("已开启") : L("已关闭"))
            )
            .accessibilityAddTraits(
                viewModel.snapshot.queue.repeatMode == .all ? .isSelected : []
            )

            Button(action: onShowQueue) {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(playerControlFill, in: Capsule())
            }
            .accessibilityLabel(Text(L("打开播放队列")))
            .accessibilityIdentifier("player.queue")
        }
        .foregroundStyle(playerForegroundPrimary)
    }

    private var shareText: String {
        let title = currentTitle ?? L("正在播放")
        guard let artist = currentArtist, !artist.isEmpty else { return title }
        return "\(title) - \(artist)"
    }

    @ViewBuilder
    private func continuePlayingContent(width: CGFloat) -> some View {
        let entries = viewModel.upcomingQueueEntries()

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                Text(L("继续播放"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(playerForegroundPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(entries) { entry in
                    ContinuePlayingRow(
                        entry: entry,
                        track: queueTracks[entry.itemID],
                        subtitle: QueueArtistNameLoader.subtitle(
                            for: queueTracks[entry.itemID],
                            artistNames: queueArtistNames
                        ),
                        artworkServing: artworkServing,
                        onSelect: { viewModel.send(.play(itemID: entry.itemID)) }
                    )
                }
            }
            .padding(.top, MusicFreeSpacingTokens.xLarge)
            .frame(width: width, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.continuePlaying.list")
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            progress

            transportControls
                .padding(.top, MusicFreeSpacingTokens.large)

            volumeControl
                .padding(.top, MusicFreeSpacingTokens.large)

            footerControls
                .padding(.top, MusicFreeSpacingTokens.xLarge)
        }
    }

    private var progress: some View {
        PlaybackProgressControl(viewModel: viewModel)
            .tint(playerForegroundPrimary)
            .foregroundStyle(playerForegroundSecondary)
    }

    private var transportControls: some View {
        HStack {
            PlaybackControlButton(
                systemImage: "backward.fill",
                accessibilityLabel: L("上一首"),
                isEnabled: viewModel.canGoPrevious,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 64,
                symbolFont: .system(size: 30, weight: .semibold),
                action: viewModel.previous
            )

            PlaybackControlButton(
                systemImage: viewModel.snapshot.phase == .playing ? "pause.fill" : "play.fill",
                accessibilityLabel: viewModel.snapshot.phase == .playing ? L("暂停") : L("播放"),
                isLoading: viewModel.presentationState == .loading || viewModel.presentationState == .buffering,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 72,
                symbolFont: .system(size: 36, weight: .semibold),
                action: viewModel.togglePlayback
            )

            PlaybackControlButton(
                systemImage: "forward.fill",
                accessibilityLabel: L("下一首"),
                isEnabled: viewModel.canGoNext,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 64,
                symbolFont: .system(size: 30, weight: .semibold),
                action: viewModel.next
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            Button {
                viewModel.setMuted(!viewModel.isMuted)
            } label: {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption)
                    .frame(width: MusicFreeLayoutMetrics.minimumHitTarget,
                           height: MusicFreeLayoutMetrics.minimumHitTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playerForegroundSecondary)
            .accessibilityLabel(Text(viewModel.isMuted ? L("取消静音") : L("静音")))

            Slider(
                value: Binding(
                    get: { Double(viewModel.displayedVolume) },
                    set: { viewModel.updateVolume(Float($0)) }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if !isEditing { viewModel.finishVolumeChange() }
                }
            )
            .tint(playerForegroundPrimary)

            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(playerForegroundSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("音量")))
    }

    private var footerControls: some View {
        HStack {
            Button {
                isLyricsPresented = true
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.title3)
            }
            .disabled(currentTrack?.lyrics == nil)
            .accessibilityLabel(Text(L("歌词")))
            .accessibilityValue(Text(currentTrack?.lyrics == nil ? L("无歌词") : L("可用")))

            Spacer()

            SystemAudioRoutePicker(
                accessibilityLabel: L("AirPlay")
            )
            .frame(
                width: MusicFreeLayoutMetrics.minimumHitTarget,
                height: MusicFreeLayoutMetrics.minimumHitTarget
            )

            Spacer()

            Button(action: onShowQueue) {
                Image(systemName: "list.bullet.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel(Text(L("播放队列")))
            .accessibilityIdentifier("player.queue.footer")
        }
        .foregroundStyle(playerForegroundSecondary)
    }

    private var artworkKey: String {
        "\(viewModel.snapshot.currentItemID?.sourceID.rawValue ?? ""):\(currentArtworkID?.rawValue ?? "")"
    }

    private var currentTrack: Track? {
        guard let itemID = viewModel.snapshot.currentItemID else { return nil }
        return queueTracks[itemID]
    }

    private var currentArtworkID: ArtworkID? {
        guard currentTrack != nil else {
            return viewModel.snapshot.currentItem?.artworkID
        }
        return currentTrack?.artworkID
    }

    private var currentTitle: String? {
        currentTrack?.title ?? viewModel.currentTitle
    }

    private var currentArtist: String? {
        NowPlayingHeaderMetadata.artistSubtitle(
            for: currentTrack,
            artistNames: queueArtistNames,
            fallback: viewModel.currentArtist
        )
    }

    private var currentAlbum: String? {
        NowPlayingHeaderMetadata.albumSubtitle(
            for: currentTrack,
            albumNames: queueAlbumNames,
            fallback: viewModel.snapshot.currentItem?.album
        )
    }

    private var playerBackdropColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.30, green: 0.25, blue: 0.26),
                Color(red: 0.08, green: 0.07, blue: 0.08)
            ]
        }
        return [
            Color(red: 0.98, green: 0.93, blue: 0.94),
            Color(red: 0.91, green: 0.94, blue: 0.96)
        ]
    }

    private var playerArtworkOverlayColors: [Color] {
        colorScheme == .dark
            ? [.black.opacity(0.16), .black.opacity(0.78)]
            : [.white.opacity(0.18), .white.opacity(0.76)]
    }

    private var playerForegroundPrimary: Color {
        MusicFreeColorTokens.foregroundPrimary
    }

    private var playerForegroundSecondary: Color {
        MusicFreeColorTokens.foregroundSecondary
    }

    private var playerForegroundTertiary: Color {
        MusicFreeColorTokens.foregroundTertiary
    }

    private var playerControlFill: Color {
        Color(.secondarySystemFill)
    }

    private var queueKey: String {
        viewModel.snapshot.queue.entries.map {
            "\($0.id.uuidString):\($0.itemID.sourceID.rawValue):\($0.itemID.externalID)"
        }.joined(separator: ",")
    }

    private func loadQueueTracks() async {
        guard let library else {
            queueTracks = [:]
            queueArtistNames = [:]
            queueAlbumNames = [:]
            return
        }

        let entries = viewModel.snapshot.queue.entries
        let expectedQueueKey = entries.map {
            "\($0.id.uuidString):\($0.itemID.sourceID.rawValue):\($0.itemID.externalID)"
        }.joined(separator: ",")
        var loaded: [MediaItemID: Track] = [:]
        for entry in entries {
            guard !Task.isCancelled else { return }
            if let track = try? await library.track(id: entry.itemID) {
                loaded[entry.itemID] = track
            }
        }
        guard !Task.isCancelled else { return }

        var loadedArtistNames: [ArtistID: String] = [:]
        do {
            loadedArtistNames = try await QueueArtistNameLoader.load(
                for: Array(loaded.values),
                from: library
            )
        } catch is CancellationError {
            return
        } catch {
            loadedArtistNames = [:]
        }

        var loadedAlbumNames: [AlbumID: String] = [:]
        let tracksBySource = Dictionary(grouping: loaded.values, by: { $0.id.sourceID })
        for (sourceID, tracks) in tracksBySource {
            guard !Task.isCancelled else { return }
            let albumIDs = Set(tracks.compactMap(\.albumID))
            do {
                loadedAlbumNames.merge(
                    try await QueueAlbumNameLoader.load(
                        albumIDs: albumIDs,
                        sourceID: sourceID,
                        from: library
                    ),
                    uniquingKeysWith: { _, new in new }
                )
            } catch is CancellationError {
                return
            } catch {
                // Album names are supplementary; keep the track and artist data usable.
            }
        }
        guard !Task.isCancelled, queueKey == expectedQueueKey else { return }
        queueTracks = loaded
        queueArtistNames = loadedArtistNames
        queueAlbumNames = loadedAlbumNames
    }

    private func observeLibraryChanges() async {
        guard let library else { return }
        let stream = await library.makeChangeStream()
        for await change in stream {
            guard !Task.isCancelled else { return }
            guard shouldReloadQueue(for: change) else { continue }
            await loadQueueTracks()
        }
    }

    private func shouldReloadQueue(for change: LibraryChange) -> Bool {
        let queueIDs = Set(viewModel.snapshot.queue.entries.map(\.itemID))
        guard !queueIDs.isEmpty else { return false }
        if !queueIDs.isDisjoint(with: change.affectedIDs.trackIDs) {
            return true
        }

        let artworkIDs = Set(queueTracks.values.compactMap(\.artworkID))
        if !artworkIDs.isDisjoint(with: change.affectedIDs.artworkIDs) {
            return true
        }

        let albumIDs = Set(queueTracks.values.compactMap(\.albumID))
        if !albumIDs.isDisjoint(with: change.affectedIDs.albumIDs) {
            return true
        }

        let artistIDs = Set(queueTracks.values.flatMap(\.artistIDs))
        return !artistIDs.isDisjoint(with: change.affectedIDs.artistIDs)
    }

    private func repeatIcon(_ mode: PlaybackRepeatMode) -> String {
        mode == .one ? "repeat.1" : "repeat"
    }

    private func repeatTitle(_ mode: PlaybackRepeatMode) -> String {
        switch mode {
        case .off: return L("关闭重复")
        case .one: return L("重复单曲")
        case .all: return L("重复队列")
        }
    }

    private func playerErrorMessage(_ error: PlaybackError) -> String {
        switch error {
        case .resourceUnavailable:
            return L("音频资源暂时不可用。")
        case .cancelled:
            return L("播放操作已取消。")
        default:
            return L("播放操作无法完成，请稍后重试。")
        }
    }
}

private struct ContinuePlayingRow: View {
    let entry: PlaybackQueueEntry
    let track: Track?
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: MusicFreeSpacingTokens.medium) {
                ArtworkResourceView(
                    artworkID: track?.artworkID,
                    sourceID: entry.itemID.sourceID,
                    serving: artworkServing,
                    accessibilityLabel: track?.artworkID == nil ? L("暂无封面") : L("封面"),
                    placeholderTitle: track?.title
                )

                VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                    Text(track?.title ?? L("正在载入歌曲"))
                        .font(MusicFreeTypographyTokens.rowTitle)
                        .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(MusicFreeTypographyTokens.rowSubtitle)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, MusicFreeSpacingTokens.small)
        .frame(minHeight: MusicFreeLayoutMetrics.compactRowMinimumHeight)
        .accessibilityLabel(Text(track?.title ?? L("播放队列歌曲")))
    }
}
