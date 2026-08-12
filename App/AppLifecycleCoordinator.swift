import SwiftUI
import UIKit

enum AppLifecyclePhase: String, Equatable, Sendable {
    case active
    case inactive
    case background
}

enum AppLifecycleEvent: Equatable, Sendable {
    case scenePhaseChanged(AppLifecyclePhase)
    case applicationWillEnterForeground
    case applicationDidBecomeActive
    case applicationWillResignActive
    case applicationDidEnterBackground
}

@MainActor
final class AppLifecycleCoordinator {
    typealias EventHandler = @MainActor @Sendable (AppLifecycleEvent) -> Void

    private let notificationCenter: NotificationCenter
    private let eventHandler: EventHandler
    private var observerTokens: [NSObjectProtocol] = []

    private(set) var phase: AppLifecyclePhase = .inactive
    private(set) var lastEvent: AppLifecycleEvent?

    var isObserving: Bool { !observerTokens.isEmpty }

    init(
        notificationCenter: NotificationCenter = .default,
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.notificationCenter = notificationCenter
        self.eventHandler = eventHandler
    }

    func start() {
        guard observerTokens.isEmpty else { return }

        let notificationNames: [Notification.Name] = [
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification
        ]

        observerTokens = notificationNames.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let notificationName = notification.name.rawValue
                MainActor.assumeIsolated {
                    self?.handle(applicationNotificationName: notificationName)
                }
            }
        }
    }

    func stop() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll(keepingCapacity: true)
    }

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            handle(.active)
        case .inactive:
            handle(.inactive)
        case .background:
            handle(.background)
        @unknown default:
            handle(.inactive)
        }
    }

    func handle(_ phase: AppLifecyclePhase) {
        emit(.scenePhaseChanged(phase))
    }

    func handle(applicationNotification notification: Notification) {
        handle(applicationNotificationName: notification.name.rawValue)
    }

    private func handle(applicationNotificationName name: String) {
        switch name {
        case UIApplication.willEnterForegroundNotification.rawValue:
            emit(.applicationWillEnterForeground)
        case UIApplication.didBecomeActiveNotification.rawValue:
            emit(.applicationDidBecomeActive)
        case UIApplication.willResignActiveNotification.rawValue:
            emit(.applicationWillResignActive)
        case UIApplication.didEnterBackgroundNotification.rawValue:
            emit(.applicationDidEnterBackground)
        default:
            break
        }
    }

    private func emit(_ event: AppLifecycleEvent) {
        switch event {
        case let .scenePhaseChanged(phase):
            self.phase = phase
        case .applicationWillEnterForeground:
            phase = .inactive
        case .applicationDidBecomeActive:
            phase = .active
        case .applicationWillResignActive:
            phase = .inactive
        case .applicationDidEnterBackground:
            phase = .background
        }

        lastEvent = event
        eventHandler(event)
    }
}
