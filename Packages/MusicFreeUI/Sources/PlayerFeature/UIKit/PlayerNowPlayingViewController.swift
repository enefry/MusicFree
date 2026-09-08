import AppServices
import AVKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import UIKit

/// Keeps the Apple Music header action hit target at 40pt while rendering the
/// visible control fill at the 32pt size used by the SwiftUI reference.
@MainActor
private final class PlayerNowPlayingHeaderButton: UIButton {
    var visualBackgroundColor: UIColor = .clear {
        didSet { visualBackgroundView.backgroundColor = visualBackgroundColor }
    }

    var visualDiameter: CGFloat = 32 {
        didSet { setNeedsLayout() }
    }

    private let visualBackgroundView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        visualBackgroundView.isUserInteractionEnabled = false
        visualBackgroundView.layer.cornerCurve = .continuous
        insertSubview(visualBackgroundView, at: 0)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        visualBackgroundView.isUserInteractionEnabled = false
        visualBackgroundView.layer.cornerCurve = .continuous
        insertSubview(visualBackgroundView, at: 0)
    }

    override var isHighlighted: Bool {
        didSet { visualBackgroundView.alpha = isHighlighted ? 0.72 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(visualDiameter, min(bounds.width, bounds.height))
        visualBackgroundView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: diameter, height: diameter)
        )
        visualBackgroundView.center = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        visualBackgroundView.layer.cornerRadius = diameter / 2
    }
}

private enum PlayerNowPlayingLayoutMetrics {
    // These values mirror the original NowPlayingView geometry. Keeping the
    // UIKit surface on the same point grid is important here: the reference
    // screenshots are captured at a different pixel scale, but the design is
    // expressed in these point values.
    static let horizontalInset: CGFloat = 32
    static let topChromeInset: CGFloat = 31
    static let artworkMaximumDimension: CGFloat = 260
    static let artworkMinimumDimension: CGFloat = 180
    static let artworkTopInset: CGFloat = 14
    static let metadataBottomInset: CGFloat = 24
    static let compactMetadataBottomInset: CGFloat = 16

    // Keep the UIKit queue in lockstep with NowPlayingView's original
    // SwiftUI geometry. These values are also the contract used by the
    // Apple Music reference screenshots.
    static let queueCurrentArtworkSize: CGFloat = 72
    static let queueCurrentRowHeight: CGFloat = 96
    static let queueHistoryArtworkSize: CGFloat = 48
    static let queueHistoryRowHeight: CGFloat = 72
    static let queueContinueArtworkSize: CGFloat = 48
    static let queueContinueRowHeight: CGFloat = 60
    static let queueRowActionWidth: CGFloat = 40
    static let queueModeHeight: CGFloat = 40
    // The current row is intentionally not flush with the visible scroll
    // viewport. UIKit's anchor calculation must leave this much room below
    // the grabber.
    static let queueCurrentAnchorVisibleTopInset: CGFloat = 18
    // Keep the final queue row above the fixed progress control. Without a
    // real content tail, the last row can settle directly on the queue
    // viewport edge and its title/subtitle are visually cut by the slider.
    static let queueBottomVisibleInset: CGFloat = 72

    // Keep these values in lockstep with NowPlayingView's original SwiftUI
    // geometry. The regular transport/progress group occupies 308pt above
    // the bottom safe area; the footer is part of that same surface but is
    // anchored to its bottom edge.
    static let regularControlsHeight: CGFloat = 308
    // Queue and lyrics use the same bottom control contract as the artwork
    // surface. Keeping a second height here moves the progress/transport group
    // by 32pt and is the main source of the visible queue/lyrics drift.
    static let alternateControlsHeight: CGFloat = regularControlsHeight
    static let compactControlsHeight: CGFloat = 216
    static let regularTransportHeight: CGFloat = 88
    static let compactTransportHeight: CGFloat = 64
    static let regularFooterHeight: CGFloat = 56
    static let compactFooterHeight: CGFloat = 44
}

/// Colors for the Now Playing surface are deliberately trait-aware instead
/// of being resolved once from `.white`/`.black`.  The app can change its
/// appearance while this controller is already presented, so every color
/// exposed here must resolve again when UIKit sends a trait change.
private enum PlayerNowPlayingPalette {
    static let primary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.96)
            : UIColor.black.withAlphaComponent(0.92)
    }

    static let primaryStrong = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.98)
            : UIColor.black.withAlphaComponent(0.94)
    }

    static let secondary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.64)
            : UIColor.black.withAlphaComponent(0.62)
    }

    static let secondaryStrong = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.72)
            : UIColor.black.withAlphaComponent(0.68)
    }

    static let tertiary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.44)
            : UIColor.black.withAlphaComponent(0.44)
    }

    static let tertiaryStrong = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.38)
            : UIColor.black.withAlphaComponent(0.38)
    }

    static let disabled = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.black.withAlphaComponent(0.28)
    }

    static let controlFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor.black.withAlphaComponent(0.10)
    }

    static let controlFillStrong = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.black.withAlphaComponent(0.14)
    }

    static let controlFillSubtle = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    }

    static let controlFillMuted = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.12)
    }

    static let selectedControlFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.42)
            : UIColor.black.withAlphaComponent(0.18)
    }

    static let trackInactive = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.24)
            : UIColor.black.withAlphaComponent(0.24)
    }

    static let rowAccessory = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.36)
            : UIColor.black.withAlphaComponent(0.36)
    }

    static let backdropBase = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.94)
            : UIColor.white.withAlphaComponent(0.94)
    }

    static let artworkPlaceholder = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.08)
    }

    static let closeButtonFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.28)
            : UIColor.white.withAlphaComponent(0.28)
    }

    static let soft = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.70)
            : UIColor.black.withAlphaComponent(0.64)
    }

    static func blurStyle(for traits: UITraitCollection) -> UIBlurEffect.Style {
        traits.userInterfaceStyle == .dark
            ? .systemUltraThinMaterialDark
            : .systemUltraThinMaterialLight
    }

    static func gradientColors(for traits: UITraitCollection) -> [CGColor] {
        let colors: [UIColor]
        if traits.userInterfaceStyle == .dark {
            colors = [
                UIColor.black.withAlphaComponent(0.08),
                UIColor.black.withAlphaComponent(0.10),
                UIColor.black.withAlphaComponent(0.24),
                UIColor.black.withAlphaComponent(0.48),
            ]
        } else {
            colors = [
                UIColor.white.withAlphaComponent(0.08),
                UIColor.white.withAlphaComponent(0.10),
                UIColor.white.withAlphaComponent(0.20),
                UIColor.white.withAlphaComponent(0.34),
            ]
        }
        return colors.map(\.cgColor)
    }
}

private enum PlayerNowPlayingBackdropImageProcessor {
    private static let scaleWidth: CGFloat = 128
    private static let blurRadius: Float = 8

    static func process(_ image: UIImage) -> UIImage? {
        guard let sourceCGImage = image.cgImage else { return nil }
        let size = image.size
        let scaleX = scaleWidth / size.width
        let sourceImage = CIImage(cgImage: sourceCGImage)
        let scaledImage = sourceImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleX)
        )
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = scaledImage
        blurFilter.radius = blurRadius

        guard let blurredImage = blurFilter.outputImage?.cropped(to: scaledImage.extent) else {
            return nil
        }

        let context = CIContext()
        guard let outputCGImage = context.createCGImage(
            blurredImage,
            from: scaledImage.extent
        ) else {
            return nil
        }
        let result = UIImage(
            cgImage: outputCGImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
        return result
    }
}

/// UIKit Now Playing surface for the incremental PlayerFeature migration.
///
/// The controller owns presentation state only. Playback, queue, seeking,
/// audio output and favorite mutations still flow through the existing
/// services and feature view models. The artwork, queue/history and lyrics
/// surfaces all live in this controller so the system presentation remains a
/// single Apple Music-style Now Playing page instead of stacking a second
/// queue sheet above it.
@MainActor
public final class PlayerNowPlayingViewController: UIViewController {
    private enum QueueListItem {
        case historyHeader
        case history(PlaybackHistoryItem)
        case historyMessage
        case current
        case playbackMode
        case continueHeader
        case upcoming(entry: PlaybackQueueEntry, itemID: MediaItemID)
        case upcomingMessage
    }

    private let serving: any PlaybackServing
    private let audioServing: (any PlaybackAudioServing)?
    private let artworkServing: (any ArtworkServing)?
    private let library: (any LibraryServing)?
    private let lyricsServing: (any LyricsServing)?
    private let onShowQueue: (() -> Void)?
    private let onShowLyrics: (() -> Void)?
    private let onShowTrackDetails: ((MediaItemID) -> Void)?
    private let onShowAlbum: ((AlbumID) -> Void)?
    private let onShowArtist: ((ArtistID) -> Void)?
    private let onAddToPlaylist: ((MediaItemID) -> Void)?
    private var fallbackCloseHandler: (() -> Void)?
    private let viewModel: PlayerViewModel
    private let favoriteController: PlayerFavoriteController
    private let historyLoader: NowPlayingHistoryLoader

    private let backdropImageView = UIImageView()
    private let backdropBlurView = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterial)
    )
    private let backdropTintView = UIView()
    private let backdropGradientView = UIView()
    private let backdropGradientLayer = CAGradientLayer()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let artworkTopSpacer = UIView()
    private let artworkMetadataSpacer = UIView()
    private let artworkBottomSpacer = UIView()
    private let artworkContainer = UIView()
    private let artworkView = MusicFreeUIKitArtworkView(
        accessibilityLabel: L("封面"),
        fillsAvailableWidth: true,
        cornerRadius: 8
    )
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let albumLabel = UILabel()
    private let metadataStack = UIStackView()
    private let artworkMetadataHeader = UIStackView()
    private let favoriteButton = PlayerNowPlayingHeaderButton()
    private let moreButton = PlayerNowPlayingHeaderButton()
    private let progressSlider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let pausedBadge = UIStackView()
    private let pausedBadgeIcon = UIImageView()
    private let pausedBadgeLabel = UILabel()
    private let progressStack = UIStackView()
    private let previousButton: MusicFreeUIKitPlaybackControlButton
    private let playPauseButton: MusicFreeUIKitPlaybackControlButton
    private let nextButton: MusicFreeUIKitPlaybackControlButton
    private let transportStack = UIStackView()
    private let muteButton = UIButton(type: .system)
    private let volumeSlider = UISlider()
    private let volumeMaxImageView = UIImageView()
    private let volumeStack = UIStackView()
    // Footer buttons own their circular selected surface. `.system` buttons
    // can acquire the iOS 26 automatic glass background even after assigning
    // a plain configuration, which turns the selected queue button into a
    // stretched droplet instead of the reference circle.
    private let lyricsButton = PlayerNowPlayingHeaderButton()
    private let routePicker = AVRoutePickerView()
    private let queueButton = PlayerNowPlayingHeaderButton()
    private let footerStack = UIStackView()
    private let queueSurface = UIView()
    private let queueListContainer = UIView()
    private let queueTableView = UITableView(frame: .zero, style: .plain)
    private let queueScrollMaskLayer = CAShapeLayer()
    private let queueCurrentFavoriteButton = PlayerNowPlayingHeaderButton()
    private let queueCurrentMoreButton = PlayerNowPlayingHeaderButton()
    private let queueCurrentActions = UIStackView()
    private let controlsContainer = UIView()
    private let controlsStack = UIStackView()
    private let lyricsSurface = UIStackView()
    private let lyricsHeaderArtworkView = MusicFreeUIKitArtworkView(
        accessibilityLabel: L("封面"),
        fillsAvailableWidth: true,
        cornerRadius: 8
    )
    private let lyricsHeaderTitleLabel = UILabel()
    private let lyricsHeaderArtistLabel = UILabel()
    private let lyricsHeaderMetadataStack = UIStackView()
    private let lyricsHeaderActions = UIStackView()
    private let lyricsHeaderFavoriteButton = PlayerNowPlayingHeaderButton()
    private let lyricsHeaderMoreButton = PlayerNowPlayingHeaderButton()
    private lazy var embeddedLyricsView = PlayerEmbeddedLyricsView(
        lyricsServing: lyricsServing,
        player: viewModel
    )
    private let lyricsOffsetButton = UIButton(type: .system)
    private let lyricsUnavailableButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let fallbackCloseButton = UIButton(type: .system)
    private var snapshotCancellable: AnyCancellable?
    private var favoriteCancellable: AnyCancellable?
    private var artworkTask: Task<Void, Never>?
    private var queueTracksTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyObservationTask: Task<Void, Never>?
    private var renderedItemID: MediaItemID?
    private var renderedArtworkKey: String?
    private var lastRenderedDisplay: PlaybackDisplaySnapshot?
    private var renderedHistoryStructureKey: String?
    private var renderedContinueStructureKey: String?
    private var historyRowsDirty = true
    private var continueRowsDirty = true
    private var renderedQueueCurrentRowSignature: String?
    private var renderedQueueModeSignature: String?
    private var queueListItems: [QueueListItem] = []
    private var requestedQueueKey: String?
    private var queueTracks: [MediaItemID: Track] = [:]
    private var queueArtistNames: [ArtistID: String] = [:]
    private var queueAlbumNames: [AlbumID: String] = [:]
    private var queueUserScrolled = false
    private var queueScrollStartOffsetY: CGFloat?
    private var queueAnchorScheduled = false
    private var isShowingQueue = false
    private var stateCancellables = Set<AnyCancellable>()
    private var artworkTopSpacerHeightConstraint: NSLayoutConstraint?
    private var artworkDimensionConstraint: NSLayoutConstraint?
    private var artworkContainerHeightConstraint: NSLayoutConstraint?
    private var artworkBottomSpacerHeightConstraint: NSLayoutConstraint?
    private var contentStackHeightConstraint: NSLayoutConstraint?
    private var contentStackBottomConstraint: NSLayoutConstraint?
    private var controlsHeightConstraint: NSLayoutConstraint?
    private var controlsStackTopConstraint: NSLayoutConstraint?
    private var progressStackHeightConstraint: NSLayoutConstraint?
    private var transportHeightConstraint: NSLayoutConstraint?
    private var volumeStackHeightConstraint: NSLayoutConstraint?
    private var footerStackHeightConstraint: NSLayoutConstraint?
    private var lyricsButtonWidthConstraint: NSLayoutConstraint?
    private var lyricsButtonHeightConstraint: NSLayoutConstraint?
    private var routePickerWidthConstraint: NSLayoutConstraint?
    private var routePickerHeightConstraint: NSLayoutConstraint?
    private var queueButtonWidthConstraint: NSLayoutConstraint?
    private var queueButtonHeightConstraint: NSLayoutConstraint?
    private var lyricsSurfaceHeightConstraint: NSLayoutConstraint?
    private var lyricsEmbeddedHeightConstraint: NSLayoutConstraint?
    private var isShowingStatus = false
    private var isShowingLyrics = false
    private var lastAppliedCompactLayout: Bool?

    public init(
        serving: any PlaybackServing,
        audioServing: (any PlaybackAudioServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil,
        onShowQueue: (() -> Void)? = nil,
        onShowLyrics: (() -> Void)? = nil,
        onShowTrackDetails: ((MediaItemID) -> Void)? = nil,
        onShowAlbum: ((AlbumID) -> Void)? = nil,
        onShowArtist: ((ArtistID) -> Void)? = nil,
        onAddToPlaylist: ((MediaItemID) -> Void)? = nil
    ) {
        self.serving = serving
        self.audioServing = audioServing
        self.artworkServing = artworkServing
        self.library = library
        self.lyricsServing = lyricsServing
        self.onShowQueue = onShowQueue
        self.onShowLyrics = onShowLyrics
        self.onShowTrackDetails = onShowTrackDetails
        self.onShowAlbum = onShowAlbum
        self.onShowArtist = onShowArtist
        self.onAddToPlaylist = onAddToPlaylist
        viewModel = PlayerViewModel(
            serving: serving,
            audioServing: audioServing
        )
        favoriteController = PlayerFavoriteController(library: library)
        historyLoader = NowPlayingHistoryLoader(library: library)
        previousButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "backward.fill",
            accessibilityLabel: L("上一首"),
            foregroundColor: PlayerNowPlayingPalette.primary,
            backgroundColor: .clear,
            showsBackground: false,
            controlSize: 72
        )
        playPauseButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "play.fill",
            accessibilityLabel: L("播放"),
            foregroundColor: PlayerNowPlayingPalette.primary,
            backgroundColor: .clear,
            showsBackground: false,
            controlSize: 88
        )
        nextButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "forward.fill",
            accessibilityLabel: L("下一首"),
            foregroundColor: PlayerNowPlayingPalette.primary,
            backgroundColor: .clear,
            showsBackground: false,
            controlSize: 72
        )
        previousButton.symbolPointSize = 34
        playPauseButton.symbolPointSize = 42
        nextButton.symbolPointSize = 34
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "player.nowPlaying.uikit"
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var preferredStatusBarStyle: UIStatusBarStyle {
        switch traitCollection.userInterfaceStyle {
        case .dark:
            .lightContent
        case .light:
            .darkContent
        default:
            .default
        }
    }

    /// The queue is presented as a second sheet above Now Playing. Hide the
    /// covered footer from the accessibility tree while that sheet is active
    /// so UI automation and VoiceOver resolve the visible queue footer.
    public func setQueueSheetPresented(_ presented: Bool) {
        view.accessibilityElementsHidden = presented
        queueButton.isAccessibilityElement = !presented
    }

    /// Installs the close affordance used when this controller is embedded as
    /// a root child after UIKit rejects its modal presentation. Normal
    /// page-sheet presentation does not provide this handler, so its existing
    /// grabber and interactive dismissal remain unchanged.
    public func setFallbackCloseHandler(_ handler: @escaping () -> Void) {
        fallbackCloseHandler = handler
        guard isViewLoaded else { return }
        configureFallbackCloseButton()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // The player backdrop owns the complete moving sheet surface. Keep
        // the presentation container transparent so interactive dismissal
        // reveals the presenting page at the sheet boundary.
        view.backgroundColor = PlayerNowPlayingPalette.backdropBase
        view.isOpaque = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        view.accessibilityIdentifier = "player.nowPlaying"
        configureViews()
        configureInitialLayoutMode()
        applyTheme()
        render(serving.snapshot)
        startObserving()
    }

    override public func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle
            != traitCollection.userInterfaceStyle else {
            return
        }
        applyTheme()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A canceled interactive dismissal can return to the same controller
        // without rebuilding it. Re-apply the presentation boundary in case
        // UIKit recreated the sheet container during the transition.
        configurePresentationSurface()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        artworkTask?.cancel()
        artworkTask = nil
    }

    deinit {
        artworkTask?.cancel()
        queueTracksTask?.cancel()
        historyTask?.cancel()
        historyObservationTask?.cancel()
    }

    /// Re-resolves every color that is stored on a UIKit view or CALayer.
    /// Dynamic `UIColor` values update text/tint automatically, but rendered
    /// images, gradients, and border CGColors do not; keep those in one place
    /// so an app appearance change never leaves a half-dark/half-light page.
    private func applyTheme() {
        guard isViewLoaded else { return }

        let traits = traitCollection
        view.backgroundColor = PlayerNowPlayingPalette.backdropBase
        backdropTintView.backgroundColor = PlayerNowPlayingPalette.backdropBase
        backdropBlurView.effect = UIBlurEffect(
            style: PlayerNowPlayingPalette.blurStyle(for: traits)
        )
        backdropGradientLayer.colors = PlayerNowPlayingPalette.gradientColors(
            for: traits
        )
        backdropGradientLayer.frame = backdropGradientView.bounds

        artworkView.backgroundColor = PlayerNowPlayingPalette.artworkPlaceholder
        lyricsHeaderArtworkView.backgroundColor = PlayerNowPlayingPalette.artworkPlaceholder
        titleLabel.textColor = PlayerNowPlayingPalette.primary
        artistLabel.textColor = PlayerNowPlayingPalette.secondary
        albumLabel.textColor = PlayerNowPlayingPalette.tertiary
        lyricsHeaderTitleLabel.textColor = PlayerNowPlayingPalette.primary
        lyricsHeaderArtistLabel.textColor = PlayerNowPlayingPalette.secondary
        elapsedLabel.textColor = PlayerNowPlayingPalette.secondary
        remainingLabel.textColor = PlayerNowPlayingPalette.secondary
        pausedBadge.backgroundColor = PlayerNowPlayingPalette.controlFill
        pausedBadgeIcon.tintColor = PlayerNowPlayingPalette.secondary
        pausedBadgeLabel.textColor = PlayerNowPlayingPalette.secondary
        statusLabel.textColor = PlayerNowPlayingPalette.secondaryStrong
        retryButton.setTitleColor(PlayerNowPlayingPalette.primary, for: .normal)
        retryButton.backgroundColor = PlayerNowPlayingPalette.controlFillStrong
        fallbackCloseButton.tintColor = PlayerNowPlayingPalette.primary
        fallbackCloseButton.backgroundColor = PlayerNowPlayingPalette.closeButtonFill

        configureHeaderButtonColors(favoriteButton)
        configureHeaderButtonColors(moreButton)
        configureHeaderButtonColors(lyricsHeaderFavoriteButton)
        configureHeaderButtonColors(lyricsHeaderMoreButton)
        configureHeaderButtonColors(queueCurrentFavoriteButton)
        configureHeaderButtonColors(queueCurrentMoreButton)
        configureFooterButtonColors()

        progressSlider.minimumTrackTintColor = PlayerNowPlayingPalette.primary
        progressSlider.maximumTrackTintColor = PlayerNowPlayingPalette.trackInactive
        progressSlider.thumbTintColor = PlayerNowPlayingPalette.primary
        progressSlider.setMinimumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.primary),
            for: .normal
        )
        progressSlider.setMaximumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.trackInactive),
            for: .normal
        )
        progressSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.primary),
            for: .normal
        )
        progressSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.primary),
            for: .highlighted
        )

        volumeSlider.minimumTrackTintColor = PlayerNowPlayingPalette.secondary
        volumeSlider.maximumTrackTintColor = PlayerNowPlayingPalette.trackInactive
        volumeSlider.thumbTintColor = PlayerNowPlayingPalette.secondary
        volumeSlider.setMinimumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.secondary),
            for: .normal
        )
        volumeSlider.setMaximumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.trackInactive),
            for: .normal
        )
        volumeSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.secondaryStrong),
            for: .normal
        )
        volumeSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.secondaryStrong),
            for: .highlighted
        )
        volumeMaxImageView.tintColor = PlayerNowPlayingPalette.secondary
        muteButton.tintColor = PlayerNowPlayingPalette.secondary
        routePicker.tintColor = PlayerNowPlayingPalette.secondary
        routePicker.activeTintColor = PlayerNowPlayingPalette.primary
        lyricsOffsetButton.tintColor = PlayerNowPlayingPalette.primary
        lyricsOffsetButton.backgroundColor = PlayerNowPlayingPalette.controlFillStrong
        lyricsUnavailableButton.tintColor = PlayerNowPlayingPalette.disabled
        lyricsUnavailableButton.backgroundColor = PlayerNowPlayingPalette.controlFillSubtle
        queueTableView.indicatorStyle = .default
        queueTableView.reloadData()
        updateFooterButtonAppearance()

    }

    private func configureHeaderButtonColors(_ button: UIButton) {
        button.tintColor = PlayerNowPlayingPalette.primary
        if let button = button as? PlayerNowPlayingHeaderButton {
            // Header actions keep their circular surface in both themes.
            // This is a separate subview, so refresh it explicitly when the
            // app appearance changes.
            button.visualBackgroundColor = PlayerNowPlayingPalette.controlFill
        }
    }

    private func configureFooterButtonColors() {
        lyricsButton.tintColor = PlayerNowPlayingPalette.secondary
        queueButton.tintColor = PlayerNowPlayingPalette.secondary
    }

    private func configureViews() {
        configureBackground()
        configureScrollView()
        configureArtwork()
        configureMetadata()
        configureLyricsSurface()
        configureControlsContainer()
        configureQueueSurface()
        configureProgress()
        configureTransport()
        configureVolume()
        configureFooter()
        configureStatus()
        configureFallbackCloseButton()
    }

    private func configureBackground() {
        // Apple Music derives the player surface from the current artwork.
        // Keep the image in the moving sheet content so interactive dismissal
        // reveals the presenting page instead of a fixed black rectangle.
        backdropTintView.translatesAutoresizingMaskIntoConstraints = false
        backdropTintView.backgroundColor = PlayerNowPlayingPalette.backdropBase
        view.addSubview(backdropTintView)

        backdropImageView.translatesAutoresizingMaskIntoConstraints = false
        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        backdropImageView.alpha = 0.92
        backdropImageView.transform = CGAffineTransform(scaleX: 1.24, y: 1.24)
        backdropImageView.isUserInteractionEnabled = false
        backdropImageView.accessibilityElementsHidden = true
        view.addSubview(backdropImageView)

        backdropBlurView.translatesAutoresizingMaskIntoConstraints = false
        backdropBlurView.alpha = 0.92
        backdropBlurView.isUserInteractionEnabled = false
        backdropBlurView.accessibilityElementsHidden = true
        view.addSubview(backdropBlurView)

        // A separate view is required for the gradient. Adding the gradient
        // as a sublayer of UIVisualEffectView makes it participate in the
        // effect view's private compositing hierarchy, which can place it
        // underneath the blur content (or make it disappear entirely on iOS
        // 26). Keeping it as a sibling gives us the same ordering as the
        // SwiftUI ZStack: artwork, blur, gradient, then player controls.
        backdropGradientView.translatesAutoresizingMaskIntoConstraints = false
        backdropGradientView.backgroundColor = .clear
        backdropGradientView.isUserInteractionEnabled = false
        backdropGradientView.accessibilityElementsHidden = true
        view.addSubview(backdropGradientView)

        backdropGradientLayer.colors = PlayerNowPlayingPalette.gradientColors(
            for: traitCollection
        )
        backdropGradientLayer.locations = [0, 0.12, 0.54, 1]
        backdropGradientLayer.name = "player.nowPlaying.background.gradient"
        backdropGradientLayer.isHidden = true
        backdropGradientView.layer.addSublayer(backdropGradientLayer)

        NSLayoutConstraint.activate([
            backdropTintView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropTintView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropTintView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropTintView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropBlurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropBlurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropBlurView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropBlurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropGradientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropGradientView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropGradientView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropGradientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropGradientLayer.frame = backdropGradientView.bounds
        configurePresentationSurface()

        let contentWidth = max(
            0,
            view.bounds.width - (PlayerNowPlayingLayoutMetrics.horizontalInset * 2)
        )
        let artworkDimension = min(
            PlayerNowPlayingLayoutMetrics.artworkMaximumDimension,
            max(
                PlayerNowPlayingLayoutMetrics.artworkMinimumDimension,
                contentWidth - 64
            )
        )
        artworkDimensionConstraint?.constant = artworkDimension
        // The SwiftUI surface reserves a 14pt inset above the artwork. Keep
        // that inset in the container instead of centering the image; the
        // latter makes the cover visibly too high on the regular-height
        // Now Playing sheet.
        artworkContainerHeightConstraint?.constant = artworkDimension
            + PlayerNowPlayingLayoutMetrics.artworkTopInset

        // Match the original layout policy: regular vertical size classes
        // keep the controls pinned while compact-height presentations leave
        // the whole player reachable through the scroll view. Do not use the
        // sheet's current bounds height here: during presentation UIKit can
        // temporarily report the pre-expansion height, which would switch the
        // entire page from compact to regular once as the sheet opens.
        let usePinnedControls = traitCollection.verticalSizeClass != .compact
        let pinnedControlsHeight = isShowingQueue || isShowingLyrics
            ? PlayerNowPlayingLayoutMetrics.alternateControlsHeight
            : PlayerNowPlayingLayoutMetrics.regularControlsHeight
        contentStackHeightConstraint?.isActive = usePinnedControls
        contentStackHeightConstraint?.constant = 0
        contentStackBottomConstraint?.constant = 0
        controlsHeightConstraint?.constant = usePinnedControls
            ? pinnedControlsHeight
            : PlayerNowPlayingLayoutMetrics.compactControlsHeight
        scrollView.alwaysBounceVertical = !usePinnedControls

        applyLayoutMode(isCompact: !usePinnedControls)

        let lyricsTopInset = artworkTopSpacerHeightConstraint?.constant
            ?? PlayerNowPlayingLayoutMetrics.topChromeInset
        let lyricsHeight = max(0, scrollView.bounds.height - lyricsTopInset)
        lyricsSurfaceHeightConstraint?.constant = lyricsHeight
        lyricsEmbeddedHeightConstraint?.constant = max(
            0,
            lyricsHeight
                - PlayerNowPlayingLayoutMetrics.queueCurrentArtworkSize
                - 12
                - 4
                - PlayerNowPlayingLayoutMetrics.regularFooterHeight
        )

        if isShowingQueue {
            updateQueueScrollMask()
            updateQueueBottomInset()
        }
    }

    private func configureInitialLayoutMode() {
        let isCompact = traitCollection.verticalSizeClass == .compact
        contentStackHeightConstraint?.isActive = !isCompact
        controlsHeightConstraint?.constant = isCompact
            ? PlayerNowPlayingLayoutMetrics.compactControlsHeight
            : PlayerNowPlayingLayoutMetrics.regularControlsHeight
        scrollView.alwaysBounceVertical = isCompact
        applyLayoutMode(isCompact: isCompact)
    }

    private func updateQueueScrollMask() {
        guard queueTableView.layer.mask === queueScrollMaskLayer else { return }
        let bounds = queueTableView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let topGutter = min(
            PlayerNowPlayingLayoutMetrics.queueCurrentAnchorVisibleTopInset,
            bounds.height
        )
        // UIScrollView.bounds.origin follows contentOffset. The mask lives
        // in the scroll view's content coordinate space, so its frame must
        // follow the current bounds origin as well. Keeping the frame at
        // (0, 0) makes the mask cover only the first content segment after a
        // programmatic queue anchor: the current row and mode buttons remain
        // visible, while Continue Playing is clipped once its content moves
        // past the mask's stale bottom edge. Tracking `bounds` keeps the
        // visible gutter fixed to the viewport for both initial anchoring and
        // user pull-down history reveals.
        queueScrollMaskLayer.frame = bounds
        queueScrollMaskLayer.path = UIBezierPath(
            rect: CGRect(
                x: 0,
                y: topGutter,
                width: bounds.width,
                height: max(0, bounds.height - topGutter)
            )
        ).cgPath
    }

    private func setQueueInitialAnchorMaskEnabled(_ isEnabled: Bool) {
        queueTableView.layer.mask = isEnabled ? queueScrollMaskLayer : nil
        if isEnabled {
            updateQueueScrollMask()
        }
    }

    private func configurePresentationSurface() {
        // UISheetPresentationController owns a separate container view above
        // the presenting page. Leaving its default background in place makes
        // the sheet top edge render as a bright strip while the player canvas
        // is transparent. Both layers must be transparent so the artwork
        // surface is the only visible player background and interactive
        // dismissal exposes the page underneath continuously.
        guard let presentationController else { return }
        presentationController.containerView?.backgroundColor = .clear
        presentationController.presentedView?.backgroundColor = .clear
        presentationController.presentedView?.isOpaque = false
        // The artwork backdrop is a child of the moving sheet. UIKit's page
        // sheet can otherwise let a full-screen child draw outside the
        // presented bounds while the sheet is being dragged, which briefly
        // paints the presenting page black at the end of the dismissal.
        presentationController.presentedView?.clipsToBounds = true
    }

    private func applyLayoutMode(isCompact: Bool) {
        guard lastAppliedCompactLayout != isCompact else { return }
        lastAppliedCompactLayout = isCompact

        artworkBottomSpacerHeightConstraint?.constant = isCompact
            ? PlayerNowPlayingLayoutMetrics.compactMetadataBottomInset
            : PlayerNowPlayingLayoutMetrics.metadataBottomInset

        // Move only the progress region down in the regular player. The
        // following transport/volume/footer controls retain their reference
        // positions by consuming the same amount from the next gap.
        controlsStackTopConstraint?.constant = 0

        progressStackHeightConstraint?.constant = 52
        transportHeightConstraint?.constant = isCompact
            ? PlayerNowPlayingLayoutMetrics.compactTransportHeight
            : PlayerNowPlayingLayoutMetrics.regularTransportHeight
        volumeStackHeightConstraint?.constant = isCompact ? 40 : 44
        footerStackHeightConstraint?.constant = isCompact
            ? PlayerNowPlayingLayoutMetrics.compactFooterHeight
            : PlayerNowPlayingLayoutMetrics.regularFooterHeight

        controlsStack.setCustomSpacing(isCompact ? 8 : 26, after: progressStack)
        controlsStack.setCustomSpacing(
            isCompact ? 6 : 28,
            after: transportStack
        )
        controlsStack.setCustomSpacing(isCompact ? 6 : 18, after: volumeStack)

        transportStack.spacing = isCompact ? 14 : 22
        volumeStack.spacing = isCompact ? 8 : 10
        footerStack.spacing = isCompact ? 24 : 60

        previousButton.setControlSize(isCompact ? 56 : 72)
        playPauseButton.setControlSize(isCompact ? 64 : 88)
        nextButton.setControlSize(isCompact ? 56 : 72)
        previousButton.symbolPointSize = isCompact ? 24 : 34
        playPauseButton.symbolPointSize = isCompact ? 30 : 42
        nextButton.symbolPointSize = isCompact ? 24 : 34

        lyricsButtonWidthConstraint?.constant = isCompact ? 44 : 56
        lyricsButtonHeightConstraint?.constant = isCompact ? 44 : 56
        routePickerWidthConstraint?.constant = isCompact ? 44 : 56
        routePickerHeightConstraint?.constant = isCompact ? 44 : 56
        queueButtonWidthConstraint?.constant = isCompact ? 44 : 56
        queueButtonHeightConstraint?.constant = isCompact ? 44 : 56
        updateFooterButtonAppearance()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "player.nowPlaying.scroll"

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.large
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        contentStackBottomConstraint = contentStack.bottomAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.bottomAnchor,
            constant: 0
        )
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // GeometryReader in the reference layout receives the sheet's
            // safe-area content region. Anchor the UIKit scroll view to the
            // same region so the 31pt grabber rhythm starts below the status
            // bar instead of pushing the artwork underneath it.
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 0
            ),
            contentStackBottomConstraint!,
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -(PlayerNowPlayingLayoutMetrics.horizontalInset * 2)
            ),
        ])
        contentStackBottomConstraint?.isActive = true
        contentStack.spacing = 0
        artworkTopSpacer.translatesAutoresizingMaskIntoConstraints = false
        artworkTopSpacer.backgroundColor = .clear
        // The system sheet owns the grabber. The original player reserves a
        // small, stable gap below that chrome before the active surface.
        artworkTopSpacerHeightConstraint = artworkTopSpacer.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.topChromeInset
        )
        artworkTopSpacerHeightConstraint?.isActive = true
        contentStack.addArrangedSubview(artworkTopSpacer)

        // In the regular-height layout the upper surface fills the viewport
        // above the pinned controls. Leaving this constraint inactive while
        // the surface is intrinsically taller preserves normal scrolling for
        // compact-height presentations.
        contentStackHeightConstraint = contentStack.heightAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.heightAnchor,
            constant: 0
        )
        contentStackHeightConstraint?.priority = .required
        contentStackHeightConstraint?.isActive = true
    }

    private func configureArtwork() {
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.backgroundColor = .clear
        artworkContainerHeightConstraint = artworkContainer.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.artworkMaximumDimension
                + PlayerNowPlayingLayoutMetrics.artworkTopInset
        )
        artworkContainerHeightConstraint?.isActive = true
        contentStack.addArrangedSubview(artworkContainer)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.accessibilityIdentifier = "player.nowPlaying.artwork"
        artworkView.placeholderSystemImage = "music.note"
        artworkView.backgroundColor = PlayerNowPlayingPalette.artworkPlaceholder
        artworkView.layer.shadowColor = UIColor.black.cgColor
        artworkView.layer.shadowOpacity = 0.35
        artworkView.layer.shadowRadius = 22
        artworkView.layer.shadowOffset = CGSize(width: 0, height: 12)
        artworkContainer.addSubview(artworkView)
        artworkDimensionConstraint = artworkView.widthAnchor.constraint(equalToConstant: 260)
        NSLayoutConstraint.activate([
            artworkDimensionConstraint!,
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            artworkView.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            artworkView.topAnchor.constraint(
                equalTo: artworkContainer.topAnchor,
                constant: PlayerNowPlayingLayoutMetrics.artworkTopInset
            ),
        ])

        artworkMetadataSpacer.translatesAutoresizingMaskIntoConstraints = false
        artworkMetadataSpacer.backgroundColor = .clear
        artworkMetadataSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        artworkMetadataSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(artworkMetadataSpacer)
    }

    private func configureMetadata() {
        titleLabel.font = MusicFreeUIFontTokens.preferred(.title2, weight: .bold)
        titleLabel.textColor = PlayerNowPlayingPalette.primary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "player.nowPlaying.current.title"

        artistLabel.font = MusicFreeUIFontTokens.preferred(.title3, weight: .regular)
        artistLabel.textColor = PlayerNowPlayingPalette.secondary
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail

        albumLabel.font = MusicFreeUIFontTokens.rowSubtitle
        albumLabel.textColor = PlayerNowPlayingPalette.tertiary
        albumLabel.numberOfLines = 1
        albumLabel.lineBreakMode = .byTruncatingTail

        metadataStack.axis = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = MusicFreeSpacingTokens.xSmall
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        metadataStack.addArrangedSubview(titleLabel)
        metadataStack.addArrangedSubview(artistLabel)
        // Album metadata is still available to the action menu and details
        // flow, but Apple Music keeps the artwork header to title + artist.

        configureHeaderButton(
            favoriteButton,
            systemImage: "star",
            accessibilityLabel: L("收藏"),
            action: #selector(toggleFavorite)
        )
        favoriteButton.accessibilityIdentifier = "player.nowPlaying.favorite"

        configureHeaderButton(
            moreButton,
            systemImage: "ellipsis",
            accessibilityLabel: L("更多操作"),
            action: nil
        )
        moreButton.accessibilityIdentifier = "player.nowPlaying.more"
        moreButton.showsMenuAsPrimaryAction = true

        let actions = UIStackView(arrangedSubviews: [favoriteButton, moreButton])
        actions.axis = .horizontal
        actions.spacing = MusicFreeSpacingTokens.xSmall
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        artworkMetadataHeader.axis = .horizontal
        artworkMetadataHeader.alignment = .center
        artworkMetadataHeader.spacing = MusicFreeSpacingTokens.medium
        artworkMetadataHeader.translatesAutoresizingMaskIntoConstraints = false
        artworkMetadataHeader.addArrangedSubview(metadataStack)
        artworkMetadataHeader.addArrangedSubview(actions)
        contentStack.addArrangedSubview(artworkMetadataHeader)
        // The action cluster owns its fixed hit targets. Let the metadata
        // column absorb the remaining width so long titles stay on one line
        // and truncate at the same point as the SwiftUI reference.
        metadataStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metadataStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // `artworkMetadata` in the reference ends 24pt above the pinned
        // progress controls. Keep this as a real arranged view instead of
        // relying on custom spacing after a hidden alternate surface; UIKit
        // otherwise drops that spacing when lyrics/queue are shown.
        artworkBottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        artworkBottomSpacer.backgroundColor = .clear
        artworkBottomSpacerHeightConstraint = artworkBottomSpacer.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.metadataBottomInset
        )
        artworkBottomSpacerHeightConstraint?.isActive = true
        contentStack.addArrangedSubview(artworkBottomSpacer)
    }

    private func configureLyricsSurface() {
        lyricsHeaderArtworkView.translatesAutoresizingMaskIntoConstraints = false
        lyricsHeaderArtworkView.cornerRadius = 8
        lyricsHeaderArtworkView.placeholderSystemImage = "music.note"
        lyricsHeaderArtworkView.backgroundColor = PlayerNowPlayingPalette.artworkPlaceholder
        lyricsHeaderArtworkView.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            lyricsHeaderArtworkView.widthAnchor.constraint(
                equalToConstant: PlayerNowPlayingLayoutMetrics.queueCurrentArtworkSize
            ),
            lyricsHeaderArtworkView.heightAnchor.constraint(
                equalToConstant: PlayerNowPlayingLayoutMetrics.queueCurrentArtworkSize
            ),
        ])

        lyricsHeaderTitleLabel.font = MusicFreeUIFontTokens.preferred(.title3, weight: .semibold)
        lyricsHeaderTitleLabel.textColor = PlayerNowPlayingPalette.primary
        lyricsHeaderTitleLabel.numberOfLines = 1
        lyricsHeaderTitleLabel.lineBreakMode = .byTruncatingTail
        // Keep the visible track title discoverable through the same stable
        // identifier on artwork, queue and lyrics surfaces. The lyrics header
        // is the current track, not a separate navigational title; using a
        // different identifier made repeated-presentation UI tests (and
        // VoiceOver clients) lose the current-title anchor when switching to
        // lyrics.
        lyricsHeaderTitleLabel.accessibilityIdentifier = "player.nowPlaying.current.title"

        lyricsHeaderArtistLabel.font = MusicFreeUIFontTokens.body
        lyricsHeaderArtistLabel.textColor = PlayerNowPlayingPalette.secondary
        lyricsHeaderArtistLabel.numberOfLines = 1
        lyricsHeaderArtistLabel.lineBreakMode = .byTruncatingTail

        lyricsHeaderMetadataStack.axis = .vertical
        lyricsHeaderMetadataStack.alignment = .leading
        lyricsHeaderMetadataStack.spacing = 3
        lyricsHeaderMetadataStack.translatesAutoresizingMaskIntoConstraints = false
        lyricsHeaderMetadataStack.addArrangedSubview(lyricsHeaderTitleLabel)
        lyricsHeaderMetadataStack.addArrangedSubview(lyricsHeaderArtistLabel)
        lyricsHeaderMetadataStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureHeaderButton(
            lyricsHeaderFavoriteButton,
            systemImage: "star",
            accessibilityLabel: L("收藏"),
            action: #selector(toggleFavorite)
        )
        lyricsHeaderFavoriteButton.accessibilityIdentifier = "player.nowPlaying.lyrics.favorite"
        configureHeaderButton(
            lyricsHeaderMoreButton,
            systemImage: "ellipsis",
            accessibilityLabel: L("更多操作"),
            action: nil
        )
        lyricsHeaderMoreButton.accessibilityIdentifier = "player.nowPlaying.lyrics.more"
        lyricsHeaderMoreButton.showsMenuAsPrimaryAction = true

        lyricsHeaderActions.axis = .horizontal
        lyricsHeaderActions.spacing = MusicFreeSpacingTokens.xSmall
        lyricsHeaderActions.setContentHuggingPriority(.required, for: .horizontal)
        lyricsHeaderActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        lyricsHeaderActions.translatesAutoresizingMaskIntoConstraints = false
        lyricsHeaderActions.addArrangedSubview(lyricsHeaderFavoriteButton)
        lyricsHeaderActions.addArrangedSubview(lyricsHeaderMoreButton)

        let header = UIStackView(arrangedSubviews: [
            lyricsHeaderArtworkView,
            lyricsHeaderMetadataStack,
            lyricsHeaderActions,
        ])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = MusicFreeSpacingTokens.medium
        header.translatesAutoresizingMaskIntoConstraints = false

        lyricsOffsetButton.translatesAutoresizingMaskIntoConstraints = false
        lyricsOffsetButton.tintColor = PlayerNowPlayingPalette.primary
        lyricsOffsetButton.backgroundColor = PlayerNowPlayingPalette.controlFillStrong
        lyricsOffsetButton.layer.cornerRadius = 28
        lyricsOffsetButton.setImage(UIImage(systemName: "quote.bubble"), for: .normal)
        lyricsOffsetButton.accessibilityLabel = L("歌词设置")
        lyricsOffsetButton.accessibilityIdentifier = "player.nowPlaying.lyrics.settings"
        lyricsOffsetButton.addTarget(self, action: #selector(showLyricsSettings), for: .touchUpInside)
        NSLayoutConstraint.activate([
            lyricsOffsetButton.widthAnchor.constraint(equalToConstant: 56),
            lyricsOffsetButton.heightAnchor.constraint(equalToConstant: 56),
        ])

        lyricsUnavailableButton.translatesAutoresizingMaskIntoConstraints = false
        lyricsUnavailableButton.tintColor = PlayerNowPlayingPalette.disabled
        lyricsUnavailableButton.backgroundColor = PlayerNowPlayingPalette.controlFillSubtle
        lyricsUnavailableButton.layer.cornerRadius = 28
        lyricsUnavailableButton.setImage(UIImage(systemName: "wand.and.stars"), for: .normal)
        lyricsUnavailableButton.accessibilityLabel = L("歌词增强不可用")
        lyricsUnavailableButton.accessibilityIdentifier = "player.nowPlaying.lyrics.enhance"
        lyricsUnavailableButton.isEnabled = false
        NSLayoutConstraint.activate([
            lyricsUnavailableButton.widthAnchor.constraint(equalToConstant: 56),
            lyricsUnavailableButton.heightAnchor.constraint(equalToConstant: 56),
        ])

        let actionBar = UIStackView(arrangedSubviews: [
            lyricsOffsetButton,
            UIView(),
            lyricsUnavailableButton,
        ])
        actionBar.axis = .horizontal
        actionBar.alignment = .center
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        lyricsSurface.axis = .vertical
        lyricsSurface.alignment = .fill
        lyricsSurface.spacing = 0
        lyricsSurface.translatesAutoresizingMaskIntoConstraints = false
        lyricsSurface.isHidden = true
        lyricsSurface.accessibilityIdentifier = "player.nowPlaying.lyrics"
        lyricsSurface.isAccessibilityElement = false
        lyricsSurface.addArrangedSubview(header)
        lyricsSurface.setCustomSpacing(10, after: header)
        lyricsSurface.addArrangedSubview(embeddedLyricsView)
        lyricsSurface.setCustomSpacing(4, after: embeddedLyricsView)
        lyricsSurface.addArrangedSubview(actionBar)
        lyricsSurfaceHeightConstraint = lyricsSurface.heightAnchor.constraint(equalToConstant: 464)
        lyricsEmbeddedHeightConstraint = embeddedLyricsView.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            lyricsSurfaceHeightConstraint!,
            lyricsEmbeddedHeightConstraint!,
            actionBar.heightAnchor.constraint(equalToConstant: 56),
        ])
        contentStack.addArrangedSubview(lyricsSurface)
    }

    private func configureQueueSurface() {
        queueSurface.translatesAutoresizingMaskIntoConstraints = false
        queueSurface.backgroundColor = .clear
        queueSurface.isHidden = true
        queueSurface.accessibilityIdentifier = "player.nowPlaying.queueLayout"
        queueSurface.isAccessibilityElement = false
        view.addSubview(queueSurface)

        queueListContainer.translatesAutoresizingMaskIntoConstraints = false
        queueListContainer.backgroundColor = .clear
        queueListContainer.accessibilityIdentifier = "player.continuePlaying.list"
        queueListContainer.isAccessibilityElement = false
        queueSurface.addSubview(queueListContainer)

        queueTableView.translatesAutoresizingMaskIntoConstraints = false
        queueTableView.backgroundColor = .clear
        queueTableView.separatorStyle = .none
        queueTableView.showsVerticalScrollIndicator = true
        queueTableView.indicatorStyle = .default
        queueTableView.alwaysBounceVertical = true
        queueTableView.contentInsetAdjustmentBehavior = .never
        queueTableView.contentInset = UIEdgeInsets(
            top: 8,
            left: 0,
            bottom: PlayerNowPlayingLayoutMetrics.queueBottomVisibleInset,
            right: 0
        )
        queueTableView.verticalScrollIndicatorInsets.bottom =
            PlayerNowPlayingLayoutMetrics.queueBottomVisibleInset
        queueTableView.rowHeight = UITableView.automaticDimension
        queueTableView.estimatedRowHeight = PlayerNowPlayingLayoutMetrics.queueContinueRowHeight
        queueTableView.sectionHeaderHeight = .leastNormalMagnitude
        queueTableView.sectionFooterHeight = .leastNormalMagnitude
        queueTableView.accessibilityIdentifier = "player.nowPlaying.upperScroll"
        queueTableView.dataSource = self
        queueTableView.delegate = self
        queueTableView.register(
            PlayerNowPlayingQueueRowCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueRowCell.historyReuseIdentifier
        )
        queueTableView.register(
            PlayerNowPlayingQueueRowCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueRowCell.currentReuseIdentifier
        )
        queueTableView.register(
            PlayerNowPlayingQueueRowCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueRowCell.upcomingReuseIdentifier
        )
        queueTableView.register(
            PlayerNowPlayingQueueHeaderCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueHeaderCell.reuseIdentifier
        )
        queueTableView.register(
            PlayerNowPlayingQueueMessageCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueMessageCell.reuseIdentifier
        )
        queueTableView.register(
            PlayerNowPlayingQueueModeCell.self,
            forCellReuseIdentifier: PlayerNowPlayingQueueModeCell.reuseIdentifier
        )
        // The current row intentionally rests below the grabber. Mask only
        // the small top gutter so history cells above the anchor do not leak
        // into the initial queue surface; pulling down reveals them normally.
        queueScrollMaskLayer.fillColor = UIColor.white.cgColor
        setQueueInitialAnchorMaskEnabled(true)
        queueListContainer.addSubview(queueTableView)

        NSLayoutConstraint.activate([
            queueSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            queueSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            queueSurface.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: PlayerNowPlayingLayoutMetrics.topChromeInset
            ),
            queueSurface.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor),
            queueListContainer.leadingAnchor.constraint(equalTo: queueSurface.leadingAnchor),
            queueListContainer.trailingAnchor.constraint(equalTo: queueSurface.trailingAnchor),
            queueListContainer.topAnchor.constraint(equalTo: queueSurface.topAnchor),
            queueListContainer.bottomAnchor.constraint(equalTo: queueSurface.bottomAnchor),
            queueTableView.leadingAnchor.constraint(equalTo: queueListContainer.leadingAnchor),
            queueTableView.trailingAnchor.constraint(equalTo: queueListContainer.trailingAnchor),
            queueTableView.topAnchor.constraint(equalTo: queueListContainer.topAnchor),
            queueTableView.bottomAnchor.constraint(equalTo: queueListContainer.bottomAnchor),
        ])

        configureQueueCurrentActionButton(
            queueCurrentFavoriteButton,
            systemImage: "star",
            accessibilityLabel: L("收藏"),
            action: #selector(toggleFavorite)
        )
        queueCurrentFavoriteButton.accessibilityIdentifier = "player.nowPlaying.current.favorite"
        configureQueueCurrentActionButton(
            queueCurrentMoreButton,
            systemImage: "ellipsis",
            accessibilityLabel: L("更多操作"),
            action: nil
        )
        queueCurrentMoreButton.accessibilityIdentifier = "player.nowPlaying.current.more"
        queueCurrentMoreButton.showsMenuAsPrimaryAction = true
        queueCurrentActions.axis = .horizontal
        queueCurrentActions.alignment = .center
        queueCurrentActions.spacing = 8
        queueCurrentActions.translatesAutoresizingMaskIntoConstraints = false
        queueCurrentActions.accessibilityIdentifier = "player.nowPlaying.current.actions"
        queueCurrentActions.addArrangedSubview(queueCurrentFavoriteButton)
        queueCurrentActions.addArrangedSubview(queueCurrentMoreButton)
    }

    private func configureHeaderButton(
        _ button: UIButton,
        systemImage: String,
        accessibilityLabel: String,
        action: Selector?
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = PlayerNowPlayingPalette.primary
        button.backgroundColor = .clear
        button.layer.cornerRadius = 20
        button.setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 20,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.accessibilityLabel = accessibilityLabel
        (button as? PlayerNowPlayingHeaderButton)?.visualBackgroundColor =
            PlayerNowPlayingPalette.controlFill
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func configureQueueCurrentActionButton(
        _ button: UIButton,
        systemImage: String,
        accessibilityLabel: String,
        action: Selector?
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = PlayerNowPlayingPalette.primary
        button.backgroundColor = .clear
        button.layer.cornerRadius = 20
        button.setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 20,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.accessibilityLabel = accessibilityLabel
        (button as? PlayerNowPlayingHeaderButton)?.visualBackgroundColor =
            PlayerNowPlayingPalette.controlFill
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    private func configureControlsContainer() {
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.backgroundColor = .clear
        controlsContainer.isAccessibilityElement = false

        controlsStack.axis = .vertical
        controlsStack.alignment = .fill
        controlsStack.spacing = 0
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(controlsContainer)
        controlsContainer.addSubview(controlsStack)

        // The footer is anchored independently below. The upper stack can
        // therefore keep the 52/88/44pt Apple Music controls while the
        // container itself is 308pt tall, matching the reference rhythm.
        controlsHeightConstraint = controlsContainer.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.regularControlsHeight
        )
        NSLayoutConstraint.activate([
            controlsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controlsHeightConstraint!,
            controlsStack.leadingAnchor.constraint(
                equalTo: controlsContainer.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            controlsStack.trailingAnchor.constraint(
                equalTo: controlsContainer.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
        ])
        controlsStackTopConstraint = controlsStack.topAnchor.constraint(
            equalTo: controlsContainer.topAnchor
        )
        controlsStackTopConstraint?.isActive = true

        // The scroll view stops at the controls' top edge. This is the key
        // difference from the old implementation, where the controls were
        // arranged after the artwork and disappeared below the viewport.
        scrollView.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor).isActive = true
    }

    private func configureProgress() {
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.minimumTrackTintColor = PlayerNowPlayingPalette.primary
        progressSlider.maximumTrackTintColor = PlayerNowPlayingPalette.trackInactive
        progressSlider.thumbTintColor = PlayerNowPlayingPalette.primary
        progressSlider.setMinimumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.primary),
            for: .normal
        )
        progressSlider.setMaximumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.trackInactive),
            for: .normal
        )
        progressSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.primary),
            for: .normal
        )
        progressSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.primary),
            for: .highlighted
        )
        progressSlider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        progressSlider.accessibilityLabel = L("播放进度")
        progressSlider.accessibilityIdentifier = "player.nowPlaying.progress"
        progressSlider.addTarget(self, action: #selector(progressTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(progressChanged), for: .valueChanged)
        for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
            progressSlider.addTarget(self, action: #selector(progressTouchEnded), for: event)
        }

        elapsedLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: MusicFreeUIFontTokens.caption.pointSize,
            weight: .regular
        )
        elapsedLabel.textColor = PlayerNowPlayingPalette.secondary
        remainingLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: MusicFreeUIFontTokens.caption.pointSize,
            weight: .regular
        )
        remainingLabel.textColor = PlayerNowPlayingPalette.secondary

        let timeStack = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeStack.axis = .horizontal
        timeStack.alignment = .center
        timeStack.translatesAutoresizingMaskIntoConstraints = false
        timeStack.heightAnchor.constraint(equalToConstant: 24).isActive = true

        pausedBadge.axis = .horizontal
        pausedBadge.alignment = .center
        pausedBadge.spacing = 4
        pausedBadge.isLayoutMarginsRelativeArrangement = true
        pausedBadge.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 3,
            leading: 8,
            bottom: 3,
            trailing: 8
        )
        pausedBadge.backgroundColor = PlayerNowPlayingPalette.controlFill
        pausedBadge.layer.cornerRadius = 10
        pausedBadge.clipsToBounds = true
        pausedBadgeIcon.image = UIImage(systemName: "speaker.slash.fill")
        pausedBadgeIcon.tintColor = PlayerNowPlayingPalette.secondary
        pausedBadgeIcon.setContentHuggingPriority(.required, for: .horizontal)
        pausedBadgeIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        pausedBadgeLabel.text = L("已暂停")
        pausedBadgeLabel.font = MusicFreeUIFontTokens.caption
        pausedBadgeLabel.textColor = PlayerNowPlayingPalette.secondary
        pausedBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        pausedBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pausedBadge.addArrangedSubview(pausedBadgeIcon)
        pausedBadge.addArrangedSubview(pausedBadgeLabel)
        pausedBadge.isHidden = true
        timeStack.insertArrangedSubview(pausedBadge, at: 2)
        timeStack.insertArrangedSubview(UIView(), at: 3)

        progressStack.axis = .vertical
        progressStack.spacing = MusicFreeSpacingTokens.xSmall
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        progressStack.addArrangedSubview(progressSlider)
        progressStack.addArrangedSubview(timeStack)
        progressStack.accessibilityIdentifier = "player.nowPlaying.progress.container"
        progressStackHeightConstraint = progressStack.heightAnchor.constraint(
            equalToConstant: 52
        )
        progressStackHeightConstraint?.isActive = true
        controlsStack.addArrangedSubview(progressStack)
        controlsStack.setCustomSpacing(26, after: progressStack)
    }

    private func configureTransport() {
        previousButton.onPrimaryAction = { [weak self] in self?.viewModel.previous() }
        previousButton.accessibilityIdentifier = "player.nowPlaying.previous"
        playPauseButton.onPrimaryAction = { [weak self] in self?.viewModel.togglePlayback() }
        playPauseButton.accessibilityIdentifier = "player.nowPlaying.playPause"
        nextButton.onPrimaryAction = { [weak self] in self?.viewModel.next() }
        nextButton.accessibilityIdentifier = "player.nowPlaying.next"

        transportStack.axis = .horizontal
        transportStack.alignment = .center
        transportStack.distribution = .equalCentering
        transportStack.spacing = MusicFreeSpacingTokens.medium
        transportStack.isLayoutMarginsRelativeArrangement = true
        transportStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: 36,
            bottom: 0,
            trailing: 36
        )
        transportStack.translatesAutoresizingMaskIntoConstraints = false
        transportStack.addArrangedSubview(previousButton)
        transportStack.addArrangedSubview(playPauseButton)
        transportStack.addArrangedSubview(nextButton)
        transportHeightConstraint = transportStack.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.regularTransportHeight
        )
        transportHeightConstraint?.isActive = true
        controlsStack.addArrangedSubview(transportStack)
        controlsStack.setCustomSpacing(28, after: transportStack)
    }

    private func configureVolume() {
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.tintColor = PlayerNowPlayingPalette.secondary
        muteButton.setImage(UIImage(systemName: "speaker.fill"), for: .normal)
        muteButton.accessibilityLabel = L("静音")
        muteButton.accessibilityIdentifier = "player.nowPlaying.mute"
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        NSLayoutConstraint.activate([
            muteButton.widthAnchor.constraint(equalToConstant: 44),
            muteButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.minimumTrackTintColor = PlayerNowPlayingPalette.secondary
        volumeSlider.maximumTrackTintColor = PlayerNowPlayingPalette.trackInactive
        volumeSlider.thumbTintColor = PlayerNowPlayingPalette.secondary
        volumeSlider.setMinimumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.secondary),
            for: .normal
        )
        volumeSlider.setMaximumTrackImage(
            sliderTrackImage(color: PlayerNowPlayingPalette.trackInactive),
            for: .normal
        )
        volumeSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.secondaryStrong),
            for: .normal
        )
        volumeSlider.setThumbImage(
            sliderThumbImage(diameter: 12, color: PlayerNowPlayingPalette.secondaryStrong),
            for: .highlighted
        )
        volumeSlider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        volumeSlider.accessibilityLabel = L("音量")
        volumeSlider.accessibilityIdentifier = "player.nowPlaying.volume"
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
            volumeSlider.addTarget(self, action: #selector(volumeTouchEnded), for: event)
        }

        volumeMaxImageView.image = UIImage(systemName: "speaker.wave.2.fill")
        volumeMaxImageView.tintColor = PlayerNowPlayingPalette.secondary
        volumeMaxImageView.contentMode = .center
        volumeMaxImageView.isAccessibilityElement = false
        volumeMaxImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            volumeMaxImageView.widthAnchor.constraint(equalToConstant: 44),
            volumeMaxImageView.heightAnchor.constraint(equalToConstant: 44),
        ])

        volumeStack.axis = .horizontal
        volumeStack.alignment = .center
        volumeStack.spacing = 10
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        volumeStack.addArrangedSubview(muteButton)
        volumeStack.addArrangedSubview(volumeSlider)
        volumeStack.addArrangedSubview(volumeMaxImageView)
        volumeStackHeightConstraint = volumeStack.heightAnchor.constraint(equalToConstant: 44)
        volumeStackHeightConstraint?.isActive = true
        controlsStack.addArrangedSubview(volumeStack)
        controlsStack.setCustomSpacing(18, after: volumeStack)
    }

    private func configureFooter() {
        configureFooterButton(
            lyricsButton,
            systemImage: "quote.bubble",
            title: L("歌词"),
            action: #selector(showLyrics)
        )
        lyricsButton.accessibilityIdentifier = "player.lyrics.footer"

        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.tintColor = PlayerNowPlayingPalette.secondary
        routePicker.activeTintColor = PlayerNowPlayingPalette.primary
        routePicker.prioritizesVideoDevices = false
        routePicker.backgroundColor = .clear
        routePicker.accessibilityLabel = L("AirPlay")
        routePicker.accessibilityIdentifier = "player.routePicker"
        routePickerWidthConstraint = routePicker.widthAnchor.constraint(equalToConstant: 56)
        routePickerHeightConstraint = routePicker.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([
            routePickerWidthConstraint!,
            routePickerHeightConstraint!,
        ])

        configureFooterButton(
            queueButton,
            systemImage: "list.bullet.fill",
            title: L("播放队列"),
            action: #selector(showQueue)
        )
        queueButton.accessibilityIdentifier = "player.queue.footer"

        footerStack.axis = .horizontal
        footerStack.alignment = .center
        footerStack.distribution = .equalSpacing
        footerStack.spacing = 60
        footerStack.isLayoutMarginsRelativeArrangement = true
        footerStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: 36,
            bottom: 0,
            trailing: 36
        )
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(lyricsButton)
        footerStack.addArrangedSubview(routePicker)
        footerStack.addArrangedSubview(queueButton)
        footerStackHeightConstraint = footerStack.heightAnchor.constraint(
            equalToConstant: PlayerNowPlayingLayoutMetrics.regularFooterHeight
        )
        footerStackHeightConstraint?.isActive = true
        // Footer controls stay pinned to the safe-area bottom instead of
        // participating in the upper stack's intrinsic-height arithmetic.
        // This is what keeps the progress and transport controls at the same
        // vertical positions as the Apple Music reference while the footer
        // remains fixed at the bottom edge.
        footerStack.removeFromSuperview()
        controlsContainer.addSubview(footerStack)
        NSLayoutConstraint.activate([
            footerStack.leadingAnchor.constraint(
                equalTo: controlsContainer.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            footerStack.trailingAnchor.constraint(
                equalTo: controlsContainer.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            footerStack.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor),
        ])
    }

    private func sliderThumbImage(diameter: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func sliderTrackImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 4, height: 4)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: 2
            ).fill()
        }
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2),
            resizingMode: .stretch
        ).withRenderingMode(.alwaysOriginal)
    }

    private func configureFooterButton(
        _ button: UIButton,
        systemImage: String,
        title: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        // Keep the footer's background entirely under our control. The
        // buttons are `.custom` so iOS 26 cannot inject an automatic glass
        // configuration behind the selected circle.
        button.configuration = nil
        button.tintColor = PlayerNowPlayingPalette.secondary
        if let glassSafeButton = button as? PlayerNowPlayingHeaderButton {
            // Keep the hit target at 56pt, but let the selected-state renderer
            // below decide when the reference circle is visible.
            glassSafeButton.visualDiameter = 0
            glassSafeButton.visualBackgroundColor = .clear
            glassSafeButton.backgroundColor = .clear
        }
        button.setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 20,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: 56)
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        if button === lyricsButton {
            lyricsButtonWidthConstraint = widthConstraint
            lyricsButtonHeightConstraint = heightConstraint
        } else if button === queueButton {
            queueButtonWidthConstraint = widthConstraint
            queueButtonHeightConstraint = heightConstraint
        }
    }

    private func configureStatus() {
        statusLabel.font = MusicFreeUIFontTokens.body
        statusLabel.textColor = PlayerNowPlayingPalette.secondaryStrong
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "player.nowPlaying.status"

        retryButton.setTitle(L("重试"), for: .normal)
        retryButton.setTitleColor(PlayerNowPlayingPalette.primary, for: .normal)
        retryButton.backgroundColor = PlayerNowPlayingPalette.controlFillStrong
        retryButton.layer.cornerRadius = 22
        retryButton.contentEdgeInsets = UIEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            left: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            right: MusicFreeSpacingTokens.large
        )
        retryButton.addTarget(self, action: #selector(retryPlayback), for: .touchUpInside)
        retryButton.isHidden = true

        let statusStack = UIStackView(arrangedSubviews: [statusLabel, retryButton])
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = MusicFreeSpacingTokens.medium
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: MusicFreeSpacingTokens.large
            ),
            statusStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -MusicFreeSpacingTokens.large
            ),
            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func configureFallbackCloseButton() {
        guard fallbackCloseHandler != nil, fallbackCloseButton.superview == nil else {
            return
        }

        fallbackCloseButton.translatesAutoresizingMaskIntoConstraints = false
        fallbackCloseButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        fallbackCloseButton.tintColor = PlayerNowPlayingPalette.primary
        fallbackCloseButton.backgroundColor = PlayerNowPlayingPalette.closeButtonFill
        fallbackCloseButton.layer.cornerRadius = 22
        fallbackCloseButton.accessibilityLabel = L("关闭播放器")
        fallbackCloseButton.accessibilityIdentifier = "player.nowPlaying.close"
        fallbackCloseButton.addTarget(
            self,
            action: #selector(closeFallbackPresentation),
            for: .touchUpInside
        )
        view.addSubview(fallbackCloseButton)
        NSLayoutConstraint.activate([
            fallbackCloseButton.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: MusicFreeSpacingTokens.medium
            ),
            fallbackCloseButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: MusicFreeSpacingTokens.xSmall
            ),
            fallbackCloseButton.widthAnchor.constraint(equalToConstant: 44),
            fallbackCloseButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func startObserving() {
        NotificationCenter.default.publisher(
            for: Notification.Name("MusicFreeUserInterfacePreferencesDidChange")
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.applyTheme()
        }
        .store(in: &stateCancellables)

        snapshotCancellable = viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
        favoriteCancellable = favoriteController.$isFavorite
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderFavoriteButton()
                self?.renderLyricsFavoriteButton()
                self?.renderQueueCurrentActions()
            }
        historyLoader.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.historyRowsDirty = true
                self?.renderQueueSurface()
            }
            .store(in: &stateCancellables)
        historyLoader.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.historyRowsDirty = true
                self?.renderQueueSurface()
            }
            .store(in: &stateCancellables)
        historyLoader.$artistNames
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.historyRowsDirty = true
                self?.renderQueueSurface()
            }
            .store(in: &stateCancellables)
        historyLoader.$isClearing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderQueueSurface() }
            .store(in: &stateCancellables)

        historyTask = Task { @MainActor [weak self] in
            await self?.historyLoader.load()
        }
        historyObservationTask = Task { @MainActor [weak self] in
            await self?.historyLoader.observeChanges()
        }
        viewModel.start()
    }

    private func render(_ snapshot: PlaybackSessionSnapshot) {
        let itemID = snapshot.currentItemID
        let retainsPreviousDisplay = snapshot.currentItem == nil
            && itemID != nil
            && snapshot.phase == .preparing
        let item = snapshot.currentItem
            ?? (retainsPreviousDisplay ? lastRenderedDisplay : nil)
        if let currentDisplay = snapshot.currentItem {
            lastRenderedDisplay = currentDisplay
        } else if itemID == nil {
            lastRenderedDisplay = nil
        }
        // Do not resolve the new queue track into the main metadata while its
        // display snapshot is still being prepared. Keeping the previous
        // track visible avoids a one-frame switch to empty/default labels.
        let track = retainsPreviousDisplay ? nil : itemID.flatMap { queueTracks[$0] }
        let hasPlaybackContent = viewModel.hasCurrentPlaybackContent
        isShowingStatus = !hasPlaybackContent || snapshot.phase == .failed
        scrollView.isHidden = isShowingStatus
        controlsContainer.isHidden = isShowingStatus
        statusLabel.isHidden = !isShowingStatus
        retryButton.isHidden = snapshot.phase != .failed

        if !hasPlaybackContent {
            statusLabel.text = L("当前没有播放内容")
        } else if snapshot.phase == .failed {
            statusLabel.text = L("播放操作无法完成，请稍后重试。")
        } else {
            statusLabel.text = nil
        }

        let title = track?.title ?? item?.title ?? L("正在播放")
        let artist = QueueArtistNameLoader.subtitle(
            for: track,
            artistNames: queueArtistNames
        ) ?? item?.artist
        let album = track.map {
            currentAlbumTitle(for: $0, snapshot: snapshot)
        } ?? item?.album
        titleLabel.text = title
        artistLabel.text = artist
        artistLabel.isHidden = artist?.isEmpty != false
        albumLabel.text = album
        albumLabel.isHidden = album?.isEmpty != false
        lyricsHeaderTitleLabel.text = title
        lyricsHeaderArtistLabel.text = artist
        lyricsHeaderArtistLabel.isHidden = artist?.isEmpty != false
        view.accessibilityValue = item?.title

        let hasStartedPlayback = viewModel.hasStartedPlayback
        let isPlaying = snapshot.phase == .playing
            || ((snapshot.phase == .preparing || snapshot.phase == .buffering)
                && hasStartedPlayback)
        playPauseButton.systemImageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.accessibilityLabel = isPlaying ? L("暂停") : L("播放")
        playPauseButton.isLoading = (snapshot.phase == .preparing
            || snapshot.phase == .buffering) && !hasStartedPlayback
        playPauseButton.isEnabled = hasPlaybackContent
        previousButton.isEnabled = viewModel.canGoPrevious
        nextButton.isEnabled = viewModel.canGoNext
        lyricsButton.isEnabled = hasPlaybackContent
        lyricsButton.accessibilityLabel = isShowingLyrics ? L("返回播放器") : L("歌词")
        lyricsButton.setImage(
            UIImage(systemName: isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"),
            for: .normal
        )
        queueButton.isEnabled = hasPlaybackContent
        queueButton.accessibilityLabel = isShowingQueue ? L("返回播放器") : L("播放队列")
        queueButton.setImage(
            UIImage(systemName: isShowingQueue ? "list.bullet.fill" : "list.bullet"),
            for: .normal
        )
        let currentTrackMenu = makeCurrentTrackMenu(itemID: itemID)
        moreButton.menu = currentTrackMenu
        lyricsHeaderMoreButton.menu = currentTrackMenu
        moreButton.isEnabled = currentTrackMenu != nil
        lyricsHeaderMoreButton.isEnabled = currentTrackMenu != nil

        embeddedLyricsView.update(query: makeLyricsQuery(snapshot), initialLyrics: nil)
        renderQueueSurface(snapshot)
        updateSurfaceVisibility()
        renderLyricsFavoriteButton()
        renderQueueCurrentActions()

        if !viewModel.isSeeking {
            let maximum = max(PlayerFormatting.seconds(snapshot.duration ?? .zero), 1)
            progressSlider.maximumValue = Float(maximum)
            progressSlider.value = min(
                max(Float(PlayerFormatting.seconds(viewModel.displayedPosition)), 0),
                Float(maximum)
            )
        }
        elapsedLabel.text = PlayerFormatting.duration(viewModel.displayedPosition)
        remainingLabel.text = PlayerFormatting.remaining(
            position: viewModel.displayedPosition,
            duration: snapshot.duration
        )
        pausedBadge.isHidden = snapshot.phase != .paused
        progressSlider.isEnabled = viewModel.canSeek
        progressSlider.accessibilityValue = "\(elapsedLabel.text ?? "") / \(remainingLabel.text ?? "")"

        volumeSlider.value = viewModel.displayedVolume
        muteButton.setImage(
            UIImage(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill"),
            for: .normal
        )
        muteButton.accessibilityLabel = viewModel.isMuted ? L("取消静音") : L("静音")
        volumeSlider.accessibilityValue = "\(Int((viewModel.displayedVolume * 100).rounded()))%"

        renderFavoriteButton()
        favoriteController.load(itemID: itemID)
        guard !retainsPreviousDisplay else { return }
        let artworkID = track?.artworkID ?? item?.artworkID
        let artworkKey = makeArtworkKey(artworkID: artworkID, itemID: itemID)
        if itemID != renderedItemID || artworkKey != renderedArtworkKey {
            renderedItemID = itemID
            renderedArtworkKey = artworkKey
            loadArtwork(for: artworkID, itemID: itemID)
        }
    }

    private func makeArtworkKey(
        artworkID: ArtworkID?,
        itemID: MediaItemID?
    ) -> String {
        "\(itemID?.sourceID.rawValue ?? ""):\(itemID?.externalID ?? ""):"
            + "\(artworkID?.rawValue ?? "")"
    }

    private func currentAlbumTitle(
        for track: Track?,
        snapshot: PlaybackSessionSnapshot
    ) -> String? {
        guard let track else {
            return snapshot.currentItem?.album
        }
        guard let albumID = track.albumID else {
            return nil
        }
        return queueAlbumNames[albumID] ?? snapshot.currentItem?.album
    }

    private func renderFavoriteButton() {
        let imageName = favoriteController.isFavorite ? "star.fill" : "star"
        favoriteButton.setImage(UIImage(systemName: imageName), for: .normal)
        favoriteButton.accessibilityLabel = favoriteController.isFavorite
            ? L("取消收藏")
            : L("收藏")
        favoriteButton.accessibilityTraits = favoriteController.isFavorite
            ? [.button, .selected]
            : [.button]
    }

    private func renderLyricsFavoriteButton() {
        let imageName = favoriteController.isFavorite ? "star.fill" : "star"
        lyricsHeaderFavoriteButton.setImage(UIImage(systemName: imageName), for: .normal)
        lyricsHeaderFavoriteButton.accessibilityLabel = favoriteController.isFavorite
            ? L("取消收藏")
            : L("收藏")
        lyricsHeaderFavoriteButton.accessibilityTraits = favoriteController.isFavorite
            ? [.button, .selected]
            : [.button]
    }

    private func updateSurfaceVisibility() {
        let showingAlternateSurface = isShowingLyrics || isShowingQueue
        // Artwork has the larger breathing room used by the reference player;
        // the compact lyrics header sits much closer to the grabber. Queue is
        // rendered by its own surface and does not consume this spacer.
        // Every Now Playing surface starts below the same system grabber
        // rhythm. Queue has its own scroll surface, but lyrics and artwork
        // share this arranged stack and must retain the 31pt top chrome gap.
        artworkTopSpacerHeightConstraint?.constant =
            PlayerNowPlayingLayoutMetrics.topChromeInset
        artworkTopSpacer.isHidden = false
        scrollView.isHidden = isShowingStatus || isShowingQueue
        queueSurface.isHidden = isShowingStatus || !isShowingQueue
        artworkContainer.isHidden = showingAlternateSurface
        artworkView.isHidden = false
        artworkMetadataSpacer.isHidden = showingAlternateSurface
        artworkMetadataHeader.isHidden = showingAlternateSurface
        artworkBottomSpacer.isHidden = showingAlternateSurface
        lyricsSurface.isHidden = !isShowingLyrics
        updateFooterButtonAppearance()
    }

    private func makeLyricsQuery(_ snapshot: PlaybackSessionSnapshot) -> LyricsQuery? {
        guard let itemID = snapshot.currentItemID,
              let item = snapshot.currentItem
                ?? (snapshot.phase == .preparing ? lastRenderedDisplay : nil) else {
            return nil
        }
        let track = snapshot.currentItem == nil ? nil : queueTracks[itemID]
        let title = track?.title ?? item.title
        let artist = QueueArtistNameLoader.subtitle(
            for: track,
            artistNames: queueArtistNames
        ) ?? item.artist
        let album = track.map {
            currentAlbumTitle(for: $0, snapshot: snapshot)
        } ?? item.album
        let durationSeconds: TimeInterval?
        if let duration = track?.duration ?? snapshot.duration ?? item.duration {
            let components = duration.components
            durationSeconds = Double(components.seconds)
                + Double(components.attoseconds) / 1000000000000000000
        } else {
            durationSeconds = nil
        }
        return LyricsQuery(
            itemID: itemID,
            title: title,
            artistName: artist,
            albumName: album,
            durationSeconds: durationSeconds
        )
    }

    /// Shows the lyrics inside the current Now Playing presentation. The
    /// queue sheet uses this after dismissing itself so the visual surface
    /// remains the same in both entry paths.
    public func showLyricsSurface() {
        guard viewModel.snapshot.currentItemID != nil else { return }
        isShowingLyrics = true
        isShowingQueue = false
        updateSurfaceVisibility()
        embeddedLyricsView.update(query: makeLyricsQuery(viewModel.snapshot))
    }

    private func loadArtwork(for artworkID: ArtworkID?, itemID: MediaItemID?) {
        artworkTask?.cancel()
        artworkTask = nil
        lyricsHeaderArtworkView.placeholderTitle = titleLabel.text

        guard let artworkID, let itemID, let artworkServing else {
            clearArtworkAndBackdrop()
            return
        }

        let cachedImage = PlayerArtworkImagePipeline.shared.cachedImage(
            artworkID: artworkID,
            sourceID: itemID.sourceID,
            maximumPixelDimension: 1_024
        )
        artworkView.image = cachedImage
        artworkView.isLoading = cachedImage == nil
        lyricsHeaderArtworkView.image = cachedImage
        lyricsHeaderArtworkView.isLoading = cachedImage == nil
        let artworkKey = makeArtworkKey(artworkID: artworkID, itemID: itemID)
        artworkTask = Task { @MainActor [weak self] in
            do {
                let image = await PlayerArtworkImagePipeline.shared.image(
                    artworkID: artworkID,
                    sourceID: itemID.sourceID,
                    maximumPixelDimension: 1024,
                    serving: artworkServing
                )
                try Task.checkCancellation()
                guard let self,
                      self.renderedItemID == itemID,
                      self.renderedArtworkKey == artworkKey
                else { return }
                let backdropImage = await Task.detached(priority: .userInitiated) {
                    image.flatMap(PlayerNowPlayingBackdropImageProcessor.process)
                }.value
                try Task.checkCancellation()
                guard self.renderedItemID == itemID,
                      self.renderedArtworkKey == artworkKey
                else { return }
                self.artworkView.image = image
                self.artworkView.isLoading = false
                self.lyricsHeaderArtworkView.image = image
                self.lyricsHeaderArtworkView.isLoading = false
                self.applyBackdropImage(backdropImage)
                self.artworkView.accessibilityValue = image == nil
                    ? "No artwork"
                    : "Artwork loaded"
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.renderedItemID == itemID,
                      self.renderedArtworkKey == artworkKey
                else { return }
                self.artworkView.image = nil
                self.artworkView.isLoading = false
                self.lyricsHeaderArtworkView.image = nil
                self.lyricsHeaderArtworkView.isLoading = false
                self.clearBackdrop()
                self.artworkView.accessibilityValue = "No artwork"
            }
        }
    }

    private func clearArtworkAndBackdrop() {
        artworkView.image = nil
        artworkView.isLoading = false
        lyricsHeaderArtworkView.image = nil
        lyricsHeaderArtworkView.isLoading = false
        clearBackdrop()
    }

    private func clearBackdrop() {
        backdropImageView.layer.removeAllAnimations()
        backdropImageView.image = nil
        backdropImageView.alpha = 0.92
        backdropImageView.isHidden = true
        backdropGradientLayer.isHidden = true
    }

    private func applyBackdropImage(_ image: UIImage?) {
        guard let image else {
            clearBackdrop()
            return
        }

        let hasExistingImage = !backdropImageView.isHidden
            && backdropImageView.image != nil
        backdropGradientLayer.isHidden = false
        backdropImageView.isHidden = false

        if hasExistingImage {
            UIView.transition(
                with: backdropImageView,
                duration: 0.24,
                options: [.transitionCrossDissolve, .beginFromCurrentState],
                animations: { [weak self] in
                    self?.backdropImageView.image = image
                }
            )
            return
        }

        backdropImageView.layer.removeAllAnimations()
        backdropImageView.image = image
        backdropImageView.alpha = 0
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) { [weak self] in
            self?.backdropImageView.alpha = 0.92
        }
    }

    @objc private func progressTouchDown() {
        viewModel.beginSeeking()
    }

    @objc private func progressChanged() {
        viewModel.updateSeeking(to: .seconds(Double(progressSlider.value)))
        elapsedLabel.text = PlayerFormatting.duration(viewModel.displayedPosition)
        remainingLabel.text = PlayerFormatting.remaining(
            position: viewModel.displayedPosition,
            duration: viewModel.snapshot.duration
        )
        progressSlider.accessibilityValue = "\(elapsedLabel.text ?? "") / \(remainingLabel.text ?? "")"
    }

    @objc private func progressTouchEnded() {
        viewModel.finishSeeking()
    }

    @objc private func volumeChanged() {
        viewModel.updateVolume(volumeSlider.value)
    }

    @objc private func volumeTouchEnded() {
        viewModel.finishVolumeChange()
    }

    @objc private func toggleMute() {
        viewModel.setMuted(!viewModel.isMuted)
    }

    @objc private func toggleFavorite() {
        favoriteController.toggle()
    }

    @objc private func showQueue() {
        guard viewModel.snapshot.currentItemID != nil else { return }
        isShowingQueue.toggle()
        if isShowingQueue {
            isShowingLyrics = false
            queueUserScrolled = false
            setQueueInitialAnchorMaskEnabled(true)
            renderQueueSurface(viewModel.snapshot)
            scheduleQueueAnchorIfNeeded()
        }
        updateSurfaceVisibility()
    }

    @objc func closeFallbackPresentation() {
        fallbackCloseHandler?()
    }

    @objc private func showLyrics() {
        guard viewModel.snapshot.currentItemID != nil else { return }
        isShowingLyrics.toggle()
        if isShowingLyrics {
            isShowingQueue = false
        }
        updateSurfaceVisibility()
        embeddedLyricsView.update(query: makeLyricsQuery(viewModel.snapshot))
        lyricsButton.accessibilityLabel = isShowingLyrics ? L("返回播放器") : L("歌词")
        lyricsButton.setImage(
            UIImage(systemName: isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"),
            for: .normal
        )
    }

    private func updateFooterButtonAppearance() {
        let selectedFill = PlayerNowPlayingPalette.selectedControlFill
        if let queueButton = queueButton as? PlayerNowPlayingHeaderButton {
            queueButton.backgroundColor = .clear
            queueButton.visualBackgroundColor = isShowingQueue ? selectedFill : .clear
            queueButton.visualDiameter = isShowingQueue ? 56 : 0
        } else {
            queueButton.backgroundColor = isShowingQueue ? selectedFill : .clear
            queueButton.layer.cornerRadius = isShowingQueue ? 28 : 0
            queueButton.clipsToBounds = isShowingQueue
        }
        queueButton.accessibilityTraits = isShowingQueue ? [.button, .selected] : [.button]

        if let lyricsButton = lyricsButton as? PlayerNowPlayingHeaderButton {
            lyricsButton.backgroundColor = .clear
            lyricsButton.visualBackgroundColor = isShowingLyrics ? selectedFill : .clear
            lyricsButton.visualDiameter = isShowingLyrics ? 56 : 0
        } else {
            lyricsButton.backgroundColor = isShowingLyrics ? selectedFill : .clear
            lyricsButton.layer.cornerRadius = isShowingLyrics ? 28 : 0
            lyricsButton.clipsToBounds = isShowingLyrics
        }
        lyricsButton.accessibilityTraits = isShowingLyrics ? [.button, .selected] : [.button]
    }

    private func renderQueueSurface() {
        renderQueueSurface(viewModel.snapshot)
    }

    private func renderQueueSurface(_ snapshot: PlaybackSessionSnapshot) {
        let structureKey = makeQueueStructureKey(snapshot)
        let historyStructureKey = makeHistoryStructureKey(snapshot)
        let continueStructureKey = makeContinueStructureKey(snapshot)
        if requestedQueueKey != structureKey {
            requestedQueueKey = structureKey
            loadQueueTracks(for: snapshot)
        }

        let currentItem = snapshot.currentItem
        let currentItemID = snapshot.currentItemID
        let currentTrack = currentItemID.flatMap { queueTracks[$0] }
        let currentTitle = currentTrack?.title ?? currentItem?.title
        let currentArtist = QueueArtistNameLoader.subtitle(
            for: currentTrack,
            artistNames: queueArtistNames
        ) ?? currentItem?.artist
        let currentArtworkID = currentTrack?.artworkID ?? currentItem?.artworkID
        let currentRowSignature = [
            currentItemID?.sourceID.rawValue ?? "",
            currentItemID?.externalID ?? "",
            currentTitle ?? L("正在播放"),
            currentArtist ?? "",
            currentArtworkID?.rawValue ?? "",
        ].joined(separator: "\u{001F}")
        let modeSignature = [
            snapshot.queue.shuffleMode.rawValue,
            snapshot.queue.repeatMode.rawValue,
            snapshot.capabilities.contains(.crossfade) ? "1" : "0",
            String(describing: snapshot.effectiveEffects.transition.mode),
        ].joined(separator: "\u{001F}")
        let needsReload = renderedHistoryStructureKey != historyStructureKey
            || renderedContinueStructureKey != continueStructureKey
            || renderedQueueCurrentRowSignature != currentRowSignature
            || renderedQueueModeSignature != modeSignature
            || historyRowsDirty
            || continueRowsDirty

        guard needsReload else { return }

        let historyItems = NowPlayingHistoryPresentation.nowPlayingItems(
            from: historyLoader.items,
            currentItemID: snapshot.currentItemID
        )
        let upcomingEntries = viewModel.upcomingQueueEntries().compactMap { entry in
            entry.itemID.map { (entry, $0) }
        }
        var items: [QueueListItem] = []
        if library != nil {
            items.append(.historyHeader)
            if historyItems.isEmpty {
                items.append(.historyMessage)
            } else {
                items.append(contentsOf: historyItems.map(QueueListItem.history))
            }
        }
        if currentItemID != nil {
            items.append(.current)
        }
        if !snapshot.queue.entries.isEmpty {
            items.append(.playbackMode)
            items.append(.continueHeader)
            if upcomingEntries.isEmpty {
                items.append(.upcomingMessage)
            } else {
                items.append(contentsOf: upcomingEntries.map { entry, itemID in
                    QueueListItem.upcoming(entry: entry, itemID: itemID)
                })
            }
        }

        queueListItems = items
        renderedHistoryStructureKey = historyStructureKey
        renderedContinueStructureKey = continueStructureKey
        renderedQueueCurrentRowSignature = currentRowSignature
        renderedQueueModeSignature = modeSignature
        historyRowsDirty = false
        continueRowsDirty = false
        queueTableView.reloadData()

        if isShowingQueue {
            scheduleQueueAnchorIfNeeded()
        }
    }

    private func makeQueueStructureKey(_ snapshot: PlaybackSessionSnapshot) -> String {
        let structure = snapshot.queue.structure
        let queueKey = structure.entries.map { entry in
            "\(entry.id.uuidString):\(entry.itemID?.sourceID.rawValue ?? ""):\(entry.itemID?.externalID ?? "")"
        }.joined(separator: ",")
        let shuffleOrderKey = structure.shuffleOrder
            .map(\.uuidString)
            .joined(separator: ",")
        return [
            structure.currentEntryID?.uuidString ?? "",
            structure.repeatMode.rawValue,
            structure.shuffleMode.rawValue,
            structure.shuffleSeed.map(String.init) ?? "",
            shuffleOrderKey,
            queueKey,
        ].joined(separator: "|")
    }

    private func makeHistoryStructureKey(_ snapshot: PlaybackSessionSnapshot) -> String {
        let visibleIDs = NowPlayingHistoryPresentation.nowPlayingItems(
            from: historyLoader.items,
            currentItemID: snapshot.currentItemID
        ).map(\.sessionID.uuidString)
        return [
            String(describing: historyLoader.state),
            visibleIDs.joined(separator: ","),
        ].joined(separator: "|")
    }

    private func makeContinueStructureKey(_ snapshot: PlaybackSessionSnapshot) -> String {
        let entries = viewModel.upcomingQueueEntries().map { entry in
            "\(entry.id.uuidString):\(entry.itemID?.sourceID.rawValue ?? ""):\(entry.itemID?.externalID ?? "")"
        }
        return entries.joined(separator: ",")
    }

    private func loadQueueTracks(for snapshot: PlaybackSessionSnapshot) {
        queueTracksTask?.cancel()
        guard let library else {
            queueTracks = [:]
            queueArtistNames = [:]
            queueAlbumNames = [:]
            return
        }

        var itemIDs: [MediaItemID] = []
        for itemID in snapshot.queue.entries.compactMap(\.itemID) {
            guard !itemIDs.contains(itemID) else { continue }
            itemIDs.append(itemID)
        }
        if let currentItemID = snapshot.currentItemID,
           !itemIDs.contains(currentItemID) {
            itemIDs.insert(currentItemID, at: 0)
        }
        queueTracksTask = Task { @MainActor [weak self] in
            var loaded: [MediaItemID: Track] = [:]
            for itemID in itemIDs {
                guard !Task.isCancelled else { return }
                if let track = try? await library.track(id: itemID) {
                    loaded[itemID] = track
                }
            }
            guard !Task.isCancelled, let self else { return }
            let names = (try? await QueueArtistNameLoader.load(
                for: Array(loaded.values),
                from: library
            )) ?? [:]
            guard !Task.isCancelled else { return }

            var albumNames: [AlbumID: String] = [:]
            let tracksBySource = Dictionary(grouping: loaded.values, by: { $0.id.sourceID })
            for (sourceID, tracks) in tracksBySource {
                guard !Task.isCancelled else { return }
                let albumIDs = Set(tracks.compactMap(\.albumID))
                do {
                    albumNames.merge(
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
                    // Album names are supplementary; keep the player usable.
                }
            }
            guard !Task.isCancelled else { return }

            self.queueTracks = loaded
            self.queueArtistNames = names
            self.queueAlbumNames = albumNames
            self.continueRowsDirty = true
            self.render(snapshot)
            self.renderQueueSurface(self.viewModel.snapshot)
            self.scheduleQueueAnchorIfNeeded()
        }
    }

    private func scheduleQueueAnchorIfNeeded() {
        guard isShowingQueue, !queueUserScrolled, !queueAnchorScheduled else { return }
        queueAnchorScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queueAnchorScheduled = false
            self.anchorQueueCurrentRowIfNeeded()
        }
    }

    private func anchorQueueCurrentRowIfNeeded() {
        guard isShowingQueue,
              !queueUserScrolled,
              let currentIndexPath = queueCurrentIndexPath
        else { return }
        view.layoutIfNeeded()
        queueTableView.layoutIfNeeded()
        updateQueueBottomInset()
        queueTableView.layoutIfNeeded()
        let rowRect = queueTableView.rectForRow(at: currentIndexPath)
        let minimumOffset = -queueTableView.contentInset.top
        let maximumOffset = max(
            minimumOffset,
            queueTableView.contentSize.height
                - queueTableView.bounds.height
                + queueTableView.contentInset.bottom
        )
        let offset = min(
            max(
                minimumOffset,
                rowRect.minY - PlayerNowPlayingLayoutMetrics.queueCurrentAnchorVisibleTopInset
            ),
            maximumOffset
        )
        guard abs(queueTableView.contentOffset.y - offset) > 0.5 else { return }
        queueTableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    private var queueCurrentIndexPath: IndexPath? {
        guard let row = queueListItems.firstIndex(where: { item in
            if case .current = item { return true }
            return false
        }) else { return nil }
        return IndexPath(row: row, section: 0)
    }

    private func updateQueueBottomInset() {
        guard isShowingQueue else { return }
        queueTableView.layoutIfNeeded()

        var requiredBottomInset = PlayerNowPlayingLayoutMetrics.queueBottomVisibleInset
        if let currentIndexPath = queueCurrentIndexPath {
            let currentRect = queueTableView.rectForRow(at: currentIndexPath)
            let contentAfterCurrent = max(
                0,
                queueTableView.contentSize.height - currentRect.maxY
            )
            requiredBottomInset = max(
                requiredBottomInset,
                queueTableView.bounds.height - contentAfterCurrent - 8
            )
        }
        guard abs(queueTableView.contentInset.bottom - requiredBottomInset) > 0.5 else {
            return
        }
        queueTableView.contentInset.bottom = requiredBottomInset
        queueTableView.verticalScrollIndicatorInsets.bottom = requiredBottomInset
    }

    private var historyMessage: String {
        switch historyLoader.state {
        case .idle, .loading:
            return L("正在载入播放历史")
        case .empty:
            return L("暂无播放历史")
        case .failed:
            return L("载入失败，点击重试")
        case .loaded:
            return L("当前歌曲尚未形成历史记录")
        }
    }

    private func renderQueueCurrentActions() {
        let imageName = favoriteController.isFavorite ? "star.fill" : "star"
        queueCurrentFavoriteButton.setImage(
            UIImage(systemName: imageName),
            for: .normal
        )
        queueCurrentFavoriteButton.accessibilityLabel = favoriteController.isFavorite
            ? L("取消收藏")
            : L("收藏")
        queueCurrentFavoriteButton.accessibilityTraits = favoriteController.isFavorite
            ? [.button, .selected]
            : [.button]
        let currentTrackMenu = makeCurrentTrackMenu(
            itemID: viewModel.snapshot.currentItemID
        )
        queueCurrentMoreButton.menu = currentTrackMenu
        queueCurrentMoreButton.isEnabled = currentTrackMenu != nil
    }

    @objc private func toggleQueueShuffle() {
        viewModel.setShuffle(
            viewModel.snapshot.queue.shuffleMode == .on ? .off : .on
        )
    }

    @objc private func toggleQueueRepeatOne() {
        viewModel.setRepeatMode(
            viewModel.snapshot.queue.repeatMode == .one ? .off : .one
        )
    }

    @objc private func toggleQueueRepeatAll() {
        viewModel.setRepeatMode(
            viewModel.snapshot.queue.repeatMode == .all ? .off : .all
        )
    }

    @objc private func clearHistory() {
        guard !historyLoader.items.isEmpty, !historyLoader.isClearing else { return }
        let alert = UIAlertController(
            title: L("清除播放历史？"),
            message: L("歌曲仍会保留在资料库中，累计播放统计不会重置。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("清除播放历史"), style: .destructive) { [weak self] _ in
            self?.historyTask?.cancel()
            self?.historyTask = Task { @MainActor [weak self] in
                await self?.historyLoader.clear()
            }
        })
        present(alert, animated: true)
    }

    private func makeQueueTrackMenu(
        title: String,
        subtitle: String?,
        track: Track? = nil,
        play: (() -> Void)? = nil,
        playNext: (() -> Void)? = nil,
        enqueue: (() -> Void)? = nil,
        destructiveAction: UIAction? = nil
    ) -> UIMenu {
        let shareText = [title, subtitle].compactMap { $0 }.joined(separator: " - ")
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            identifier: UIAction.Identifier("player.nowPlaying.actions.share")
        ) { [weak self] _ in
            let activity = UIActivityViewController(
                activityItems: [shareText],
                applicationActivities: nil
            )
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self?.view
                popover.sourceRect = CGRect(
                    x: self?.view.bounds.midX ?? 0,
                    y: self?.view.bounds.midY ?? 0,
                    width: 1,
                    height: 1
                )
            }
            self?.present(activity, animated: true)
        }
        var actions: [UIMenuElement] = []
        if let play {
            actions.append(UIAction(
                title: L("播放"),
                image: UIImage(systemName: "play.fill"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.play")
            ) { _ in play() })
        }
        if let playNext {
            actions.append(UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.playNext")
            ) { _ in playNext() })
        }
        if let enqueue {
            actions.append(UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.enqueue")
            ) { _ in enqueue() })
        }
        if let albumID = track?.albumID, let onShowAlbum {
            actions.append(UIAction(
                title: L("跳转到专辑"),
                image: UIImage(systemName: "rectangle.stack"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.album")
            ) { _ in onShowAlbum(albumID) })
        }
        if let artistID = track?.artistID, let onShowArtist {
            actions.append(UIAction(
                title: L("跳转到艺人"),
                image: UIImage(systemName: "person"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.artist")
            ) { _ in onShowArtist(artistID) })
        }

        var groups: [UIMenuElement] = [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [share]
            ),
        ]
        if !actions.isEmpty {
            groups.append(UIMenu(title: "", options: [.displayInline], children: actions))
        }
        if let destructiveAction {
            groups.append(UIMenu(
                title: "",
                options: [.displayInline],
                children: [destructiveAction]
            ))
        }
        return UIMenu(children: groups)
    }

    @objc private func showLyricsSettings() {
        let alert = UIAlertController(
            title: L("歌词设置"),
            message: L("当前偏移：由播放器同步。"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: L("重置歌词偏移"), style: .default) { [weak self] _ in
            self?.embeddedLyricsView.resetOffset()
        })
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = lyricsOffsetButton
            popover.sourceRect = lyricsOffsetButton.bounds
        }
        present(alert, animated: true)
    }

    @objc private func retryPlayback() {
        viewModel.play()
    }

    private func makeCurrentTrackMenu(itemID: MediaItemID?) -> UIMenu? {
        guard let itemID else { return nil }

        let favorite = UIAction(
            title: favoriteController.isFavorite ? L("取消收藏") : L("收藏"),
            image: UIImage(systemName: favoriteController.isFavorite ? "star.slash" : "star"),
            identifier: UIAction.Identifier("player.nowPlaying.actions.favorite"),
            state: favoriteController.isFavorite ? .on : .off
        ) { [weak self] _ in
            self?.favoriteController.toggle()
        }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            identifier: UIAction.Identifier("player.nowPlaying.actions.share")
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.shareCurrentTrack() }
        }

        var actions: [UIMenuElement] = [
            UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.playNext")
            ) { [weak self] _ in
                self?.viewModel.send(.enqueueNext(itemIDs: [itemID]))
            },
            UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.enqueue")
            ) { [weak self] _ in
                self?.viewModel.send(.enqueueItems(itemIDs: [itemID]))
            },
        ]
        if let onAddToPlaylist {
            actions.append(UIAction(
                title: L("添加到播放列表"),
                image: UIImage(systemName: "text.badge.plus"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.addToPlaylist")
            ) { _ in onAddToPlaylist(itemID) })
        }
        if onShowQueue != nil {
            actions.append(UIAction(
                title: L("管理播放队列"),
                image: UIImage(systemName: "list.bullet"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.manageQueue")
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.onShowQueue?() }
            })
        }
        if let onShowTrackDetails {
            actions.append(UIAction(
                title: L("查看歌曲详情"),
                image: UIImage(systemName: "info.circle"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.trackDetails")
            ) { _ in onShowTrackDetails(itemID) })
        }
        if let track = queueTracks[itemID] {
            if let albumID = track.albumID, let onShowAlbum {
                actions.append(UIAction(
                    title: L("跳转到专辑"),
                    image: UIImage(systemName: "rectangle.stack"),
                    identifier: UIAction.Identifier("player.nowPlaying.actions.album")
                ) { _ in onShowAlbum(albumID) })
            }
            if let artistID = track.artistID, let onShowArtist {
                actions.append(UIAction(
                    title: L("跳转到艺人"),
                    image: UIImage(systemName: "person"),
                    identifier: UIAction.Identifier("player.nowPlaying.actions.artist")
                ) { _ in onShowArtist(artistID) })
            }
        }

        var groups: [UIMenuElement] = [
            UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [favorite, share]
            ),
            UIMenu(title: "", options: [.displayInline], children: actions),
        ]
        if library != nil {
            let delete = UIAction(
                title: L("删除"),
                image: UIImage(systemName: "trash"),
                identifier: UIAction.Identifier("player.nowPlaying.actions.delete"),
                attributes: [.destructive]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.requestDeleteCurrentTrack(itemID: itemID)
                }
            }
            groups.append(UIMenu(
                title: "",
                options: [.displayInline],
                children: [delete]
            ))
        }
        return UIMenu(children: groups)
    }

    private func shareCurrentTrack() {
        let activity = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )
        if let popover = activity.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        present(activity, animated: true)
    }

    private func requestDeleteCurrentTrack(itemID: MediaItemID) {
        guard let library, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除歌曲？"),
            message: L("删除后将从资料库移除这首歌曲。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    _ = try await library.delete([itemID])
                } catch {
                    guard let self else { return }
                    let failure = UIAlertController(
                        title: L("无法删除歌曲"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    failure.addAction(UIAlertAction(title: L("好"), style: .default))
                    self.present(failure, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    private var shareText: String {
        let title = viewModel.currentTitle ?? L("正在播放")
        guard let artist = viewModel.currentArtist, !artist.isEmpty else { return title }
        return "\(title) - \(artist)"
    }
}

@MainActor
private final class PlayerNowPlayingQueueRowCell: UITableViewCell {
    static let historyReuseIdentifier = "PlayerNowPlayingQueueRowCell.history"
    static let currentReuseIdentifier = "PlayerNowPlayingQueueRowCell.current"
    static let upcomingReuseIdentifier = "PlayerNowPlayingQueueRowCell.upcoming"

    let rowView: PlayerNowPlayingQueueRowView

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        let artworkSize: CGFloat
        let rowHeight: CGFloat
        switch reuseIdentifier {
        case Self.currentReuseIdentifier:
            artworkSize = PlayerNowPlayingLayoutMetrics.queueCurrentArtworkSize
            rowHeight = PlayerNowPlayingLayoutMetrics.queueCurrentRowHeight
        case Self.historyReuseIdentifier:
            artworkSize = PlayerNowPlayingLayoutMetrics.queueHistoryArtworkSize
            rowHeight = PlayerNowPlayingLayoutMetrics.queueHistoryRowHeight
        default:
            artworkSize = PlayerNowPlayingLayoutMetrics.queueContinueArtworkSize
            rowHeight = PlayerNowPlayingLayoutMetrics.queueContinueRowHeight
        }
        rowView = PlayerNowPlayingQueueRowView(
            artworkSize: artworkSize,
            rowHeight: rowHeight,
            showsSeparator: false
        )
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false
        rowView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            rowView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            rowView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowView.prepareForReuse()
    }
}

@MainActor
private final class PlayerNowPlayingQueueHeaderCell: UITableViewCell {
    static let reuseIdentifier = "PlayerNowPlayingQueueHeaderCell"

    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private var onAction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false

        titleLabel.font = MusicFreeUIFontTokens.preferred(.title2, weight: .bold)
        titleLabel.textColor = PlayerNowPlayingPalette.primary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header

        actionButton.titleLabel?.font = MusicFreeUIFontTokens.preferred(.body, weight: .regular)
        actionButton.setTitleColor(PlayerNowPlayingPalette.secondary, for: .normal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addTarget(self, action: #selector(performAction), for: .touchUpInside)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = MusicFreeSpacingTokens.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(UIView())
        contentStack.addArrangedSubview(actionButton)
        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.heightAnchor.constraint(equalToConstant: 44),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        titleLabel.accessibilityIdentifier = nil
        titleLabel.accessibilityValue = nil
        actionButton.accessibilityIdentifier = nil
    }

    func configure(
        title: String,
        titleAccessibilityIdentifier: String?,
        titleAccessibilityValue: String? = nil,
        actionTitle: String? = nil,
        actionAccessibilityIdentifier: String? = nil,
        actionEnabled: Bool = true,
        onAction: (() -> Void)? = nil
    ) {
        titleLabel.text = title
        titleLabel.textColor = PlayerNowPlayingPalette.primary
        titleLabel.accessibilityIdentifier = titleAccessibilityIdentifier
        titleLabel.accessibilityValue = titleAccessibilityValue
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.setTitleColor(PlayerNowPlayingPalette.secondary, for: .normal)
        actionButton.accessibilityIdentifier = actionAccessibilityIdentifier
        actionButton.isHidden = actionTitle == nil
        actionButton.isEnabled = actionEnabled
        actionButton.alpha = actionEnabled ? 1 : 0.42
        self.onAction = onAction
    }

    @objc private func performAction() {
        onAction?()
    }
}

@MainActor
private final class PlayerNowPlayingQueueMessageCell: UITableViewCell {
    static let reuseIdentifier = "PlayerNowPlayingQueueMessageCell"

    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = MusicFreeUIFontTokens.rowSubtitle
        messageLabel.textColor = PlayerNowPlayingPalette.secondary
        messageLabel.numberOfLines = 2
        messageLabel.textAlignment = .left
        contentView.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            messageLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            messageLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            messageLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        messageLabel.text = text
        messageLabel.textColor = PlayerNowPlayingPalette.secondary
    }
}

@MainActor
private final class PlayerNowPlayingQueueModeCell: UITableViewCell {
    static let reuseIdentifier = "PlayerNowPlayingQueueModeCell"

    private let shuffleButton = UIButton(type: .system)
    private let repeatOneButton = UIButton(type: .system)
    private let repeatAllButton = UIButton(type: .system)
    private let crossfadeButton = UIButton(type: .system)
    private let buttonStack = UIStackView()
    private var onShuffle: (() -> Void)?
    private var onRepeatOne: (() -> Void)?
    private var onRepeatAll: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false

        configureButton(
            shuffleButton,
            systemImage: "shuffle",
            action: #selector(toggleShuffle)
        )
        configureButton(
            repeatOneButton,
            systemImage: "repeat.1",
            action: #selector(toggleRepeatOne)
        )
        configureButton(
            repeatAllButton,
            systemImage: "infinity",
            action: #selector(toggleRepeatAll)
        )
        configureButton(
            crossfadeButton,
            systemImage: "waveform.path.ecg",
            action: nil
        )

        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.accessibilityIdentifier = "player.nowPlaying.modeControls"
        buttonStack.accessibilityLabel = L("播放模式")
        buttonStack.isAccessibilityElement = false
        buttonStack.addArrangedSubview(shuffleButton)
        buttonStack.addArrangedSubview(repeatOneButton)
        buttonStack.addArrangedSubview(repeatAllButton)
        buttonStack.addArrangedSubview(crossfadeButton)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            buttonStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PlayerNowPlayingLayoutMetrics.horizontalInset
            ),
            buttonStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            buttonStack.heightAnchor.constraint(
                equalToConstant: PlayerNowPlayingLayoutMetrics.queueModeHeight
            ),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        shuffleSelected: Bool,
        repeatOneSelected: Bool,
        repeatAllSelected: Bool,
        crossfadeSelected: Bool,
        crossfadeEnabled: Bool,
        onShuffle: @escaping () -> Void,
        onRepeatOne: @escaping () -> Void,
        onRepeatAll: @escaping () -> Void
    ) {
        self.onShuffle = onShuffle
        self.onRepeatOne = onRepeatOne
        self.onRepeatAll = onRepeatAll
        configureState(
            shuffleButton,
            isSelected: shuffleSelected,
            isEnabled: true,
            title: L("随机播放")
        )
        configureState(
            repeatOneButton,
            isSelected: repeatOneSelected,
            isEnabled: true,
            title: L("重复单曲")
        )
        configureState(
            repeatAllButton,
            isSelected: repeatAllSelected,
            isEnabled: true,
            title: L("重复队列")
        )
        configureState(
            crossfadeButton,
            isSelected: crossfadeSelected,
            isEnabled: crossfadeEnabled,
            title: L("淡入淡出")
        )
    }

    private func configureButton(
        _ button: UIButton,
        systemImage: String,
        action: Selector?
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = PlayerNowPlayingPalette.primary
        button.backgroundColor = PlayerNowPlayingPalette.controlFill
        button.layer.cornerRadius = 20
        button.clipsToBounds = true
        button.setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 20,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.accessibilityTraits = [.button]
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    private func configureState(
        _ button: UIButton,
        isSelected: Bool,
        isEnabled: Bool,
        title: String
    ) {
        button.tintColor = PlayerNowPlayingPalette.primary
        button.backgroundColor = isSelected
            ? PlayerNowPlayingPalette.selectedControlFill
            : PlayerNowPlayingPalette.controlFill
        button.alpha = isEnabled ? 1 : 0.36
        button.isEnabled = isEnabled
        button.accessibilityLabel = title
        button.accessibilityValue = isEnabled
            ? (isSelected ? L("已开启") : L("已关闭"))
            : L("不可用")
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    @objc private func toggleShuffle() {
        onShuffle?()
    }

    @objc private func toggleRepeatOne() {
        onRepeatOne?()
    }

    @objc private func toggleRepeatAll() {
        onRepeatAll?()
    }
}

@MainActor
private final class PlayerNowPlayingQueueRowView: UIControl {
    var onActivate: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?
    var titleAccessibilityIdentifier: String? {
        didSet { titleLabel.accessibilityIdentifier = titleAccessibilityIdentifier }
    }

    var accessoryView: UIView? {
        didSet { updateAccessoryView() }
    }

    private let artworkView: MusicFreeUIKitArtworkView
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let accessoryContainer = UIView()
    private let contentStack = UIStackView()
    private let actionImageView = UIImageView()
    private var accessoryWidthConstraint: NSLayoutConstraint!
    private var rowHeightConstraint: NSLayoutConstraint!
    private var artworkTask: Task<Void, Never>?
    private var renderedArtworkKey: String?
    private let artworkMaximumPixelDimension: Int

    init(artworkSize: CGFloat, rowHeight: CGFloat, showsSeparator _: Bool) {
        artworkView = MusicFreeUIKitArtworkView(
            accessibilityLabel: L("封面"),
            fillsAvailableWidth: true,
            cornerRadius: rowHeight >= 96 ? 12 : (rowHeight >= 72 ? 8 : 6)
        )
        artworkMaximumPixelDimension = artworkSize >= 64 ? 256 : 160
        super.init(frame: .zero)

        accessoryWidthConstraint = accessoryContainer.widthAnchor.constraint(equalToConstant: 32)
        rowHeightConstraint = heightAnchor.constraint(equalToConstant: rowHeight)
        rowHeightConstraint.priority = .required
        commonInit(artworkSize: artworkSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        artworkTask?.cancel()
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.72 : 1 }
    }

    func configure(
        title: String,
        subtitle: String?,
        artworkID: ArtworkID?,
        itemID: MediaItemID?,
        artworkServing: (any ArtworkServing)?,
        actionImage: String?,
        actionTint: UIColor,
        titleFont: UIFont,
        subtitleFont: UIFont,
        titleAccessibilityIdentifier: String?
    ) {
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        titleLabel.text = title
        titleLabel.font = titleFont
        subtitleLabel.font = subtitleFont
        // Keep a stable two-line row rhythm when metadata is incomplete. A
        // hidden subtitle collapses the stack, which vertically centers a
        // lone title too low in a partially visible row near the fixed
        // playback controls.
        let hasSubtitle = subtitle?.isEmpty == false
        subtitleLabel.text = hasSubtitle ? subtitle : " "
        subtitleLabel.isHidden = false
        subtitleLabel.alpha = hasSubtitle ? 1 : 0
        actionImageView.image = actionImage.flatMap { UIImage(systemName: $0) }
        actionImageView.tintColor = actionTint
        artworkView.placeholderTitle = title
        artworkView.accessibilityLabel = artworkID == nil ? L("暂无封面") : L("封面")
        updateAccessoryView()
        loadArtwork(artworkID: artworkID, itemID: itemID, serving: artworkServing)
        updateAccessibility(title: title, subtitle: subtitle)
    }

    func prepareForReuse() {
        artworkTask?.cancel()
        artworkTask = nil
        renderedArtworkKey = nil
        artworkView.image = nil
        artworkView.isLoading = false
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.alpha = 1
        actionImageView.image = nil
        accessoryView = nil
        onActivate = nil
        menuProvider = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityValue = nil
        accessibilityTraits = []
        isAccessibilityElement = false
    }

    private func commonInit(artworkSize: CGFloat) {
        backgroundColor = .clear
        isAccessibilityElement = false
        isUserInteractionEnabled = true
        addTarget(self, action: #selector(handleActivation), for: .touchUpInside)
        addTarget(self, action: #selector(handleActivation), for: .primaryActionTriggered)
        addInteraction(UIContextMenuInteraction(delegate: self))

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.placeholderSystemImage = "music.note"
        artworkView.isAccessibilityElement = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = PlayerNowPlayingPalette.primary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isAccessibilityElement = true

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.textColor = PlayerNowPlayingPalette.secondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isAccessibilityElement = true

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        actionImageView.translatesAutoresizingMaskIntoConstraints = false
        actionImageView.contentMode = .center
        actionImageView.isAccessibilityElement = false

        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(actionImageView)
        NSLayoutConstraint.activate([
            actionImageView.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            actionImageView.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            actionImageView.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            actionImageView.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
            accessoryWidthConstraint,
        ])

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(artworkView)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(accessoryContainer)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            rowHeightConstraint,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: artworkSize),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateAccessoryView() {
        accessoryContainer.subviews
            .filter { $0 !== actionImageView }
            .forEach { $0.removeFromSuperview() }
        guard let accessoryView else {
            let hasActionImage = actionImageView.image != nil
            actionImageView.isHidden = !hasActionImage
            accessoryWidthConstraint.constant = hasActionImage
                ? PlayerNowPlayingLayoutMetrics.queueRowActionWidth
                : 0
            contentStack.setCustomSpacing(hasActionImage ? 12 : 0, after: textStack)
            return
        }
        actionImageView.isHidden = true
        accessoryWidthConstraint.constant = 88
        contentStack.setCustomSpacing(12, after: textStack)
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(accessoryView)
        NSLayoutConstraint.activate([
            accessoryView.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            accessoryView.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            accessoryView.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
        ])
    }

    private func updateAccessibility(title: String, subtitle: String?) {
        titleLabel.accessibilityLabel = title
        subtitleLabel.isAccessibilityElement = subtitle?.isEmpty == false
        subtitleLabel.accessibilityLabel = subtitle
    }

    @objc private func handleActivation() {
        onActivate?()
    }

    private func loadArtwork(
        artworkID: ArtworkID?,
        itemID: MediaItemID?,
        serving: (any ArtworkServing)?
    ) {
        let artworkKey = "\(itemID?.sourceID.rawValue ?? ""):"
            + "\(itemID?.externalID ?? ""):"
            + "\(artworkID?.rawValue ?? "")"
        guard renderedArtworkKey != artworkKey else { return }
        renderedArtworkKey = artworkKey
        artworkTask?.cancel()
        artworkTask = nil
        guard let artworkID, let sourceID = itemID?.sourceID, let serving else {
            artworkView.image = nil
            artworkView.isLoading = false
            return
        }
        let cachedImage = PlayerArtworkImagePipeline.shared.cachedImage(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: artworkMaximumPixelDimension
        )
        artworkView.image = cachedImage
        artworkView.isLoading = cachedImage == nil
        artworkTask = Task { @MainActor [weak self] in
            do {
                let image = await PlayerArtworkImagePipeline.shared.image(
                    artworkID: artworkID,
                    sourceID: sourceID,
                    maximumPixelDimension: self?.artworkMaximumPixelDimension ?? 160,
                    serving: serving
                )
                try Task.checkCancellation()
                guard let self, self.renderedArtworkKey == artworkKey else { return }
                self.artworkView.image = image
                self.artworkView.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.renderedArtworkKey == artworkKey else { return }
                self.artworkView.isLoading = false
            }
        }
    }

    override func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        let configuration = UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { _ in menu }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
}

extension PlayerNowPlayingViewController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in _: UITableView) -> Int {
        1
    }

    public func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        queueListItems.count
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard queueListItems.indices.contains(indexPath.row) else {
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }

        switch queueListItems[indexPath.row] {
        case .historyHeader:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueHeaderCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueHeaderCell
            let visibleCount = NowPlayingHistoryPresentation.nowPlayingItems(
                from: historyLoader.items,
                currentItemID: viewModel.snapshot.currentItemID
            ).count
            cell.configure(
                title: L("历史"),
                titleAccessibilityIdentifier: "player.nowPlaying.history.heading",
                titleAccessibilityValue: String(visibleCount),
                actionTitle: L("清除"),
                actionAccessibilityIdentifier: "player.nowPlaying.history.clear",
                actionEnabled: !historyLoader.items.isEmpty && !historyLoader.isClearing,
                onAction: { [weak self] in self?.clearHistory() }
            )
            return cell

        case let .history(item):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueRowCell.historyReuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueRowCell
            let subtitle = QueueArtistNameLoader.subtitle(
                for: item.track,
                artistNames: historyLoader.artistNames
            )
            let row = cell.rowView
            row.accessibilityIdentifier = "player.nowPlaying.history.\(item.sessionID.uuidString)"
            row.accessibilityHint = L("重新播放歌曲")
            row.accessibilityLabel = [item.track.title, subtitle]
                .compactMap { $0 }
                .joined(separator: ", ")
            row.accessibilityTraits = [.button]
            row.isAccessibilityElement = true
            row.onActivate = { [weak self] in
                self?.viewModel.send(.play(itemID: item.track.id))
            }
            row.menuProvider = { [weak self] in
                self?.makeQueueTrackMenu(
                    title: item.track.title,
                    subtitle: QueueArtistNameLoader.subtitle(
                        for: item.track,
                        artistNames: self?.historyLoader.artistNames ?? [:]
                    ),
                    track: item.track,
                    play: { [weak self] in
                        self?.viewModel.send(.play(itemID: item.track.id))
                    },
                    playNext: { [weak self] in
                        self?.viewModel.send(.enqueueNext(itemIDs: [item.track.id]))
                    },
                    enqueue: { [weak self] in
                        self?.viewModel.send(.enqueueItems(itemIDs: [item.track.id]))
                    }
                )
            }
            row.configure(
                title: item.track.title,
                subtitle: subtitle,
                artworkID: item.track.artworkID,
                itemID: item.track.id,
                artworkServing: artworkServing,
                actionImage: nil,
                actionTint: PlayerNowPlayingPalette.rowAccessory,
                titleFont: MusicFreeUIFontTokens.preferred(.body, weight: .medium),
                subtitleFont: MusicFreeUIFontTokens.rowSubtitle,
                titleAccessibilityIdentifier: nil
            )
            return cell

        case .historyMessage:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueMessageCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueMessageCell
            cell.configure(text: historyMessage)
            return cell

        case .current:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueRowCell.currentReuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueRowCell
            let snapshot = viewModel.snapshot
            let itemID = snapshot.currentItemID
            let track = itemID.flatMap { queueTracks[$0] }
            let title = track?.title ?? snapshot.currentItem?.title ?? L("正在播放")
            let artist = QueueArtistNameLoader.subtitle(
                for: track,
                artistNames: queueArtistNames
            ) ?? snapshot.currentItem?.artist
            let row = cell.rowView
            row.accessibilityIdentifier = "player.nowPlaying.current"
            row.accessibilityValue = snapshot.currentItem?.title
            row.onActivate = { [weak self] in self?.viewModel.play() }
            row.menuProvider = { [weak self] in
                guard let self else { return nil }
                return self.makeCurrentTrackMenu(itemID: self.viewModel.snapshot.currentItemID)
            }
            row.accessoryView = queueCurrentActions
            row.configure(
                title: title,
                subtitle: artist,
                artworkID: track?.artworkID ?? snapshot.currentItem?.artworkID,
                itemID: itemID,
                artworkServing: artworkServing,
                actionImage: "speaker.wave.2.fill",
                actionTint: MusicFreeUIColorTokens.accent,
                titleFont: MusicFreeUIFontTokens.preferred(.title3, weight: .semibold),
                subtitleFont: MusicFreeUIFontTokens.preferred(.body, weight: .regular),
                titleAccessibilityIdentifier: "player.nowPlaying.current.title"
            )
            return cell

        case .playbackMode:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueModeCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueModeCell
            let snapshot = viewModel.snapshot
            cell.configure(
                shuffleSelected: snapshot.queue.shuffleMode == .on,
                repeatOneSelected: snapshot.queue.repeatMode == .one,
                repeatAllSelected: snapshot.queue.repeatMode == .all,
                crossfadeSelected: snapshot.effectiveEffects.transition.mode == .crossfade,
                crossfadeEnabled: snapshot.capabilities.contains(.crossfade),
                onShuffle: { [weak self] in self?.toggleQueueShuffle() },
                onRepeatOne: { [weak self] in self?.toggleQueueRepeatOne() },
                onRepeatAll: { [weak self] in self?.toggleQueueRepeatAll() }
            )
            return cell

        case .continueHeader:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueHeaderCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueHeaderCell
            cell.configure(
                title: L("继续播放"),
                titleAccessibilityIdentifier: "player.nowPlaying.upcoming.heading"
            )
            return cell

        case let .upcoming(entry, itemID):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueRowCell.upcomingReuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueRowCell
            let track = queueTracks[itemID]
            let title = track?.title ?? itemID.externalID
            let subtitle = QueueArtistNameLoader.subtitle(
                for: track,
                artistNames: queueArtistNames
            )
            let row = cell.rowView
            row.accessibilityIdentifier = "player.continuePlaying.\(entry.id.uuidString)"
            row.accessibilityHint = L("播放歌曲")
            row.onActivate = { [weak self] in
                self?.viewModel.send(.play(itemID: itemID))
            }
            row.menuProvider = { [weak self] in
                self?.makeQueueTrackMenu(
                    title: title,
                    subtitle: subtitle,
                    track: track,
                    play: { [weak self] in
                        self?.viewModel.send(.play(itemID: itemID))
                    },
                    destructiveAction: UIAction(
                        title: L("从队列移除"),
                        image: UIImage(systemName: "trash"),
                        identifier: UIAction.Identifier("player.nowPlaying.actions.removeFromQueue"),
                        attributes: [.destructive]
                    ) { [weak self] _ in
                        self?.viewModel.removeQueueEntry(entry.id)
                    }
                )
            }
            row.configure(
                title: title,
                subtitle: subtitle,
                artworkID: track?.artworkID,
                itemID: itemID,
                artworkServing: artworkServing,
                actionImage: "line.3.horizontal",
                actionTint: PlayerNowPlayingPalette.rowAccessory,
                titleFont: MusicFreeUIFontTokens.rowTitle,
                subtitleFont: MusicFreeUIFontTokens.rowSubtitle,
                titleAccessibilityIdentifier: nil
            )
            return cell

        case .upcomingMessage:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: PlayerNowPlayingQueueMessageCell.reuseIdentifier,
                for: indexPath
            ) as! PlayerNowPlayingQueueMessageCell
            cell.configure(text: L("队列末尾"))
            return cell
        }
    }

    public func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard queueListItems.indices.contains(indexPath.row) else { return 0 }
        switch queueListItems[indexPath.row] {
        case .historyHeader:
            return 68
        case .history, .historyMessage:
            return PlayerNowPlayingLayoutMetrics.queueHistoryRowHeight
        case .current:
            return PlayerNowPlayingLayoutMetrics.queueCurrentRowHeight + 10
        case .playbackMode:
            return PlayerNowPlayingLayoutMetrics.queueModeHeight + 16
        case .continueHeader:
            return 44
        case .upcoming, .upcomingMessage:
            return PlayerNowPlayingLayoutMetrics.queueContinueRowHeight
        }
    }

    public func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard queueListItems.indices.contains(indexPath.row),
              case .historyMessage = queueListItems[indexPath.row],
              historyLoader.state == .failed
        else { return }
        historyTask?.cancel()
        historyTask = Task { @MainActor [weak self] in
            await self?.historyLoader.load()
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === queueTableView else { return }
        // Programmatic anchoring happens before the user takes ownership of
        // the table. Keep the temporary mask aligned until dragging begins.
        updateQueueScrollMask()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === queueTableView {
            queueScrollStartOffsetY = scrollView.contentOffset.y
            queueUserScrolled = true
            // The mask exists only to hide the history row that precedes the
            // initial current-item anchor. Once the user scrolls, UITableView
            // must clip against its own bounds so a partially visible reused
            // cell is not cut an extra 18pt below the real viewport edge.
            setQueueInitialAnchorMaskEnabled(false)
        }
    }

    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === queueTableView, !decelerate else { return }
        correctQueueBottomVisibilityIfNeeded()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === queueTableView else { return }
        correctQueueBottomVisibilityIfNeeded()
    }

    private func correctQueueBottomVisibilityIfNeeded() {
        defer { queueScrollStartOffsetY = nil }
        guard isShowingQueue,
              let startOffsetY = queueScrollStartOffsetY,
              queueTableView.contentOffset.y > startOffsetY + 0.5
        else { return }

        queueTableView.layoutIfNeeded()
        guard let lastVisibleIndexPath = queueTableView.indexPathsForVisibleRows?
            .compactMap({ indexPath -> (IndexPath, CGRect)? in
                guard let cell = queueTableView.cellForRow(at: indexPath) else {
                    return nil
                }
                return (indexPath, cell.convert(cell.bounds, to: queueTableView))
            })
            .max(by: { $0.1.maxY < $1.1.maxY })
        else { return }

        let safeBottom = queueTableView.bounds.height - 8
        let overflow = lastVisibleIndexPath.1.maxY - safeBottom
        guard overflow > 0.5 else { return }

        let minimumOffset = -queueTableView.contentInset.top
        let maximumOffset = max(
            minimumOffset,
            queueTableView.contentSize.height
                - queueTableView.bounds.height
                + queueTableView.contentInset.bottom
        )
        let correctedOffset = min(
            max(minimumOffset, queueTableView.contentOffset.y + overflow),
            maximumOffset
        )
        guard correctedOffset > queueTableView.contentOffset.y + 0.5 else { return }
        queueTableView.setContentOffset(
            CGPoint(x: queueTableView.contentOffset.x, y: correctedOffset),
            animated: false
        )
    }
}
