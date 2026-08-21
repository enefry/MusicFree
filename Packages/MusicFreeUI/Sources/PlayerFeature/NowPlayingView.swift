import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SwiftUI

enum NowPlayingSurface: Equatable {
    case artwork
    case lyrics
    case queue
}

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

private enum NowPlayingLayoutMetrics {
    static let horizontalInset: CGFloat = 32
    static let topChromeInset: CGFloat = 31
    static let pinnedControlsHeight: CGFloat = 308
    // Compact-height presentations keep transport controls pinned below a
    // smaller, independently scrolling upper surface.
    static let compactControlsHeight: CGFloat = 216
    static let compactHeaderHeight: CGFloat = 72
    static let footerHeight: CGFloat = 56
    static let headerArtworkSize: CGFloat = 72
    static let headerActionSize: CGFloat = 40
    static let headerActionSpacing: CGFloat = 8
    static let headerContentSpacing: CGFloat = 12
    static let queueRowArtworkSize: CGFloat = 48
    static let queueRowHeight: CGFloat = 60
    static let queueRowActionWidth: CGFloat = 40

    static var headerActionsWidth: CGFloat {
        (headerActionSize * 2) + headerActionSpacing
    }

    static func headerTextWidth(
        contentWidth: CGFloat,
        leadingWidth: CGFloat = 0
    ) -> CGFloat {
        max(
            0,
            contentWidth
                - leadingWidth
                - (leadingWidth > 0 ? headerContentSpacing : 0)
                - headerActionsWidth
                - headerContentSpacing
        )
    }

    static func queueRowTextWidth(contentWidth: CGFloat) -> CGFloat {
        max(
            0,
            contentWidth
                - queueRowArtworkSize
                - headerContentSpacing
                - queueRowActionWidth
                - headerContentSpacing
        )
    }
}

enum NowPlayingHeaderMetadata {
    static func title(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

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
            return artistSubtitle(fallback)
        }
        guard let albumID = track.albumID else {
            return nil
        }
        return albumNames[albumID]
    }
}

struct NowPlayingView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var viewModel: PlayerViewModel
    private let onShowQueue: () -> Void
    @Binding private var isMoreActionsPresented: Bool
    private let artworkServing: (any ArtworkServing)?
    private let library: (any LibraryServing)?
    private let lyricsServing: (any LyricsServing)?

    @StateObject private var artworkLoader = ArtworkImageLoader()
    @StateObject private var favoriteController: PlayerFavoriteController
    @State private var queueTracks: [MediaItemID: Track] = [:]
    @State private var queueArtistNames: [ArtistID: String] = [:]
    @State private var queueAlbumNames: [AlbumID: String] = [:]
    @State private var surface: NowPlayingSurface = .artwork
    @State private var isMoreActionsDismissEnabled = false

    init(
        viewModel: PlayerViewModel,
        onShowQueue: @escaping () -> Void = {},
        isMoreActionsPresented: Binding<Bool> = .constant(false),
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil
    ) {
        self.viewModel = viewModel
        self.onShowQueue = onShowQueue
        self._isMoreActionsPresented = isMoreActionsPresented
        self.artworkServing = artworkServing
        self.library = library
        self.lyricsServing = lyricsServing
        _favoriteController = StateObject(
            wrappedValue: PlayerFavoriteController(library: library)
        )
    }

    var body: some View {
        ZStack {
            playerBackdrop
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if isMoreActionsPresented {
                moreActionsOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L("正在播放")))
                .accessibilityIdentifier("player.nowPlaying")
                .allowsHitTesting(false)
        }
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
        .onChange(of: viewModel.snapshot.currentItemID) { _, _ in
            surface = .artwork
        }
    }

    private var moreActionsOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .onTapGesture {
                    guard isMoreActionsDismissEnabled else { return }
                    isMoreActionsPresented = false
                    isMoreActionsDismissEnabled = false
                }

            NowPlayingActionsPanel(
                shareText: shareText,
                canEnqueue: viewModel.snapshot.currentItemID != nil,
                onEnqueue: {
                    guard let itemID = viewModel.snapshot.currentItemID else {
                        isMoreActionsPresented = false
                        isMoreActionsDismissEnabled = false
                        return
                    }
                    viewModel.send(.enqueue(itemID: itemID, at: nil))
                    isMoreActionsPresented = false
                    isMoreActionsDismissEnabled = false
                },
                onManageQueue: {
                    isMoreActionsPresented = false
                    isMoreActionsDismissEnabled = false
                    // Let the overlay leave the hit-test tree before opening
                    // the queue sheet from the same presentation host.
                    DispatchQueue.main.async {
                        onShowQueue()
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .zIndex(2)
    }

    private var playbackContent: some View {
        GeometryReader { geometry in
            let contentWidth = max(
                0,
                geometry.size.width - (NowPlayingLayoutMetrics.horizontalInset * 2)
            )
            let layoutMode = NowPlayingVerticalLayoutPolicy.mode(
                availableHeight: geometry.size.height,
                verticalSizeClass: verticalSizeClass,
                dynamicTypeSize: dynamicTypeSize
            )
            // GeometryReader is already laid out inside the safe-area content
            // region. Only reserve the gap below the root drag handle here.
            let topChromeInset = NowPlayingLayoutMetrics.topChromeInset
            let pinnedSurfaceHeight = max(
                0,
                geometry.size.height
                    - topChromeInset
                    - NowPlayingLayoutMetrics.pinnedControlsHeight
            )

            ZStack(alignment: .top) {
                if layoutMode == .scrolling {
                    let compactSurfaceHeight = max(
                        0,
                        geometry.size.height
                            - topChromeInset
                            - NowPlayingLayoutMetrics.compactControlsHeight
                    )

                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            surfaceContent(
                                contentWidth: contentWidth,
                                surfaceHeight: compactSurfaceHeight
                            )
                            .frame(
                                width: contentWidth,
                                height: compactSurfaceHeight,
                                alignment: .top
                            )

                            compactBottomControls
                                .frame(
                                    width: contentWidth,
                                    height: NowPlayingLayoutMetrics.compactControlsHeight,
                                    alignment: .top
                                )
                        }
                        .frame(width: geometry.size.width, alignment: .top)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentMargins(.top, topChromeInset, for: .scrollContent)
                    .contentMargins(.bottom, 0, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player.nowPlaying.scroll")
                } else {
                    playerColumn(
                        viewportWidth: geometry.size.width,
                        contentWidth: contentWidth,
                        surfaceHeight: pinnedSurfaceHeight,
                        topChromeInset: topChromeInset,
                        isPinned: true
                    )
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playerColumn(
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        surfaceHeight: CGFloat,
        topChromeInset: CGFloat,
        isPinned: Bool
    ) -> some View {
        VStack(spacing: 0) {
            surfaceContent(
                contentWidth: contentWidth,
                surfaceHeight: surfaceHeight
            )
            .frame(width: contentWidth, height: surfaceHeight)

            bottomControls
                .frame(
                    width: contentWidth,
                    height: isPinned ? NowPlayingLayoutMetrics.pinnedControlsHeight : nil,
                    alignment: .top
                )
        }
        .frame(width: viewportWidth, alignment: .top)
        // The root player overlay owns the visible drag indicator. Keep the
        // content below that safe-area chrome.
        .padding(.top, topChromeInset)
    }

    @ViewBuilder
    private func surfaceContent(
        contentWidth: CGFloat,
        surfaceHeight: CGFloat
    ) -> some View {
        switch surface {
        case .artwork:
            artworkSurface(contentWidth: contentWidth, surfaceHeight: surfaceHeight)
        case .lyrics:
            lyricsSurface(contentWidth: contentWidth, surfaceHeight: surfaceHeight)
        case .queue:
            queueSurface(contentWidth: contentWidth, surfaceHeight: surfaceHeight)
        }
    }

    private func artworkSurface(contentWidth: CGFloat, surfaceHeight: CGFloat) -> some View {
        let dimension = min(260, max(180, contentWidth - 64))
        let usesPortraitSpacing = verticalSizeClass != .compact
        let metadataBottomSpacing = usesPortraitSpacing ? 24.0 : 16.0

        return VStack(spacing: 0) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: currentArtworkID == nil ? L("暂无封面") : L("封面"),
                fillsAvailableWidth: true,
                cornerRadius: 0
            )
            .frame(width: dimension, height: dimension)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
            .padding(.top, 14)

            Spacer(minLength: 0)

            artworkMetadata(contentWidth: contentWidth)
                .padding(.bottom, metadataBottomSpacing)
        }
        .frame(width: contentWidth, height: surfaceHeight, alignment: .top)
        .accessibilityIdentifier("player.nowPlaying.artwork")
        .accessibilityElement(children: .contain)
    }

    private func artworkMetadata(contentWidth: CGFloat) -> some View {
        let textWidth = NowPlayingLayoutMetrics.headerTextWidth(
            contentWidth: contentWidth
        )

        return HStack(
            alignment: .center,
            spacing: NowPlayingLayoutMetrics.headerContentSpacing
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle ?? L("正在播放"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(playerForegroundPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(currentArtist) {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(playerForegroundSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: textWidth, alignment: .leading)
            .clipped()

            headerActions
        }
        .frame(width: contentWidth, alignment: .leading)
        .clipped()
    }

    private func compactHeader(contentWidth: CGFloat) -> some View {
        let textWidth = NowPlayingLayoutMetrics.headerTextWidth(
            contentWidth: contentWidth,
            leadingWidth: NowPlayingLayoutMetrics.headerArtworkSize
        )

        return HStack(
            alignment: .center,
            spacing: NowPlayingLayoutMetrics.headerContentSpacing
        ) {
            ArtworkView(
                image: artworkLoader.image,
                accessibilityLabel: currentArtworkID == nil ? L("暂无封面") : L("封面"),
                fillsAvailableWidth: true,
                cornerRadius: 12
            )
            .frame(
                width: NowPlayingLayoutMetrics.headerArtworkSize,
                height: NowPlayingLayoutMetrics.headerArtworkSize
            )
            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(currentTitle ?? L("正在播放"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(playerForegroundPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(currentArtist) {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(playerForegroundSecondary)
                    .lineLimit(1)
                }
            }
            .frame(width: textWidth, alignment: .leading)
            .clipped()

            headerActions
        }
        .frame(
            width: contentWidth,
            height: NowPlayingLayoutMetrics.compactHeaderHeight,
            alignment: .leading
        )
        .clipped()
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                favoriteController.toggle()
            } label: {
                Image(systemName: favoriteController.isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(playerControlFill, in: Circle())
            }
            .frame(width: 40, height: 40)
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text(favoriteController.isFavorite ? L("取消收藏") : L("收藏")))

            Button {
                isMoreActionsDismissEnabled = false
                isMoreActionsPresented = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard isMoreActionsPresented else { return }
                    isMoreActionsDismissEnabled = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(playerControlFill, in: Circle())
            }
            .frame(width: 40, height: 40)
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text(L("更多操作")))
        }
        .fixedSize()
    }

    private func queueSurface(contentWidth: CGFloat, surfaceHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    compactHeader(contentWidth: contentWidth)
                    .padding(.top, 0)

                    queueModeControls(contentWidth: contentWidth)
                    .padding(.top, 16)

                    continuePlayingContent(contentWidth: contentWidth)
                    .padding(.top, 16)
                }
                .frame(width: contentWidth, alignment: .top)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("player.nowPlaying.upperScroll")

            LinearGradient(
                colors: [.clear, .black.opacity(0.16)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)
        }
        .frame(width: contentWidth, height: surfaceHeight, alignment: .top)
    }

    private func lyricsSurface(contentWidth: CGFloat, surfaceHeight: CGFloat) -> some View {
        let lyricsContentHeight = max(
            0,
            surfaceHeight
                - NowPlayingLayoutMetrics.compactHeaderHeight
                - 12
                - 4
                - NowPlayingLayoutMetrics.footerHeight
        )

        return VStack(spacing: 0) {
            compactHeader(contentWidth: contentWidth)

            lyricsView
                .frame(width: contentWidth, height: lyricsContentHeight)
                .padding(.top, 12)

            lyricsActionBar
                .frame(width: contentWidth, height: NowPlayingLayoutMetrics.footerHeight)
                .padding(.top, 4)
        }
        .frame(width: contentWidth, height: surfaceHeight, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private var lyricsActionBar: some View {
        HStack {
            Menu {
                Button(L("重置歌词偏移")) {
                    NotificationCenter.default.post(
                        name: .musicFreeResetLyricsOffset,
                        object: nil
                    )
                }
            } label: {
                Image(systemName: "character.bubble")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(playerControlFill, in: Circle())
            }
            .foregroundStyle(playerForegroundPrimary)
            .accessibilityLabel(Text(L("歌词设置")))

            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.title3.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(playerControlFill.opacity(0.46), in: Circle())
                .foregroundStyle(playerForegroundTertiary)
                .accessibilityLabel(Text(L("歌词增强不可用")))
        }
    }

    private var lyricsView: some View {
        LyricsView(
            title: currentTitle ?? L("正在播放"),
            lyrics: currentTrack?.lyrics,
            query: currentLyricsQuery,
            lyricsServing: lyricsServing,
            player: viewModel,
            presentation: .embedded
        )
    }

    private func queueModeControls(contentWidth: CGFloat) -> some View {
        let buttonWidth = max(0, (contentWidth - (12 * 3)) / 4)

        return HStack(spacing: 12) {
            modeButton(
                systemImage: "shuffle",
                title: L("随机播放"),
                isSelected: viewModel.snapshot.queue.shuffleMode == .on,
                isEnabled: true,
                width: buttonWidth
            ) {
                viewModel.setShuffle(
                    viewModel.snapshot.queue.shuffleMode == .on ? .off : .on
                )
            }

            modeButton(
                systemImage: "repeat.1",
                title: L("重复单曲"),
                isSelected: viewModel.snapshot.queue.repeatMode == .one,
                isEnabled: true,
                width: buttonWidth
            ) {
                viewModel.setRepeatMode(
                    viewModel.snapshot.queue.repeatMode == .one ? .off : .one
                )
            }

            modeButton(
                systemImage: "infinity",
                title: L("重复队列"),
                isSelected: viewModel.snapshot.queue.repeatMode == .all,
                isEnabled: true,
                width: buttonWidth
            ) {
                viewModel.setRepeatMode(
                    viewModel.snapshot.queue.repeatMode == .all ? .off : .all
                )
            }

            modeButton(
                systemImage: "waveform.path.ecg",
                title: L("淡入淡出"),
                isSelected: viewModel.snapshot.effectiveEffects.transition.mode == .crossfade,
                isEnabled: viewModel.snapshot.capabilities.contains(.crossfade),
                width: buttonWidth
            ) {}
        }
        .frame(width: contentWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("播放模式")))
        .accessibilityIdentifier("player.nowPlaying.modeControls")
    }

    private func modeButton(
        systemImage: String,
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: width, height: 40)
                .background(
                    isSelected ? playerSelectedControlFill : playerControlFill,
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerForegroundPrimary)
        .opacity(isEnabled ? 1 : 0.36)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isEnabled ? (isSelected ? L("已开启") : L("已关闭")) : L("不可用")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func continuePlayingContent(contentWidth: CGFloat) -> some View {
        let entries = viewModel.upcomingQueueEntries().filter { $0.itemID != nil }

        return VStack(alignment: .leading, spacing: 0) {
            Text(L("继续播放"))
                .font(.title2.weight(.bold))
                .foregroundStyle(playerForegroundPrimary)

            if let album = currentAlbum {
                Text(L("From %@", album))
                    .font(.title3)
                    .foregroundStyle(playerForegroundSecondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            if entries.isEmpty {
                Text(L("队列末尾"))
                    .font(.body)
                    .foregroundStyle(playerForegroundSecondary)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        if let itemID = entry.itemID {
                            ContinuePlayingRow(
                                entry: entry,
                                itemID: itemID,
                                track: queueTracks[itemID],
                                subtitle: QueueArtistNameLoader.subtitle(
                                    for: queueTracks[itemID],
                                    artistNames: queueArtistNames
                                ),
                                artworkServing: artworkServing,
                                onSelect: { viewModel.send(.play(itemID: itemID)) },
                                foregroundPrimary: playerForegroundPrimary,
                                foregroundSecondary: playerForegroundSecondary,
                                foregroundTertiary: playerForegroundTertiary,
                                contentWidth: contentWidth
                            )
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.continuePlaying.list")
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            playerProgress

            transportControls
                .padding(.top, 26)

            volumeControl
                .padding(.top, 28)

            footerControls
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
    }

    private var compactBottomControls: some View {
        VStack(spacing: 0) {
            playerProgress

            compactTransportControls
                .padding(.top, 8)

            compactVolumeControl
                .padding(.top, 6)

            compactFooterControls
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var compactTransportControls: some View {
        HStack(spacing: 14) {
            PlaybackControlButton(
                systemImage: "backward.fill",
                accessibilityLabel: L("上一首"),
                isEnabled: viewModel.canGoPrevious,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 56,
                symbolFont: .system(size: 24, weight: .semibold),
                action: viewModel.previous
            )

            PlaybackControlButton(
                systemImage: viewModel.snapshot.phase == .playing ? "pause.fill" : "play.fill",
                accessibilityLabel: viewModel.snapshot.phase == .playing ? L("暂停") : L("播放"),
                isLoading: viewModel.presentationState == .loading || viewModel.presentationState == .buffering,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 64,
                symbolFont: .system(size: 30, weight: .semibold),
                action: viewModel.togglePlayback
            )

            PlaybackControlButton(
                systemImage: "forward.fill",
                accessibilityLabel: L("下一首"),
                isEnabled: viewModel.canGoNext,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 56,
                symbolFont: .system(size: 24, weight: .semibold),
                action: viewModel.next
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }

    private var compactVolumeControl: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.setMuted(!viewModel.isMuted)
            } label: {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playerForegroundSecondary)
            .accessibilityLabel(Text(viewModel.isMuted ? L("取消静音") : L("静音")))

            CompactPlayerSlider(
                value: Binding(
                    get: { Double(viewModel.displayedVolume) },
                    set: { viewModel.updateVolume(Float($0)) }
                ),
                in: 0...1,
                accessibilityLabel: L("音量"),
                accessibilityValue: {
                    "\(Int((viewModel.displayedVolume * 100).rounded()))%"
                },
                minimumTrackColor: .white.withAlphaComponent(0.64),
                maximumTrackColor: .white.withAlphaComponent(0.24),
                thumbColor: .white.withAlphaComponent(0.64),
                onEditingChanged: { isEditing in
                    if !isEditing { viewModel.finishVolumeChange() }
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 16, maxHeight: 16)

            Image(systemName: "speaker.wave.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(playerForegroundSecondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("音量")))
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private var compactFooterControls: some View {
        HStack(spacing: 24) {
            footerButton(
                systemImage: surface == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                title: surface == .lyrics ? L("返回播放器") : L("歌词"),
                isSelected: surface == .lyrics,
                isEnabled: currentTrack != nil && (currentTrack?.lyrics != nil || lyricsServing != nil),
                controlSize: 44
            ) {
                surface = surface == .lyrics ? .artwork : .lyrics
            }
            .accessibilityIdentifier("player.lyrics.footer")

            SystemAudioRoutePicker(
                accessibilityLabel: L("AirPlay"),
                tintColor: .white
            )
            .frame(width: 44, height: 44)

            footerButton(
                systemImage: "list.bullet",
                title: surface == .queue ? L("返回播放器") : L("播放队列"),
                isSelected: surface == .queue,
                isEnabled: true,
                controlSize: 44
            ) {
                surface = surface == .queue ? .artwork : .queue
            }
            .accessibilityIdentifier("player.queue.footer")
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .foregroundStyle(playerForegroundSecondary)
    }

    private var playerProgress: some View {
        VStack(spacing: 8) {
            CompactPlayerSlider(
                value: Binding(
                    get: { PlayerFormatting.seconds(viewModel.displayedPosition) },
                    set: { viewModel.updateSeeking(to: .seconds($0)) }
                ),
                in: 0...max(PlayerFormatting.seconds(viewModel.duration ?? .zero), 1),
                accessibilityLabel: L("播放进度"),
                accessibilityValue: {
                    "\(PlayerFormatting.duration(viewModel.displayedPosition)) / "
                        + PlayerFormatting.remaining(
                            position: viewModel.displayedPosition,
                            duration: viewModel.duration
                        )
                },
                minimumTrackColor: .white.withAlphaComponent(0.96),
                maximumTrackColor: .white.withAlphaComponent(0.24),
                thumbColor: .white.withAlphaComponent(0.96),
                onEditingChanged: { isEditing in
                    if isEditing {
                        viewModel.beginSeeking()
                    } else {
                        viewModel.finishSeeking()
                    }
                }
            )
            .disabled(!viewModel.canSeek)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 20, maxHeight: 20)

            HStack {
                Text(PlayerFormatting.duration(viewModel.displayedPosition))

                Spacer(minLength: 8)

                if viewModel.snapshot.phase == .paused {
                    Label(L("已暂停"), systemImage: "speaker.slash.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(playerControlFill, in: Capsule(style: .continuous))
                }

                Spacer(minLength: 8)

                Text(
                    PlayerFormatting.remaining(
                        position: viewModel.displayedPosition,
                        duration: viewModel.duration
                    )
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(playerForegroundSecondary)
            .accessibilityHidden(true)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 22) {
            PlaybackControlButton(
                systemImage: "backward.fill",
                accessibilityLabel: L("上一首"),
                isEnabled: viewModel.canGoPrevious,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 72,
                symbolFont: .system(size: 34, weight: .semibold),
                action: viewModel.previous
            )

            PlaybackControlButton(
                systemImage: viewModel.snapshot.phase == .playing ? "pause.fill" : "play.fill",
                accessibilityLabel: viewModel.snapshot.phase == .playing ? L("暂停") : L("播放"),
                isLoading: viewModel.presentationState == .loading || viewModel.presentationState == .buffering,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 88,
                symbolFont: .system(size: 42, weight: .semibold),
                action: viewModel.togglePlayback
            )

            PlaybackControlButton(
                systemImage: "forward.fill",
                accessibilityLabel: L("下一首"),
                isEnabled: viewModel.canGoNext,
                foregroundColor: playerForegroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 72,
                symbolFont: .system(size: 34, weight: .semibold),
                action: viewModel.next
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.setMuted(!viewModel.isMuted)
            } label: {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playerForegroundSecondary)
            .accessibilityLabel(Text(viewModel.isMuted ? L("取消静音") : L("静音")))

            CompactPlayerSlider(
                value: Binding(
                    get: { Double(viewModel.displayedVolume) },
                    set: { viewModel.updateVolume(Float($0)) }
                ),
                in: 0...1,
                accessibilityLabel: L("音量"),
                accessibilityValue: {
                    "\(Int((viewModel.displayedVolume * 100).rounded()))%"
                },
                minimumTrackColor: .white.withAlphaComponent(0.64),
                maximumTrackColor: .white.withAlphaComponent(0.24),
                thumbColor: .white.withAlphaComponent(0.64),
                onEditingChanged: { isEditing in
                    if !isEditing { viewModel.finishVolumeChange() }
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 20, maxHeight: 20)

            Image(systemName: "speaker.wave.2.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(playerForegroundSecondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("音量")))
    }

    private var footerControls: some View {
        HStack(spacing: 60) {
            footerButton(
                systemImage: surface == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                title: surface == .lyrics ? L("返回播放器") : L("歌词"),
                isSelected: surface == .lyrics,
                isEnabled: currentTrack != nil && (currentTrack?.lyrics != nil || lyricsServing != nil)
            ) {
                surface = surface == .lyrics ? .artwork : .lyrics
            }
            .accessibilityIdentifier("player.lyrics.footer")

            SystemAudioRoutePicker(
                accessibilityLabel: L("AirPlay"),
                tintColor: .white
            )
            .frame(width: 56, height: 56)

            footerButton(
                systemImage: "list.bullet",
                title: surface == .queue ? L("返回播放器") : L("播放队列"),
                isSelected: surface == .queue,
                isEnabled: true
            ) {
                surface = surface == .queue ? .artwork : .queue
            }
            .accessibilityIdentifier("player.queue.footer")
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .foregroundStyle(playerForegroundSecondary)
    }

    private func footerButton(
        systemImage: String,
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        controlSize: CGFloat = 56,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: controlSize, height: controlSize)
                .background(
                    isSelected ? playerSelectedControlFill : .clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerForegroundSecondary)
        .opacity(isEnabled ? 1 : 0.34)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
    }

    private var playerBackdrop: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image = artworkLoader.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .blur(radius: 42)
                        .scaleEffect(1.24)
                        .opacity(0.9)

                    LinearGradient(
                        colors: [
                            .black.opacity(0.16),
                            .black.opacity(0.28),
                            .black.opacity(0.68)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var playerForegroundPrimary: Color {
        .white.opacity(0.96)
    }

    private var playerForegroundSecondary: Color {
        .white.opacity(0.64)
    }

    private var playerForegroundTertiary: Color {
        .white.opacity(0.38)
    }

    private var playerControlFill: Color {
        .white.opacity(0.13)
    }

    private var playerSelectedControlFill: Color {
        .white.opacity(0.42)
    }

    private var artworkKey: String {
        "\(viewModel.snapshot.currentItemID?.sourceID.rawValue ?? ""):\(currentArtworkID?.rawValue ?? "")"
    }

    private var currentTrack: Track? {
        guard let itemID = viewModel.snapshot.currentItemID else { return nil }
        return queueTracks[itemID]
    }

    private var currentArtworkID: ArtworkID? {
        currentTrack?.artworkID ?? viewModel.snapshot.currentItem?.artworkID
    }

    private var currentTitle: String? {
        NowPlayingHeaderMetadata.title(currentTrack?.title ?? viewModel.currentTitle)
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

    private var currentLyricsQuery: LyricsQuery? {
        guard let currentTrack,
              let title = currentTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let durationSeconds: TimeInterval?
        if let duration = currentTrack.duration ?? viewModel.snapshot.duration {
            let components = duration.components
            durationSeconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        } else {
            durationSeconds = nil
        }
        return LyricsQuery(
            itemID: currentTrack.id,
            title: title,
            artistName: currentArtist,
            albumName: currentAlbum,
            durationSeconds: durationSeconds
        )
    }

    private var shareText: String {
        let title = currentTitle ?? L("正在播放")
        guard let artist = currentArtist, !artist.isEmpty else { return title }
        return "\(title) - \(artist)"
    }

    private var queueKey: String {
        viewModel.snapshot.queue.entries.map { entry in
            guard let itemID = entry.itemID else {
                return "\(entry.id.uuidString):logical:\(entry.logicalTrackID.rawValue)"
            }
            return "\(entry.id.uuidString):\(itemID.sourceID.rawValue):\(itemID.externalID)"
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
        let expectedQueueKey = entries.map { entry in
            guard let itemID = entry.itemID else {
                return "\(entry.id.uuidString):logical:\(entry.logicalTrackID.rawValue)"
            }
            return "\(entry.id.uuidString):\(itemID.sourceID.rawValue):\(itemID.externalID)"
        }.joined(separator: ",")
        var loaded: [MediaItemID: Track] = [:]
        for entry in entries {
            guard !Task.isCancelled else { return }
            guard let itemID = entry.itemID else { continue }
            if let track = try? await library.track(id: itemID) {
                loaded[itemID] = track
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
                // Album metadata is supplementary; keep the player usable.
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
        let queueIDs = Set(viewModel.snapshot.queue.entries.compactMap(\.itemID))
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
    let itemID: MediaItemID
    let track: Track?
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?
    let onSelect: () -> Void
    let foregroundPrimary: Color
    let foregroundSecondary: Color
    let foregroundTertiary: Color
    let contentWidth: CGFloat

    var body: some View {
        let textWidth = NowPlayingLayoutMetrics.queueRowTextWidth(
            contentWidth: contentWidth
        )

        Button(action: onSelect) {
            HStack(spacing: NowPlayingLayoutMetrics.headerContentSpacing) {
                ArtworkResourceView(
                    artworkID: track?.artworkID,
                    sourceID: itemID.sourceID,
                    serving: artworkServing,
                    accessibilityLabel: track?.artworkID == nil ? L("暂无封面") : L("封面"),
                    placeholderTitle: track?.title,
                    fillsAvailableWidth: true,
                    cornerRadius: 6
                )
                .frame(
                    width: NowPlayingLayoutMetrics.queueRowArtworkSize,
                    height: NowPlayingLayoutMetrics.queueRowArtworkSize
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? L("正在载入歌曲"))
                        .font(.body)
                        .foregroundStyle(foregroundPrimary)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(foregroundSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: textWidth, alignment: .leading)
                .clipped()

                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundStyle(foregroundTertiary)
                    .frame(
                        width: NowPlayingLayoutMetrics.queueRowActionWidth,
                        height: NowPlayingLayoutMetrics.queueRowArtworkSize,
                        alignment: .trailing
                    )
            }
            .frame(
                width: contentWidth,
                height: NowPlayingLayoutMetrics.queueRowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(track?.title ?? L("播放队列歌曲")))
    }
}

struct NowPlayingActionsPanel: View {
    let shareText: String
    let canEnqueue: Bool
    let onEnqueue: () -> Void
    let onManageQueue: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(L("更多操作"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ShareLink(item: shareText) {
                    actionRow(title: L("分享"), systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel(Text(L("分享")))
                .accessibilityIdentifier("player.nowPlaying.actions.share")

                if canEnqueue {
                    Button(action: onEnqueue) {
                        actionRow(title: L("加入播放队列"), systemImage: "text.append")
                    }
                    .accessibilityLabel(Text(L("加入播放队列")))
                    .accessibilityIdentifier("player.nowPlaying.actions.enqueue")
                }

                Button(action: onManageQueue) {
                    actionRow(title: L("管理完整队列"), systemImage: "rectangle.stack")
                }
                .accessibilityLabel(Text(L("管理完整队列")))
                .accessibilityIdentifier("player.nowPlaying.actions.manageQueue")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.nowPlaying.actions")
    }

    private func actionRow(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 16)
            .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension Notification.Name {
    static let musicFreeResetLyricsOffset = Notification.Name("MusicFreeResetLyricsOffset")
}
