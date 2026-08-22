import AppServices
import Combine
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

enum NowPlayingHistoryAction: Equatable {
    case play
    case enqueueNext

    var title: String {
        switch self {
        case .play:
            return L("播放")
        case .enqueueNext:
            return L("下一首播放")
        }
    }

    var systemImage: String {
        switch self {
        case .play:
            return "play.fill"
        case .enqueueNext:
            return "text.append"
        }
    }

    func command(for itemID: MediaItemID) -> PlaybackSessionCommand {
        switch self {
        case .play:
            return .play(itemID: itemID)
        case .enqueueNext:
            return .enqueueNext(itemIDs: [itemID])
        }
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
    static let historyRowHeight: CGFloat = 72
    static let currentArtworkSize: CGFloat = 72
    static let currentRowHeight: CGFloat = 96

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

private let nowPlayingCurrentQueueAnchor = "player.nowPlaying.current.anchor"

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
    private let rendersBackdrop: Bool

    @StateObject private var artworkLoader = ArtworkImageLoader()
    @StateObject private var favoriteController: PlayerFavoriteController
    @StateObject private var historyLoader: NowPlayingHistoryLoader
    @State private var queueTracks: [MediaItemID: Track] = [:]
    @State private var queueArtistNames: [ArtistID: String] = [:]
    @State private var queueAlbumNames: [AlbumID: String] = [:]
    @State private var surface: NowPlayingSurface = .artwork
    @State private var isMoreActionsDismissEnabled = false
    @State private var selectedHistoryItem: PlaybackHistoryItem?
    @State private var isHistoryActionPresented = false
    @State private var activeHistoryAction: NowPlayingHistoryAction?
    @State private var activeHistorySessionID: UUID?
    @State private var historyActionErrorMessage: String?
    @State private var isHistoryClearConfirmationPresented = false
    @State private var hasAppliedQueueInitialScrollPosition = false
    @State private var queueScrollGeneration = 0
    @State private var queueHasUserScrolled = false

    init(
        viewModel: PlayerViewModel,
        onShowQueue: @escaping () -> Void = {},
        isMoreActionsPresented: Binding<Bool> = .constant(false),
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil,
        rendersBackdrop: Bool = true
    ) {
        self.viewModel = viewModel
        self.onShowQueue = onShowQueue
        self._isMoreActionsPresented = isMoreActionsPresented
        self.artworkServing = artworkServing
        self.library = library
        self.lyricsServing = lyricsServing
        self.rendersBackdrop = rendersBackdrop
        _favoriteController = StateObject(
            wrappedValue: PlayerFavoriteController(library: library)
        )
        _historyLoader = StateObject(
            wrappedValue: NowPlayingHistoryLoader(library: library)
        )
    }

    var body: some View {
        ZStack {
            // REGRESSION GUARD: the system player sheet owns the stable dark
            // surface. Keep this view transparent when rendersBackdrop is
            // false so a presentation transition cannot add a second layer.
            if rendersBackdrop {
                playerBackdrop
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

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
        .background(
            rendersBackdrop
                ? Color.black.ignoresSafeArea()
                : Color.clear.ignoresSafeArea()
        )
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
        .task(id: historyLoadKey) {
            await historyLoader.load()
        }
        .task {
            await observeLibraryChanges()
        }
        .task {
            await historyLoader.observeChanges()
        }
        .task(id: viewModel.snapshot.currentItemID) {
            favoriteController.load(itemID: viewModel.snapshot.currentItemID)
        }
        .onChange(of: viewModel.snapshot.currentItemID) { _, _ in
            resetQueueInitialScrollPosition(reanchor: true)
        }
        .onChange(of: viewModel.snapshot.queue.currentEntryID) { _, _ in
            resetQueueInitialScrollPosition(reanchor: true)
        }
        .onChange(of: surface) { _, surface in
            if surface == .queue {
                resetQueueInitialScrollPosition(reanchor: true)
            }
        }
        .confirmationDialog(
            L("播放历史歌曲"),
            isPresented: $isHistoryActionPresented
        ) {
            if let selectedHistoryItem {
                ForEach([NowPlayingHistoryAction.play, .enqueueNext], id: \.self) { action in
                    Button {
                        beginHistoryAction(action, for: selectedHistoryItem)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(activeHistoryAction != nil)
                }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            if let selectedHistoryItem {
                Text(selectedHistoryItem.track.title)
            }
        }
        .alert(
            L("操作失败"),
            isPresented: Binding(
                get: { historyActionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { historyActionErrorMessage = nil }
                }
            )
        ) {
            Button(L("好"), role: .cancel) { historyActionErrorMessage = nil }
        } message: {
            Text(historyActionErrorMessage ?? L("请稍后重试。"))
        }
        .confirmationDialog(
            L("清除播放历史？"),
            isPresented: $isHistoryClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("清除播放历史"), role: .destructive) {
                Task { await historyLoader.clear() }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("歌曲仍会保留在资料库中，累计播放统计不会重置。"))
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
            // SwiftUI can propose a zero-width/zero-height frame while a
            // system sheet is installing or rotating. Do not render content
            // with that proposal: fixed artwork would overflow while text
            // frames collapse and show only a trailing fragment.
            if geometry.size.width <= NowPlayingLayoutMetrics.horizontalInset * 2
                || geometry.size.height <= 1 {
                Color.clear
            } else {
                let contentWidth = geometry.size.width
                    - (NowPlayingLayoutMetrics.horizontalInset * 2)
                let layoutMode = NowPlayingVerticalLayoutPolicy.mode(
                    availableHeight: geometry.size.height,
                    verticalSizeClass: verticalSizeClass,
                    dynamicTypeSize: dynamicTypeSize
                )
                // GeometryReader is already laid out inside the safe-area
                // content region. Only reserve the gap below the root drag
                // handle here.
                let topChromeInset = NowPlayingLayoutMetrics.topChromeInset
                let pinnedSurfaceHeight = max(
                    0,
                    geometry.size.height
                        - topChromeInset
                        - NowPlayingLayoutMetrics.pinnedControlsHeight
                )

                ZStack(alignment: .top) {
                    if surface == .queue {
                        queuePlayerColumn(
                            viewportWidth: geometry.size.width,
                            viewportHeight: geometry.size.height,
                            contentWidth: contentWidth,
                            topChromeInset: topChromeInset,
                            usesCompactControls: layoutMode == .scrolling
                        )
                    } else if layoutMode == .scrolling {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func queuePlayerColumn(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        contentWidth: CGFloat,
        topChromeInset: CGFloat,
        usesCompactControls: Bool
    ) -> some View {
        let controlsHeight = usesCompactControls
            ? NowPlayingLayoutMetrics.compactControlsHeight
            : NowPlayingLayoutMetrics.pinnedControlsHeight

        let availableQueueHeight = max(
            0,
            viewportHeight - topChromeInset - controlsHeight
        )

        return VStack(spacing: 0) {
            queueSurface(
                contentWidth: contentWidth,
                surfaceHeight: availableQueueHeight
            )
            .frame(width: contentWidth, height: availableQueueHeight)

            queueBottomControls(usesCompactControls: usesCompactControls)
                .frame(
                    width: contentWidth,
                    height: controlsHeight,
                    alignment: .top
                )
        }
        .frame(
            width: viewportWidth,
            height: max(0, viewportHeight - topChromeInset),
            alignment: .top
        )
        .padding(.top, topChromeInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.nowPlaying.queueLayout")
    }

    @ViewBuilder
    private func queueBottomControls(usesCompactControls: Bool) -> some View {
        if usesCompactControls {
            compactBottomControls
        } else {
            bottomControls
        }
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
            ZStack {
                ArtworkView(
                    image: artworkLoader.image,
                    accessibilityLabel: currentArtworkID == nil ? L("暂无封面") : L("封面"),
                    fillsAvailableWidth: true,
                    cornerRadius: 0
                )
            }
            .frame(width: dimension, height: dimension)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
            // Keep the fixture's real-cover state observable even though
            // ArtworkView intentionally owns its own accessibility element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(currentArtworkID == nil ? L("暂无封面") : L("封面"))
            )
            .accessibilityValue(
                Text(artworkLoader.image == nil ? "No artwork" : "Artwork loaded")
            )
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(
                artworkLoader.image == nil
                    ? "player.nowPlaying.artwork.placeholder"
                    : "player.nowPlaying.artwork.image"
            )
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
                    // REGRESSION GUARD: the system Sheet leaves a presenting
                    // Mini Player transition copy in the accessibility tree.
                    // Give the visible Now Playing title its own identity so
                    // UI checks cannot mistake that off-screen copy for this
                    // layout boundary.
                    .accessibilityIdentifier("player.nowPlaying.current.title")

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(currentArtist) {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(playerForegroundSecondary)
                        .lineLimit(1)
                }
            }
            // REGRESSION GUARD: do not derive this width from a transient
            // GeometryReader proposal. During a system-sheet transition the
            // proposal can change while the HStack still owns its previous
            // text layout, leaving only the title tail at the leading edge.
            // The actions keep their fixed width; the title gets the rest.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            headerActions
        }
        .frame(width: contentWidth, alignment: .leading)
        .clipped()
    }

    private func compactHeader(contentWidth: CGFloat) -> some View {
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
                    // Keep this identifier aligned with the Artwork and
                    // Queue current rows. See the Sheet transition guard above.
                    .accessibilityIdentifier("player.nowPlaying.current.title")

                if let artist = NowPlayingHeaderMetadata.artistSubtitle(currentArtist) {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(playerForegroundSecondary)
                    .lineLimit(1)
                }
            }
            // Keep the title in the remaining width when the system Sheet
            // remeasures its content. A computed fixed width can retain a
            // stale horizontal position for one transition frame.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        let historyItems = displayedHistoryItems

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Keep one system-coordinated scroll container. The lazy stack
                // is required for large history snapshots; adding a nested
                // ScrollView or a second drag state machine regresses sheet
                // dismissal and can make the transition flash or hang.
                LazyVStack(alignment: .leading, spacing: 0) {
                    queueHistoryHeader(
                        contentWidth: contentWidth,
                        historyCount: historyItems.count
                    )
                        .padding(.bottom, 24)

                    if historyLoader.failureMessage != nil {
                        Button {
                            Task { await historyLoader.load() }
                        } label: {
                            Label(L("载入失败，点击重试"), systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(playerForegroundSecondary)
                                .frame(
                                    width: contentWidth,
                                    height: NowPlayingLayoutMetrics.historyRowHeight,
                                    alignment: .leading
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(historyLoader.state == .loading)
                    }

                    switch historyLoader.state {
                    case .idle, .loading:
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(playerForegroundSecondary)
                            Text(L("正在载入播放历史"))
                                .font(.subheadline)
                                .foregroundStyle(playerForegroundSecondary)
                        }
                        .frame(
                            width: contentWidth,
                            height: NowPlayingLayoutMetrics.historyRowHeight,
                            alignment: .leading
                        )
                    case .failed:
                        if historyLoader.failureMessage == nil {
                            historyRetryRow
                        }
                    case .empty:
                        Text(L("暂无播放历史"))
                            .font(.subheadline)
                            .foregroundStyle(playerForegroundSecondary)
                            .frame(
                                width: contentWidth,
                                height: NowPlayingLayoutMetrics.historyRowHeight,
                                alignment: .leading
                            )
                    case .loaded:
                        if historyItems.isEmpty {
                            Text(L("当前歌曲尚未形成历史记录"))
                                .font(.subheadline)
                                .foregroundStyle(playerForegroundSecondary)
                                .frame(
                                    width: contentWidth,
                                    height: NowPlayingLayoutMetrics.historyRowHeight,
                                    alignment: .leading
                                )
                        } else {
                            // REGRESSION GUARD: keep history rows as direct
                            // LazyVStack children. Wrapping this ForEach in a
                            // composite history view makes large snapshots an
                            // eager block and causes endpoint scrolling stalls.
                            ForEach(historyItems) { item in
                                nowPlayingHistoryRow(
                                    item,
                                    contentWidth: contentWidth,
                                    isNewest: item.id == historyItems.first?.id,
                                    isOldest: item.id == historyItems.last?.id
                                )
                            }
                        }
                    }

                    currentPlayingContent(contentWidth: contentWidth)
                        .padding(.bottom, 28)

                    queueModeControls(contentWidth: contentWidth)
                        .padding(.bottom, 28)

                    continuePlayingContent(contentWidth: contentWidth)
                        .padding(.bottom, 24)

                    queueScrollTailSpacer(
                        contentWidth: contentWidth,
                        surfaceHeight: surfaceHeight
                    )
                }
                .frame(width: contentWidth, alignment: .top)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("player.nowPlaying.upperScroll")
            .onAppear {
                // REGRESSION GUARD: entering the queue is a new navigation
                // intent. Always place the current row at the viewport top;
                // history remains immediately above it and is revealed only
                // when the user pulls the system scroll view downward.
                resetQueueInitialScrollPosition(reanchor: true)
                applyInitialQueueScrollPosition(using: proxy)
            }
            .onChange(of: historyLoader.state) { _, state in
                guard state != .loading, !queueHasUserScrolled else { return }
                resetQueueInitialScrollPosition()
                applyInitialQueueScrollPosition(using: proxy)
            }
            .onChange(of: queueAnchorKey) { _, _ in
                resetQueueInitialScrollPosition(reanchor: true)
                applyInitialQueueScrollPosition(using: proxy)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    queueHasUserScrolled = true
                }
            }
        }
        .frame(width: contentWidth, height: surfaceHeight, alignment: .top)
    }

    private func queueScrollTailSpacer(
        contentWidth: CGFloat,
        surfaceHeight: CGFloat
    ) -> some View {
        // REGRESSION GUARD: ScrollViewReader cannot place the current row at
        // the top when the content after it is shorter than the viewport; the
        // system clamps the offset to the bottom and leaves the row halfway
        // down the screen. Preserve normal system scrolling by adding only
        // the invisible tail height needed to make the current anchor valid.
        let upcomingCount = viewModel.upcomingQueueEntries()
            .filter { $0.itemID != nil }
            .count
        // Keep the estimate intentionally conservative. The mode controls,
        // the Continue Playing heading, and optional album metadata all sit
        // after the current row but are not represented by one fixed row.
        let estimatedContentAfterCurrent =
            CGFloat(upcomingCount + 1) * NowPlayingLayoutMetrics.queueRowHeight
                + 180
        let tailHeight = max(0, surfaceHeight - estimatedContentAfterCurrent)

        return Color.clear
            .frame(width: contentWidth, height: tailHeight)
            .accessibilityHidden(true)
    }

    private func queueHistoryHeader(
        contentWidth: CGFloat,
        historyCount: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("历史"))
                .font(.title2.weight(.bold))
                .foregroundStyle(playerForegroundPrimary)
                .frame(minHeight: 44, alignment: .leading)
                // Keep the loaded count observable for the large-history
                // acceptance test without adding another visible label.
                .accessibilityValue(Text("\(historyCount)"))
                .accessibilityIdentifier("player.nowPlaying.history.heading")

            Spacer(minLength: 12)

            Button(L("清除"), role: .destructive) {
                isHistoryClearConfirmationPresented = true
            }
            .font(.title3)
            .foregroundStyle(playerForegroundSecondary)
            .disabled(displayedHistoryItems.isEmpty || historyLoader.isClearing)
            .accessibilityIdentifier("player.nowPlaying.history.clear")
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var historyRetryRow: some View {
        Button {
            Task { await historyLoader.load() }
        } label: {
            Label(L("载入失败，点击重试"), systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(playerForegroundSecondary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: NowPlayingLayoutMetrics.historyRowHeight,
                    alignment: .leading
                )
        }
        .buttonStyle(.plain)
    }

    private func currentPlayingContent(contentWidth: CGFloat) -> some View {
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
                width: NowPlayingLayoutMetrics.currentArtworkSize,
                height: NowPlayingLayoutMetrics.currentArtworkSize
            )
            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
            .accessibilityIdentifier("player.nowPlaying.current.image")

            VStack(alignment: .leading, spacing: 3) {
                Text(currentTitle ?? L("正在播放"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(playerForegroundPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("player.nowPlaying.current.title")

                if let artist = currentArtist {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(playerForegroundSecondary)
                        .lineLimit(1)
                }
            }
            // The current row shares the same transition-sensitive width
            // contract as the artwork and lyrics headers. Keep its cover and
            // actions fixed, then let the text absorb only the remainder.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            headerActions
        }
        .frame(width: contentWidth, alignment: .leading)
        .frame(height: NowPlayingLayoutMetrics.currentRowHeight, alignment: .leading)
        .id(nowPlayingCurrentQueueAnchor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.nowPlaying.current")
    }

    private var displayedHistoryItems: [PlaybackHistoryItem] {
        NowPlayingHistoryPresentation.nowPlayingItems(
            from: historyLoader.items,
            currentItemID: viewModel.snapshot.currentItemID
        )
    }

    private func nowPlayingHistoryRow(
        _ item: PlaybackHistoryItem,
        contentWidth: CGFloat,
        isNewest: Bool,
        isOldest: Bool
    ) -> some View {
        NowPlayingHistoryRow(
            item: item,
            artistNames: historyLoader.artistNames,
            artworkServing: artworkServing,
            contentWidth: contentWidth,
            isPerformingAction: activeHistorySessionID == item.sessionID,
            boundaryAccessibilityIdentifier: isNewest
                ? "player.nowPlaying.history.newest"
                : isOldest
                    ? "player.nowPlaying.history.oldest"
                    : nil,
            onSelect: {
                guard activeHistoryAction == nil else { return }
                selectedHistoryItem = item
                isHistoryActionPresented = true
            }
        )
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
        .accessibilityIdentifier("player.nowPlaying.lyrics")
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
        // REGRESSION GUARD: Now Playing is intentionally a solid dark surface.
        // Artwork remains visible in the album-art elements only; do not add a
        // full-screen cover blur here or in the system presentation background.
        Color.black
        .ignoresSafeArea()
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

    private var historyLoadKey: String {
        let generation = viewModel.snapshot.generation.rawValue
        let itemID = viewModel.snapshot.currentItemID
        return "\(generation):\(itemID?.sourceID.rawValue ?? ""):\(itemID?.externalID ?? "")"
    }

    private var queueAnchorKey: String {
        viewModel.snapshot.queue.currentEntryID?.uuidString ?? "none"
    }

    private func resetQueueInitialScrollPosition(reanchor: Bool = false) {
        hasAppliedQueueInitialScrollPosition = false
        queueScrollGeneration &+= 1
        if reanchor {
            queueHasUserScrolled = false
        }
    }

    private func applyInitialQueueScrollPosition(using proxy: ScrollViewProxy) {
        guard !hasAppliedQueueInitialScrollPosition,
              !queueHasUserScrolled,
              viewModel.snapshot.queue.currentEntryID != nil
        else { return }

        hasAppliedQueueInitialScrollPosition = true
        let expectedGeneration = queueScrollGeneration
        proxy.scrollTo(nowPlayingCurrentQueueAnchor, anchor: .top)
        Task { @MainActor in
            // LazyVStack may not have materialized the target row during the
            // first appearance callback. Give layout a few run-loop turns so
            // the system scroll position is applied to the real row.
            for delay in [0, 80_000_000, 220_000_000, 600_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                } else {
                    await Task.yield()
                }
                guard expectedGeneration == queueScrollGeneration,
                      !Task.isCancelled
                else { return }
                proxy.scrollTo(nowPlayingCurrentQueueAnchor, anchor: .top)
            }
        }
    }

    private func beginHistoryAction(
        _ action: NowPlayingHistoryAction,
        for item: PlaybackHistoryItem
    ) {
        guard activeHistoryAction == nil else { return }

        isHistoryActionPresented = false
        activeHistoryAction = action
        activeHistorySessionID = item.sessionID
        viewModel.send(action.command(for: item.track.id))

        Task { @MainActor in
            await viewModel.waitForPendingWork()
            guard !Task.isCancelled else { return }

            let error = viewModel.lastCommandError
            activeHistoryAction = nil
            activeHistorySessionID = nil
            selectedHistoryItem = nil
            if let error {
                historyActionErrorMessage = playerErrorMessage(error)
            }
        }
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

/// Shares one decoded player artwork between the presenting underlay and the
/// system sheet presentation background. Keeping this state above both view
/// instances prevents a transition frame from showing different fallbacks.
@MainActor
public final class PlayerPresentationBackdropStore: ObservableObject {
    @Published public private(set) var image: Image?

    private let artworkLoader = ArtworkImageLoader()
    private var observationTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkKey = ""

    public init() {}

    public func start(
        playback: any PlaybackServing,
        artworkServing: any ArtworkServing
    ) {
        guard observationTask == nil else { return }

        apply(
            playback.snapshot,
            artworkServing: artworkServing
        )
        observationTask = Task { [weak self] in
            for await nextSnapshot in playback.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.apply(nextSnapshot, artworkServing: artworkServing)
            }
        }
    }

    private func apply(
        _ nextSnapshot: PlaybackSessionSnapshot,
        artworkServing: any ArtworkServing
    ) {
        // REGRESSION GUARD: playback snapshots include progress updates. Do
        // not publish or retain those high-frequency values in the root view;
        // doing so rebuilds the TabView bottom accessory while it is settling
        // and can produce an invalid Mini Player hit frame. Only the artwork
        // image below is presentation state and may invalidate the UI.
        let nextArtworkKey = "\(nextSnapshot.currentItemID?.sourceID.rawValue ?? ""):\(nextSnapshot.currentItem?.artworkID?.rawValue ?? "")"
        guard artworkKey != nextArtworkKey else { return }

        artworkKey = nextArtworkKey
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            await self.artworkLoader.load(
                artworkID: nextSnapshot.currentItem?.artworkID,
                sourceID: nextSnapshot.currentItemID?.sourceID,
                serving: artworkServing
            )
            guard !Task.isCancelled, self.artworkKey == nextArtworkKey else {
                return
            }
            self.image = self.artworkLoader.image
        }
    }
}

/// Paints the player artwork behind the system sheet's safe areas. The
/// presentation background is separate from NowPlayingView's content bounds,
/// so it can cover the status-bar region without participating in gestures.
@MainActor
public struct PlayerPresentationBackdrop: View {
    @ObservedObject private var store: PlayerPresentationBackdropStore
    private let presentationDimCompensation: Double

    public init(
        store: PlayerPresentationBackdropStore,
        presentationDimCompensation: Double = 0
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.presentationDimCompensation = presentationDimCompensation
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image = store.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .blur(radius: 42)
                        .scaleEffect(1.24)
                        .opacity(0.92)

                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.08), location: 0),
                            .init(color: .black.opacity(0.08), location: 0.10),
                            .init(color: .black.opacity(0.20), location: 0.50),
                            .init(color: .black.opacity(0.46), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                if presentationDimCompensation > 0 {
                    Color.black.opacity(presentationDimCompensation)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NowPlayingHistoryRow: View {
    let item: PlaybackHistoryItem
    let artistNames: [ArtistID: String]
    let artworkServing: (any ArtworkServing)?
    let contentWidth: CGFloat
    let isPerformingAction: Bool
    let boundaryAccessibilityIdentifier: String?
    let onSelect: () -> Void

    var body: some View {
        let textWidth = max(
            0,
            contentWidth
                - NowPlayingLayoutMetrics.queueRowArtworkSize
                - NowPlayingLayoutMetrics.headerContentSpacing
                - (isPerformingAction
                    ? NowPlayingLayoutMetrics.queueRowActionWidth
                        + NowPlayingLayoutMetrics.headerContentSpacing
                    : 0)
        )

        Button(action: onSelect) {
            HStack(spacing: NowPlayingLayoutMetrics.headerContentSpacing) {
                ArtworkResourceView(
                    artworkID: item.track.artworkID,
                    sourceID: item.track.id.sourceID,
                    serving: artworkServing,
                    accessibilityLabel: item.track.artworkID == nil ? L("暂无封面") : L("封面"),
                    placeholderTitle: item.track.title,
                    fillsAvailableWidth: true,
                    cornerRadius: 8
                )
                .frame(
                    width: NowPlayingLayoutMetrics.queueRowArtworkSize,
                    height: NowPlayingLayoutMetrics.queueRowArtworkSize
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.track.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)

                    if let subtitle = QueueArtistNameLoader.subtitle(
                        for: item.track,
                        artistNames: artistNames
                    ) {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                    }
                }
                .frame(
                    width: textWidth,
                    alignment: .leading
                )
                .clipped()

                if isPerformingAction {
                    ProgressView()
                        .tint(.white.opacity(0.84))
                        .frame(width: 28, height: 28)
                }
            }
            .frame(
                width: contentWidth,
                height: NowPlayingLayoutMetrics.historyRowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: contentWidth,
            height: NowPlayingLayoutMetrics.historyRowHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .disabled(isPerformingAction)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(L("选择播放方式")))
        .accessibilityIdentifier(
            boundaryAccessibilityIdentifier
                ?? "player.nowPlaying.history.\(item.sessionID.uuidString)"
        )
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
