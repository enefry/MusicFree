import SwiftUI

public struct ArtworkView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale

    private let image: Image?
    private let accessibilityLabel: String
    private let isLoading: Bool
    private let placeholderSystemImage: String
    private let placeholderTitle: String?
    private let fillsAvailableWidth: Bool
    private let cornerRadius: CGFloat

    public init(
        image: Image? = nil,
        accessibilityLabel: String? = nil,
        isLoading: Bool = false,
        placeholderSystemImage: String = "music.note",
        placeholderTitle: String? = nil,
        fillsAvailableWidth: Bool = false,
        cornerRadius: CGFloat = MusicFreeLayoutMetrics.artworkCornerRadius
    ) {
        self.image = image
        self.accessibilityLabel = accessibilityLabel ?? "Artwork"
        self.isLoading = isLoading
        self.placeholderSystemImage = placeholderSystemImage
        self.placeholderTitle = placeholderTitle
        self.fillsAvailableWidth = fillsAvailableWidth
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let stateDescription {
                framedContent.accessibilityValue(Text(stateDescription))
            } else {
                framedContent
            }
        }
    }

    private var stateDescription: String? {
        if isLoading {
            return "Loading"
        }
        if image == nil {
            return "No artwork"
        }
        return nil
    }

    private var dimension: CGFloat {
        horizontalSizeClass == .regular
            ? MusicFreeLayoutMetrics.regularArtworkDimension
            : MusicFreeLayoutMetrics.compactArtworkDimension
    }

    @ViewBuilder
    private var artworkContent: some View {
        if isLoading {
            ProgressView()
                .tint(MusicFreeColorTokens.accent)
                .accessibilityHidden(true)
        } else if let image {
            image
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            ZStack {
                MusicFreeColorTokens.backgroundSecondary
                Image(systemName: placeholderSystemImage)
                    .font(MusicFreeTypographyTokens.screenTitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
//                    .overlay {
//                        Image(systemName: placeholderSystemImage)
//                            .font(MusicFreeTypographyTokens.screenTitle)
//                            // 1. 设置为阴影的颜色
//                            .foregroundStyle(Color.red.opacity(0.3))
//                            // 2. 模糊并发生偏移，形成阴影倾向
//                            .blur(radius: 2)
//                            .offset(x: 0, y: 3)
//                            // 3. 将阴影混合限制在原图标的非透明区域内
//                            .blendMode(.sourceAtop)
//                    }
//                    // 4. 确保超出图标边缘的阴影被裁剪掉
//                    .mask {
//                        Image(systemName: placeholderSystemImage)
//                            .font(MusicFreeTypographyTokens.screenTitle)
//                    }
            }
            .accessibilityHidden(true)
        }
    }

    private var framedContent: some View {
        Group {
            if fillsAvailableWidth {
                Color.clear
                    .aspectRatio(MusicFreeLayoutMetrics.artworkAspectRatio, contentMode: .fit)
                    .overlay {
                        artworkContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
            } else {
                artworkContent
                    .frame(width: dimension, height: dimension)
            }
        }
        .background(MusicFreeColorTokens.backgroundSecondary)
        .clipShape(
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.black.opacity(0.3), lineWidth: 1 / displayScale)
            .accessibilityHidden(true)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isImage)
    }
}
