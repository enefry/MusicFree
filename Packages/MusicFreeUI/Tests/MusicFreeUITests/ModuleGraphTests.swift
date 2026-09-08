import LibraryFeature
import PlayerFeature
import PlaylistFeature
import SettingsFeature
import SwiftUI
import Testing
import UIKit

@MainActor
@Test("Active feature entry points compile")
func activeFeatureEntryPointsCompile() {
    let _: UIViewController.Type = LibraryHomeViewController.self
    let _: UIViewController.Type = LibraryCollectionsViewController.self
    let _: UIViewController.Type = LibraryCollectionDetailViewController.self
    let _: UIViewController.Type = PlayerMiniPlayerViewController.self
    let _: UIViewController.Type = PlayerNowPlayingViewController.self
    let _: UIViewController.Type = PlayerQueueViewController.self
    let _: UIViewController.Type = PlaylistListViewController.self
    let _: UIViewController.Type = PlaylistDetailViewController.self
    let _: UIViewController.Type = OnlineSourcesViewController.self
    let _: SettingsScene<EmptyView>.Type = SettingsScene<EmptyView>.self
}
