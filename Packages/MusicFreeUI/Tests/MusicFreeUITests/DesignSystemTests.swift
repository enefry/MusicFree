import DesignSystem
import Testing
import UIKit

@Test("String Catalog resolves all six supported languages")
func stringCatalogResolvesSupportedLanguages() {
    #expect(
        MusicFreeLanguage.allCases == [.english, .chinese, .french, .german, .spanish, .japanese]
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .english)) == "Albums"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .chinese)) == "专辑"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .french)) == "Albums"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .german)) == "Alben"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .spanish)) == "Álbumes"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .japanese)) == "アルバム"
    )
}

@Test("Appearance options expose system, light, and dark schemes")
func appearanceOptionsMapToColorSchemes() {
    #expect(MusicFreeAppearance.allCases == [.system, .light, .dark])
    #expect(MusicFreeAppearance.system.colorScheme == nil)
    #expect(MusicFreeAppearance.light.colorScheme == .light)
    #expect(MusicFreeAppearance.dark.colorScheme == .dark)
    #expect(MusicFreeAppearance.system.title == "System")
    #expect(MusicFreeAppearance.light.title == "Light")
    #expect(MusicFreeAppearance.dark.title == "Dark")
}

@Test("DesignSystem exposes semantic tokens and stable layout metrics")
func semanticTokensAndLayoutMetricsAreAvailable() {
    #expect(MusicFreeLayoutMetrics.minimumHitTarget == 44)
    #expect(MusicFreeLayoutMetrics.artworkAspectRatio == 1)
    #expect(MusicFreeSpacingTokens.contentInset == MusicFreeSpacingTokens.large)
    #expect(MusicFreeSpacingTokens.controlGap == MusicFreeSpacingTokens.small)

    _ = MusicFreeColorTokens.backgroundPrimary
    _ = MusicFreeColorTokens.foregroundSecondary
    _ = MusicFreeColorTokens.accent
    _ = MusicFreeTypographyTokens.body
    _ = MusicFreeTypographyTokens.rowTitle
}

@Test("UIKit adapters keep semantic colors, typography, and layout metrics aligned")
func uikitTokenAdaptersStayAligned() {
    let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
    let resolvedBackground = MusicFreeUIColorTokens.backgroundPrimary.resolvedColor(with: darkTraits)
    let resolvedAccent = MusicFreeUIColorTokens.accent.resolvedColor(with: darkTraits)

    #expect(resolvedBackground.cgColor.numberOfComponents > 0)
    #expect(resolvedAccent.cgColor.numberOfComponents > 0)
    #expect(MusicFreeUIFontTokens.rowTitle.pointSize > 0)
    #expect(MusicFreeUIFontTokens.controlLabel.pointSize > 0)
    #expect(MusicFreeSpacingTokens.contentInsets.leading == MusicFreeSpacingTokens.contentInset)
    #expect(MusicFreeSpacingTokens.rowInsets.top == MusicFreeSpacingTokens.small)
    #expect(MusicFreeLayoutMetrics.minimumHitTargetSize == CGSize(width: 44, height: 44))
    #expect(
        MusicFreeLayoutMetrics.artworkDimension(for: UITraitCollection(horizontalSizeClass: .regular))
            == MusicFreeLayoutMetrics.regularArtworkDimension
    )
}

@Test("Accent color storage normalizes hex values and bridges UIKit colors")
func accentColorStorageNormalizesHexValues() {
    #expect(MusicFreeAccentColorStore.normalizedHex("#12abef") == "12ABEF")
    #expect(
        MusicFreeAccentColorStore.normalizedHex("invalid")
            == MusicFreeAccentColorStore.defaultHex
    )

    let color = UIColor(red: 18 / 255, green: 171 / 255, blue: 239 / 255, alpha: 1)
    #expect(MusicFreeAccentColorStore.hexString(for: color) == "12ABEF")
    #expect(
        MusicFreeAccentColorStore.hexString(
            for: MusicFreeAccentColorStore.onAccentUIColor(forHex: "F5F5F5")
        ) == "000000"
    )
    #expect(
        MusicFreeAccentColorStore.hexString(
            for: MusicFreeAccentColorStore.onAccentUIColor(forHex: "FF2D55")
        ) == "000000"
    )
}

@Test("UIKit accent token resolves the persisted color dynamically")
func uikitAccentTokenTracksPersistedColor() {
    let defaults = UserDefaults.standard
    let originalValue = defaults.string(forKey: MusicFreeAccentColorStore.storageKey)
    defer {
        if let originalValue {
            defaults.set(originalValue, forKey: MusicFreeAccentColorStore.storageKey)
        } else {
            defaults.removeObject(forKey: MusicFreeAccentColorStore.storageKey)
        }
    }

    MusicFreeAccentColorStore.setHexValue("12ABEF")
    let blueAccent = MusicFreeUIColorTokens.accent.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light)
    )
    #expect(MusicFreeAccentColorStore.hexString(for: blueAccent) == "12ABEF")

    MusicFreeAccentColorStore.setHexValue("F5F5F5")
    let lightAccent = MusicFreeUIColorTokens.accent.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light)
    )
    #expect(MusicFreeAccentColorStore.hexString(for: lightAccent) == "F5F5F5")
}

@MainActor
@Test("UIKit components expose stable accessibility and activation surfaces")
func uikitComponentsExposeStableContracts() {
    let artwork = MusicFreeUIKitArtworkView(
        accessibilityLabel: "Album artwork",
        placeholderTitle: "Album"
    )
    #expect(artwork.isAccessibilityElement)
    #expect(artwork.accessibilityLabel == "Album artwork")
    #expect(artwork.accessibilityTraits.contains(.image))
    #expect(artwork.accessibilityValue == "No artwork, Album")

    var didActivate = false
    let row = MusicFreeUIKitMediaRowView(
        title: "Track title",
        subtitle: "Artist name",
        onActivate: { didActivate = true }
    )
    row.activationHint = "Opens track"
    row.activate()
    #expect(didActivate)
    #expect(row.accessibilityLabel == "Track title")
    #expect(row.accessibilityValue == "Artist name")
    #expect(row.accessibilityHint == "Opens track")
    #expect(row.accessibilityTraits.contains(.button))

    let header = MusicFreeUIKitSectionHeaderView(title: "Albums", actionTitle: "See All")
    #expect(header.subviews.isEmpty == false)

    let empty = MusicFreeUIKitEmptyStateView(title: "Nothing here")
    let error = MusicFreeUIKitErrorStateView(message: "Try again")
    #expect(empty.accessibilityElements?.isEmpty == false)
    #expect(error.accessibilityElements?.isEmpty == false)

    let loading = MusicFreeUIKitLoadingStateView()
    #expect(loading.isLoading)
    loading.isLoading = false
    #expect(loading.isHidden)

    let playback = MusicFreeUIKitPlaybackControlButton(
        systemImage: "play.fill",
        accessibilityLabel: "Play",
        accessibilityValue: "Ready"
    )
    #expect(playback.accessibilityLabel == "Play")
    #expect(playback.accessibilityTraits.contains(.button))
    playback.isLoading = true
    #expect(playback.accessibilityValue == "Loading")
    playback.isLoading = false
    #expect(playback.accessibilityValue == "Ready")

    let miniPlayer = MusicFreeUIKitMiniPlayerView(title: "Track title", subtitle: "Artist name")
    #expect(miniPlayer.accessibilityLabel == "Track title")
    #expect(miniPlayer.accessibilityValue == "Artist name")
}

@MainActor
@Test("Artwork remains visible while a replacement image is loading")
func artworkRemainsVisibleWhileLoading() {
    let artwork = MusicFreeUIKitArtworkView(image: UIImage())

    artwork.isLoading = true

    let renderedImage = artwork.subviews
        .compactMap { $0 as? UIImageView }
        .first?
        .image
    #expect(renderedImage != nil)
    #expect(artwork.accessibilityValue == "Loading")
}
