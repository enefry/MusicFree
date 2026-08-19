import SwiftUI
import UIKit

struct CompactPlayerSlider: UIViewRepresentable {
    @Binding var value: Double

    let bounds: ClosedRange<Double>
    let accessibilityLabel: String
    let accessibilityValue: () -> String
    let minimumTrackColor: UIColor
    let maximumTrackColor: UIColor
    let thumbColor: UIColor
    let onEditingChanged: (Bool) -> Void

    init(
        value: Binding<Double>,
        in bounds: ClosedRange<Double>,
        accessibilityLabel: String,
        accessibilityValue: @escaping () -> String,
        minimumTrackColor: UIColor,
        maximumTrackColor: UIColor,
        thumbColor: UIColor,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        _value = value
        self.bounds = bounds
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.minimumTrackColor = minimumTrackColor
        self.maximumTrackColor = maximumTrackColor
        self.thumbColor = thumbColor
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        slider.value = Float(value)
        slider.isContinuous = true
        slider.setMinimumTrackImage(trackImage(color: minimumTrackColor), for: .normal)
        slider.setMaximumTrackImage(trackImage(color: maximumTrackColor), for: .normal)
        slider.setThumbImage(thumbImage(color: thumbColor), for: .normal)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingBegan(_:)),
            for: .touchDown
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        slider.accessibilityLabel = accessibilityLabel
        slider.accessibilityValue = accessibilityValue()
        slider.accessibilityTraits = [.adjustable]
        slider.setContentHuggingPriority(.required, for: .vertical)
        slider.setContentCompressionResistancePriority(.required, for: .vertical)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        if abs(Double(slider.value) - value) > 0.0001 {
            slider.setValue(Float(value), animated: false)
        }
        slider.accessibilityLabel = accessibilityLabel
        slider.accessibilityValue = accessibilityValue()
    }

    private func trackImage(color: UIColor) -> UIImage {
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
        )
    }

    private func thumbImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }

    final class Coordinator: NSObject {
        private var parent: CompactPlayerSlider

        init(_ parent: CompactPlayerSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: UISlider) {
            parent.value = Double(sender.value)
        }

        @objc func editingBegan(_: UISlider) {
            parent.onEditingChanged(true)
        }

        @objc func editingEnded(_: UISlider) {
            parent.onEditingChanged(false)
        }
    }
}
