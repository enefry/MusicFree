import AppServices
import DesignSystem
import Foundation
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
    @State private var unavailableFeature: String?
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
                    title: "当前没有播放内容",
                    message: "从资料库选择一首歌曲开始播放。",
                    systemImage: "play.circle"
                )
            case .loading:
                LoadingStateView(isLoading: true, label: "正在准备播放") {
                    playbackContent
                }
            case .buffering:
                LoadingStateView(isLoading: true, label: "正在缓冲") {
                    playbackContent
                }
            case .playing, .paused, .stopped:
                playbackContent
            case .failed(let error):
                ErrorStateView(
                    title: "播放失败",
                    message: playerErrorMessage(error),
                    retryTitle: "重试",
                    retry: viewModel.play
                )
            case .unsupported:
                EmptyStateView(
                    title: "暂不支持",
                    message: "当前播放引擎不支持此操作。",
                    systemImage: "nosign"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: viewModel.snapshot.currentItem?.artworkID,
                sourceID: viewModel.snapshot.currentItemID?.sourceID,
                serving: artworkServing
            )
        }
        .task(id: queueKey) {
            await loadQueueTracks()
        }
        .task(id: viewModel.snapshot.currentItemID) {
            favoriteController.load(itemID: viewModel.snapshot.currentItemID)
        }
        .alert(
            "暂不可用",
            isPresented: Binding(
                get: { unavailableFeature != nil },
                set: { isPresented in
                    if !isPresented { unavailableFeature = nil }
                }
            )
        ) {
            Button("好", role: .cancel) { unavailableFeature = nil }
        } message: {
            Text(unavailableFeature ?? "当前播放引擎尚未提供此功能。")
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
                accessibilityLabel: viewModel.snapshot.currentItem?.artworkID == nil ? "暂无封面" : "封面",
                fillsAvailableWidth: true
            )
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(viewModel.currentTitle ?? "正在播放")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(playerForegroundPrimary)
                    .lineLimit(2)

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(viewModel.currentArtist) {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(playerForegroundSecondary)
                        .lineLimit(1)
                }

                if let album = viewModel.snapshot.currentItem?.album {
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
            .accessibilityLabel(Text(favoriteController.isFavorite ? "取消收藏" : "收藏"))

            Menu {
                ShareLink(item: shareText) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                if let itemID = viewModel.snapshot.currentItemID {
                    Button {
                        viewModel.send(.enqueue(itemID: itemID, at: nil))
                    } label: {
                        Label("加入播放队列", systemImage: "text.append")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(playerControlFill, in: Circle())
            }
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text("更多操作"))
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
            .accessibilityLabel(Text("随机播放"))
            .accessibilityValue(
                Text(viewModel.snapshot.queue.shuffleMode == .on ? "已开启" : "已关闭")
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
            .accessibilityLabel(Text("重复模式"))
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
            .accessibilityLabel(Text("连续播放"))
            .accessibilityValue(
                Text(viewModel.snapshot.queue.repeatMode == .all ? "已开启" : "已关闭")
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
            .accessibilityLabel(Text("打开播放队列"))
            .accessibilityIdentifier("player.queue")
        }
        .foregroundStyle(playerForegroundPrimary)
    }

    private var shareText: String {
        let title = viewModel.currentTitle ?? "正在播放"
        guard let artist = viewModel.currentArtist, !artist.isEmpty else { return title }
        return "\(title) - \(artist)"
    }

    @ViewBuilder
    private func continuePlayingContent(width: CGFloat) -> some View {
        let entries = viewModel.upcomingQueueEntries()

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                Text("继续播放")
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
                accessibilityLabel: "上一首",
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
                accessibilityLabel: viewModel.snapshot.phase == .playing ? "暂停" : "播放",
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
                accessibilityLabel: "下一首",
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
            .accessibilityLabel(Text(viewModel.isMuted ? "取消静音" : "静音"))

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
        .accessibilityLabel(Text("音量"))
    }

    private var footerControls: some View {
        HStack {
            Button {
                unavailableFeature = "当前音频源没有可显示的歌词。"
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.title3)
            }
            .accessibilityLabel(Text("歌词"))

            Spacer()

            Button {
                unavailableFeature = "当前版本暂不支持 AirPlay 输出。"
            } label: {
                Image(systemName: "airplayaudio")
                    .font(.title3)
            }
            .accessibilityLabel(Text("AirPlay"))

            Spacer()

            Button(action: onShowQueue) {
                Image(systemName: "list.bullet.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel(Text("播放队列"))
            .accessibilityIdentifier("player.queue.footer")
        }
        .foregroundStyle(playerForegroundSecondary)
    }

    private var artworkKey: String {
        "\(viewModel.snapshot.currentItemID?.sourceID.rawValue ?? ""):\(viewModel.snapshot.currentItem?.artworkID?.rawValue ?? "")"
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
        viewModel.snapshot.queue.entries.map { $0.id.uuidString }.joined(separator: ",")
    }

    private func loadQueueTracks() async {
        guard let library else {
            queueTracks = [:]
            queueArtistNames = [:]
            return
        }

        var loaded: [MediaItemID: Track] = [:]
        for entry in viewModel.snapshot.queue.entries {
            guard !Task.isCancelled else { return }
            if let track = try? await library.track(id: entry.itemID) {
                loaded[entry.itemID] = track
            }
        }
        guard !Task.isCancelled else { return }
        queueTracks = loaded

        let artistIDs = Set(loaded.values.flatMap(\.artistIDs))
        do {
            let names = try await QueueArtistNameLoader.load(
                artistIDs: artistIDs,
                from: library
            )
            guard !Task.isCancelled else { return }
            queueArtistNames = names
        } catch is CancellationError {
            return
        } catch {
            queueArtistNames = [:]
        }
    }

    private func repeatIcon(_ mode: PlaybackRepeatMode) -> String {
        mode == .one ? "repeat.1" : "repeat"
    }

    private func repeatTitle(_ mode: PlaybackRepeatMode) -> String {
        switch mode {
        case .off: return "关闭重复"
        case .one: return "重复单曲"
        case .all: return "重复队列"
        }
    }

    private func playerErrorMessage(_ error: PlaybackError) -> String {
        switch error {
        case .resourceUnavailable:
            return "音频资源暂时不可用。"
        case .cancelled:
            return "播放操作已取消。"
        default:
            return "播放操作无法完成，请稍后重试。"
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
                    accessibilityLabel: track?.artworkID == nil ? "暂无封面" : "封面",
                    placeholderTitle: track?.title
                )

                VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                    Text(track?.title ?? "正在载入歌曲")
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
        .accessibilityLabel(Text(track?.title ?? "播放队列歌曲"))
    }
}
