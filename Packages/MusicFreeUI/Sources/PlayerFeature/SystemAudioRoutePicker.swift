import AVKit
import SwiftUI
import UIKit

/// Presents Apple's route picker so output selection stays owned by the system.
struct SystemAudioRoutePicker: UIViewRepresentable {
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    init(
        accessibilityLabel: String,
        accessibilityIdentifier: String = "player.routePicker"
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        update(view)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        update(uiView)
    }

    private func update(_ view: AVRoutePickerView) {
        view.tintColor = .secondaryLabel
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
    }
}
