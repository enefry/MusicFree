import Foundation
import MusicDomain
import UIKit

private let applicationLogger = MusicLogger(
    subsystem: MusicLogger.subsystem,
    category: "application"
)

private func prepareAutomaticImportPlaceholder() {
    applicationLogger.debug("preparing automatic import placeholder")
    guard let document = NSSearchPathForDirectoriesInDomains(
        .documentDirectory,
        .userDomainMask,
        true
    ).first else {
        return
    }

    let keepFile = "\(document)/\(AppDocumentsScanner.automaticImportPlaceholderFileName)"
    if !FileManager.default.fileExists(atPath: keepFile) {
        FileManager.default.createFile(atPath: keepFile, contents: nil)
    }
    applicationLogger.debug("automatic import placeholder is ready")
}

/// UIKit application entry point for the MusicFree application.
///
/// UIKit owns the application root. Settings is the only feature that may
/// still use SwiftUI, and it is hosted below the UIKit shell.
@main
@MainActor
final class MusicFreeAppDelegate: UIResponder, UIApplicationDelegate {
    let container: AppContainer

    override init() {
        #if DEBUG
            DebugNetworkCapture.configureFromPreferences()
            AppBVTFixtureSeeder.seedIfRequested()
        #endif
        container = AppContainer()
        super.init()
    }

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            prepareAutomaticImportPlaceholder()
        }
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = MusicFreeSceneDelegate.self
        return configuration
    }
}
