import UIKit

@MainActor
public final class MusicFreeUIKitPlaybackControlButton: UIButton {
    public var systemImageName: String = "play.fill" {
        didSet { updateAppearance() }
    }

    public var isLoading: Bool = false {
        didSet { updateAppearance() }
    }

    public var showsBackground: Bool = true {
        didSet { updateAppearance() }
    }

    public var controlForegroundColor: UIColor = MusicFreeUIColorTokens.onAccent {
        didSet { updateAppearance() }
    }

    public var controlBackgroundColor: UIColor = MusicFreeUIColorTokens.accent {
        didSet { updateAppearance() }
    }

    /// Allows surfaces such as Now Playing to match the native transport
    /// hierarchy without changing the hit target or affecting compact rows.
    /// Existing callers keep the design-system default size.
    public var symbolPointSize: CGFloat = MusicFreeUIFontTokens.controlLabel.pointSize {
        didSet { updateAppearance() }
    }

    public var symbolWeight: UIImage.SymbolWeight = .semibold {
        didSet { updateAppearance() }
    }

    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var sizeConstraints: [NSLayoutConstraint] = []
    private var normalAccessibilityValue: String?

    public init(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        accessibilityValue: String? = nil,
        isSelected: Bool = false,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        foregroundColor: UIColor = MusicFreeUIColorTokens.onAccent,
        backgroundColor: UIColor = MusicFreeUIColorTokens.accent,
        showsBackground: Bool = true,
        controlSize: CGFloat = MusicFreeLayoutMetrics.minimumHitTarget,
        action: (() -> Void)? = nil
    ) {
        systemImageName = systemImage
        self.isLoading = isLoading
        controlForegroundColor = foregroundColor
        controlBackgroundColor = backgroundColor
        self.showsBackground = showsBackground
        super.init(frame: .zero)

        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityValue = accessibilityValue
        normalAccessibilityValue = accessibilityValue
        onPrimaryAction = action
        commonInit(controlSize: controlSize)
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        updateAppearance()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(controlSize: MusicFreeLayoutMetrics.minimumHitTarget)
    }

    public var onPrimaryAction: (() -> Void)?

    /// Updates the button's hit target when the same transport control is
    /// reused by a full-height and compact Now Playing surface.
    ///
    /// The original initializer deliberately installs required size
    /// constraints so standalone callers get a deterministic control. A
    /// compact player is a different layout contract, so expose the small
    /// constraint mutation instead of scaling the view (which would also
    /// scale its hit target and leave the stack with incorrect intrinsic
    /// geometry).
    public func setControlSize(_ controlSize: CGFloat) {
        guard controlSize > 0 else { return }
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints = [
            widthAnchor.constraint(equalToConstant: controlSize),
            heightAnchor.constraint(equalToConstant: controlSize),
        ]
        NSLayoutConstraint.activate(sizeConstraints)
        setNeedsLayout()
    }

    override public var isSelected: Bool {
        didSet { updateAppearance() }
    }

    override public var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override public var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.72 : (isEnabled && !isLoading ? 1 : 0.45) }
    }

    @objc private func handlePrimaryAction() {
        onPrimaryAction?()
    }

    private func commonInit(controlSize: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        sizeConstraints = [
            widthAnchor.constraint(equalToConstant: controlSize),
            heightAnchor.constraint(equalToConstant: controlSize),
        ]
        NSLayoutConstraint.activate(sizeConstraints)
        addTarget(self, action: #selector(handlePrimaryAction), for: .touchUpInside)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        layer.masksToBounds = true
        updateAppearance()
    }

    private func updateAppearance() {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: symbolPointSize,
            weight: symbolWeight
        )
        setImage(UIImage(systemName: systemImageName, withConfiguration: configuration), for: .normal)
        tintColor = controlForegroundColor
        backgroundColor = showsBackground ? controlBackgroundColor : .clear
        layer.cornerRadius = (bounds.height > 0 ? bounds.height : MusicFreeLayoutMetrics.minimumHitTarget) / 2
        activityIndicator.color = controlForegroundColor
        imageView?.isHidden = isLoading
        if isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        alpha = isEnabled && !isLoading ? 1 : 0.45
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        if isLoading {
            accessibilityValue = "Loading"
        } else {
            accessibilityValue = normalAccessibilityValue
        }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

@MainActor
public final class MusicFreeUIKitPillActionButton: UIButton {
    public var actionTitle: String = "" {
        didSet { updateAppearance() }
    }

    public var systemImageName: String = "play.fill" {
        didSet { updateAppearance() }
    }

    public var onPrimaryAction: (() -> Void)?

    public init(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        actionTitle = title
        systemImageName = systemImage
        onPrimaryAction = action
        super.init(frame: .zero)
        commonInit()
        self.isEnabled = isEnabled
        updateAppearance()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    @objc private func handlePrimaryAction() {
        onPrimaryAction?()
    }

    override public var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(handlePrimaryAction), for: .touchUpInside)
        titleLabel?.font = MusicFreeUIFontTokens.controlLabel
        titleLabel?.adjustsFontForContentSizeCategory = true
        contentEdgeInsets = UIEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            left: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            right: MusicFreeSpacingTokens.large
        )
        heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        layer.masksToBounds = true
        updateAppearance()
    }

    private func updateAppearance() {
        setTitle(actionTitle, for: .normal)
        setImage(UIImage(systemName: systemImageName), for: .normal)
        tintColor = MusicFreeUIColorTokens.accent
        setTitleColor(MusicFreeUIColorTokens.accent, for: .normal)
        backgroundColor = MusicFreeUIColorTokens.playerControl.withAlphaComponent(isEnabled ? 1 : 0.55)
        layer.borderColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.24).cgColor
        layer.borderWidth = 0.5
        alpha = isEnabled ? 1 : 0.45
        accessibilityLabel = actionTitle
        accessibilityTraits = [.button]
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

@MainActor
public final class MusicFreeUIKitMiniPlayerView: UIControl {
    public var artworkImage: UIImage? {
        didSet { artworkView.image = artworkImage }
    }

    public var titleText: String = "" {
        didSet { titleLabel.text = titleText; updateAccessibility() }
    }

    public var subtitleText: String? {
        didSet { subtitleLabel.text = subtitleText; updateAccessibility() }
    }

    public var isPlaying: Bool = false {
        didSet { updatePlaybackButton() }
    }

    public var onActivate: (() -> Void)?
    public var onPlayPause: (() -> Void)?

    private let artworkView = MusicFreeUIKitArtworkView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let playPauseButton: MusicFreeUIKitPlaybackControlButton
    private let stack = UIStackView()

    public init(
        title: String = "",
        subtitle: String? = nil,
        artwork: UIImage? = nil,
        isPlaying: Bool = false,
        onActivate: (() -> Void)? = nil,
        onPlayPause: (() -> Void)? = nil
    ) {
        titleText = title
        subtitleText = subtitle
        artworkImage = artwork
        self.isPlaying = isPlaying
        self.onActivate = onActivate
        self.onPlayPause = onPlayPause
        playPauseButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: isPlaying ? "pause.fill" : "play.fill",
            accessibilityLabel: isPlaying ? "Pause" : "Play",
            showsBackground: false
        )
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        playPauseButton = MusicFreeUIKitPlaybackControlButton(
            systemImage: "play.fill",
            accessibilityLabel: "Play",
            showsBackground: false
        )
        super.init(coder: coder)
        commonInit()
    }

    @objc private func handleActivation() {
        onActivate?()
        sendActions(for: .primaryActionTriggered)
    }

    private func commonInit() {
        addTarget(self, action: #selector(handleActivation), for: .touchUpInside)
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.medium,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.medium
        )

        artworkView.image = artworkImage
        artworkView.accessibilityElementsHidden = true
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = 1
        titleLabel.text = titleText
        titleLabel.isAccessibilityElement = false

        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.text = subtitleText
        subtitleLabel.isAccessibilityElement = false

        textStack.axis = .vertical
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        playPauseButton.onPrimaryAction = { [weak self] in self?.onPlayPause?() }
        playPauseButton.accessibilityHint = "Play or pause"

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = directionalLayoutMargins
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(artworkView)
        stack.addArrangedSubview(textStack)
        stack.addArrangedSubview(playPauseButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])
        updatePlaybackButton()
        updateAccessibility()
    }

    private func updatePlaybackButton() {
        playPauseButton.systemImageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    private func updateAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = titleText
        accessibilityValue = subtitleText
        accessibilityTraits = [.button]
    }
}
