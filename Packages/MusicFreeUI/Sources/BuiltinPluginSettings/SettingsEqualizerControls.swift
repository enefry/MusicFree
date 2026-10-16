import DesignSystem
import PlaybackAPI
import SettingsAPI
import UIKit

@MainActor
final class SettingsEqualizerBankView: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var controls: [SettingsEqualizerBandView] = []
    private var frequencies: [Double] = []

    init() {
        super.init(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.canCancelContentTouches = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 228),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(bands: [EqualizerBandDescriptor], enabled: Bool,
                   gain: (EqualizerBandDescriptor) -> Double, save: @escaping (Double, EqualizerBandDescriptor) -> Void) {
        let next = bands.filter { max(Double($0.minimumGainDecibels), EqualizerGain.minimumDecibels) <= min(Double($0.maximumGainDecibels), EqualizerGain.maximumDecibels) }
        if frequencies != next.map(\.centerFrequencyHz) {
            frequencies = next.map(\.centerFrequencyHz)
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            controls = next.map { _ in SettingsEqualizerBandView() }
            controls.forEach { stack.addArrangedSubview($0) }
        }
        for (control, band) in zip(controls, next) {
            control.configure(band: band, gain: gain(band), enabled: enabled) { save($0, band) }
        }
    }
}

@MainActor
private final class SettingsEqualizerBandView: UIView {
    private let gainLabel = UILabel()
    private let frequencyLabel = UILabel()
    private let slider = SettingsEqualizerSlider()
    private var save: ((Double) -> Void)?
    private var isEditing = false
    private var lastCommittedValue: Float?

    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        [gainLabel, frequencyLabel].forEach {
            $0.font = .preferredFont(forTextStyle: .caption2)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.textColor = .secondaryLabel
            addSubview($0)
        }
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        addSubview(slider)
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.addTarget(self, action: #selector(ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.onAccessibilityCommit = { [weak self] in self?.ended() }
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetBand))
        reset.numberOfTapsRequired = 2
        reset.cancelsTouchesInView = false
        addGestureRecognizer(reset)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelHeight = max(30, gainLabel.font.lineHeight + 4)
        gainLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: labelHeight)
        frequencyLabel.frame = CGRect(x: 0, y: bounds.height - labelHeight - 4, width: bounds.width, height: labelHeight)
        slider.bounds = CGRect(x: 0, y: 0, width: max(100, bounds.height - labelHeight * 2 - 14), height: 32)
        slider.center = CGPoint(x: bounds.midX, y: bounds.midY - 2)
    }

    func configure(band: EqualizerBandDescriptor, gain: Double, enabled: Bool, save: @escaping (Double) -> Void) {
        self.save = save
        let frequency = band.centerFrequencyHz
        frequencyLabel.text = frequency >= 1_000 ? String(format: "%gk", frequency / 1_000) : String(format: "%.0f", frequency)
        slider.accessibilityIdentifier = "settings.playback.equalizer.band.\(Int(frequency.rounded()))"
        slider.accessibilityLabel = frequency >= 1_000 ? String(format: "%g kHz", frequency / 1_000) : String(format: "%.0f Hz", frequency)
        slider.minimumValue = Float(max(Double(band.minimumGainDecibels), EqualizerGain.minimumDecibels))
        slider.maximumValue = Float(min(Double(band.maximumGainDecibels), EqualizerGain.maximumDecibels))
        if !isEditing && !slider.isTracking { slider.value = Float(gain); updateValueLabel() }
        if !slider.isTracking { slider.isEnabled = enabled }
        slider.tintColor = MusicFreeUIColorTokens.accent
        alpha = enabled ? 1 : 0.5
    }
    private func updateValueLabel() {
        gainLabel.text = String(format: "%+.1f", slider.value)
        slider.accessibilityValue = String(format: "%+.1f dB", slider.value)
    }
    @objc private func changed() {
        // UIKit can deliver a final valueChanged after touchUp with the snapped
        // value. It must not reopen the draft that ended() just committed.
        if slider.isTracking || slider.value != lastCommittedValue { isEditing = true }
        updateValueLabel()
    }
    @objc private func ended() {
        let value = min(max((Double(slider.value) * 2).rounded() / 2, Double(slider.minimumValue)), Double(slider.maximumValue))
        lastCommittedValue = Float(value)
        slider.value = Float(value)
        updateValueLabel()
        isEditing = false
        save?(value)
    }
    @objc private func resetBand() {
        guard slider.isEnabled else { return }
        slider.value = min(max(0, slider.minimumValue), slider.maximumValue)
        ended()
    }
}

@MainActor
private final class SettingsEqualizerSlider: UISlider {
    var onAccessibilityCommit: (() -> Void)?
    override func accessibilityIncrement() { super.accessibilityIncrement(); onAccessibilityCommit?() }
    override func accessibilityDecrement() { super.accessibilityDecrement(); onAccessibilityCommit?() }
}

@MainActor
final class SettingsChoiceGridView: UIStackView {
    struct Choice { let id: String; let title: String; let selected: Bool; let action: () -> Void }
    private var buttons: [UIButton] = []
    private var identities: [String] = []
    init() { super.init(frame: .zero); axis = .vertical; spacing = 8 }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func configure(choices: [Choice], enabled: Bool) {
        if identities != choices.map(\.id) {
            identities = choices.map(\.id)
            arrangedSubviews.forEach { $0.removeFromSuperview() }
            buttons = choices.map { _ in UIButton(type: .system) }
            for index in stride(from: 0, to: buttons.count, by: 2) {
                let row = UIStackView(arrangedSubviews: Array(buttons[index..<min(index + 2, buttons.count)]))
                row.spacing = 8; row.distribution = .fillEqually
                if row.arrangedSubviews.count == 1 { row.addArrangedSubview(UIView()) }
                addArrangedSubview(row)
            }
        }
        for (button, choice) in zip(buttons, choices) {
            var config = choice.selected ? UIButton.Configuration.filled() : .tinted()
            config.title = choice.title
            config.baseBackgroundColor = MusicFreeUIColorTokens.accent
            config.baseForegroundColor = choice.selected ? MusicFreeAccentColorStore.onAccentUIColor : MusicFreeUIColorTokens.accent
            config.cornerStyle = .capsule
            config.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
            button.configuration = config
            button.accessibilityIdentifier = choice.id
            button.accessibilityTraits = choice.selected ? [.button, .selected] : .button
            button.isEnabled = enabled
            button.removeAction(identifiedBy: .init("select"), for: .touchUpInside)
            button.addAction(UIAction(identifier: .init("select")) { _ in choice.action() }, for: .touchUpInside)
        }
    }
}
