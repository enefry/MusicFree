import AppServices
import Combine
import DesignSystem
import MusicDomain
import PlaybackAPI
import UIKit

/// Native UIKit lyrics surface for the Player migration.
///
/// The controller intentionally keeps lyrics fetching and playback state at
/// their existing service boundaries. It only renders the fetched document
/// and follows the active timed line as the playback snapshot advances.
@available(iOS 16.0, *)
@MainActor
public final class PlayerLyricsViewController: UIViewController {
    private enum LoadState {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    private let serving: any PlaybackServing
    private let lyricsServing: (any LyricsServing)?
    private let query: LyricsQuery?
    private let initialLyrics: TrackLyrics?
    private let player: PlayerViewModel
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let stateView = MusicFreeUIKitEmptyStateView(
        title: L("无歌词"),
        message: L("当前音频源没有可显示的歌词。"),
        systemImage: "quote.bubble"
    )
    private var snapshotCancellable: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var lyrics: TrackLyrics?
    private var loadState: LoadState = .idle
    private var runtimeOffsetMilliseconds = 0
    private var lineLabels: [UILabel] = []
    private var renderedActiveIndex: Int?

    public init(
        serving: any PlaybackServing,
        lyricsServing: (any LyricsServing)?,
        query: LyricsQuery?,
        initialLyrics: TrackLyrics? = nil
    ) {
        self.serving = serving
        self.lyricsServing = lyricsServing
        self.query = query
        self.initialLyrics = initialLyrics
        player = PlayerViewModel(serving: serving, autoStart: false)
        super.init(nibName: nil, bundle: nil)
        title = query?.title ?? L("歌词")
        restorationIdentifier = "player.lyrics.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "player.lyrics"
        configureViews()
        player.start()
        snapshotCancellable = player.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateActiveLine(animated: true) }
        loadTask = Task { @MainActor [weak self] in
            await self?.loadLyrics()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
        player.stop()
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "lyrics.scroll"
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: MusicFreeSpacingTokens.large),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: MusicFreeSpacingTokens.large),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * MusicFreeSpacingTokens.contentInset)
        ])

        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(showLyricsSettings)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = L("歌词设置")
        render()
    }

    private func loadLyrics(forceRefresh: Bool = false) async {
        if let initialLyrics, !initialLyrics.isEmpty {
            lyrics = initialLyrics
            loadState = .loaded
            render()
            return
        }
        guard let lyricsServing, let query else {
            loadState = .empty
            render()
            return
        }
        loadState = .loading
        render()
        do {
            let fetched = try await lyricsServing.fetchLyrics(for: query, forceRefresh: forceRefresh)
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
        guard isViewLoaded else { return }
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
                            await self?.loadLyrics(forceRefresh: true)
                        }
                    }
            case .failed:
                stateView.titleText = L("歌曲加载失败")
                stateView.messageText = L("当前音频源没有可显示的歌词。")
                stateView.actionTitle = L("重试")
                stateView.onAction = { [weak self] in
                        self?.loadTask?.cancel()
                        self?.loadTask = Task { @MainActor [weak self] in
                            await self?.loadLyrics(forceRefresh: true)
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
                label.font = MusicFreeUIFontTokens.screenTitle
                label.textColor = MusicFreeUIColorTokens.foregroundPrimary
                label.numberOfLines = 0
                label.text = line.text
                label.accessibilityIdentifier = "lyrics.line.\(index)"
                label.accessibilityLabel = line.text
                label.tag = index
                contentStack.addArrangedSubview(label)
                lineLabels.append(label)
            }
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 180).isActive = true
            contentStack.addArrangedSubview(spacer)
        } else {
            let label = UILabel()
            label.font = MusicFreeUIFontTokens.body
            label.textColor = MusicFreeUIColorTokens.foregroundPrimary
            label.numberOfLines = 0
            label.text = lyrics.rawText
            label.accessibilityIdentifier = "lyrics.rawText"
            contentStack.addArrangedSubview(label)
        }
        updateActiveLine(animated: false)
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
                ? MusicFreeUIFontTokens.preferred(.title2, weight: .bold)
                : MusicFreeUIFontTokens.preferred(.title3, weight: .semibold)
            let alpha: CGFloat
            switch distance {
            case 0: alpha = 1
            case 1: alpha = 0.62
            case 2: alpha = 0.42
            default: alpha = 0.24
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
        scrollView.scrollRectToVisible(labelRect.insetBy(dx: 0, dy: -80), animated: animated)
    }

    @objc private func showLyricsSettings() {
        let alert = UIAlertController(
            title: L("歌词设置"),
            message: L("当前偏移：%d 毫秒", runtimeOffsetMilliseconds),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: L("提前 250 毫秒"), style: .default) { [weak self] _ in
            self?.runtimeOffsetMilliseconds -= 250
            self?.updateActiveLine(animated: true)
        })
        alert.addAction(UIAlertAction(title: L("延后 250 毫秒"), style: .default) { [weak self] _ in
            self?.runtimeOffsetMilliseconds += 250
            self?.updateActiveLine(animated: true)
        })
        alert.addAction(UIAlertAction(title: L("重置歌词偏移"), style: .default) { [weak self] _ in
            self?.runtimeOffsetMilliseconds = 0
            self?.updateActiveLine(animated: true)
        })
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }
}
