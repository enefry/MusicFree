import LibraryFeature
import PlayerFeature
import PlaylistFeature
import SettingsFeature
import SwiftUI
import Testing

@MainActor
@Test("Feature entry points compile")
func featureEntryPointsCompile() {
    _ = LibraryScene()
    _ = PlayerScene()
    _ = MiniPlayerView()
    _ = PlaylistScene()
    _ = SettingsScene<EmptyView>()
}
