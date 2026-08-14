import DesignSystem
import SwiftUI
import Testing

@Test("String Catalog resolves English and Simplified Chinese")
func stringCatalogResolvesSupportedLanguages() {
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .english)) == "Albums"
    )
    #expect(
        String(localized: MusicFreeLocalization.resource("专辑", language: .chinese)) == "专辑"
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

@MainActor
@Test("DesignSystem components compose without business dependencies")
func baseComponentsCompose() {
    let artwork = ArtworkView(
        image: Image(systemName: "music.note"),
        accessibilityLabel: "Album artwork"
    )
    let gridArtwork = ArtworkView(
        accessibilityLabel: "Grid album artwork",
        fillsAvailableWidth: true
    )
    let playbackButton = PlaybackControlButton(
        systemImage: "play.fill",
        accessibilityLabel: "Play",
        action: {}
    )
    let row = MediaRow(
        title: "Track title",
        subtitle: "Artist name",
        artwork: Image(systemName: "music.note"),
        artworkAccessibilityLabel: "Track artwork",
        accessory: { playbackButton },
        action: {}
    )
    let empty = EmptyStateView(
        title: "Nothing here",
        message: "There is no content yet.",
        systemImage: "music.note.list",
        actionTitle: "Add content",
        action: {}
    )
    let loading = LoadingStateView(isLoading: true) {
        Text("Content")
    }
    let error = ErrorStateView(
        message: "The content could not be loaded.",
        retry: {}
    )
    let capability = CapabilitySection(isAvailable: false) {
        Text("Optional content")
    }
    let compatibility = MusicFreeEmptyState("Empty", systemImage: "music.note")

    _ = [
        AnyView(artwork),
        AnyView(gridArtwork),
        AnyView(playbackButton),
        AnyView(row),
        AnyView(empty),
        AnyView(loading),
        AnyView(error),
        AnyView(capability),
        AnyView(compatibility)
    ]
}
