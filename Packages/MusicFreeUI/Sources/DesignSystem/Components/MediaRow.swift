import SwiftUI

public struct MediaRow<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let artwork: Image?
    private let showsArtwork: Bool
    private let artworkAccessibilityLabel: String?
    private let placeholderSystemImage: String
    private let accessory: Accessory
    private let action: (() -> Void)?

    public init(
        title: String,
        subtitle: String? = nil,
        artwork: Image? = nil,
        showsArtwork: Bool = true,
        artworkAccessibilityLabel: String? = nil,
        placeholderSystemImage: String = "music.note",
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.showsArtwork = showsArtwork
        self.artworkAccessibilityLabel = artworkAccessibilityLabel
        self.placeholderSystemImage = placeholderSystemImage
        self.accessory = accessory()
        self.action = action
    }

    public var body: some View {
        if let action {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: MusicFreeSpacingTokens.rowGap) {
            if showsArtwork {
                ArtworkView(
                    image: artwork,
                    accessibilityLabel: artworkAccessibilityLabel,
                    placeholderSystemImage: placeholderSystemImage,
                    placeholderTitle: title
                )
            }

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(title)
                    .font(MusicFreeTypographyTokens.rowTitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle {
                    Text(subtitle)
                        .font(MusicFreeTypographyTokens.rowSubtitle)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            accessory
        }
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.small)
        .frame(minHeight: rowMinimumHeight)
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(MusicFreeColorTokens.separator.opacity(0.72))
        .accessibilityElement(children: .contain)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var rowMinimumHeight: CGFloat {
        horizontalSizeClass == .regular
            ? MusicFreeLayoutMetrics.regularRowMinimumHeight
            : MusicFreeLayoutMetrics.compactRowMinimumHeight
    }
}
