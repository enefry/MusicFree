import DesignSystem
import MusicDomain
import UIKit

@MainActor
enum LibraryMetadataForm {
    static func field(_ value: String?, identifier: String, numeric: Bool = false) -> UITextField {
        let field = UITextField()
        field.text = value
        field.placeholder = L("未设置")
        field.font = MusicFreeUIFontTokens.body
        field.textColor = MusicFreeUIColorTokens.foregroundPrimary
        field.textAlignment = .right
        field.clearButtonMode = .whileEditing
        field.keyboardType = numeric ? .numberPad : .default
        field.accessibilityIdentifier = identifier
        return field
    }

    static func row(_ title: String, control: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = MusicFreeUIFontTokens.body
        label.textColor = MusicFreeUIColorTokens.foregroundPrimary
        label.numberOfLines = 0
        label.setContentHuggingPriority(.required, for: .horizontal)
        let content: UIView
        if control is UISwitch {
            let container = UIView()
            control.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            content = container
        } else {
            content = control
        }
        let stack = UIStackView(arrangedSubviews: [label, content])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.4).isActive = true
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if let field = control as? UITextField { field.accessibilityLabel = title }
        return stack
    }

    static func textView(_ value: String?, identifier: String) -> UITextView {
        let view = UITextView()
        view.text = value
        view.font = MusicFreeUIFontTokens.body
        view.textColor = MusicFreeUIColorTokens.foregroundPrimary
        view.backgroundColor = .clear
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.heightAnchor.constraint(equalToConstant: 140).isActive = true
        view.accessibilityIdentifier = identifier
        return view
    }

    static func section(_ title: String, rows: [UIView]) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = MusicFreeUIFontTokens.secondary
        label.textColor = MusicFreeUIColorTokens.foregroundSecondary
        label.accessibilityTraits = .header
        let content = UIStackView()
        content.axis = .vertical
        content.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        content.layer.cornerRadius = 12
        content.clipsToBounds = true
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = UIView()
                line.backgroundColor = MusicFreeUIColorTokens.separator
                line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                content.addArrangedSubview(line)
            }
            content.addArrangedSubview(row)
        }
        let stack = UIStackView(arrangedSubviews: [label, content])
        stack.axis = .vertical
        stack.spacing = MusicFreeSpacingTokens.small
        return stack
    }

    static func names(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: CharacterSet(charactersIn: ";；、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func shouldDismissKeyboard(for touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    static func dateText(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    static func durationText(_ duration: Duration?) -> String {
        guard let duration else { return L("未知") }
        let seconds = max(0, duration.components.seconds)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func ratingTitle(_ rating: TrackContentRating) -> String {
        switch rating {
        case .unknown: L("未知")
        case .clean: L("无警告")
        case .explicit: L("成人内容")
        }
    }
}

@MainActor
final class LibraryMetadataDateControl: UIStackView {
    let enabledSwitch = UISwitch()
    let picker = UIDatePicker()
    var date: Date? { enabledSwitch.isOn ? picker.date : nil }

    init(date: Date?, title: String, identifier: String, maximumDate: Date? = nil) {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.timeZone = TimeZone(secondsFromGMT: 0)
        picker.calendar = Calendar(identifier: .gregorian)
        picker.maximumDate = maximumDate
        picker.date = date ?? Date()
        picker.accessibilityIdentifier = identifier + ".date"
        enabledSwitch.isOn = date != nil
        enabledSwitch.accessibilityLabel = title
        enabledSwitch.accessibilityIdentifier = identifier + ".enabled"
        enabledSwitch.addTarget(self, action: #selector(updateVisibility), for: .valueChanged)
        addArrangedSubview(LibraryMetadataForm.row(title, control: enabledSwitch))
        let dateRow = UIStackView(arrangedSubviews: [picker])
        dateRow.isLayoutMarginsRelativeArrangement = true
        dateRow.directionalLayoutMargins = .init(top: 0, leading: 16, bottom: 12, trailing: 16)
        addArrangedSubview(dateRow)
        updateVisibility()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func updateVisibility() { arrangedSubviews.last?.isHidden = !enabledSwitch.isOn }
}

struct LibraryDetailInfoRow {
    let title: String
    let value: String
    let symbol: String
    var identifier: String? = nil
}

struct LibraryDetailInfoSection {
    let title: String
    let rows: [LibraryDetailInfoRow]
}

@MainActor
final class LibraryDetailInfoView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = MusicFreeSpacingTokens.large
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ sections: [LibraryDetailInfoSection]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in sections {
            let title = UILabel()
            title.text = section.title
            title.font = MusicFreeUIFontTokens.sectionTitle
            title.textColor = MusicFreeUIColorTokens.foregroundPrimary
            title.accessibilityTraits = .header
            let stack = UIStackView(arrangedSubviews: [title])
            stack.axis = .vertical
            stack.spacing = 12
            for row in section.rows {
                let icon = UIImageView(image: UIImage(systemName: row.symbol))
                icon.tintColor = MusicFreeUIColorTokens.accent
                icon.contentMode = .scaleAspectFit
                icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
                let label = UILabel()
                label.text = row.title
                label.font = MusicFreeUIFontTokens.body
                label.textColor = MusicFreeUIColorTokens.foregroundPrimary
                label.numberOfLines = 0
                let value = UILabel()
                value.text = row.value
                value.font = MusicFreeUIFontTokens.body
                value.textColor = MusicFreeUIColorTokens.foregroundSecondary
                value.numberOfLines = 0
                value.textAlignment = .right
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let textStack = UIStackView(arrangedSubviews: [label, value])
                textStack.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
                textStack.spacing = 12
                textStack.alignment = .top
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
                let rowStack = UIStackView(arrangedSubviews: [icon, textStack])
                rowStack.axis = .horizontal
                rowStack.alignment = .top
                rowStack.spacing = 12
                rowStack.isAccessibilityElement = true
                rowStack.accessibilityLabel = row.title + ", " + row.value
                rowStack.accessibilityIdentifier = row.identifier
                rowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
                stack.addArrangedSubview(rowStack)
                let line = UIView()
                line.backgroundColor = MusicFreeUIColorTokens.separator
                line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                stack.addArrangedSubview(line)
            }
            addArrangedSubview(stack)
        }
    }
}
