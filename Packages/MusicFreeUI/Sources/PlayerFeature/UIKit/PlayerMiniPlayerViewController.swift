import AppServices
import DesignSystem
import MusicDomain
import MediaSourceAPI
import PlaybackAPI
import UIKit

/// UIKit Mini Player used by the incremental UIKit root shell.
///
/// The controller deliberately owns only presentation state. Playback commands
/// and snapshot ordering continue to flow through the existing PlayerViewModel
/// and PlaybackServing boundary so this migration does not fork player logic.
@MainActor
public final class PlayerMiniPlayerViewController: UIViewController {
    private let serving: any PlaybackServing
    private let artworkServing: (any ArtworkServing)?
    private let onPresentPlayer: () -> Void
    private let viewModel: PlayerViewModel

//    private let separatorView = UIView()
    private let surfaceButton = PlayerMiniPlayerRootView()
    private let artworkView = MusicFreeUIKitArtworkView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metadataStack = UIStackView()
    private let openControl = UIButton(type: .system)
    private let playPauseButton: MusicFreeUIKitPlaybackControlButton
    private let nextButton: MusicFreeUIKitPlaybackControlButton
    private var observationTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var renderedItemID: MediaItemID?
    private var lastRenderedDisplay: PlaybackDisplaySnapshot?
    private var metadataLeadingToArtworkConstraint: NSLayoutConstraint!
    private var metadataLeadingToSurfaceConstraint: NSLayoutConstraint!
    private var isInlinePresentation = false
    private var isCommittingSwipe = false

    public init(
        serving: any PlaybackServing,
        audioServing: (any PlaybackAudioServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil,
        onPresentPlayer: @escaping () -> Void
    ) {
        self.serving = serving
        self.artworkServing = artworkServing
        self.onPresentPlayer = onPresentPlayer
        viewModel = PlayerViewModel(
            serving: serving,
            audioServing: audioServing
        )
        playPauseButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "play.fill",
            accessibilityLabel: L("播放"),
            foregroundColor: MusicFreeUIColorTokens.foregroundPrimary,
            backgroundColor: .clear,
            showsBackground: false,
            controlSize: MusicFreeLayoutMetrics.minimumHitTarget
        )
        nextButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "forward.fill",
            accessibilityLabel: L("下一首"),
            foregroundColor: MusicFreeUIColorTokens.foregroundPrimary,
            backgroundColor: .clear,
            showsBackground: false,
            controlSize: MusicFreeLayoutMetrics.minimumHitTarget
        )
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "player.mini.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let container = PlayerMiniPlayerContainerView()
        container.addSubview(surfaceButton)
        surfaceButton.translatesAutoresizingMaskIntoConstraints = false
        surfaceButton.accessibilityIdentifier = "player.mini"
        surfaceButton.addTarget(self, action: #selector(openPlayer), for: .primaryActionTriggered)
        let swipeRecognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleHorizontalSwipe(_:))
        )
        swipeRecognizer.cancelsTouchesInView = true
        container.addGestureRecognizer(swipeRecognizer)
        NSLayoutConstraint.activate([
            surfaceButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surfaceButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surfaceButton.topAnchor.constraint(equalTo: container.topAnchor),
            surfaceButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // UITabAccessory owns the Liquid Glass surface. Keep every content
        // layer transparent so the system material remains visible through
        // regular and inline presentations.
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        view.accessibilityIdentifier = "player.mini"
        view.accessibilityLabel = L("迷你播放器")

        configureViews()
        updateAccessoryPresentation()
        render(serving.snapshot)
        startObserving()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard #available(iOS 26.0, *),
              previousTraitCollection?.tabAccessoryEnvironment
                  != traitCollection.tabAccessoryEnvironment
        else {
            return
        }
        updateAccessoryPresentation()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        artworkTask?.cancel()
        artworkTask = nil
    }

    deinit {
        observationTask?.cancel()
        artworkTask?.cancel()
    }

    private func configureViews() {
//        separatorView.translatesAutoresizingMaskIntoConstraints = false
//        separatorView.backgroundColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.32)
//        separatorView.accessibilityElementsHidden = true
//        view.addSubview(separatorView)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.cornerRadius = 5
        artworkView.placeholderSystemImage = "music.note"
        artworkView.accessibilityElementsHidden = true
        artworkView.isUserInteractionEnabled = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityIdentifier = "player.mini.title"

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isAccessibilityElement = true
        subtitleLabel.accessibilityIdentifier = "player.mini.subtitle"

        metadataStack.axis = .vertical
        metadataStack.alignment = .fill
        metadataStack.spacing = MusicFreeSpacingTokens.xSmall
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        metadataStack.isUserInteractionEnabled = false
        metadataStack.addArrangedSubview(titleLabel)
        metadataStack.addArrangedSubview(subtitleLabel)

        openControl.translatesAutoresizingMaskIntoConstraints = false
        openControl.accessibilityIdentifier = "player.mini.open"
        openControl.accessibilityLabel = L("打开正在播放")
        openControl.accessibilityTraits = [.button]
        openControl.backgroundColor = .clear
        openControl.contentHorizontalAlignment = .fill
        openControl.contentVerticalAlignment = .fill
        openControl.addTarget(self, action: #selector(openPlayer), for: .primaryActionTriggered)
        playPauseButton.onPrimaryAction = { [weak self] in
            self?.viewModel.togglePlayback()
        }
        playPauseButton.accessibilityIdentifier = "player.mini.playPause"

        nextButton.onPrimaryAction = { [weak self] in
            self?.viewModel.next()
        }
        nextButton.accessibilityIdentifier = "player.mini.next"

        let controlsStack = UIStackView(arrangedSubviews: [playPauseButton, nextButton])
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.spacing = MusicFreeSpacingTokens.xSmall
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        surfaceButton.addSubview(artworkView)
        surfaceButton.addSubview(metadataStack)
        // Keep the presentation target inside the accessory's concrete root
        // button. UITabAccessory can apply custom hit-testing to its content
        // wrapper; sibling controls on the wrapper may expose a frame but
        // still receive an invalid activation point. A nested control remains
        // discoverable under `player.mini.open` while the aggregate
        // `player.mini` button stays the primary target.
        surfaceButton.addSubview(openControl)
        view.addSubview(controlsStack)

        metadataLeadingToArtworkConstraint = metadataStack.leadingAnchor.constraint(
            equalTo: artworkView.trailingAnchor,
            constant: MusicFreeSpacingTokens.rowGap
        )
        metadataLeadingToSurfaceConstraint = metadataStack.leadingAnchor.constraint(
            equalTo: surfaceButton.leadingAnchor,
            constant: MusicFreeSpacingTokens.small
        )

        NSLayoutConstraint.activate([
//            separatorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
//            separatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
//            separatorView.topAnchor.constraint(equalTo: view.topAnchor),
//            separatorView.heightAnchor.constraint(equalToConstant: MusicFreeSpacingTokens.hairline),

            // Keep the presentation target independent from the controls
            // stack's intrinsic width.  UITabAccessory may resolve the
            // stack's size after the first layout pass; tying the target's
            // trailing edge to it can otherwise produce a zero/negative hit
            // frame even though the Mini Player is visible.
            openControl.leadingAnchor.constraint(equalTo: surfaceButton.leadingAnchor),
            openControl.trailingAnchor.constraint(equalTo: surfaceButton.trailingAnchor),
            openControl.topAnchor.constraint(equalTo: surfaceButton.topAnchor),
            openControl.bottomAnchor.constraint(equalTo: surfaceButton.bottomAnchor),

            artworkView.leadingAnchor.constraint(equalTo: surfaceButton.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            artworkView.centerYAnchor.constraint(equalTo: surfaceButton.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 30),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),

            metadataLeadingToArtworkConstraint,
            metadataLeadingToSurfaceConstraint,
            metadataStack.trailingAnchor.constraint(equalTo: controlsStack.leadingAnchor, constant: -MusicFreeSpacingTokens.small),
            metadataStack.centerYAnchor.constraint(equalTo: surfaceButton.centerYAnchor),

            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            controlsStack.centerYAnchor.constraint(equalTo: openControl.centerYAnchor),
            controlsStack.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
            controlsStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
    }

    private func updateAccessoryPresentation() {
        let isInline: Bool
        if #available(iOS 26.0, *) {
            isInline = traitCollection.tabAccessoryEnvironment == .inline
        } else {
            isInline = false
        }
        isInlinePresentation = isInline
        view.backgroundColor = .clear
        view.isOpaque = false
        surfaceButton.backgroundColor = .clear
        surfaceButton.isOpaque = false
//        separatorView.isHidden = isInline
        // Match the SwiftUI accessory contract: the inline state is a compact
        // title + primary control row inside the tab bar. Artwork, subtitle and
        // the secondary next action belong to the regular accessory state and
        // must not reserve width when the tab bar collapses.
        artworkView.isHidden = isInline
        subtitleLabel.isHidden = isInline || subtitleLabel.text?.isEmpty != false
        nextButton.isHidden = isInline
        metadataLeadingToArtworkConstraint?.isActive = !isInline
        metadataLeadingToSurfaceConstraint?.isActive = isInline
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    private func startObserving() {
        let serving = self.serving
        observationTask = Task { @MainActor [weak self] in
            for await snapshot in serving.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.render(snapshot)
            }
        }
    }

    private func render(_ snapshot: PlaybackSessionSnapshot) {
        guard isViewLoaded else { return }

        let itemID = snapshot.currentItemID
        let retainsPreviousDisplay = snapshot.currentItem == nil
            && itemID != nil
            && snapshot.phase == .preparing
        let display = snapshot.currentItem
            ?? (retainsPreviousDisplay ? lastRenderedDisplay : nil)
        if let currentDisplay = snapshot.currentItem {
            lastRenderedDisplay = currentDisplay
        } else if itemID == nil {
            lastRenderedDisplay = nil
        }
        titleLabel.text = display?.title ?? ""
        subtitleLabel.text = display?.artist
        subtitleLabel.isHidden = isInlinePresentation || display?.artist?.isEmpty != false
        titleLabel.accessibilityLabel = display?.title
        subtitleLabel.accessibilityLabel = display?.artist
        view.accessibilityValue = display?.title

        let hasStartedPlayback = viewModel.hasStartedPlayback
        let isPlaying = snapshot.phase == .playing
            || ((snapshot.phase == .preparing || snapshot.phase == .buffering)
                && hasStartedPlayback)
        playPauseButton.systemImageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.accessibilityLabel = isPlaying ? L("暂停") : L("播放")
        playPauseButton.isLoading = (snapshot.phase == .preparing
            || snapshot.phase == .buffering) && !hasStartedPlayback
        playPauseButton.isEnabled = itemID != nil
        nextButton.isEnabled = viewModel.canGoNext

        guard !retainsPreviousDisplay else { return }
        if itemID != renderedItemID {
            renderedItemID = itemID
            loadArtwork(for: display?.artworkID, itemID: itemID)
        }
    }

    private func loadArtwork(for artworkID: ArtworkID?, itemID: MediaItemID?) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkView.placeholderTitle = titleLabel.text

        guard let artworkID, let itemID, let artworkServing else {
            artworkView.image = nil
            artworkView.isLoading = false
            return
        }

        let cachedImage = PlayerArtworkImagePipeline.shared.cachedImage(
            artworkID: artworkID,
            sourceID: itemID.sourceID,
            maximumPixelDimension: 160
        )
        artworkView.image = cachedImage
        artworkView.isLoading = cachedImage == nil
        artworkTask = Task { @MainActor [weak self] in
            do {
                let image = await PlayerArtworkImagePipeline.shared.image(
                    artworkID: artworkID,
                    sourceID: itemID.sourceID,
                    maximumPixelDimension: 160,
                    serving: artworkServing
                )
                try Task.checkCancellation()
                guard let self, self.renderedItemID == itemID else { return }
                self.artworkView.image = image
                self.artworkView.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.renderedItemID == itemID else { return }
                self.artworkView.image = nil
                self.artworkView.isLoading = false
            }
        }
    }

    @objc private func openPlayer() {
        onPresentPlayer()
    }

    @objc private func handleHorizontalSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard !isCommittingSwipe else { return }

        let translation = recognizer.translation(in: surfaceButton)
        let translationSize = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .changed:
            let offset = MiniPlayerSwipePolicy.displayOffset(
                for: translationSize,
                canGoPrevious: viewModel.canGoPrevious,
                canGoNext: viewModel.canGoNext
            )
            surfaceButton.transform = CGAffineTransform(translationX: offset, y: 0)

        case .ended:
            let velocity = recognizer.velocity(in: surfaceButton)
            let predictedTranslation = CGSize(
                width: translation.x + velocity.x * 0.12,
                height: translation.y + velocity.y * 0.12
            )
            let action = MiniPlayerSwipePolicy.action(
                for: translationSize,
                predictedEndTranslation: predictedTranslation,
                canGoPrevious: viewModel.canGoPrevious,
                canGoNext: viewModel.canGoNext,
                activationDistance: MiniPlayerSwipePolicy.activationDistance(
                    for: surfaceButton.bounds.width
                )
            )
            guard let action else {
                resetSwipeTransform()
                return
            }

            isCommittingSwipe = true
            switch action {
            case .previous:
                viewModel.previous()
            case .next:
                viewModel.next()
            }
            resetSwipeTransform { [weak self] in
                self?.isCommittingSwipe = false
            }

        case .cancelled, .failed:
            resetSwipeTransform()

        default:
            break
        }
    }

    private func resetSwipeTransform(completion: (() -> Void)? = nil) {
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.surfaceButton.transform = .identity
        } completion: { _ in
            completion?()
        }
    }
}

private final class PlayerMiniPlayerRootView: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // The root control is intentionally a concrete button as well as the
        // nested title/artwork button. XCTest and VoiceOver can therefore
        // target the aggregate `player.mini` surface while the inner control
        // remains available for the legacy `player.mini.open` identifier.
        accessibilityTraits = [.button]
        backgroundColor = .clear
        isOpaque = false
        adjustsImageWhenHighlighted = false
        showsTouchWhenHighlighted = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let height: CGFloat
        if #available(iOS 26.0, *), traitCollection.tabAccessoryEnvironment == .inline {
            height = MusicFreeLayoutMetrics.miniPlayerInlineHeight
        } else {
            height = MusicFreeLayoutMetrics.miniPlayerContentHeight
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard #available(iOS 26.0, *),
              previousTraitCollection?.tabAccessoryEnvironment
                  != traitCollection.tabAccessoryEnvironment
        else {
            return
        }
        invalidateIntrinsicContentSize()
    }
}

private final class PlayerMiniPlayerContainerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
    }

    override var intrinsicContentSize: CGSize {
        let height: CGFloat
        if #available(iOS 26.0, *), traitCollection.tabAccessoryEnvironment == .inline {
            height = MusicFreeLayoutMetrics.miniPlayerInlineHeight
        } else {
            height = MusicFreeLayoutMetrics.miniPlayerContentHeight
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard #available(iOS 26.0, *),
              previousTraitCollection?.tabAccessoryEnvironment
                  != traitCollection.tabAccessoryEnvironment
        else {
            return
        }
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
