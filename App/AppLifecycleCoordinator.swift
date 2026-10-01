import MediaSourceAPI
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
    private var mediaConversionScheduler: (any MediaConversionScheduling)?
    private(set) var conversionPolicyTask: Task<Void, Never>?
    private var applicationIsInBackground = false

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
        applicationIsInBackground = UIApplication.shared.applicationState == .background
        updateConversionPolicy()

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
        applicationIsInBackground = true
        updateConversionPolicy()
    }

    func setMediaConversionScheduler(_ scheduler: (any MediaConversionScheduling)?) {
        mediaConversionScheduler = scheduler
        applicationIsInBackground = UIApplication.shared.applicationState == .background
        updateConversionPolicy()
    }

    private func updateConversionPolicy() {
        guard let scheduler = mediaConversionScheduler else { return }
        let previous = conversionPolicyTask
        let isInBackground = applicationIsInBackground
        conversionPolicyTask = Task {
            await previous?.value
            await scheduler.updateApplicationInBackground(isInBackground)
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
            applicationIsInBackground = false
            updateConversionPolicy()
        case .applicationDidBecomeActive:
            phase = .active
            applicationIsInBackground = false
            updateConversionPolicy()
        case .applicationWillResignActive:
            phase = .inactive
        case .applicationDidEnterBackground:
            phase = .background
            applicationIsInBackground = true
            updateConversionPolicy()
        }

        lastEvent = event
        eventHandler(event)
    }
}
