import AppServices
import DesignSystem
import MediaSourceAPI
import MusicDomain
import SwiftUI

struct ArtworkResourceView: View {
    let artworkID: ArtworkID?
    let sourceID: MediaSourceID?
    let serving: (any ArtworkServing)?
    let accessibilityLabel: String
    let placeholderTitle: String?
    let fillsAvailableWidth: Bool
    let cornerRadius: CGFloat

    @StateObject private var loader = ArtworkImageLoader()

    init(
        artworkID: ArtworkID?,
        sourceID: MediaSourceID?,
        serving: (any ArtworkServing)?,
        accessibilityLabel: String,
        placeholderTitle: String? = nil,
        fillsAvailableWidth: Bool = false,
        cornerRadius: CGFloat = MusicFreeLayoutMetrics.artworkCornerRadius
    ) {
        self.artworkID = artworkID
        self.sourceID = sourceID
        self.serving = serving
        self.accessibilityLabel = accessibilityLabel
        self.placeholderTitle = placeholderTitle
        self.fillsAvailableWidth = fillsAvailableWidth
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ArtworkView(
            image: loader.image,
            accessibilityLabel: accessibilityLabel,
            placeholderTitle: placeholderTitle,
            fillsAvailableWidth: fillsAvailableWidth,
            cornerRadius: cornerRadius
        )
        .task(id: loadKey) {
            await loader.load(
                artworkID: artworkID,
                sourceID: sourceID,
                serving: serving
            )
        }
    }

    private var loadKey: String {
        "\(sourceID?.rawValue ?? ""):\(artworkID?.rawValue ?? "")"
    }
}
