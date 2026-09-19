import DesignSystem
import MediaSourceAPI
import UIKit

enum LibraryImportStatusTone: Equatable {
    case active
    case warning
    case success
    case failure
    case cancelled
}

enum LibraryImportStatusAction: Equatable {
    case cancel
    case continueImport
    case dismiss
}

struct LibraryImportStatusPresentation: Equatable {
    let tone: LibraryImportStatusTone
    let title: String
    let detail: String?
    let progress: Float?
    let showsActivity: Bool
    let primaryAction: LibraryImportStatusAction?
    let secondaryAction: LibraryImportStatusAction?

    static func make(
        state: LibraryImportState,
        failures: [LibraryImportFailure]
    ) -> Self? {
        switch state {
        case .idle:
            return nil
        case .importing(let progress):
            return progressPresentation(
                progress,
                title: L("正在导入媒体"),
                primaryAction: .cancel
            )
        case .awaitingConfirmation(let progress):
            return Self(
                tone: .warning,
                title: L("部分文件导入失败"),
                detail: confirmationDetail(progress.failures),
                progress: nil,
                showsActivity: false,
                primaryAction: .continueImport,
                secondaryAction: .cancel
            )
        case .cancelling(let progress):
            return progressPresentation(
                progress,
                title: L("正在取消导入"),
                primaryAction: nil
            )
        case .completed(let result):
            return resultPresentation(result, failures: failures)
        case .failed(let message):
            return Self(
                tone: .failure,
                title: L("import.failed.title"),
                detail: message,
                progress: nil,
                showsActivity: false,
                primaryAction: .dismiss,
                secondaryAction: nil
            )
        }
    }

    private static func progressPresentation(
        _ progress: ImportProgressSnapshot,
        title: String,
        primaryAction: LibraryImportStatusAction?
    ) -> Self {
        var detailParts: [String] = []
        if let phase = progress.phase {
            detailParts.append(phase.title)
        }
        if progress.totalItems > 0 {
            detailParts.append(
                L("已处理 %d，共 %d", progress.processedItems, progress.totalItems)
            )
        }
        if let currentItemName = progress.currentItemName,
           !currentItemName.isEmpty {
            detailParts.append(currentItemName)
        }

        let fraction: Float?
        if progress.totalItems > 0 {
            fraction = min(
                1,
                Float(progress.processedItems) / Float(progress.totalItems)
            )
        } else {
            fraction = nil
        }

        return Self(
            tone: .active,
            title: title,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            progress: fraction,
            showsActivity: true,
            primaryAction: primaryAction,
            secondaryAction: nil
        )
    }

    private static func resultPresentation(
        _ result: MediaImportResult,
        failures: [LibraryImportFailure]
    ) -> Self {
        let tone: LibraryImportStatusTone
        let title: String
        if result.isCancelled {
            tone = .cancelled
            title = L("导入已取消")
        } else if result.failed > 0, result.imported == 0 {
            tone = .failure
            title = L("import.failed.title")
        } else if result.failed > 0 {
            tone = .warning
            title = L("部分文件导入失败")
        } else {
            tone = .success
            title = L("导入完成")
        }

        var detailParts = resultSummary(result)
        if let failure = failures.first {
            detailParts.append(failureDetail(failure))
        }
        if failures.count > 1 {
            detailParts.append(L("还有 %d 项失败", failures.count - 1))
        }

        return Self(
            tone: tone,
            title: title,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "\n"),
            progress: nil,
            showsActivity: false,
            primaryAction: .dismiss,
            secondaryAction: nil
        )
    }

    private static func resultSummary(_ result: MediaImportResult) -> [String] {
        var parts: [String] = []
        if result.imported > 0 { parts.append(L("已导入 %d 首", result.imported)) }
        if result.duplicate > 0 { parts.append(L("重复 %d 首", result.duplicate)) }
        if result.skipped > 0 { parts.append(L("已跳过 %d 首", result.skipped)) }
        if result.failed > 0 { parts.append(L("失败 %d 首", result.failed)) }
        if result.cancelled > 0 { parts.append(L("取消 %d 首", result.cancelled)) }
        return parts.isEmpty ? [] : [parts.joined(separator: " · ")]
    }

    private static func confirmationDetail(
        _ failures: [LibraryImportFailure]
    ) -> String {
        guard let failure = failures.first else {
            return L("以下文件无法导入。确认后将继续导入其他文件。")
        }
        return [
            failureDetail(failure),
            L("以下文件无法导入。确认后将继续导入其他文件。")
        ].joined(separator: "\n")
    }

    private static func failureDetail(_ failure: LibraryImportFailure) -> String {
        let reason = failure.code == "corrupted_media"
            ? L("媒体解析失败或超时，请重试。")
            : failure.message
        return L("format.colonPair", failure.itemName, reason)
    }
}

@MainActor
final class LibraryImportStatusView: UIView {
    var onCancel: (() -> Void)?
    var onContinueImport: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let blurView = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemMaterial)
    )
    private let iconView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private var primaryAction: LibraryImportStatusAction?
    private var secondaryAction: LibraryImportStatusAction?
    private var previousTone: LibraryImportStatusTone?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        state: LibraryImportState,
        failures: [LibraryImportFailure]
    ) {
        guard let presentation = LibraryImportStatusPresentation.make(
            state: state,
            failures: failures
        ) else {
            previousTone = nil
            isHidden = true
            accessibilityElementsHidden = true
            return
        }

        let wasHidden = isHidden
        isHidden = false
        accessibilityElementsHidden = false
        titleLabel.text = presentation.title
        detailLabel.text = presentation.detail
        detailLabel.isHidden = presentation.detail?.isEmpty != false

        if let progress = presentation.progress {
            progressView.progress = progress
            progressView.isHidden = false
        } else {
            progressView.isHidden = true
        }

        activityIndicator.isHidden = !presentation.showsActivity
        if presentation.showsActivity {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        configureIcon(for: presentation.tone, hidden: presentation.showsActivity)

        primaryAction = presentation.primaryAction
        secondaryAction = presentation.secondaryAction
        configure(primaryButton, for: presentation.primaryAction, isPrimary: true)
        configure(secondaryButton, for: presentation.secondaryAction, isPrimary: false)

        accessibilityLabel = [presentation.title, presentation.detail]
            .compactMap { $0 }
            .joined(separator: ", ")

        if wasHidden || previousTone != presentation.tone {
            UIAccessibility.post(
                notification: .announcement,
                argument: accessibilityLabel
            )
        }
        previousTone = presentation.tone
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        accessibilityElementsHidden = true
        accessibilityIdentifier = "library.import.statusOverlay"
        layer.cornerRadius = MusicFreeLayoutMetrics.artworkCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = MusicFreeLayoutMetrics.artworkCornerRadius
        blurView.layer.cornerCurve = .continuous
        blurView.layer.masksToBounds = true
        blurView.layer.borderColor = MusicFreeUIColorTokens.separator
            .withAlphaComponent(0.32)
            .cgColor
        blurView.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        addSubview(blurView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 22,
            weight: .semibold
        )
        iconView.accessibilityElementsHidden = true

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = MusicFreeUIColorTokens.accent
        activityIndicator.hidesWhenStopped = true
        activityIndicator.accessibilityElementsHidden = true

        titleLabel.font = MusicFreeUIFontTokens.sectionTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.accessibilityIdentifier = "library.import.statusOverlay.title"

        detailLabel.font = MusicFreeUIFontTokens.caption
        detailLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.accessibilityIdentifier = "library.import.statusOverlay.detail"

        progressView.progressTintColor = MusicFreeUIColorTokens.accent
        progressView.trackTintColor = MusicFreeUIColorTokens.separator.withAlphaComponent(0.22)
        progressView.accessibilityIdentifier = "library.import.statusOverlay.progress"

        primaryButton.addTarget(self, action: #selector(primaryTriggered), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTriggered), for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = MusicFreeSpacingTokens.xSmall

        let statusContainer = UIView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(iconView)
        statusContainer.addSubview(activityIndicator)

        let actionStack = UIStackView(arrangedSubviews: [secondaryButton, primaryButton])
        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = MusicFreeSpacingTokens.xSmall

        let headerStack = UIStackView(arrangedSubviews: [statusContainer, textStack, actionStack])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = MusicFreeSpacingTokens.medium

        let contentStack = UIStackView(arrangedSubviews: [headerStack, progressView])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.small
        blurView.contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusContainer.widthAnchor.constraint(equalToConstant: 28),
            statusContainer.heightAnchor.constraint(equalToConstant: 28),
            iconView.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            activityIndicator.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            secondaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            contentStack.leadingAnchor.constraint(
                equalTo: blurView.contentView.leadingAnchor,
                constant: MusicFreeSpacingTokens.medium
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: blurView.contentView.trailingAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
            contentStack.topAnchor.constraint(
                equalTo: blurView.contentView.topAnchor,
                constant: MusicFreeSpacingTokens.small
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: blurView.contentView.bottomAnchor,
                constant: -MusicFreeSpacingTokens.small
            ),
        ])
    }

    private func configureIcon(
        for tone: LibraryImportStatusTone,
        hidden: Bool
    ) {
        iconView.isHidden = hidden
        switch tone {
        case .active:
            iconView.image = UIImage(systemName: "arrow.down.circle.fill")
            iconView.tintColor = MusicFreeUIColorTokens.accent
        case .warning:
            iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            iconView.tintColor = MusicFreeUIColorTokens.warning
        case .success:
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = MusicFreeUIColorTokens.positive
        case .failure:
            iconView.image = UIImage(systemName: "xmark.octagon.fill")
            iconView.tintColor = MusicFreeUIColorTokens.destructive
        case .cancelled:
            iconView.image = UIImage(systemName: "pause.circle.fill")
            iconView.tintColor = MusicFreeUIColorTokens.warning
        }
    }

    private func configure(
        _ button: UIButton,
        for action: LibraryImportStatusAction?,
        isPrimary: Bool
    ) {
        guard let action else {
            button.isHidden = true
            return
        }
        button.isHidden = false

        var configuration: UIButton.Configuration
        switch action {
        case .continueImport:
            configuration = .filled()
            configuration.title = L("继续导入其他文件")
            configuration.image = UIImage(systemName: "checkmark")
            configuration.imagePadding = MusicFreeSpacingTokens.xSmall
            configuration.baseBackgroundColor = MusicFreeUIColorTokens.accent
            configuration.baseForegroundColor = MusicFreeUIColorTokens.onAccent
            configuration.cornerStyle = .medium
        case .cancel, .dismiss:
            configuration = isPrimary ? .plain() : .tinted()
            configuration.image = UIImage(systemName: "xmark")
            configuration.baseForegroundColor = action == .cancel
                ? MusicFreeUIColorTokens.destructive
                : MusicFreeUIColorTokens.foregroundSecondary
            configuration.cornerStyle = .medium
        }
        button.configuration = configuration

        switch action {
        case .cancel:
            button.accessibilityLabel = L("取消导入")
            button.accessibilityIdentifier = "library.import.statusOverlay.cancel"
        case .continueImport:
            button.accessibilityLabel = L("继续导入其他文件")
            button.accessibilityIdentifier = "library.import.statusOverlay.continue"
        case .dismiss:
            button.accessibilityLabel = L("关闭导入结果")
            button.accessibilityIdentifier = "library.import.statusOverlay.dismiss"
        }
    }

    @objc private func primaryTriggered() {
        perform(primaryAction)
    }

    @objc private func secondaryTriggered() {
        perform(secondaryAction)
    }

    private func perform(_ action: LibraryImportStatusAction?) {
        switch action {
        case .cancel: onCancel?()
        case .continueImport: onContinueImport?()
        case .dismiss: onDismiss?()
        case nil: break
        }
    }
}
