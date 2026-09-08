import UIKit

/// Native UIKit artwork surface shared by collection cells, rows and player
/// chrome. It owns placeholder/loading rendering and accessibility semantics.
@MainActor
public final class MusicFreeUIKitArtworkView: UIView {
    public var image: UIImage? {
        didSet { updateContent() }
    }

    public var isLoading: Bool = false {
        didSet { updateContent() }
    }

    public var placeholderSystemImage: String = "music.note" {
        didSet { updateContent() }
    }

    public var placeholderTitle: String? {
        didSet { updateAccessibility() }
    }

    public var fillsAvailableWidth: Bool = false {
        didSet { invalidateIntrinsicContentSize() }
    }

    public var cornerRadius: CGFloat = MusicFreeLayoutMetrics.artworkCornerRadius {
        didSet { updateCornerStyle() }
    }

    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var lastHorizontalSizeClass: UIUserInterfaceSizeClass?

    public init(
        image: UIImage? = nil,
        accessibilityLabel: String = "Artwork",
        isLoading: Bool = false,
        placeholderSystemImage: String = "music.note",
        placeholderTitle: String? = nil,
        fillsAvailableWidth: Bool = false,
        cornerRadius: CGFloat = MusicFreeLayoutMetrics.artworkCornerRadius
    ) {
        self.image = image
        self.isLoading = isLoading
        self.placeholderSystemImage = placeholderSystemImage
        self.placeholderTitle = placeholderTitle
        self.fillsAvailableWidth = fillsAvailableWidth
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        self.accessibilityLabel = accessibilityLabel
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public override var intrinsicContentSize: CGSize {
        guard !fillsAvailableWidth else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        return MusicFreeLayoutMetrics.artworkSize(for: traitCollection)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if lastHorizontalSizeClass != traitCollection.horizontalSizeClass {
            lastHorizontalSizeClass = traitCollection.horizontalSizeClass
            invalidateIntrinsicContentSize()
        }
    }

    private func commonInit() {
        backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [.image]

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        addSubview(imageView)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = MusicFreeUIColorTokens.accent
        activityIndicator.hidesWhenStopped = true
        activityIndicator.isAccessibilityElement = false
        addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateCornerStyle()
        updateContent()
    }

    private func updateContent() {
        if isLoading {
            if let image {
                imageView.image = image
                imageView.contentMode = .scaleAspectFill
                imageView.tintColor = nil
            } else {
                imageView.image = nil
            }
            activityIndicator.startAnimating()
        } else if let image {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
            activityIndicator.stopAnimating()
        } else {
            let configuration = UIImage.SymbolConfiguration(
                font: MusicFreeUIFontTokens.screenTitle
            )
            imageView.image = UIImage(
                systemName: placeholderSystemImage,
                withConfiguration: configuration
            )
            imageView.contentMode = .center
            imageView.tintColor = MusicFreeUIColorTokens.foregroundTertiary
            activityIndicator.stopAnimating()
        }
        updateAccessibility()
    }

    private func updateAccessibility() {
        if isLoading {
            accessibilityValue = "Loading"
        } else if image == nil {
            accessibilityValue = placeholderTitle.map { "No artwork, \($0)" } ?? "No artwork"
        } else {
            accessibilityValue = nil
        }
    }

    private func updateCornerStyle() {
        layer.cornerRadius = cornerRadius
        layer.borderColor = UIColor.black.withAlphaComponent(0.3).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }
}
