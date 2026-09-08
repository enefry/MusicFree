import UIKit

@MainActor
open class MusicFreeUIKitStateView: UIView {
    public enum Style: Sendable {
        case empty(systemImage: String)
        case error(systemImage: String)
    }

    public var titleText: String {
        didSet { titleLabel.text = titleText }
    }

    public var messageText: String? {
        didSet {
            messageLabel.text = messageText
            messageLabel.isHidden = messageText?.isEmpty != false
        }
    }

    public var actionTitle: String? {
        didSet { updateAction() }
    }

    public var onAction: (() -> Void)? {
        didSet { updateAction() }
    }

    private let style: Style
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stack = UIStackView()

    public init(
        style: Style,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.style = style
        self.titleText = title
        self.messageText = message
        self.actionTitle = actionTitle
        self.onAction = onAction
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.style = .empty(systemImage: "music.note")
        self.titleText = ""
        self.messageText = nil
        self.actionTitle = nil
        self.onAction = nil
        super.init(coder: coder)
        commonInit()
    }

    @objc private func handleAction() {
        onAction?()
    }

    private func commonInit() {
        let imageName: String
        let iconColor: UIColor
        switch style {
        case let .empty(systemImage):
            imageName = systemImage
            iconColor = MusicFreeUIColorTokens.foregroundSecondary
        case let .error(systemImage):
            imageName = systemImage
            iconColor = MusicFreeUIColorTokens.destructive
        }

        iconView.image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(font: MusicFreeUIFontTokens.screenTitle)
        )
        iconView.tintColor = iconColor
        iconView.contentMode = .scaleAspectFit
        iconView.accessibilityElementsHidden = true

        titleLabel.font = MusicFreeUIFontTokens.sectionTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = titleText

        messageLabel.font = MusicFreeUIFontTokens.body
        messageLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.text = messageText
        messageLabel.isHidden = messageText?.isEmpty != false

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = MusicFreeUIColorTokens.accent
        configuration.baseForegroundColor = MusicFreeUIColorTokens.onAccent
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.large,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.large
        )
        actionButton.configuration = configuration
        actionButton.titleLabel?.font = MusicFreeUIFontTokens.controlLabel
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(actionButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: MusicFreeSpacingTokens.contentInset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -MusicFreeSpacingTokens.contentInset
            ),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: MusicFreeSpacingTokens.xLarge),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -MusicFreeSpacingTokens.xLarge),
            iconView.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            iconView.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])

        isAccessibilityElement = false
        accessibilityElements = [titleLabel, messageLabel, actionButton]
        updateAction()
    }

    private func updateAction() {
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle?.isEmpty != false || onAction == nil
    }
}

@MainActor
public final class MusicFreeUIKitEmptyStateView: MusicFreeUIKitStateView {
    public init(
        title: String,
        message: String? = nil,
        systemImage: String = "music.note.list",
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        super.init(
            style: .empty(systemImage: systemImage),
            title: title,
            message: message,
            actionTitle: actionTitle,
            onAction: onAction
        )
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

@MainActor
public final class MusicFreeUIKitErrorStateView: MusicFreeUIKitStateView {
    public init(
        title: String = "Unable to load",
        message: String,
        retryTitle: String? = "Try Again",
        retry: (() -> Void)? = nil
    ) {
        super.init(
            style: .error(systemImage: "exclamationmark.triangle"),
            title: title,
            message: message,
            actionTitle: retryTitle,
            onAction: retry
        )
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

@MainActor
public final class MusicFreeUIKitLoadingStateView: UIView {
    public var isLoading: Bool = true {
        didSet { updateLoadingState() }
    }

    public var labelText: String = "Loading" {
        didSet { label.text = labelText; accessibilityLabel = labelText }
    }

    private let indicator = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let stack = UIStackView()

    public init(label: String = "Loading") {
        self.labelText = label
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        indicator.color = MusicFreeUIColorTokens.accent
        indicator.hidesWhenStopped = true
        self.label.font = MusicFreeUIFontTokens.body
        self.label.textColor = MusicFreeUIColorTokens.foregroundSecondary
        self.label.textAlignment = .center
        self.label.text = labelText

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(indicator)
        stack.addArrangedSubview(self.label)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.updatesFrequently]
        accessibilityLabel = labelText
        updateLoadingState()
    }

    private func updateLoadingState() {
        if isLoading {
            indicator.startAnimating()
            isHidden = false
        } else {
            indicator.stopAnimating()
            isHidden = true
        }
    }
}
