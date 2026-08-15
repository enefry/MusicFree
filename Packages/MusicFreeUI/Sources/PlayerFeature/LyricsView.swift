import DesignSystem
import MusicDomain
import SwiftUI

struct LyricsView: View {
    let title: String
    let lyrics: TrackLyrics
    @ObservedObject private var player: PlayerViewModel

    @State private var runtimeOffsetMilliseconds = 0

    init(title: String, lyrics: TrackLyrics, player: PlayerViewModel) {
        self.title = title
        self.lyrics = lyrics
        _player = ObservedObject(wrappedValue: player)
    }

    private var activeLineIndex: Int? {
        lyrics.activeLineIndex(
            at: player.snapshot.position,
            runtimeOffsetMilliseconds: runtimeOffsetMilliseconds
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lyrics.isTimed {
                    LazyVStack(alignment: .leading, spacing: MusicFreeSpacingTokens.medium) {
                        ForEach(Array(lyrics.timedLines.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .font(index == activeLineIndex ? .title3.weight(.bold) : .body)
                                .foregroundStyle(
                                    index == activeLineIndex
                                        ? MusicFreeColorTokens.foregroundPrimary
                                        : MusicFreeColorTokens.foregroundSecondary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, MusicFreeSpacingTokens.xSmall)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                    .padding(.vertical, MusicFreeSpacingTokens.large)
                } else {
                    Text(lyrics.rawText)
                        .font(.body)
                        .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MusicFreeSpacingTokens.contentInset)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: activeLineIndex) { _, index in
                scroll(to: index, using: proxy)
            }
            .task {
                scroll(to: activeLineIndex, using: proxy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Stepper(
                L("歌词偏移 %d 毫秒", runtimeOffsetMilliseconds),
                value: $runtimeOffsetMilliseconds,
                in: -10_000...10_000,
                step: 250
            )
            .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
            .padding(.vertical, MusicFreeSpacingTokens.small)
            .background(.bar)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scroll(to index: Int?, using proxy: ScrollViewProxy) {
        guard let index else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}
