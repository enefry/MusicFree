import UIKit

@MainActor
public final class MusicFreeUIKitSectionHeaderView: UIView {
    public var titleText: String = "" {
        didSet { titleLabel.text = titleText }
    }

    public var actionTitle: String? {
        didSet { updateAction() }
    }

    public var onAction: (() -> Void)? {
        didSet { updateAction() }
    }

    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stack = UIStackView()

    public init(
        title: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.titleText = title
        self.actionTitle = actionTitle
        self.onAction = onAction
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    @objc private func handleAction() {
        onAction?()
    }

    private func commonInit() {
        titleLabel.font = MusicFreeUIFontTokens.preferred(.title3, weight: .bold)
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.text = titleText
        titleLabel.numberOfLines = 1
        titleLabel.accessibilityTraits = [.header]

        actionButton.titleLabel?.font = MusicFreeUIFontTokens.preferred(.subheadline, weight: .semibold)
        actionButton.setTitleColor(MusicFreeUIColorTokens.accent, for: .normal)
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = MusicFreeSpacingTokens.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(UIView())
        stack.addArrangedSubview(actionButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])
        updateAction()
    }

    private func updateAction() {
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle?.isEmpty != false || onAction == nil
    }
}
