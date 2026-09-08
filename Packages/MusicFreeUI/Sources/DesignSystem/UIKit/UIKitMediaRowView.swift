import UIKit

/// A native, reusable media row. The row itself is the primary activation
/// target; optional accessory content is supplied by the owning feature.
@MainActor
public final class MusicFreeUIKitMediaRowView: UIControl {
    /// Queue surfaces expose title/subtitle as independent static-text
    /// descendants so XCTest/VoiceOver can address the same hierarchy as the
    /// legacy SwiftUI queue. Browse rows keep the aggregate button semantics.
    public var exposesTextAccessibility: Bool = false {
        didSet { updateAccessibility() }
    }

    public var titleText: String = "" {
        didSet { titleLabel.text = titleText; updateAccessibility() }
    }

    /// Number of lines allowed for the primary title. Most browse rows stay
    /// single-line, while add-to-playlist rows match SwiftUI's flexible
    /// `MediaRow` and wrap long titles without clipping the subtitle.
    public var titleNumberOfLines: Int = 1 {
        didSet { titleLabel.numberOfLines = max(1, titleNumberOfLines) }
    }

    /// Optional identifier for the title label when a parent cell exposes the
    /// row as an activation target but tests/VoiceOver still need to address
    /// the visible title as a separate StaticText descendant.
    public var titleAccessibilityIdentifier: String? {
        didSet { titleLabel.accessibilityIdentifier = titleAccessibilityIdentifier }
    }

    public var subtitleText: String? {
        didSet {
            subtitleLabel.text = subtitleText
            subtitleLabel.isHidden = subtitleText?.isEmpty != false
            updateAccessibility()
        }
    }

    public var artworkImage: UIImage? {
        didSet { artworkView.image = artworkImage }
    }

    public var showsArtwork: Bool = true {
        didSet { artworkView.isHidden = !showsArtwork }
    }

    public var artworkAccessibilityLabel: String = "Artwork" {
        didSet { artworkView.accessibilityLabel = artworkAccessibilityLabel }
    }

    public var placeholderSystemImage: String = "music.note" {
        didSet { artworkView.placeholderSystemImage = placeholderSystemImage }
    }

    public var activationHint: String? {
        didSet { updateAccessibility() }
    }

    public var onActivate: (() -> Void)? {
        didSet { updateAccessibility() }
    }

    public var accessoryView: UIView? {
        didSet { updateAccessoryView() }
    }

    private let artworkView = MusicFreeUIKitArtworkView()

    @MainActor
    public var artworkSurface: MusicFreeUIKitArtworkView { artworkView }
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let accessoryContainer = UIView()
    private let contentStack = UIStackView()
    private var minimumHeightConstraint: NSLayoutConstraint!
    private var lastHorizontalSizeClass: UIUserInterfaceSizeClass?

    public init(
        title: String,
        subtitle: String? = nil,
        artwork: UIImage? = nil,
        showsArtwork: Bool = true,
        artworkAccessibilityLabel: String? = nil,
        placeholderSystemImage: String = "music.note",
        accessoryView: UIView? = nil,
        onActivate: (() -> Void)? = nil
    ) {
        self.titleText = title
        self.subtitleText = subtitle
        self.artworkImage = artwork
        self.showsArtwork = showsArtwork
        self.artworkAccessibilityLabel = artworkAccessibilityLabel ?? "Artwork"
        self.placeholderSystemImage = placeholderSystemImage
        self.accessoryView = accessoryView
        self.onActivate = onActivate
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.72 : 1 }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if lastHorizontalSizeClass != traitCollection.horizontalSizeClass {
            lastHorizontalSizeClass = traitCollection.horizontalSizeClass
            minimumHeightConstraint?.constant = traitCollection.horizontalSizeClass == .regular
                ? MusicFreeLayoutMetrics.regularRowMinimumHeight
                : MusicFreeLayoutMetrics.compactRowMinimumHeight
        }
    }

    @objc private func handleActivation() {
        onActivate?()
    }

    /// Performs the same semantic action used by keyboard and pointer activation.
    public func activate() {
        onActivate?()
    }

    private func commonInit() {
        addTarget(self, action: #selector(handleActivation), for: .touchUpInside)
        addTarget(self, action: #selector(handleActivation), for: .primaryActionTriggered)
        directionalLayoutMargins = MusicFreeSpacingTokens.rowInsets
        preservesSuperviewLayoutMargins = true

        artworkView.accessibilityLabel = artworkAccessibilityLabel
        artworkView.placeholderSystemImage = placeholderSystemImage
        artworkView.image = artworkImage
        artworkView.isHidden = !showsArtwork

        titleLabel.font = MusicFreeUIFontTokens.rowTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.numberOfLines = max(1, titleNumberOfLines)
        titleLabel.text = titleText
        titleLabel.accessibilityIdentifier = titleAccessibilityIdentifier

        subtitleLabel.font = MusicFreeUIFontTokens.rowSubtitle
        subtitleLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        subtitleLabel.numberOfLines = 1
        subtitleLabel.text = subtitleText
        subtitleLabel.isHidden = subtitleText?.isEmpty != false

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = MusicFreeSpacingTokens.xSmall
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = MusicFreeSpacingTokens.rowGap
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = directionalLayoutMargins
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(artworkView)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(accessoryContainer)
        addSubview(contentStack)

        minimumHeightConstraint = heightAnchor.constraint(
            greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.compactRowMinimumHeight
        )
        minimumHeightConstraint.priority = .required
        NSLayoutConstraint.activate([
            minimumHeightConstraint,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: MusicFreeLayoutMetrics.compactArtworkDimension),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            accessoryContainer.widthAnchor.constraint(equalToConstant: 32)
        ])

        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateAccessoryView()
        updateAccessibility()
    }

    private func updateAccessoryView() {
        accessoryContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let accessoryView else {
            accessoryContainer.isHidden = true
            return
        }
        accessoryContainer.isHidden = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(accessoryView)
        NSLayoutConstraint.activate([
            accessoryView.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            accessoryView.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            accessoryView.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor)
        ])
    }

    private func updateAccessibility() {
        if exposesTextAccessibility {
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityValue = nil
            accessibilityHint = nil
            accessibilityTraits = []
            titleLabel.isAccessibilityElement = true
            titleLabel.accessibilityLabel = titleText
            subtitleLabel.isAccessibilityElement = subtitleText?.isEmpty == false
            subtitleLabel.accessibilityLabel = subtitleText
        } else {
            isAccessibilityElement = true
            accessibilityLabel = titleText
            accessibilityValue = subtitleText
            accessibilityHint = activationHint
            accessibilityTraits = onActivate == nil ? [] : [.button]
            titleLabel.isAccessibilityElement = false
            subtitleLabel.isAccessibilityElement = false
        }
        artworkView.isAccessibilityElement = false
    }
}
