import AppServices
import DesignSystem
import MusicDomain
import SwiftUI

enum LyricsViewPresentation: Equatable {
    case navigation
    case embedded
}

struct LyricsView: View {
    let title: String
    let initialLyrics: TrackLyrics?
    let query: LyricsQuery?
    let lyricsServing: (any LyricsServing)?
    let presentation: LyricsViewPresentation
    @ObservedObject private var player: PlayerViewModel

    @State private var runtimeOffsetMilliseconds = 0
    @State private var fetchedLyrics: TrackLyrics?
    @State private var loadState: LyricsLoadState = .idle

    init(title: String, lyrics: TrackLyrics, player: PlayerViewModel) {
        self.init(
            title: title,
            lyrics: Optional(lyrics),
            query: nil,
            lyricsServing: nil,
            player: player,
            presentation: .navigation
        )
    }

    init(
        title: String,
        lyrics: TrackLyrics?,
        query: LyricsQuery?,
        lyricsServing: (any LyricsServing)?,
        player: PlayerViewModel,
        presentation: LyricsViewPresentation = .navigation
    ) {
        self.title = title
        self.initialLyrics = lyrics
        self.query = query
        self.lyricsServing = lyricsServing
        self.presentation = presentation
        _player = ObservedObject(wrappedValue: player)
    }

    private var lyrics: TrackLyrics? {
        initialLyrics ?? fetchedLyrics
    }

    private var activeLineIndex: Int? {
        guard let lyrics else { return nil }
        return lyrics.activeLineIndex(
            at: player.snapshot.position,
            runtimeOffsetMilliseconds: runtimeOffsetMilliseconds
        )
    }

    var body: some View {
        Group {
            if presentation == .navigation {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                content
            }
        }
        .task(id: query) {
            await loadLyrics(forceRefresh: false)
        }
        .onChange(of: query) { _, _ in
            fetchedLyrics = nil
            loadState = .idle
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .musicFreeResetLyricsOffset
            )
        ) { _ in
            runtimeOffsetMilliseconds = 0
        }
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics {
            lyricsDocument(lyrics)
        } else {
            lyricsStateView
        }
    }

    private func lyricsDocument(_ lyrics: TrackLyrics) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    lyricsDocumentContent(lyrics)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .accessibilityIdentifier(
                    presentation == .embedded
                        ? "player.nowPlaying.lyricsScroll"
                        : "lyrics.scroll"
                )
                .onChange(of: activeLineIndex) { _, index in
                    scroll(to: index, using: proxy)
                }
                .task {
                    scroll(to: activeLineIndex, using: proxy)
                }
            }

            if presentation == .navigation {
                lyricsOffsetMenu
                    .padding(.trailing, MusicFreeSpacingTokens.small)
                    .padding(.bottom, MusicFreeSpacingTokens.small)
            }
        }
    }

    @ViewBuilder
    private func lyricsDocumentContent(_ lyrics: TrackLyrics) -> some View {
        if lyrics.isTimed {
            VStack(alignment: .leading, spacing: presentation == .embedded ? 14 : MusicFreeSpacingTokens.medium) {
                ForEach(Array(lyrics.timedLines.enumerated()), id: \.offset) { index, line in
                    Text(line.text)
                        .font(lyricsFont(for: index))
                        .foregroundStyle(lyricsForegroundPrimary)
                        .opacity(lyricsOpacity(for: index))
                        .blur(radius: lyricsBlur(for: index))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, presentation == .embedded ? 4 : MusicFreeSpacingTokens.xSmall)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(line.text))
                        .accessibilityIdentifier(
                            presentation == .embedded
                                ? "player.nowPlaying.lyrics.line.\(index)"
                                : "lyrics.line.\(index)"
                        )
                        .id(index)
                }
            }
            .padding(.horizontal, presentation == .embedded ? 0 : MusicFreeSpacingTokens.contentInset)
            .padding(.top, presentation == .embedded ? 58 : MusicFreeSpacingTokens.large)
            // Keep enough trailing space for the last active line to reach the
            // same reading position as lines in the middle of the document.
            .padding(.bottom, presentation == .embedded ? 240 : MusicFreeSpacingTokens.large)
        } else {
            Text(lyrics.rawText)
                .font(.body)
                .foregroundStyle(lyricsForegroundPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MusicFreeSpacingTokens.contentInset)
        }
    }

    private var lyricsOffsetMenu: some View {
        Menu {
            Stepper(
                L("歌词偏移 %d 毫秒", runtimeOffsetMilliseconds),
                value: $runtimeOffsetMilliseconds,
                in: -10_000...10_000,
                step: 250
            )
            Button(L("重置歌词偏移")) {
                runtimeOffsetMilliseconds = 0
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(lyricsForegroundSecondary)
                .frame(width: 44, height: 44)
                .background(.black.opacity(presentation == .embedded ? 0.16 : 0.04), in: Circle())
        }
        .accessibilityLabel(Text(L("歌词设置")))
    }

    @ViewBuilder
    private var lyricsStateView: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView(L("正在加载"))
                .tint(lyricsForegroundPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            let retry: (() -> Void)? = lyricsServing == nil
                ? nil
                : { Task { await loadLyrics(forceRefresh: true) } }
            EmptyStateView(
                title: L("无歌词"),
                message: L("当前音频源没有可显示的歌词。"),
                systemImage: "quote.bubble",
                actionTitle: retry == nil ? nil : L("重试"),
                action: retry
            )
        case .failed:
            ErrorStateView(
                title: L("歌曲加载失败"),
                message: L("当前音频源没有可显示的歌词。"),
                retryTitle: L("重试"),
                retry: { Task { await loadLyrics(forceRefresh: true) } }
            )
        case .loaded:
            EmptyStateView(
                title: L("无歌词"),
                message: L("当前音频源没有可显示的歌词。"),
                systemImage: "quote.bubble"
            )
        }
    }

    private func loadLyrics(forceRefresh: Bool) async {
        guard lyrics == nil else {
            loadState = .loaded
            return
        }
        guard let lyricsServing, let query else {
            loadState = .empty
            return
        }
        guard !Task.isCancelled else { return }
        loadState = .loading
        do {
            let result = try await lyricsServing.fetchLyrics(
                for: query,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            fetchedLyrics = result
            loadState = result == nil ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }

    private func scroll(to index: Int?, using proxy: ScrollViewProxy) {
        guard let index else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            let anchor = presentation == .embedded
                ? UnitPoint(x: 0.5, y: 0.25)
                : .center
            proxy.scrollTo(index, anchor: anchor)
        }
    }

    private func lyricsFont(for index: Int) -> Font {
        guard presentation == .embedded else {
            return index == activeLineIndex
                ? .title2.weight(.bold)
                : .title3.weight(.semibold)
        }
        return index == activeLineIndex
            ? .system(size: 32, weight: .bold)
            : .title2.weight(.semibold)
    }

    private func lyricsOpacity(for index: Int) -> Double {
        guard let activeLineIndex else {
            return presentation == .embedded ? 0.78 : 0.78
        }
        switch abs(index - activeLineIndex) {
        case 0: return 1
        case 1: return presentation == .embedded ? 0.34 : 0.62
        case 2: return presentation == .embedded ? 0.22 : 0.42
        default: return presentation == .embedded ? 0.12 : 0.24
        }
    }

    private func lyricsBlur(for index: Int) -> CGFloat {
        guard presentation == .embedded, let activeLineIndex else { return 0 }
        return index == activeLineIndex ? 0 : 2.5
    }

    private var lyricsForegroundPrimary: Color {
        presentation == .embedded
            ? .white.opacity(0.96)
            : MusicFreeColorTokens.foregroundPrimary
    }

    private var lyricsForegroundSecondary: Color {
        presentation == .embedded
            ? .white.opacity(0.62)
            : MusicFreeColorTokens.foregroundSecondary
    }
}

private enum LyricsLoadState {
    case idle
    case loading
    case loaded
    case empty
    case failed
}
