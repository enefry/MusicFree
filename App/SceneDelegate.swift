import DesignSystem
import UIKit

/// Owns the window for one scene while `AppContainer` stays app-owned.
@MainActor
final class MusicFreeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? MusicFreeAppDelegate
        else {
            return
        }

        let rootViewController = RootViewController.makeRootViewController(
            container: appDelegate.container
        )
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = AppUserInterfacePreferences.appearance
            .userInterfaceStyle
        window.tintColor = MusicFreeUIColorTokens.accent
        window.rootViewController = rootViewController
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? MusicFreeAppDelegate else {
            return
        }
        appDelegate.container.lifecycleCoordinator.handle(.active)
        (window?.rootViewController as? RootViewController)?.sceneDidBecomeActive()
    }

    func sceneWillResignActive(_: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? MusicFreeAppDelegate else {
            return
        }
        (window?.rootViewController as? RootViewController)?.sceneWillResignActive()
        appDelegate.container.lifecycleCoordinator.handle(.inactive)
    }

    func sceneDidEnterBackground(_: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? MusicFreeAppDelegate else {
            return
        }
        (window?.rootViewController as? RootViewController)?.sceneWillResignActive()
        // Backgrounding is not an explicit audition stop. The user may only
        // be switching apps briefly; retain the queue and current position.
        // Audio interruptions are handled by OnlineAuditionCoordinator and
        // pause the engine without clearing the session.
        appDelegate.container.lifecycleCoordinator.handle(.background)
    }

    func sceneDidDisconnect(_: UIScene) {
        (window?.rootViewController as? RootViewController)?.sceneDidDisconnect()
        window = nil
    }
}
