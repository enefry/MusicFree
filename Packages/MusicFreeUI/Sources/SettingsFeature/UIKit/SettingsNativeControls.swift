import DesignSystem
import UIKit

@MainActor public struct SettingsNativeRow {
    public enum Control {
        case none
        case toggle(Bool, (Bool) -> Void)
        case menu(String, UIMenu)
        case stepper(Double, ClosedRange<Double>, (Double) -> Void)
        case time(Date, (Date) -> Void)
        case slider(Double, ClosedRange<Double>, Double, (Double) -> String, (Double) -> Void)
        case custom(UIView)
    }
    public let id: String
    public let title: String
    public var detail = ""
    public var image: UIImage?
    public var trailingValue = ""
    public var isSelected = false
    public var accessorySymbol: String?
    public var swatchColor: UIColor?
    public var disclosure = false
    public var destructive = false
    public var enabled = true
    public var action: (() -> Void)?
    public var control: Control = .none
    public init(id: String, title: String, detail: String = "", image: UIImage? = nil,
                trailingValue: String = "", isSelected: Bool = false, accessorySymbol: String? = nil,
                swatchColor: UIColor? = nil, disclosure: Bool = false, destructive: Bool = false,
                enabled: Bool = true, action: (() -> Void)? = nil, control: Control = .none) {
        self.id = id; self.title = title; self.detail = detail; self.image = image
        self.trailingValue = trailingValue; self.isSelected = isSelected; self.accessorySymbol = accessorySymbol
        self.swatchColor = swatchColor; self.disclosure = disclosure; self.destructive = destructive
        self.enabled = enabled; self.action = action; self.control = control
    }

}

@MainActor final class SettingsNativeDataSource: UITableViewDiffableDataSource<String, String> {
    var canMoveRow: ((IndexPath) -> Bool)?
    var moveRow: ((IndexPath, IndexPath) -> Void)?
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { canMoveRow?(indexPath) ?? false }
    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath,
              let source = itemIdentifier(for: sourceIndexPath),
              let destination = itemIdentifier(for: destinationIndexPath) else { return }
        var next = snapshot()
        next.deleteItems([source])
        if sourceIndexPath.row < destinationIndexPath.row { next.insertItems([source], afterItem: destination) }
        else { next.insertItems([source], beforeItem: destination) }
        apply(next, animatingDifferences: false)
        moveRow?(sourceIndexPath, destinationIndexPath)
    }
    var sectionText: ((Int, Bool) -> String?)?
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sectionText?(section, false) }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sectionText?(section, true) }
}

@MainActor final class SettingsNativeCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let symbol = UIImageView()
    private let slider = SettingsValueSlider()
    private let toggle = UISwitch()
    private let menu = UIButton(type: .system)
    private let stepper = UIStepper()
    private let datePicker = UIDatePicker()
    private let customContainer = UIStackView()
    private let trailingLabel = UILabel()
    private let trailingIcon = UIImageView()
    private let colorSwatch = UIView()
    private let trailingStack = UIStackView()
    private var row: SettingsNativeRow?
    var rowID: String? { row?.id }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.font = MusicFreeUIFontTokens.body
        detailLabel.font = MusicFreeUIFontTokens.secondary
        titleLabel.numberOfLines = 0
        detailLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = .init(pointSize: 22)
        NSLayoutConstraint.activate([symbol.widthAnchor.constraint(equalToConstant: 28), symbol.heightAnchor.constraint(equalToConstant: 28)])
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 4
        let top = UIStackView(arrangedSubviews: [symbol, labels])
        top.spacing = 12
        top.alignment = .center
        let stack = UIStackView(arrangedSubviews: [top, slider, customContainer])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        customContainer.axis = .vertical
        trailingLabel.font = MusicFreeUIFontTokens.secondary
        trailingLabel.textColor = .secondaryLabel
        trailingLabel.adjustsFontForContentSizeCategory = true
        trailingIcon.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
        trailingIcon.contentMode = .scaleAspectFit
        colorSwatch.layer.cornerRadius = 10
        NSLayoutConstraint.activate([colorSwatch.widthAnchor.constraint(equalToConstant: 20), colorSwatch.heightAnchor.constraint(equalToConstant: 20)])
        trailingStack.spacing = 8
        trailingStack.alignment = .center
        [trailingLabel, colorSwatch, trailingIcon].forEach { trailingStack.addArrangedSubview($0) }
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.onAccessibilityCommit = { [weak self] in self?.sliderChanged(); self?.sliderEnded() }
        menu.showsMenuAsPrimaryAction = true
        stepper.addTarget(self, action: #selector(stepperChanged), for: .valueChanged)
        datePicker.datePickerMode = .time
        datePicker.preferredDatePickerStyle = .compact
        datePicker.addTarget(self, action: #selector(timeChanged), for: .valueChanged)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ row: SettingsNativeRow) {
        self.row = row
        titleLabel.text = row.title
        titleLabel.isHidden = row.title.isEmpty
        titleLabel.textColor = row.destructive ? .systemRed : .label
        if !slider.isTracking { detailLabel.text = row.detail }
        detailLabel.isHidden = row.detail.isEmpty
        symbol.image = row.image
        symbol.isHidden = row.image == nil
        symbol.tintColor = MusicFreeUIColorTokens.accent
        symbol.layer.cornerRadius = row.image?.isSymbolImage == false ? 6 : 0
        symbol.clipsToBounds = true
        accessibilityIdentifier = row.id
        if case .none = row.control {
            isAccessibilityElement = true
            accessibilityLabel = row.title
            accessibilityValue = [row.detail, row.trailingValue].filter { !$0.isEmpty }.joined(separator: ", ")
            accessibilityTraits = row.action == nil ? .staticText : .button
            if row.isSelected { accessibilityTraits.insert(.selected) }
        } else {
            isAccessibilityElement = false
        }
        selectionStyle = row.action == nil ? .none : .default
        accessoryType = row.disclosure ? .disclosureIndicator : .none
        let isSlider: Bool = { if case .slider = row.control { return true }; return false }()
        slider.isHidden = !isSlider
        customContainer.isHidden = true
        switch row.control {
        case .none:
            if !row.trailingValue.isEmpty || row.isSelected || row.accessorySymbol != nil || row.swatchColor != nil {
                trailingLabel.text = row.trailingValue
                trailingLabel.isHidden = row.trailingValue.isEmpty
                colorSwatch.backgroundColor = row.swatchColor
                colorSwatch.isHidden = row.swatchColor == nil
                let icon = row.isSelected ? "checkmark" : (row.accessorySymbol ?? (row.disclosure ? "chevron.right" : nil))
                trailingIcon.image = icon.flatMap { UIImage(systemName: $0) }
                trailingIcon.tintColor = row.isSelected ? MusicFreeUIColorTokens.accent : .tertiaryLabel
                trailingIcon.isHidden = icon == nil
                trailingStack.frame.size = trailingStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
                accessoryView = trailingStack
            } else { accessoryView = nil }
        case .custom(let content):
            accessoryView = nil
            if customContainer.arrangedSubviews.first !== content {
                customContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
                customContainer.addArrangedSubview(content)
            }
            customContainer.isHidden = false
        case .toggle(let value, _):
            toggle.setOn(value, animated: false)
            toggle.isEnabled = row.enabled
            toggle.onTintColor = MusicFreeUIColorTokens.accent
            toggle.accessibilityLabel = row.title
            toggle.accessibilityIdentifier = row.id
            accessoryView = toggle
        case .menu(let title, let options):
            menu.setTitle(title, for: .normal)
            menu.menu = options
            menu.isEnabled = row.enabled
            menu.accessibilityLabel = row.title
            menu.accessibilityValue = title
            menu.accessibilityIdentifier = row.id
            menu.sizeToFit()
            accessoryView = menu
        case .stepper(let value, let range, _):
            stepper.minimumValue = range.lowerBound
            stepper.maximumValue = range.upperBound
            stepper.value = value
            stepper.isEnabled = row.enabled
            stepper.accessibilityLabel = row.title
            stepper.accessibilityIdentifier = row.id
            accessoryView = stepper
        case .time(let date, _):
            if !datePicker.isTracking && datePicker.date != date { datePicker.date = date }
            if datePicker.locale?.identifier != MusicFreeLocalization.locale.identifier {
                datePicker.locale = MusicFreeLocalization.locale
            }
            datePicker.isEnabled = row.enabled
            datePicker.accessibilityIdentifier = row.id
            accessoryView = datePicker
        case .slider(let value, let range, let step, _, _):
            slider.isHidden = false
            accessoryView = nil
            if !slider.isTracking {
                slider.minimumValue = Float(range.lowerBound)
                slider.maximumValue = Float(range.upperBound)
                slider.value = Float(value)
                slider.isEnabled = row.enabled
            }
            slider.accessibilityStep = Float(step)
            slider.tintColor = MusicFreeUIColorTokens.accent
            slider.accessibilityLabel = row.title
            slider.accessibilityValue = detailLabel.text
            slider.accessibilityIdentifier = row.id
        }
        // Editing mode uses separate accessories. Keep provider switches and
        // other controls available alongside the metadata reorder handles.
        editingAccessoryView = accessoryView
        editingAccessoryType = accessoryType
        contentView.alpha = row.enabled ? 1 : 0.5
    }

    @objc private func stepperChanged() {
        if case .stepper(_, _, let change) = row?.control { change(stepper.value) }
    }
    @objc private func timeChanged() {
        if case .time(_, let change) = row?.control { change(datePicker.date) }
    }
    @objc private func toggleChanged() {
        if case .toggle(_, let change) = row?.control { change(toggle.isOn) }
    }
    @objc private func sliderChanged() {
        guard case .slider(_, _, let step, let format, _) = row?.control else { return }
        let value = step > 0 ? (Double(slider.value) / step).rounded() * step : Double(slider.value)
        detailLabel.text = format(value)
        slider.accessibilityValue = detailLabel.text
    }
    @objc private func sliderEnded() {
        guard case .slider(_, let range, let step, _, let save) = row?.control else { return }
        let value = step > 0 ? (Double(slider.value) / step).rounded() * step : Double(slider.value)
        save(min(max(value, range.lowerBound), range.upperBound))
    }
}


/// VoiceOver adjustments have no touch-up event. Commit a complete step here.
@MainActor
private final class SettingsValueSlider: UISlider {
    var accessibilityStep: Float = 0
    var onAccessibilityCommit: (() -> Void)?
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    private func adjust(_ direction: Float) {
        guard isEnabled else { return }
        let step = accessibilityStep > 0 ? accessibilityStep : (maximumValue - minimumValue) / 10
        value = min(max(value + direction * step, minimumValue), maximumValue)
        onAccessibilityCommit?()
    }
}
