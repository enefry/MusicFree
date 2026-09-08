import AppServices
import Combine
import DesignSystem
import MusicDomain
import PlaybackAPI
import UIKit

/// The scrollable, native UIKit lyrics document used inside Now Playing.
///
/// This is intentionally a UIView rather than a second view controller. The
/// Apple Music surface keeps the compact header, progress, transport and
/// footer controls in the same presentation while only the middle document
/// changes from artwork to timed lyrics.
@MainActor
final class PlayerEmbeddedLyricsView: UIView {
    private let lyricsServing: (any LyricsServing)?
    private let player: PlayerViewModel
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let stateView = MusicFreeUIKitEmptyStateView(
        title: L("无歌词"),
        message: L("当前音频源没有可显示的歌词。"),
        systemImage: "quote.bubble"
    )
    private var loadTask: Task<Void, Never>?
    private var snapshotCancellable: AnyCancellable?
    private var lyrics: TrackLyrics?
    private var query: LyricsQuery?
    private var loadState: LoadState = .idle
    private var runtimeOffsetMilliseconds = 0
    private var lineLabels: [UILabel] = []
    private var renderedActiveIndex: Int?

    private enum LoadState {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    init(
        lyricsServing: (any LyricsServing)?,
        player: PlayerViewModel
    ) {
        self.lyricsServing = lyricsServing
        self.player = player
        super.init(frame: .zero)
        accessibilityIdentifier = "player.nowPlaying.lyrics"
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(query: LyricsQuery?, initialLyrics: TrackLyrics? = nil) {
        guard self.query != query || (initialLyrics != nil && lyrics == nil) else {
            updateActiveLine(animated: true)
            return
        }
        self.query = query
        loadTask?.cancel()
        loadTask = nil
        lyrics = initialLyrics
        renderedActiveIndex = nil
        if let initialLyrics, !initialLyrics.isEmpty {
            loadState = .loaded
            render()
        } else {
            loadTask = Task { @MainActor [weak self] in
                await self?.loadLyrics()
            }
        }
    }

    func updatePosition() {
        updateActiveLine(animated: true)
    }

    func resetOffset() {
        runtimeOffsetMilliseconds = 0
        updateActiveLine(animated: true)
    }

    private func configureViews() {
        backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.accessibilityIdentifier = "player.nowPlaying.lyricsScroll"
        addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        stateView.backgroundColor = .clear
        addSubview(stateView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 18
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -200
            ),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stateView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateView.topAnchor.constraint(equalTo: topAnchor),
            stateView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        snapshotCancellable = player.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateActiveLine(animated: true) }
    }

    private func loadLyrics() async {
        guard let lyricsServing, let query else {
            lyrics = nil
            loadState = .empty
            render()
            return
        }
        loadState = .loading
        render()
        do {
            let fetched = try await lyricsServing.fetchLyrics(
                for: query,
                forceRefresh: false
            )
            try Task.checkCancellation()
            lyrics = fetched
            loadState = fetched == nil ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed
        }
        render()
    }

    private func render() {
        guard !isHidden else { return }
        guard let lyrics, !lyrics.isEmpty else {
            scrollView.isHidden = true
            stateView.isHidden = false
            switch loadState {
            case .idle, .loading:
                stateView.titleText = L("正在加载")
                stateView.messageText = nil
                stateView.actionTitle = nil
                stateView.onAction = nil
            case .empty, .loaded:
                stateView.titleText = L("无歌词")
                stateView.messageText = L("当前音频源没有可显示的歌词。")
                stateView.actionTitle = lyricsServing == nil ? nil : L("重试")
                stateView.onAction = lyricsServing == nil ? nil : { [weak self] in
                    self?.loadTask?.cancel()
                    self?.loadTask = Task { @MainActor [weak self] in
                        await self?.loadLyrics()
                    }
                }
            case .failed:
                stateView.titleText = L("歌曲加载失败")
                stateView.messageText = L("当前音频源没有可显示的歌词。")
                stateView.actionTitle = L("重试")
                stateView.onAction = { [weak self] in
                    self?.loadTask?.cancel()
                    self?.loadTask = Task { @MainActor [weak self] in
                        await self?.loadLyrics()
                    }
                }
            }
            return
        }

        scrollView.isHidden = false
        stateView.isHidden = true
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lineLabels.removeAll(keepingCapacity: true)

        if lyrics.isTimed {
            for (index, line) in lyrics.timedLines.enumerated() {
                let label = UILabel()
                label.font = MusicFreeUIFontTokens.preferred(.title2, weight: .semibold)
                label.textColor = .white.withAlphaComponent(0.96)
                label.numberOfLines = 0
                label.lineBreakMode = .byWordWrapping
                label.text = line.text
                label.accessibilityIdentifier = "player.nowPlaying.lyrics.line.\(index)"
                label.accessibilityLabel = line.text
                label.tag = index
                label.isAccessibilityElement = true
                contentStack.addArrangedSubview(label)
                lineLabels.append(label)
            }
            updateActiveLine(animated: false)
        } else {
            let label = UILabel()
            label.font = MusicFreeUIFontTokens.body
            label.textColor = .white.withAlphaComponent(0.96)
            label.numberOfLines = 0
            label.text = lyrics.rawText
            label.accessibilityIdentifier = "player.nowPlaying.lyrics.rawText"
            contentStack.addArrangedSubview(label)
        }
    }

    private func updateActiveLine(animated: Bool) {
        guard let lyrics, lyrics.isTimed, !lineLabels.isEmpty else { return }
        let activeIndex = lyrics.activeLineIndex(
            at: player.snapshot.position,
            runtimeOffsetMilliseconds: runtimeOffsetMilliseconds
        )
        guard activeIndex != renderedActiveIndex || !animated else { return }
        renderedActiveIndex = activeIndex

        for (index, label) in lineLabels.enumerated() {
            let distance = activeIndex.map { abs(index - $0) }
            let isActive = activeIndex == index
            let font = isActive
                ? MusicFreeUIFontTokens.preferred(.title1, weight: .bold)
                : MusicFreeUIFontTokens.preferred(.title2, weight: .semibold)
            let alpha: CGFloat
            switch distance {
            case 0: alpha = 1
            case 1: alpha = 0.34
            case 2: alpha = 0.22
            default: alpha = 0.12
            }
            let changes = {
                label.font = font
                label.alpha = alpha
            }
            if animated {
                UIView.animate(withDuration: 0.22, animations: changes)
            } else {
                changes()
            }
        }

        guard let activeIndex, lineLabels.indices.contains(activeIndex) else { return }
        let label = lineLabels[activeIndex]
        let labelRect = contentStack.convert(label.frame, to: scrollView)
        scrollView.scrollRectToVisible(
            labelRect.insetBy(dx: 0, dy: -80),
            animated: animated
        )
    }
}
