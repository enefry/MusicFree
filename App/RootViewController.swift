import AppServices
import Combine
import DesignSystem
import LibraryAPI
import LibraryFeature
import MusicDomain
import OnlineSourceAdapter
import PlaybackAPI
import PlayerFeature
import PlaylistFeature
import SettingsFeature
import UIKit

/// UIKit root shell for all production features.
///
/// Settings is intentionally hosted by SwiftUI below this controller. Every
/// other route is rendered by native UIKit view controllers.
@MainActor
final class RootViewController: UIViewController {
    private static let automaticDocumentsScanDelay: Duration = .seconds(4)
    private static let contentTransitionDuration: TimeInterval = 0.24

    private enum ApplicationLayout: Equatable {
        case compact
        case regular
    }

    private struct RegularRouteColumns {
        let contentNavigationController: RootNavigationController
        let detailNavigationController: RootNavigationController
    }

    let container: AppContainer

    private let sceneID = UUID()
    private var startupObservation: AnyCancellable?
    private var userInterfacePreferencesObservation: AnyCancellable?
    private var startupTask: Task<Void, Never>?
    private var automaticDocumentsScanTask: Task<Void, Never>?
    private var contentViewController: UIViewController?
    private var selectedRoute: AppRouter.Route
    private var lastRenderedStartupState: AppStartupState?
    private var applicationSurfaceServicesID: ObjectIdentifier?
    private var compactSurfaceController: UIViewController?
    private var compactTabBarController: RootTabBarController?
    private var regularSurfaceController: UIViewController?
    private var regularSplitViewController: UISplitViewController?
    private var regularSidebarController: RootSidebarViewController?
    private var regularRouteColumns: [AppRouter.Route: RegularRouteColumns] = [:]
    private var renderedApplicationLayout: ApplicationLayout?
    private var selectedSettingsDestination: SettingsDestination = .general
    private var regularSettingsDestination: SettingsDestination?
    private var settingsSceneModel: SettingsSceneModel?
    private var settingsSceneModelServicesID: ObjectIdentifier?
    private var hasRegisteredScene = false
    private var libraryViewModel: LibraryViewModel?
    private var libraryViewModelServicesID: ObjectIdentifier?
    private var onlineSourcesModel: OnlineSourcesSceneModel?
    private var onlineSourcesModelServicesID: ObjectIdentifier?
    private var fallbackPlayerController: PlayerNowPlayingViewController?
    private var appliedAppearance: MusicFreeAppearance?
    private var appliedLanguage: MusicFreeLanguage?
    private var appliedAccentColor: String?

    init(container: AppContainer) {
        self.container = container
        selectedRoute = container.router.selectedRoute
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "root"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func makeRootViewController(container: AppContainer) -> UIViewController {
        return RootViewController(container: container)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyUserInterfacePreferences(rebuildSurface: false)
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "app.root"

        startupObservation = container.$startupState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderCurrentSurface()
            }

        userInterfacePreferencesObservation = NotificationCenter.default.publisher(
            for: AppUserInterfacePreferences.didChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.applyUserInterfacePreferences(rebuildSurface: true)
        }

        renderCurrentSurface()
        startServicesIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        registerSceneIfNeeded()
        startServicesIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass else {
            return
        }
        renderCurrentSurface()
    }

    deinit {
        startupTask?.cancel()
        automaticDocumentsScanTask?.cancel()
    }

    private func applyUserInterfacePreferences(rebuildSurface: Bool) {
        let appearance = AppUserInterfacePreferences.appearance
        let language = AppUserInterfacePreferences.language
        let accentColor = AppUserInterfacePreferences.accentColorHex
        let didChange = appliedAppearance != appearance
            || appliedLanguage != language
            || appliedAccentColor != accentColor

        appliedAppearance = appearance
        appliedLanguage = language
        appliedAccentColor = accentColor
        overrideUserInterfaceStyle = appearance.userInterfaceStyle
        view.window?.overrideUserInterfaceStyle = appearance.userInterfaceStyle
        view.window?.tintColor = MusicFreeUIColorTokens.accent
        view.tintColor = MusicFreeUIColorTokens.accent
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityValue = "language=\(language.rawValue);appearance=\(appearance.rawValue)"

        guard rebuildSurface, didChange else { return }
        refreshLocalizedNavigationChrome()
    }

    /// Called by the scene delegate instead of using `viewDidDisappear`.
    /// Presentations and size-class changes can remove a child surface while
    /// the scene is still alive.
    func sceneDidDisconnect() {
        cancelAutomaticDocumentsScan()
        guard hasRegisteredScene else { return }
        hasRegisteredScene = false
        container.sceneDidDisappear(sceneID)
    }

    /// Defers automatic Documents work until the fourth second after the scene
    /// becomes active, keeping filesystem enumeration and import preparation
    /// away from the launch and foreground-transition critical paths.
    func sceneDidBecomeActive() {
        scheduleAutomaticDocumentsScan()
    }

    func sceneWillResignActive() {
        cancelAutomaticDocumentsScan()
    }

    private func registerSceneIfNeeded() {
        guard !hasRegisteredScene else { return }
        hasRegisteredScene = true
        container.sceneDidAppear(sceneID)
    }

    private func renderCurrentSurface() {
        guard isViewLoaded else { return }

        if container.startupState.isUsable,
           let services = container.serviceContainer {
            prepareApplicationSurfaceCache(for: services)
            let nextLayout = applicationLayout
            synchronizeApplicationSurfaceIfNeeded(
                for: nextLayout,
                services: services
            )
            let nextController = makeApplicationSurface(services: services)
            if contentViewController !== nextController {
                install(nextController)
            }
            renderedApplicationLayout = nextLayout
            lastRenderedStartupState = container.startupState
            return
        }

        guard !(contentViewController is StartupViewController)
            || lastRenderedStartupState != container.startupState
        else {
            return
        }
        let nextController = StartupViewController(
            state: container.startupState,
            onRetry: { [weak self] in self?.retryStartup() }
        )
        install(nextController)
        lastRenderedStartupState = container.startupState
    }

    private func install(_ nextController: UIViewController) {
        let previousController = contentViewController
        guard previousController !== nextController else { return }

        let shouldAnimate = previousController != nil && !UIAccessibility.isReduceMotionEnabled

        let replaceControllers = {
            self.addChild(nextController)
            nextController.view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(nextController.view)
            NSLayoutConstraint.activate([
                nextController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                nextController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                nextController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                nextController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            nextController.didMove(toParent: self)
            self.contentViewController = nextController

            previousController?.willMove(toParent: nil)
            previousController?.view.removeFromSuperview()
            previousController?.removeFromParent()
        }
        guard shouldAnimate else {
            replaceControllers()
            return
        }

        UIView.transition(
            with: view,
            duration: Self.contentTransitionDuration,
            options: [.transitionCrossDissolve, .curveEaseInOut, .allowUserInteraction],
            animations: replaceControllers
        )
    }

    private func makeApplicationSurface(services: AppServiceContainer) -> UIViewController {
        if traitCollection.horizontalSizeClass == .regular {
            if regularSurfaceController == nil {
                regularSurfaceController = makeRegularSplitView(services: services)
            }
            if let splitViewController = regularSplitViewController {
                installRegularColumns(
                    for: selectedRoute,
                    in: splitViewController,
                    services: services
                )
            }
            return regularSurfaceController!
        }
        if compactSurfaceController == nil {
            compactSurfaceController = makeCompactTabBar(services: services)
        }
        compactTabBarController?.selectRoute(selectedRoute)
        return compactSurfaceController!
    }

    private func prepareApplicationSurfaceCache(for services: AppServiceContainer) {
        let servicesID = ObjectIdentifier(services)
        guard applicationSurfaceServicesID != servicesID else { return }

        applicationSurfaceServicesID = servicesID
        compactSurfaceController = nil
        compactTabBarController = nil
        regularSurfaceController = nil
        regularSplitViewController = nil
        regularSidebarController = nil
        regularRouteColumns.removeAll()
        renderedApplicationLayout = nil
        regularSettingsDestination = nil
        settingsSceneModel = nil
        settingsSceneModelServicesID = nil
    }

    private var applicationLayout: ApplicationLayout {
        traitCollection.horizontalSizeClass == .regular ? .regular : .compact
    }

    private func synchronizeApplicationSurfaceIfNeeded(
        for nextLayout: ApplicationLayout,
        services: AppServiceContainer
    ) {
        guard let previousLayout = renderedApplicationLayout,
              previousLayout != nextLayout
        else {
            return
        }

        switch (previousLayout, nextLayout) {
        case (.compact, .regular):
            handoffCompactSurfaceToRegular(services: services)
        case (.regular, .compact):
            handoffRegularSurfaceToCompact(services: services)
        case (.compact, .compact), (.regular, .regular):
            break
        }
    }

    /// Moves the compact route stacks into the regular shell instead of
    /// rebuilding pages from only the selected route. The same controller
    /// instances retain their navigation stack, loaded data and scroll
    /// offsets while their container changes from a tab navigation controller
    /// to the regular content/detail columns.
    private func handoffCompactSurfaceToRegular(services: AppServiceContainer) {
        guard compactTabBarController != nil else { return }
        if regularSurfaceController == nil {
            regularSurfaceController = makeRegularSplitView(services: services)
        }

        let servicesID = ObjectIdentifier(services)
        for route in compactRoutes where route != .settings {
            guard let compactNavigationController = compactNavigationController(for: route),
                  let contentController = compactNavigationController.viewControllers.first,
                  !isNavigationHandoffPlaceholder(contentController)
            else {
                continue
            }

            let detailControllers = compactNavigationController.viewControllers
                .dropFirst()
                .filter { !isNavigationHandoffPlaceholder($0) }
            let columns = regularColumns(for: route, services: services)
            let detailInstaller: (UIViewController) -> Void = { [weak self] controller in
                self?.setRegularDetailColumn(
                    controller,
                    for: route,
                    servicesID: servicesID
                )
            }
            // Detach the compact stack before assigning its controllers to the
            // regular columns. UIKit navigation controllers cannot safely own
            // the same child at the same time; doing this first avoids a
            // transient double-parent relationship during a size-class change.
            compactNavigationController.setViewControllers(
                [makeNavigationHandoffPlaceholder()],
                animated: false
            )
            configureRegularContentController(
                contentController,
                route: route,
                services: services,
                onSelectDetail: detailInstaller
            )
            columns.contentNavigationController.setViewControllers(
                [contentController],
                animated: false
            )
            columns.detailNavigationController.setViewControllers(
                detailControllers.isEmpty
                    ? [makeRegularInitialDetailViewController(
                        route: route,
                        services: services
                    )]
                    : Array(detailControllers),
                animated: false
            )
        }

        if selectedRoute == .settings,
           let columns = regularRouteColumns[.settings] {
            (columns.contentNavigationController.viewControllers.first
                as? SettingsCategoriesViewController)?.selectDestination(
                selectedSettingsDestination
            )
            // Keep the existing regular detail host when compact did not
            // change the selected category. Recreating it on every width
            // transition would discard its nested Settings navigation and
            // scroll position.
            synchronizeRegularSettingsDetail(services: services)
        }
    }

    /// Moves the regular content/detail controllers back into the compact
    /// route stacks. This is the reverse of the handoff above, so a later
    /// Stage Manager/window-size transition restores the exact same pages
    /// rather than returning to each route's initial root.
    private func handoffRegularSurfaceToCompact(services: AppServiceContainer) {
        guard regularSplitViewController != nil else { return }
        let compactSettingsDestination = selectedSettingsDestination == .general
            ? nil
            : selectedSettingsDestination
        if compactSurfaceController == nil {
            compactSurfaceController = makeCompactTabBar(
                services: services,
                initialSettingsDestination: compactSettingsDestination
            )
        }

        for route in compactRoutes where route != .settings {
            guard let columns = regularRouteColumns[route],
                  let contentController = columns.contentNavigationController
                  .viewControllers.first,
                  !isNavigationHandoffPlaceholder(contentController),
                  let compactNavigationController = compactNavigationController(for: route)
            else {
                continue
            }

            let detailControllers = columns.detailNavigationController.viewControllers
                .filter { !isNavigationHandoffPlaceholder($0) }
            configureCompactContentController(
                contentController,
                route: route,
                services: services
            )
            // Release the regular columns' ownership before restoring the
            // original compact stack, for the same reason as the forward
            // handoff above.
            columns.contentNavigationController.setViewControllers(
                [makeNavigationHandoffPlaceholder()],
                animated: false
            )
            columns.detailNavigationController.setViewControllers(
                [makeNavigationHandoffPlaceholder()],
                animated: false
            )
            compactNavigationController.setViewControllers(
                [contentController] + detailControllers,
                animated: false
            )
        }

        if let settingsController = compactSettingsHostingController() {
            settingsController.updateNavigationDestination(compactSettingsDestination)
        }
    }

    private func compactNavigationController(
        for route: AppRouter.Route
    ) -> RootNavigationController? {
        compactTabBarController?.rootViewController(for: route)
            as? RootNavigationController
    }

    private func isNavigationHandoffPlaceholder(
        _ controller: UIViewController
    ) -> Bool {
        controller is NavigationHandoffPlaceholderViewController
    }

    private func makeNavigationHandoffPlaceholder() -> UIViewController {
        NavigationHandoffPlaceholderViewController()
    }

    private func selectRoute(_ route: AppRouter.Route) {
        selectedRoute = route
        container.selectRoute(route)
        compactTabBarController?.selectRoute(route)
        regularSidebarController?.selectRoute(route)
        guard let splitViewController = regularSplitViewController,
              let services = container.serviceContainer,
              applicationSurfaceServicesID == ObjectIdentifier(services)
        else {
            return
        }
        installRegularColumns(
            for: route,
            in: splitViewController,
            services: services
        )
        if route == .settings {
            synchronizeRegularSettingsDetail(services: services)
        }
    }

    private func updateSelectedSettingsDestination(_ destination: SettingsDestination?) {
        let destination = destination ?? .general
        selectedSettingsDestination = destination
        (regularRouteColumns[.settings]?.contentNavigationController.viewControllers.first
            as? SettingsCategoriesViewController)?.selectDestination(destination)
    }

    private func compactSettingsHostingController() -> SettingsHostingController? {
        compactTabBarController?.rootViewController(for: .settings)
            as? SettingsHostingController
    }

    private func refreshLocalizedNavigationChrome() {
        compactTabBarController?.reloadLocalizedContent()
        regularSidebarController?.reloadLocalizedContent()
        if let settingsColumns = regularRouteColumns[.settings],
           let settingsController = settingsColumns.contentNavigationController
           .viewControllers.first as? SettingsCategoriesViewController {
            settingsController.reloadLocalizedContent()
        }
        compactTabBarController?.applyAccentColor()
        regularRouteColumns.values.forEach { columns in
            columns.contentNavigationController.applyAccentColor()
            columns.detailNavigationController.applyAccentColor()
        }
        refreshAccentColor(in: view)
    }

    private func refreshAccentColor(in root: UIView) {
        root.setNeedsDisplay()
        root.setNeedsLayout()
        if let button = root as? UIButton {
            button.setNeedsUpdateConfiguration()
        }
        root.subviews.forEach { refreshAccentColor(in: $0) }
    }

    private func makeCompactTabBar(
        services: AppServiceContainer,
        initialSettingsDestination: SettingsDestination? = nil
    ) -> UIViewController {
        // Keep the tab bar controller as the surface root.  Wrapping it in a
        // second container makes iOS 26 account for the bottom accessory in
        // both the tab-bar safe area and the parent container, leaving a large
        // blank tail below the visual tab bar.
        let routes = compactRoutes
        let tabBarController = RootTabBarController(
            playbackServing: services.playbackServing,
            audioServing: services.playbackAudioServing,
            artworkServing: services.artworkServing,
            auditionServing: services.onlineAudition,
            onPresentPlayer: { [weak self] in
                self?.presentPlayer(using: services)
            }
        )
        let routeControllers = routes.map { route in
            // Settings owns its SwiftUI NavigationStack and is placed directly
            // in the tab bar. All other routes are native UIKit navigation
            // controllers.
            let controller: UIViewController
            switch route {
            case .settings:
                controller = SettingsHostingController(
                    container: container,
                    services: services,
                    model: makeSettingsSceneModel(services: services),
                    initialDestination: initialSettingsDestination,
                    onNavigationChange: { [weak self] destination in
                        self?.updateSelectedSettingsDestination(destination)
                    }
                )
            case .library, .playlists, .onlineSources:
                let navigationController = RootNavigationController(
                    rootViewController: makeFeatureViewController(route: route, services: services)
                )
                navigationController.navigationBar.prefersLargeTitles = true
                controller = navigationController
            }

            controller.view.accessibilityIdentifier = "app.tab.\(route.rawValue)"
            return (route: route, controller: controller)
        }
        let routeDescriptors = routeControllers.map { route, controller in
            RootTabDescriptor(
                identifier: route.rawValue,
                title: route.title,
                systemImage: route.systemImage,
                controller: controller,
                kind: .standard
            )
        }

        let searchController = makeLibrarySearchViewController(services: services)
        let searchNavigationController = RootNavigationController(
            rootViewController: searchController
        )
        searchNavigationController.navigationBar.prefersLargeTitles = false
        searchNavigationController.view.accessibilityIdentifier = "app.tab.librarySearch"
        let searchDescriptor = RootTabDescriptor(
            identifier: RootTabDescriptor.searchIdentifier,
            title: L("library.search.tabTitle"),
            systemImage: "magnifyingglass",
            controller: searchNavigationController,
            kind: .search
        )

        tabBarController.installTabs(
            routeDescriptors + [searchDescriptor],
            selectedIdentifier: selectedRoute.rawValue
        )
        tabBarController.onSelectRoute = { [weak self] route in
            self?.selectRoute(route)
        }
        tabBarController.view.accessibilityIdentifier = "app.tabBar"
        compactTabBarController = tabBarController
        return tabBarController
    }

    /// The compact primary navigation mirrors the product reference with all
    /// four first-class routes. Online Sources is intentionally not hidden in
    /// the default UIKit shell: it is a user-facing destination and must stay
    /// reachable without a debug-only launch argument.
    private var compactRoutes: [AppRouter.Route] {
        AppRouter.Route.allCases
    }

    private func makeRegularSplitView(services: AppServiceContainer) -> UIViewController {
        let splitViewController = UISplitViewController(style: .tripleColumn)
        splitViewController.preferredDisplayMode = .twoBesideSecondary
        splitViewController.preferredSplitBehavior = .tile
        splitViewController.presentsWithGesture = true

        let sidebar = RootSidebarViewController(
            routes: AppRouter.Route.allCases,
            selectedRoute: selectedRoute
        )
        let sidebarNavigationController = RootNavigationController(rootViewController: sidebar)
        sidebarNavigationController.navigationBar.prefersLargeTitles = true
        sidebarNavigationController.view.accessibilityIdentifier = "app.sidebar"
        regularSplitViewController = splitViewController
        regularSidebarController = sidebar

        splitViewController.setViewController(sidebarNavigationController, for: .primary)
        installRegularColumns(
            for: selectedRoute,
            in: splitViewController,
            services: services
        )
        splitViewController.view.accessibilityIdentifier = "app.splitView"

        sidebar.onSelectRoute = { [weak self] route in
            self?.selectRoute(route)
        }
        return RootSurfaceContainerViewController(
            contentViewController: splitViewController,
            services: services,
            compactTabBarController: nil,
            onPresentPlayer: { [weak self] in
                self?.presentPlayer(using: services)
            }
        )
    }

    private func installRegularColumns(
        for route: AppRouter.Route,
        in splitViewController: UISplitViewController,
        services: AppServiceContainer
    ) {
        let columns = regularColumns(for: route, services: services)
        if splitViewController.viewController(for: .supplementary)
            !== columns.contentNavigationController {
            splitViewController.setViewController(
                columns.contentNavigationController,
                for: .supplementary
            )
        }
        if splitViewController.viewController(for: .secondary)
            !== columns.detailNavigationController {
            splitViewController.setViewController(
                columns.detailNavigationController,
                for: .secondary
            )
        }
    }

    private func setRegularDetailColumn(
        _ controller: UIViewController,
        for route: AppRouter.Route,
        servicesID: ObjectIdentifier
    ) {
        guard applicationSurfaceServicesID == servicesID,
              let columns = regularRouteColumns[route]
        else {
            return
        }
        columns.detailNavigationController.setViewControllers(
            [controller],
            animated: false
        )
        guard selectedRoute == route,
              let splitViewController = regularSplitViewController,
              splitViewController.viewController(for: .secondary)
              !== columns.detailNavigationController
        else {
            return
        }
        splitViewController.setViewController(
            columns.detailNavigationController,
            for: .secondary
        )
    }

    private func synchronizeRegularSettingsDetail(
        services: AppServiceContainer
    ) {
        guard let columns = regularRouteColumns[.settings],
              regularSettingsDestination != selectedSettingsDestination
        else {
            return
        }
        if let settingsController = columns.detailNavigationController
            .viewControllers.first as? SettingsHostingController {
            settingsController.updateNavigationDestination(selectedSettingsDestination)
        } else {
            columns.detailNavigationController.setViewControllers(
                [makeSettingsDetailViewController(
                    destination: selectedSettingsDestination,
                    services: services
                )],
                animated: false
            )
        }
        regularSettingsDestination = selectedSettingsDestination
    }

    private func regularColumns(
        for route: AppRouter.Route,
        services: AppServiceContainer
    ) -> RegularRouteColumns {
        if let columns = regularRouteColumns[route] {
            return columns
        }

        let servicesID = ObjectIdentifier(services)
        let detailInstaller: (UIViewController) -> Void = { [weak self] controller in
            self?.setRegularDetailColumn(
                controller,
                for: route,
                servicesID: servicesID
            )
        }
        let contentController = makeRegularContentViewController(
            route: route,
            services: services,
            onSelectDetail: detailInstaller
        )
        let columns = RegularRouteColumns(
            contentNavigationController: makeRegularColumnNavigationController(
                rootViewController: contentController,
                accessibilityIdentifier: "app.secondaryColumn"
            ),
            detailNavigationController: makeRegularColumnNavigationController(
                rootViewController: makeRegularInitialDetailViewController(
                    route: route,
                    services: services
                ),
                accessibilityIdentifier: "app.detailColumn"
            )
        )
        regularRouteColumns[route] = columns
        if route == .settings, regularSettingsDestination == nil {
            regularSettingsDestination = selectedSettingsDestination
        }
        return columns
    }

    private func makeRegularColumnNavigationController(
        rootViewController: UIViewController,
        accessibilityIdentifier: String
    ) -> RootNavigationController {
        let navigationController = RootNavigationController(
            rootViewController: rootViewController
        )
        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.view.accessibilityIdentifier = accessibilityIdentifier
        return navigationController
    }

    private func makeRegularContentViewController(
        route: AppRouter.Route,
        services: AppServiceContainer,
        onSelectDetail: @escaping (UIViewController) -> Void
    ) -> UIViewController {
        switch route {
        case .library:
            let controller = makeLibraryHomeViewController(services: services)
            configureRegularContentController(
                controller,
                route: route,
                services: services,
                onSelectDetail: onSelectDetail
            )
            return controller
        case .playlists:
            let controller = PlaylistListViewController(
                playlistServing: services.playlistServing,
                playbackServing: services.playbackServing,
                libraryServing: services.libraryServing,
                artworkServing: services.artworkServing
            )
            configureRegularContentController(
                controller,
                route: route,
                services: services,
                onSelectDetail: onSelectDetail
            )
            return controller
        case .onlineSources:
            let controller = makeOnlineSourcesViewController(services: services)
            configureRegularContentController(
                controller,
                route: route,
                services: services,
                onSelectDetail: onSelectDetail
            )
            return controller
        case .settings:
            let controller = makeRegularSettingsCategoriesViewController(
                selectedDestination: selectedSettingsDestination,
                onSelectDestination: onSelectDetailSettingsDestination(
                    services: services,
                    onSelectDetail: onSelectDetail
                )
            )
            return controller
        }
    }

    private func onSelectDetailSettingsDestination(
        services: AppServiceContainer,
        onSelectDetail: @escaping (UIViewController) -> Void
    ) -> (SettingsDestination) -> Void {
        { [weak self] destination in
            guard let self else { return }
            self.updateSelectedSettingsDestination(destination)
            if let settingsController = self.regularRouteColumns[.settings]?
                .detailNavigationController.viewControllers.first as? SettingsHostingController {
                settingsController.updateNavigationDestination(destination)
                self.regularSettingsDestination = destination
            } else {
                self.regularSettingsDestination = destination
                onSelectDetail(self.makeSettingsDetailViewController(
                    destination: destination,
                    services: services
                ))
            }
        }
    }

    private func configureRegularContentController(
        _ controller: UIViewController,
        route: AppRouter.Route,
        services: AppServiceContainer,
        onSelectDetail: @escaping (UIViewController) -> Void
    ) {
        switch route {
        case .library:
            guard let controller = controller as? LibraryHomeViewController else {
                return
            }
            controller.onSelectSection = { [weak self] section in
                guard let self else { return }
                onSelectDetail(self.makeLibrarySectionViewController(
                    section: section,
                    services: services
                ))
            }
            controller.onSelectAlbum = { [weak self] albumID in
                guard let self else { return }
                let title = self.libraryAlbumTitle(for: albumID)
                onSelectDetail(self.makeLibraryCollectionDetailViewController(
                    kind: .album(albumID),
                    title: title,
                    services: services
                ))
            }
            controller.onSelectTrack = { [weak self] trackID in
                guard let self else { return }
                onSelectDetail(self.makeLibraryTrackDetailViewController(
                    trackID: trackID,
                    services: services
                ))
            }
        case .playlists:
            guard let controller = controller as? PlaylistListViewController else {
                return
            }
            controller.onSelectPlaylist = { [weak self] playlist in
                guard let self else { return }
                onSelectDetail(self.makePlaylistDetailViewController(
                    playlist: playlist,
                    services: services
                ))
            }
        case .onlineSources:
            (controller as? OnlineSourcesViewController)?.onSelectDetail = onSelectDetail
        case .settings:
            guard let controller = controller as? SettingsCategoriesViewController else {
                return
            }
            controller.onSelectDestination = onSelectDetailSettingsDestination(
                services: services,
                onSelectDetail: onSelectDetail
            )
        }
    }

    private func configureCompactContentController(
        _ controller: UIViewController,
        route: AppRouter.Route,
        services: AppServiceContainer
    ) {
        switch route {
        case .library:
            guard let controller = controller as? LibraryHomeViewController else {
                return
            }
            controller.onSelectSection = { [weak self, weak controller] section in
                guard let self, let navigationController = controller?.navigationController else {
                    return
                }
                navigationController.pushViewController(
                    self.makeLibrarySectionViewController(
                        section: section,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectAlbum = { [weak self, weak controller] albumID in
                guard let self, let controller else { return }
                let title = self.libraryAlbumTitle(for: albumID)
                controller.navigationController?.pushViewController(
                    self.makeLibraryCollectionDetailViewController(
                        kind: .album(albumID),
                        title: title,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectTrack = { [weak self, weak controller] trackID in
                guard let self, let navigationController = controller?.navigationController else {
                    return
                }
                navigationController.pushViewController(
                    self.makeLibraryTrackDetailViewController(
                        trackID: trackID,
                        services: services
                    ),
                    animated: true
                )
            }
        case .playlists:
            guard let controller = controller as? PlaylistListViewController else {
                return
            }
            controller.onSelectPlaylist = { [weak self, weak controller] playlist in
                guard let self, let navigationController = controller?.navigationController else {
                    return
                }
                navigationController.pushViewController(
                    self.makePlaylistDetailViewController(
                        playlist: playlist,
                        services: services
                    ),
                    animated: true
                )
            }
        case .onlineSources:
            (controller as? OnlineSourcesViewController)?.onSelectDetail = nil
        case .settings:
            break
        }
    }

    private func makeRegularInitialDetailViewController(
        route: AppRouter.Route,
        services: AppServiceContainer
    ) -> UIViewController {
        switch route {
        case .settings:
            return makeSettingsDetailViewController(
                destination: selectedSettingsDestination,
                services: services
            )
        case .library:
            return MigrationPlaceholderViewController(
                title: L("资料库详情"),
                message: L("从中间栏选择一个资料库分区。"),
                systemImage: "rectangle.split.3x1",
                accessibilityIdentifier: "library.detail.empty"
            )
        case .playlists:
            return MigrationPlaceholderViewController(
                title: L("歌单详情"),
                message: L("从中间栏选择一个歌单。"),
                systemImage: "music.note.list",
                accessibilityIdentifier: "playlists.detail.empty"
            )
        case .onlineSources:
            return MigrationPlaceholderViewController(
                title: L("在线源详情"),
                message: L("从中间栏选择一个在线源。"),
                systemImage: "externaldrive.connected.to.line.below",
                accessibilityIdentifier: "onlineSources.detail.empty"
            )
        }
    }

    private func makeSettingsDetailViewController(
        destination: SettingsDestination,
        services: AppServiceContainer
    ) -> UIViewController {
        SettingsHostingController(
            container: container,
            services: services,
            model: makeSettingsSceneModel(services: services),
            layout: .detail(destination)
        )
    }

    private func makeSettingsSceneModel(
        services: AppServiceContainer
    ) -> SettingsSceneModel {
        let servicesID = ObjectIdentifier(services)
        if settingsSceneModelServicesID != servicesID {
            #if LYRICS_DISABLED
                let lyricsServing: (any LyricsServing)? = nil
            #else
                let lyricsServing: (any LyricsServing)? = services.lyrics
            #endif
            settingsSceneModel = SettingsSceneModel(
                settingsServing: services.settingsServing,
                storageMaintenance: services.storageMaintenanceServing,
                metadataEnrichment: services.metadataEnrichmentServing,
                lyricsServing: lyricsServing
            )
            settingsSceneModelServicesID = servicesID
        }
        return settingsSceneModel!
    }

    private func makeFeatureViewController(
        route: AppRouter.Route,
        services: AppServiceContainer
    ) -> UIViewController {
        switch route {
        case .settings:
            return SettingsHostingController(
                container: container,
                services: services,
                model: makeSettingsSceneModel(services: services)
            )
        case .library:
            return makeLibraryHomeViewController(services: services)
        case .playlists:
            let controller = PlaylistListViewController(
                playlistServing: services.playlistServing,
                playbackServing: services.playbackServing,
                libraryServing: services.libraryServing,
                artworkServing: services.artworkServing
            )
            controller.onSelectPlaylist = { [weak self, weak controller] playlist in
                guard let self, let navigationController = controller?.navigationController else {
                    return
                }
                navigationController.pushViewController(
                    self.makePlaylistDetailViewController(
                        playlist: playlist,
                        services: services
                    ),
                    animated: true
                )
            }
            return controller
        case .onlineSources:
            return makeOnlineSourcesViewController(services: services)
        }
    }

    private func makePlaylistDetailViewController(
        playlist: Playlist,
        services: AppServiceContainer
    ) -> UIViewController {
        PlaylistDetailViewController(
            playlist: playlist,
            playlistServing: services.playlistServing,
            playbackServing: services.playbackServing,
            libraryServing: services.libraryServing,
            artworkServing: services.artworkServing
        )
    }

    private func makeOnlineSourcesViewController(
        services: AppServiceContainer
    ) -> UIViewController {
        let servicesID = ObjectIdentifier(services)
        if onlineSourcesModelServicesID != servicesID {
            onlineSourcesModel = makeOnlineSourcesModel(services: services)
            onlineSourcesModelServicesID = servicesID
        }
        guard let onlineSourcesModel else {
            return MigrationPlaceholderViewController(
                title: AppRouter.Route.onlineSources.title,
                message: L("在线源正在准备中。"),
                systemImage: AppRouter.Route.onlineSources.systemImage,
                accessibilityIdentifier: "onlineSources.migrationPlaceholder"
            )
        }
        return OnlineSourcesViewController(model: onlineSourcesModel)
    }

    private func makeOnlineSourcesModel(
        services: AppServiceContainer
    ) -> OnlineSourcesSceneModel {
        let credentialStore = KeychainOnlineCredentialStore()
        let dsAudioAuthorizer = DSAudioDeviceAuthorizer(
            credentialStore: credentialStore
        )
        #if DEBUG
            let useBVTOnlineFixtures = AppBVTFixtureSeeder.shouldUseOnlineSourceFixtures()
        #else
            let useBVTOnlineFixtures = false
        #endif
        let googleDriveOAuthConfigured: Bool
        let authorizeGoogleDrive: GoogleDriveAuthorizer?
        if useBVTOnlineFixtures {
            googleDriveOAuthConfigured = true
            authorizeGoogleDrive = { _ in }
        } else if let configuration = GoogleDriveOAuthConfiguration.fromMainBundle() {
            googleDriveOAuthConfigured = true
            authorizeGoogleDrive = { sourceID in
                let oauth = GoogleDriveOAuthClient(configuration: configuration)
                _ = try await oauth.authorize(
                    for: GoogleDriveSourceConfiguration(
                        sourceID: sourceID,
                        displayName: "Google Drive"
                    )
                )
            }
        } else {
            googleDriveOAuthConfigured = false
            authorizeGoogleDrive = nil
        }
        let authorizeDSAudioSource: DSAudioSourceAuthorizer = { request in
            if useBVTOnlineFixtures {
                return .authorized
            }
            do {
                _ = try await dsAudioAuthorizer.authorize(
                    sourceID: request.sourceID,
                    endpoint: request.endpoint,
                    account: request.account,
                    password: request.password,
                    deviceName: request.deviceName,
                    oneTimeCode: request.oneTimeCode,
                    challengeToken: request.challengeToken
                )
                return .authorized
            } catch let challenge as DSAudioDeviceAuthorizationChallenge {
                return .verificationRequired(challengeToken: challenge.challengeToken)
            }
        }
        return OnlineSourcesSceneModel(
            serving: services.onlineSources,
            auditionServing: services.onlineAudition,
            settingsServing: services.settingsServing,
            importer: container.importAvailable ? services.importServing : nil,
            downloadQueue: services.onlineDownloadQueueServing,
            authorizeDSAudioSource: authorizeDSAudioSource,
            authorizeGoogleDrive: authorizeGoogleDrive,
            removeCredential: { recordID in
                try await credentialStore.remove(recordID: recordID)
            },
            isGoogleDriveOAuthConfigured: googleDriveOAuthConfigured
        )
    }

    private func makeLibraryHomeViewController(
        services: AppServiceContainer,
        onSelectSection: ((LibrarySection) -> Void)? = nil,
        onSelectAlbum: ((AlbumID) -> Void)? = nil
    ) -> UIViewController {
        let libraryViewModel = resolveLibraryViewModel(services: services)

        let controller = LibraryHomeViewController(
            viewModel: libraryViewModel,
            artworkServing: services.artworkServing,
            mediaSourceResolver: services.mediaSourceResolver
        )
        let play: (MediaItemID) -> Void = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onPlayTrack = play
        controller.onEnqueueNextTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
            }
        }
        controller.onEnqueueTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
            }
        }
        controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        controller.onSelectSection = { [weak self, weak controller] section in
            if let onSelectSection {
                onSelectSection(section)
                return
            }
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibrarySectionViewController(section: section, services: services),
                animated: true
            )
        }
        controller.onSelectAlbum = { [weak self, weak controller] albumID in
            if let onSelectAlbum {
                onSelectAlbum(albumID)
                return
            }
            guard let self, let controller else { return }
            let title = self.libraryAlbumTitle(for: albumID)
            controller.navigationController?.pushViewController(
                self.makeLibraryCollectionDetailViewController(kind: .album(albumID), title: title, services: services),
                animated: true
            )
        }
        controller.onSelectTrack = { [weak self, weak controller] trackID in
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibraryTrackDetailViewController(
                    trackID: trackID,
                    services: services
                ),
                animated: true
            )
        }
        return controller
    }

    private func makeLibrarySearchViewController(
        services: AppServiceContainer
    ) -> LibrarySearchViewController {
        let libraryViewModel = resolveLibraryViewModel(services: services)
        let controller = LibrarySearchViewController(
            viewModel: libraryViewModel,
            artworkServing: services.artworkServing,
            mediaSourceResolver: services.mediaSourceResolver
        )
        controller.onPlayTrack = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onEnqueueNextTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
            }
        }
        controller.onEnqueueTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
            }
        }
        controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        controller.onSelectAlbum = { [weak self, weak controller] albumID in
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibraryCollectionDetailViewController(
                    kind: .album(albumID),
                    title: self.libraryAlbumTitle(for: albumID),
                    services: services
                ),
                animated: true
            )
        }
        controller.onSelectTrack = { [weak self, weak controller] trackID in
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibraryTrackDetailViewController(
                    trackID: trackID,
                    services: services
                ),
                animated: true
            )
        }
        return controller
    }

    private func resolveLibraryViewModel(
        services: AppServiceContainer
    ) -> LibraryViewModel {
        let servicesID = ObjectIdentifier(services)
        if libraryViewModelServicesID != servicesID {
            libraryViewModel = LibraryViewModel(
                library: services.libraryServing,
                importer: container.importAvailable ? services.importServing : nil,
                initialPreparation: { [weak self] in
                    await self?.scanDocumentsIfNeeded(force: false)
                },
                refreshPreparation: { [weak self] in
                    await self?.scanDocumentsIfNeeded(force: true)
                }
            )
            libraryViewModelServicesID = servicesID
        }
        return libraryViewModel!
    }

    private func libraryAlbumTitle(for albumID: AlbumID) -> String? {
        guard let libraryViewModel else { return nil }
        return libraryViewModel.searchAlbums.first(where: { $0.id == albumID })?.title
            ?? libraryViewModel.albums.first(where: { $0.id == albumID })?.title
            ?? libraryViewModel.recentAlbums.first(where: { $0.id == albumID })?.title
    }

    private func makeRegularSettingsCategoriesViewController(
        selectedDestination: SettingsDestination = .general,
        onSelectDestination: @escaping (SettingsDestination) -> Void
    ) -> UIViewController {
        let controller = SettingsCategoriesViewController(
            selectedDestination: selectedDestination
        )
        controller.onSelectDestination = onSelectDestination
        return controller
    }

    private func makeLibrarySectionViewController(
        section: LibrarySection,
        services: AppServiceContainer
    ) -> UIViewController {
        guard let libraryViewModel else {
            return MigrationPlaceholderViewController(
                title: section.title,
                message: L("UIKit 迁移中：该资料库分区将在后续阶段接入。"),
                systemImage: section.systemImage,
                accessibilityIdentifier: "library.section.\(section.rawValue).migrationPlaceholder"
            )
        }

        if [.albums, .artists, .genres, .folders].contains(section) {
            let controller = LibraryCollectionsViewController(
                viewModel: libraryViewModel,
                section: section,
                artworkServing: services.artworkServing,
                mediaSourceResolver: services.mediaSourceResolver
            )
            controller.onSelectAlbum = { [weak controller] albumID in
                guard let controller else { return }
                let title = libraryViewModel.albums.first(where: { $0.id == albumID })?.title
                controller.navigationController?.pushViewController(
                    self.makeLibraryCollectionDetailViewController(
                        kind: .album(albumID),
                        title: title,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectNoAlbum = { [weak controller] in
                guard let controller else { return }
                controller.navigationController?.pushViewController(
                    self.makeLibraryCollectionDetailViewController(
                        kind: .noAlbum,
                        title: L("无专辑"),
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectArtist = { [weak controller] artistID in
                guard let controller else { return }
                controller.navigationController?.pushViewController(
                    self.makeLibraryArtistDetailViewController(
                        artistID: artistID,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectGenre = { [weak controller] genreID in
                guard let controller else { return }
                let title = libraryViewModel.genres.first(where: { $0.id == genreID })?.name
                controller.navigationController?.pushViewController(
                    self.makeLibraryCollectionDetailViewController(
                        kind: .genre(genreID),
                        title: title,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onSelectFolder = { [weak controller] path in
                guard let controller else { return }
                controller.navigationController?.pushViewController(
                    self.makeLibraryCollectionDetailViewController(
                        kind: .folder(path),
                        title: path,
                        services: services
                    ),
                    animated: true
                )
            }
            controller.onPlayTracks = { itemIDs, shuffle in
                guard !itemIDs.isEmpty else { return }
                Task { @MainActor in
                    await services.playbackServing.send(
                        .playItems(itemIDs: itemIDs, shuffle: shuffle)
                    )
                }
            }
            controller.onEnqueueNextTracks = { itemIDs in
                guard !itemIDs.isEmpty else { return }
                Task { @MainActor in
                    await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
                }
            }
            controller.onEnqueueTracks = { itemIDs in
                guard !itemIDs.isEmpty else { return }
                Task { @MainActor in
                    await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
                }
            }
            controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
                guard let self, let controller, !itemIDs.isEmpty else { return }
                self.presentAddToPlaylist(
                    itemIDs: itemIDs,
                    playlistServing: services.playlistServing,
                    from: controller
                )
            }
            return controller
        }

        guard [.tracks, .favorites, .recent].contains(section) else {
            return MigrationPlaceholderViewController(
                title: section.title,
                message: L("UIKit 迁移中：该资料库分区将在后续阶段接入。"),
                systemImage: section.systemImage,
                accessibilityIdentifier: "library.section.\(section.rawValue).migrationPlaceholder"
            )
        }

        let controller = LibraryTracksViewController(
            viewModel: libraryViewModel,
            section: section,
            artworkServing: services.artworkServing,
            mediaSourceResolver: services.mediaSourceResolver
        )
        let play: (MediaItemID) -> Void = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onSelectTrack = { [weak self, weak controller] itemID in
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibraryTrackDetailViewController(
                    trackID: itemID,
                    services: services
                ),
                animated: true
            )
        }
        controller.onPlayTrack = play
        controller.onPlayTracks = { itemIDs, shuffle in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(
                    .playItems(itemIDs: itemIDs, shuffle: shuffle)
                )
            }
        }
        controller.onEnqueueNextTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
            }
        }
        controller.onEnqueueTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
            }
        }
        controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        return controller
    }

    private func makeLibraryTrackDetailViewController(
        trackID: MediaItemID,
        services: AppServiceContainer
    ) -> UIViewController {
        let controller = LibraryTrackDetailViewController(
            trackID: trackID,
            library: services.libraryServing,
            artworkServing: services.artworkServing
        )
        controller.onPlayTrack = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onAddToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        return controller
    }

    private func presentAddToPlaylist(
        itemIDs: [MediaItemID],
        playlistServing: any PlaylistServing,
        from presenter: UIViewController
    ) {
        guard !itemIDs.isEmpty, presenter.presentedViewController == nil else { return }
        let controller = LibraryAddToPlaylistViewController(
            itemIDs: itemIDs,
            playlistServing: playlistServing
        )
        let navigationController = RootNavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        presenter.present(navigationController, animated: true)
    }

    private func makeLibraryCollectionDetailViewController(
        kind: LibraryCollectionDetailViewController.Kind,
        title: String?,
        services: AppServiceContainer
    ) -> UIViewController {
        let controller = LibraryCollectionDetailViewController(
            kind: kind,
            title: title,
            library: services.libraryServing,
            artworkServing: services.artworkServing,
            mediaSourceResolver: services.mediaSourceResolver,
            metadataEnrichment: services.metadataEnrichmentServing
        )
        let play: (MediaItemID) -> Void = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onSelectTrack = { [weak self, weak controller] itemID in
            guard let self, let navigationController = controller?.navigationController else {
                return
            }
            navigationController.pushViewController(
                self.makeLibraryTrackDetailViewController(
                    trackID: itemID,
                    services: services
                ),
                animated: true
            )
        }
        controller.onPlayTrack = play
        controller.onPlayTracks = { itemIDs, shuffle in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(
                    .playItems(itemIDs: itemIDs, shuffle: shuffle)
                )
            }
        }
        controller.onEnqueueNextTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
            }
        }
        controller.onEnqueueTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
            }
        }
        controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        return controller
    }

    private func makeLibraryArtistDetailViewController(
        artistID: ArtistID,
        services: AppServiceContainer
    ) -> UIViewController {
        let controller = LibraryArtistDetailViewController(
            artistID: artistID,
            library: services.libraryServing,
            artworkServing: services.artworkServing,
            mediaSourceResolver: services.mediaSourceResolver
        )
        let play: (MediaItemID) -> Void = { itemID in
            Task { @MainActor in
                await services.playbackServing.send(.play(itemID: itemID))
            }
        }
        controller.onPlayTrack = play
        controller.onPlayTracks = { itemIDs, shuffle in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(
                    .playItems(itemIDs: itemIDs, shuffle: shuffle)
                )
            }
        }
        controller.onEnqueueNextTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
            }
        }
        controller.onEnqueueTracks = { itemIDs in
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
            }
        }
        controller.onAddTracksToPlaylist = { [weak self, weak controller] itemIDs in
            guard let self, let controller, !itemIDs.isEmpty else { return }
            self.presentAddToPlaylist(
                itemIDs: itemIDs,
                playlistServing: services.playlistServing,
                from: controller
            )
        }
        controller.onOpenAlbums = { [weak self, weak controller] albumIDs in
            guard let self, let controller else { return }
            controller.navigationController?.pushViewController(
                self.makeLibraryCollectionDetailViewController(
                    kind: .albums(albumIDs),
                    title: nil,
                    services: services
                ),
                animated: true
            )
        }
        return controller
    }

    private func index(for route: AppRouter.Route) -> Int {
        AppRouter.Route.allCases.firstIndex(of: route) ?? 0
    }

    /// Starts the shared service graph and completes the UIKit startup path.
    ///
    /// This remains internal so integration tests can exercise the same
    /// startup sequence as the scene delegate without constructing the
    /// removed SwiftUI root.
    func startServices() async {
        await startServices(waitForPostStartupMaintenance: true)
    }

    private func startServices(waitForPostStartupMaintenance: Bool) async {
        if container.serviceContainer == nil {
            guard await container.retryComposition() else {
                return
            }
        }
        guard !Task.isCancelled,
              let services = container.serviceContainer
        else {
            return
        }

        // A second scene appearance can call this method after the shared
        // service graph is already usable. Do not briefly publish `.loading`
        // in that case: RootViewController observes the state and would
        // otherwise replace the live navigation surface with the startup
        // screen while the idempotent start call is running.
        if !container.startupState.isUsable {
            container.updateStartupState(.loading)
        }

        do {
            let report = try await services.start()
            guard container.serviceContainer === services else {
                await services.stop()
                return
            }
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(
                    AppBVTFixtureSeeder.resetPlaybackHistoryLaunchArgument
                ) {
                    // BVT-only reset: keep visual runs deterministic without
                    // affecting normal users or production launches.
                    try? await services.libraryServing.clearPlaybackHistory()
                }
            #endif
            container.completeStartup(report)
            if waitForPostStartupMaintenance {
                let fallbacks = await services.waitForPostStartupMaintenance()
                container.completePostStartupMaintenance(fallbacks, for: services)
            } else {
                Task { @MainActor in
                    let fallbacks = await services.waitForPostStartupMaintenance()
                    container.completePostStartupMaintenance(fallbacks, for: services)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await container.handleFailedServiceStart(services, error: error)
        }
    }

    private func startServicesIfNeeded() {
        guard startupTask == nil else { return }

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startServices(waitForPostStartupMaintenance: false)
            self.startupTask = nil
            self.renderCurrentSurface()
        }
    }

    private func retryStartup() {
        guard startupTask == nil else { return }
        startServicesIfNeeded()
    }

    private func scanDocumentsIfNeeded(force: Bool = false) async {
        guard let scanner = container.documentsScanner else { return }
        do {
            _ = try await scanner.scanIfNeeded(force: force)
        } catch is CancellationError {
            return
        } catch {
            container.diagnosticsExporter.record(
                code: "import.documents.scan-failed",
                message: String(describing: error)
            )
        }
    }

    private func scheduleAutomaticDocumentsScan() {
        cancelAutomaticDocumentsScan()
        automaticDocumentsScanTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.automaticDocumentsScanDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.automaticDocumentsScanTask = nil
            await self.scanDocumentsIfNeeded()
        }
    }

    private func cancelAutomaticDocumentsScan() {
        automaticDocumentsScanTask?.cancel()
        automaticDocumentsScanTask = nil
    }

    private func presentPlayer(using services: AppServiceContainer) {
        // Covers both an in-flight modal attempt and an installed fallback
        // child. A second request must not orphan the first child by replacing
        // the only removal reference.
        guard fallbackPlayerController == nil else { return }

        let presenter = topMostPresenter()
        guard presenter.presentedViewController == nil else {
            return
        }

        let playerController = PlayerNowPlayingViewController(
            serving: services.playbackServing,
            audioServing: services.playbackAudioServing,
            artworkServing: services.artworkServing,
            library: services.libraryServing,
            lyricsServing: services.lyrics,
            onShowQueue: { [weak self] in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentQueue(using: services, from: presenter)
            },
            onShowLyrics: { [weak self] in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentLyrics(using: services, from: presenter)
            },
            onShowTrackDetails: { [weak self] itemID in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentTrackDetails(
                    itemID: itemID,
                    using: services,
                    from: presenter
                )
            },
            onShowAlbum: { [weak self] albumID in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentAlbumDetails(
                    albumID: albumID,
                    using: services,
                    from: presenter
                )
            },
            onShowArtist: { [weak self] artistID in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentArtistDetails(
                    artistID: artistID,
                    using: services,
                    from: presenter
                )
            },
            onAddToPlaylist: { [weak self] itemID in
                guard let self, let presenter = self.activePlayerPresenter() else { return }
                self.presentAddToPlaylist(
                    itemIDs: [itemID],
                    playlistServing: services.playlistServing,
                    from: presenter
                )
            }
        )
        playerController.modalPresentationStyle = .pageSheet
        fallbackPlayerController = playerController

        if let sheet = playerController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 48
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }

        presenter.present(playerController, animated: true)

        // A scene can be visible while UIKit still rejects a presentation
        // during an in-flight root transition (notably on simulator BVTs).
        // Keep the migration slice deterministic by installing the same
        // controller as a child only when the modal request did not attach.
        DispatchQueue.main.async { [weak self] in
            guard let self, let playerController = self.fallbackPlayerController else {
                return
            }
            guard playerController.presentingViewController == nil else {
                self.fallbackPlayerController = nil
                return
            }
            self.installFallbackPlayer(playerController)
        }
    }

    private func installFallbackPlayer(_ playerController: PlayerNowPlayingViewController) {
        guard fallbackPlayerController === playerController else { return }

        playerController.setFallbackCloseHandler { [weak self, weak playerController] in
            guard let self, let playerController else { return }
            self.removeFallbackPlayer(playerController)
        }
        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerController.view)
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerController.didMove(toParent: self)
        fallbackPlayerController = playerController
    }

    private func removeFallbackPlayer(_ playerController: PlayerNowPlayingViewController) {
        guard fallbackPlayerController === playerController else { return }

        playerController.willMove(toParent: nil)
        playerController.view.removeFromSuperview()
        playerController.removeFromParent()
        fallbackPlayerController = nil
    }

    private func topMostPresenter() -> UIViewController {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    /// Returns the active player surface for actions that present a secondary
    /// sheet. Normally the player is a modal descendant of the root. If UIKit
    /// rejected that presentation and the player was installed as a fallback
    /// child, the child itself must remain the presenter; using only the root's
    /// presentedViewController would make queue/details/lyrics actions no-op.
    private func activePlayerPresenter() -> UIViewController? {
        if let fallbackPlayerController,
           fallbackPlayerController.parent === self {
            return fallbackPlayerController
        }

        let presenter = topMostPresenter()
        return presenter === self ? nil : presenter
    }

    private func presentTrackDetails(
        itemID: MediaItemID,
        using services: AppServiceContainer,
        from presenter: UIViewController
    ) {
        guard presenter.presentedViewController == nil else { return }
        let controller = makeLibraryTrackDetailViewController(
            trackID: itemID,
            services: services
        )
        let navigationController = RootNavigationController(
            rootViewController: controller
        )
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        presenter.present(navigationController, animated: true)
    }

    private func presentAlbumDetails(
        albumID: AlbumID,
        using services: AppServiceContainer,
        from presenter: UIViewController
    ) {
        guard presenter.presentedViewController == nil else { return }
        let controller = makeLibraryCollectionDetailViewController(
            kind: .album(albumID),
            title: libraryAlbumTitle(for: albumID),
            services: services
        )
        let navigationController = RootNavigationController(
            rootViewController: controller
        )
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        presenter.present(navigationController, animated: true)
    }

    private func presentArtistDetails(
        artistID: ArtistID,
        using services: AppServiceContainer,
        from presenter: UIViewController
    ) {
        guard presenter.presentedViewController == nil else { return }
        let controller = makeLibraryArtistDetailViewController(
            artistID: artistID,
            services: services
        )
        let navigationController = RootNavigationController(
            rootViewController: controller
        )
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        presenter.present(navigationController, animated: true)
    }

    private func presentQueue(
        using services: AppServiceContainer,
        from presenter: UIViewController
    ) {
        guard presenter.presentedViewController == nil else { return }

        let queueController = PlayerQueueViewController(
            serving: services.playbackServing,
            audioServing: services.playbackAudioServing,
            artworkServing: services.artworkServing,
            library: services.libraryServing,
            onShowLyrics: { [weak self, weak presenter] in
                guard let self else { return }
                let presented = self.topMostPresenter()
                guard let queueController = presented as? PlayerQueueViewController
                    ?? (presented as? UINavigationController)?.viewControllers
                    .compactMap({ $0 as? PlayerQueueViewController })
                    .first
                else { return }
                queueController.dismiss(animated: true) {
                    (presenter as? PlayerNowPlayingViewController)?.showLyricsSurface()
                }
            },
            onShowAlbum: { [weak self, weak presenter] albumID in
                guard let self, let presenter else { return }
                presenter.dismiss(animated: true) {
                    self.presentAlbumDetails(
                        albumID: albumID,
                        using: services,
                        from: presenter
                    )
                }
            },
            onShowArtist: { [weak self, weak presenter] artistID in
                guard let self, let presenter else { return }
                presenter.dismiss(animated: true) {
                    self.presentArtistDetails(
                        artistID: artistID,
                        using: services,
                        from: presenter
                    )
                }
            },
            onDismiss: { [weak presenter] in
                (presenter as? PlayerNowPlayingViewController)?.setQueueSheetPresented(false)
            }
        )
        let navigationController = UINavigationController(rootViewController: queueController)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        navigationController.navigationBar.tintColor = MusicFreeUIColorTokens.accent
        navigationController.navigationBar.titleTextAttributes = [
            .foregroundColor: MusicFreeUIColorTokens.foregroundPrimary,
        ]
        navigationController.navigationBar.isTranslucent = false
        navigationController.navigationBar.barTintColor = MusicFreeUIColorTokens.backgroundPrimary
        navigationController.view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary

        (presenter as? PlayerNowPlayingViewController)?.setQueueSheetPresented(true)

        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 0
        }
        presenter.present(navigationController, animated: true)
    }

    private func presentLyrics(
        using services: AppServiceContainer,
        from presenter: UIViewController
    ) {
        guard presenter.presentedViewController == nil,
              #available(iOS 16.0, *) else { return }
        guard let itemID = services.playbackServing.snapshot.currentItemID,
              let display = services.playbackServing.snapshot.currentItem else { return }

        let durationSeconds: TimeInterval?
        if let duration = display.duration {
            let components = duration.components
            durationSeconds = Double(components.seconds)
                + Double(components.attoseconds) / 1000000000000000000
        } else {
            durationSeconds = nil
        }
        let query = LyricsQuery(
            itemID: itemID,
            title: display.title,
            artistName: display.artist,
            albumName: display.album,
            durationSeconds: durationSeconds
        )
        let lyricsController = PlayerLyricsViewController(
            serving: services.playbackServing,
            lyricsServing: services.lyrics,
            query: query
        )
        lyricsController.modalPresentationStyle = .pageSheet
        if let sheet = lyricsController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 0
        }
        presenter.present(lyricsController, animated: true)
    }
}

/// UIKit-owned surface container. It owns Mini Player placement, safe-area
/// ownership and presentation independently of the Settings SwiftUI host.
@MainActor
private final class RootSurfaceContainerViewController: UIViewController {
    private let contentViewController: UIViewController
    private let miniPlayerController: PlayerMiniPlayerViewController
    private let onlineAuditionController: OnlineAuditionViewController
    private let miniPlayerAccessoryContainer = PlayerMiniPlayerAccessoryContainerView()
    // Keep the standalone (regular-width) Mini Player on an opaque surface.
    // The previous UIVisualEffectView made the presenting collection bleed
    // through the accessory and diverged from the compact tab reference.
    private let miniPlayerBackgroundView = UIView()
    private let playbackServing: any PlaybackServing
    private let auditionServing: any OnlineAuditionServing
    private weak var compactTabBarController: UITabBarController?
    private var miniPlayerHeightConstraint: NSLayoutConstraint!
    private var onlineAuditionBottomConstraint: NSLayoutConstraint!
    private var playbackObservationTask: Task<Void, Never>?
    private var auditionObservationTask: Task<Void, Never>?
    private var formalMiniPlayerRequested = false
    private var isAuditionRetained = false
    private var isMiniPlayerVisible = false

    init(
        contentViewController: UIViewController,
        services: AppServiceContainer,
        compactTabBarController: UITabBarController?,
        onPresentPlayer: @escaping () -> Void
    ) {
        self.contentViewController = contentViewController
        playbackServing = services.playbackServing
        auditionServing = services.onlineAudition
        self.compactTabBarController = compactTabBarController
        miniPlayerController = PlayerMiniPlayerViewController(
            serving: services.playbackServing,
            audioServing: services.playbackAudioServing,
            artworkServing: services.artworkServing,
            onPresentPlayer: onPresentPlayer
        )
        onlineAuditionController = OnlineAuditionViewController(serving: services.onlineAudition)
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "root.surface"
        miniPlayerController.view.accessibilityIdentifier = "player.mini"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(MusicFreeColorTokens.backgroundPrimary)

        addChild(contentViewController)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentViewController.view)
        contentViewController.didMove(toParent: self)

        addChild(miniPlayerController)
        miniPlayerController.view.translatesAutoresizingMaskIntoConstraints = false
        miniPlayerController.didMove(toParent: self)
        addChild(onlineAuditionController)
        onlineAuditionController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(onlineAuditionController.view)
        onlineAuditionController.didMove(toParent: self)
        onlineAuditionBottomConstraint = onlineAuditionController.view.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor
        )
        NSLayoutConstraint.activate([
            onlineAuditionController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            onlineAuditionController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            onlineAuditionBottomConstraint,
            onlineAuditionController.view.heightAnchor.constraint(
                equalToConstant: MusicFreeLayoutMetrics.miniPlayerLegacyHeight
            )
        ])

        if let compactTabBarController {
            if #available(iOS 26.0, *) {
                compactTabBarController.tabBarMinimizeBehavior = .onScrollDown
                compactTabBarController.bottomAccessory = nil
            }
            miniPlayerAccessoryContainer.setContentView(miniPlayerController.view)
            miniPlayerController.view.isHidden = true
            miniPlayerController.view.accessibilityElementsHidden = true
        } else {
            miniPlayerBackgroundView.translatesAutoresizingMaskIntoConstraints = false
            miniPlayerBackgroundView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
            miniPlayerBackgroundView.isOpaque = true
            miniPlayerBackgroundView.isHidden = true
            view.addSubview(miniPlayerBackgroundView)
            view.addSubview(miniPlayerController.view)

            miniPlayerHeightConstraint = miniPlayerController.view.heightAnchor.constraint(
                equalToConstant: 0
            )
            NSLayoutConstraint.activate([
                miniPlayerBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                miniPlayerBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                miniPlayerBackgroundView.topAnchor.constraint(equalTo: miniPlayerController.view.topAnchor),
                miniPlayerBackgroundView.bottomAnchor.constraint(equalTo: miniPlayerController.view.bottomAnchor),
                miniPlayerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                miniPlayerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                miniPlayerController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                miniPlayerHeightConstraint,
            ])
        }

        NSLayoutConstraint.activate([
            contentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateAdditionalSafeAreaInsets(miniPlayerHeight: 0)

        let playback = playbackServing
        playbackObservationTask = Task { @MainActor [weak self] in
            self?.updateVisibility(for: playback.snapshot)
            for await snapshot in playback.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.updateVisibility(for: snapshot)
            }
        }

        let audition = auditionServing
        auditionObservationTask = Task { @MainActor [weak self] in
            self?.updateAuditionVisibility(for: audition.snapshot)
            for await snapshot in audition.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.updateAuditionVisibility(for: snapshot)
            }
        }
    }

    deinit {
        playbackObservationTask?.cancel()
        auditionObservationTask?.cancel()
    }

    private func updateVisibility(for snapshot: PlaybackSessionSnapshot) {
        // During a track handoff the coordinator publishes the selected item
        // ID before resolving its display snapshot. Keep the Mini Player and
        // its safe-area reservation alive for that transient state; removing
        // them for one snapshot makes the whole tab layout jump and then
        // return when the display metadata arrives.
        formalMiniPlayerRequested = snapshot.currentItemID != nil
            && snapshot.queue.currentEntryID != nil
            && snapshot.queue.currentItemID != nil
            && [.preparing, .buffering, .playing, .paused].contains(snapshot.phase)
        applyMiniPlayerVisibility()
    }

    private func updateAuditionVisibility(for snapshot: OnlineAuditionSnapshot) {
        isAuditionRetained = snapshot.hasRetainedSession
        applyMiniPlayerVisibility()
    }

    /// A retained audition session owns the one bottom playback slot. The
    /// formal coordinator keeps its paused session intact, so closing the
    /// audition can restore this surface without restarting formal playback.
    private func applyMiniPlayerVisibility() {
        let isVisible = formalMiniPlayerRequested && !isAuditionRetained
        let bottomAccessoryAdapter: NSObject? = {
            if #available(iOS 26.0, *) {
                compactTabBarController?.bottomAccessory
            } else {
                nil
            }
        }()
        if let compactTabBarController {
            let changed = isMiniPlayerVisible != isVisible
                || (isVisible && bottomAccessoryAdapter == nil)
                || (!isVisible && bottomAccessoryAdapter != nil)
            isMiniPlayerVisible = isVisible
            miniPlayerController.view.isHidden = !isVisible
            miniPlayerController.view.accessibilityElementsHidden = !isVisible
            miniPlayerAccessoryContainer.isHidden = !isVisible
            miniPlayerAccessoryContainer.accessibilityElementsHidden = !isVisible
            guard changed else { return }

            if #available(iOS 26.0, *) {
                let accessory = isVisible
                    ? UITabAccessory(contentView: miniPlayerAccessoryContainer)
                    : nil
                // Remove the system glass together with its content when idle.
                compactTabBarController.setBottomAccessory(
                    accessory,
                    animated: isVisible && view.window != nil
                )
            }
            return
        }

        let targetHeight: CGFloat = isVisible ? MusicFreeLayoutMetrics.miniPlayerLegacyHeight : 0
        let changed = miniPlayerHeightConstraint.constant != targetHeight

        isMiniPlayerVisible = isVisible
        miniPlayerController.view.isHidden = !isVisible
        miniPlayerBackgroundView.isHidden = !isVisible
        miniPlayerHeightConstraint.constant = targetHeight
        updateAdditionalSafeAreaInsets(
            miniPlayerHeight: isAuditionRetained ? MusicFreeLayoutMetrics.miniPlayerLegacyHeight : targetHeight
        )
        guard changed else { return }

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            self?.view.layoutIfNeeded()
        }
    }

    private func updateAdditionalSafeAreaInsets(miniPlayerHeight: CGFloat) {
        guard compactTabBarController == nil else { return }
        var insets = contentViewController.additionalSafeAreaInsets
        insets.bottom = miniPlayerHeight
        contentViewController.additionalSafeAreaInsets = insets
    }
}

@MainActor
private final class PlayerMiniPlayerAccessoryContainerView: UIView {
    private let shadowView = UIView()
    private let backgroundView = UIView()
    private var widthConstraint: NSLayoutConstraint?
    private var contentView: UIView?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var inlineLeadingConstraint: NSLayoutConstraint?
    private var inlineTrailingConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Stay hidden until the host has an actual playback surface to show.
        isHidden = true
        accessibilityElementsHidden = true
        // UITabAccessory owns the iOS 26 Liquid Glass surface. Any opaque
        // background in its content hierarchy covers that system material and
        // leaves only the floating capsule geometry visible.
        backgroundColor = .clear
        isOpaque = false
        layer.masksToBounds = false

        shadowView.translatesAutoresizingMaskIntoConstraints = false
        shadowView.backgroundColor = .clear
        shadowView.layer.cornerRadius = MusicFreeLayoutMetrics.miniPlayerCornerRadius
        shadowView.layer.cornerCurve = .continuous
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0
        shadowView.layer.shadowRadius = 14
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(shadowView)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = .clear
        backgroundView.isOpaque = false
        backgroundView.layer.cornerRadius = MusicFreeLayoutMetrics.miniPlayerCornerRadius
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.layer.masksToBounds = true
        backgroundView.layer.borderColor = MusicFreeUIColorTokens.separator
            .withAlphaComponent(0.24)
            .cgColor
        backgroundView.layer.borderWidth = 0
        addSubview(backgroundView)
        // UITabAccessory already supplies the reference horizontal margin in
        // its regular environment. A second inset creates a nested capsule
        // and leaves the system material visible around it.
        let regularLeadingConstraint = backgroundView.leadingAnchor.constraint(
            equalTo: leadingAnchor
        )
        let regularTrailingConstraint = backgroundView.trailingAnchor.constraint(
            equalTo: trailingAnchor
        )
        let regularTopConstraint = backgroundView.topAnchor.constraint(equalTo: topAnchor)
        let regularBottomConstraint = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            regularLeadingConstraint,
            regularTrailingConstraint,
            regularTopConstraint,
            regularBottomConstraint,
            shadowView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            shadowView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            shadowView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            shadowView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContentView(_ contentView: UIView) {
        guard self.contentView !== contentView else { return }
        let previousContent = self.contentView
        self.contentView = nil
        NSLayoutConstraint.deactivate([
            contentLeadingConstraint, contentTrailingConstraint, contentTopConstraint,
            contentBottomConstraint, inlineLeadingConstraint, inlineTrailingConstraint,
        ].compactMap { $0 })
        previousContent?.removeFromSuperview()
        self.contentView = contentView
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        contentLeadingConstraint = contentView.leadingAnchor.constraint(
            equalTo: backgroundView.leadingAnchor
        )
        contentTrailingConstraint = contentView.trailingAnchor.constraint(
            equalTo: backgroundView.trailingAnchor
        )
        contentTopConstraint = contentView.topAnchor.constraint(equalTo: backgroundView.topAnchor)
        contentBottomConstraint = contentView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor)
        inlineLeadingConstraint = contentView.leadingAnchor.constraint(equalTo: leadingAnchor)
        inlineTrailingConstraint = contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            contentLeadingConstraint!,
            contentTrailingConstraint!,
            contentTopConstraint!,
            contentBottomConstraint!,
        ])
        bringSubviewToFront(contentView)
        updateLayoutForAccessoryEnvironment()
        updateSuperviewWidthConstraint()
    }

    override var intrinsicContentSize: CGSize {
        let height: CGFloat
        if #available(iOS 26.0, *), traitCollection.tabAccessoryEnvironment == .inline {
            height = MusicFreeLayoutMetrics.miniPlayerInlineHeight
        } else {
            height = MusicFreeLayoutMetrics.miniPlayerContentHeight
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateBackgroundForAccessoryEnvironment()
        updateSuperviewWidthConstraint()
    }

    private func updateBackgroundForAccessoryEnvironment() {
        // Both accessory environments use UIKit's system-provided Liquid
        // Glass. The content view supplies only artwork, labels and controls.
        backgroundView.isHidden = true
        shadowView.isHidden = true
        backgroundView.layer.borderWidth = 0
        shadowView.layer.shadowOpacity = 0
        backgroundColor = .clear
        isOpaque = false
        updateLayoutForAccessoryEnvironment()
    }

    private func updateLayoutForAccessoryEnvironment() {
        guard let contentView, contentView.superview === self else { return }
        let isInline: Bool
        if #available(iOS 26.0, *) {
            isInline = traitCollection.tabAccessoryEnvironment == .inline
        } else {
            isInline = false
        }
        contentLeadingConstraint?.isActive = !isInline
        contentTrailingConstraint?.isActive = !isInline
        inlineLeadingConstraint?.isActive = isInline
        inlineTrailingConstraint?.isActive = isInline
        contentTopConstraint?.isActive = true
        contentBottomConstraint?.isActive = true
    }

    private func updateSuperviewWidthConstraint() {
        widthConstraint?.isActive = false
        widthConstraint = nil
        guard let superview else { return }
        let constraint = widthAnchor.constraint(equalTo: superview.widthAnchor)
        constraint.isActive = true
        widthConstraint = constraint
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBackgroundForAccessoryEnvironment()
        guard #available(iOS 26.0, *),
              previousTraitCollection?.tabAccessoryEnvironment
              != traitCollection.tabAccessoryEnvironment
        else {
            return
        }
        invalidateIntrinsicContentSize()
    }
}

/// Describes one destination hosted by the root tab bar.
///
/// The same descriptors populate the iOS 18 `UITab` API and the classic
/// `viewControllers` API, so routes, titles and accessibility identifiers stay
/// identical down to iOS 17 where `UITab` does not exist.
private struct RootTabDescriptor {
    enum Kind {
        case standard
        case search
    }

    static let searchIdentifier = "librarySearch"

    let identifier: String
    let title: String
    let systemImage: String
    let controller: UIViewController
    let kind: Kind
}

@MainActor
private final class RootTabBarController: UITabBarController, UITabBarControllerDelegate {
    var onSelectRoute: ((AppRouter.Route) -> Void)?

    /// Height of the docked Mini Player used before iOS 26 introduced
    /// `UITabAccessory`.
    private static let legacyMiniPlayerHeight =
        MusicFreeLayoutMetrics.miniPlayerLegacyHeight

    private let playbackServing: any PlaybackServing
    private let auditionServing: any OnlineAuditionServing
    private let miniPlayerController: PlayerMiniPlayerViewController
    private let onlineAuditionController: OnlineAuditionViewController
    private let miniPlayerAccessoryContainer = PlayerMiniPlayerAccessoryContainerView()
    private let legacyMiniPlayerHostView = UIView()
    private var legacyMiniPlayerHeightConstraint: NSLayoutConstraint?
    private var descriptors: [RootTabDescriptor] = []
    private var playbackObservationTask: Task<Void, Never>?
    private var auditionObservationTask: Task<Void, Never>?
    private var formalMiniPlayerRequested = false
    private var isAuditionRetained = false
    private var isMiniPlayerVisible = false
    private weak var boundContentScrollView: UIScrollView?
    private var boundContentScrollViewBaseInsets: UIEdgeInsets?
    private var boundContentScrollViewBaseIndicatorInsets: UIEdgeInsets?
    private var accessoryContainsAudition = false

    /// `UITabAccessory` hosts the Mini Player from iOS 26 onwards. Earlier
    /// releases dock it manually above the tab bar.
    private var usesBottomAccessory: Bool {
        if #available(iOS 26.0, *) {
            true
        } else {
            false
        }
    }

    init(
        playbackServing: any PlaybackServing,
        audioServing: (any PlaybackAudioServing)?,
        artworkServing: (any ArtworkServing)?,
        auditionServing: any OnlineAuditionServing,
        onPresentPlayer: @escaping () -> Void
    ) {
        self.playbackServing = playbackServing
        self.auditionServing = auditionServing
        miniPlayerController = PlayerMiniPlayerViewController(
            serving: playbackServing,
            audioServing: audioServing,
            artworkServing: artworkServing,
            onPresentPlayer: onPresentPlayer
        )
        if #available(iOS 26.0, *) {
            onlineAuditionController = OnlineAuditionViewController(serving: auditionServing, usesSystemAccessory: true)
        } else {
            onlineAuditionController = OnlineAuditionViewController(serving: auditionServing)
        }
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "root.tabBar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Installs the compact destinations, preferring the iOS 18 tab model and
    /// falling back to `viewControllers` + `UITabBarItem` on iOS 17.
    func installTabs(_ descriptors: [RootTabDescriptor], selectedIdentifier: String) {
        self.descriptors = descriptors
        if #available(iOS 18.0, *) {
            let tabs = descriptors.map(Self.makeTab(for:))
            self.tabs = tabs
            selectedTab = tabs.first { $0.identifier == selectedIdentifier } ?? tabs.first
        } else {
            viewControllers = descriptors.map { descriptor in
                let item = UITabBarItem(
                    title: descriptor.title,
                    image: UIImage(systemName: descriptor.systemImage),
                    tag: 0
                )
                item.accessibilityIdentifier = "app.tab.\(descriptor.identifier)"
                descriptor.controller.tabBarItem = item
                return descriptor.controller
            }
            selectedIndex = descriptors.firstIndex {
                $0.identifier == selectedIdentifier
            } ?? 0
        }
    }

    @available(iOS 18.0, *)
    private static func makeTab(for descriptor: RootTabDescriptor) -> UITab {
        let controller = descriptor.controller
        switch descriptor.kind {
        case .standard:
            return UITab(
                title: descriptor.title,
                image: UIImage(systemName: descriptor.systemImage),
                identifier: descriptor.identifier
            ) { _ in controller }
        case .search:
            let searchTab = UISearchTab { _ in controller }
            if #available(iOS 26.0, *) {
                searchTab.automaticallyActivatesSearch = true
            }
            searchTab.accessibilityIdentifier = "app.tab.\(descriptor.identifier)"
            return searchTab
        }
    }

    /// Identifier of the visible destination. `UISearchTab` keeps UIKit's own
    /// identifier, so resolve through the hosted controller first.
    private var selectedDescriptorIdentifier: String? {
        guard let controller = selectedContentViewController else { return nil }
        return descriptors.first { $0.controller === controller }?.identifier
    }

    private var selectedContentViewController: UIViewController? {
        if #available(iOS 18.0, *) {
            return selectedTab?.viewController
        }
        return selectedViewController
    }

    func selectRoute(_ route: AppRouter.Route) {
        guard let index = descriptors.firstIndex(where: { $0.identifier == route.rawValue })
        else {
            return
        }
        if #available(iOS 18.0, *) {
            guard let tab = tab(forIdentifier: route.rawValue) else { return }
            if selectedTab !== tab {
                selectedTab = tab
            }
        } else if selectedIndex != index {
            selectedIndex = index
        }
    }

    func rootViewController(for route: AppRouter.Route) -> UIViewController? {
        descriptors.first { $0.identifier == route.rawValue }?.controller
    }

    func reloadLocalizedContent() {
        for descriptor in descriptors {
            // `UISearchTab` is localized by UIKit, but the iOS 17 fallback owns
            // a plain `UITabBarItem` whose title has to be refreshed too.
            let title: String
            let systemImage: String
            if let route = AppRouter.Route(rawValue: descriptor.identifier) {
                title = route.title
                systemImage = route.systemImage
            } else {
                title = L("library.search.tabTitle")
                systemImage = descriptor.systemImage
            }
            let image = UIImage(systemName: systemImage)
            if #available(iOS 18.0, *) {
                guard let tab = tab(forIdentifier: descriptor.identifier),
                      !(tab is UISearchTab)
                else {
                    continue
                }
                tab.title = title
                tab.image = image
            } else {
                descriptor.controller.tabBarItem.title = title
                descriptor.controller.tabBarItem.image = image
            }
        }
    }

    func applyAccentColor() {
        view.tintColor = MusicFreeUIColorTokens.accent
        tabBar.tintColor = MusicFreeUIColorTokens.accent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        // Let iOS 26 own the floating Tab Bar geometry and its safe-area
        // reservation. Hiding the system bar and drawing a second capsule
        // caused a blank tail below the bar and prevented UITabAccessory from
        // collapsing the Mini Player into the Tab Bar.
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
        tabBar.accessibilityIdentifier = "app.tabBar"
        configureTabBarAppearance()
        let onlineSourcesReselectGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTabBarDoubleTap(_:))
        )
        onlineSourcesReselectGesture.numberOfTapsRequired = 2
        onlineSourcesReselectGesture.cancelsTouchesInView = false
        // The iOS 26 floating capsule is hosted outside UITabBar's historical
        // touch surface. Observe at the controller root so taps on the system
        // capsule are still delivered; the handler restricts recognition to
        // the actual bottom bar frame and never cancels UIKit's own action.
        view.addGestureRecognizer(onlineSourcesReselectGesture)

        addChild(miniPlayerController)
        miniPlayerController.view.translatesAutoresizingMaskIntoConstraints = false
        miniPlayerController.didMove(toParent: self)
        addChild(onlineAuditionController)
        onlineAuditionController.view.translatesAutoresizingMaskIntoConstraints = false
        if usesBottomAccessory {
            accessoryContainsAudition = auditionServing.snapshot.hasRetainedSession
            miniPlayerAccessoryContainer.setContentView(
                accessoryContainsAudition ? onlineAuditionController.view : miniPlayerController.view
            )
        } else {
            view.addSubview(onlineAuditionController.view)
            NSLayoutConstraint.activate([
                onlineAuditionController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                onlineAuditionController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                onlineAuditionController.view.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
                onlineAuditionController.view.heightAnchor.constraint(equalToConstant: Self.legacyMiniPlayerHeight),
            ])
            installLegacyMiniPlayer()
        }
        onlineAuditionController.didMove(toParent: self)
        isAuditionRetained = auditionServing.snapshot.hasRetainedSession

        let playback = playbackServing
        playbackObservationTask = Task { @MainActor [weak self] in
            self?.updateMiniPlayerVisibility(for: playback.snapshot)
            for await snapshot in playback.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.updateMiniPlayerVisibility(for: snapshot)
            }
        }

        let audition = auditionServing
        auditionObservationTask = Task { @MainActor [weak self] in
            self?.updateAuditionVisibility(for: audition.snapshot)
            for await snapshot in audition.makeSnapshotStream() {
                guard !Task.isCancelled else { return }
                self?.updateAuditionVisibility(for: snapshot)
            }
        }
    }

    /// Before iOS 26 there is no `UITabAccessory`, so the Mini Player is docked
    /// on an opaque surface directly above the tab bar. Pin it to
    /// `tabBar.topAnchor` because the bar's height is only known after layout.
    private func installLegacyMiniPlayer() {
        legacyMiniPlayerHostView.translatesAutoresizingMaskIntoConstraints = false
        legacyMiniPlayerHostView.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        legacyMiniPlayerHostView.isOpaque = true
        legacyMiniPlayerHostView.isHidden = true
        legacyMiniPlayerHostView.clipsToBounds = true
        view.addSubview(legacyMiniPlayerHostView)
        legacyMiniPlayerHostView.addSubview(miniPlayerController.view)

        let separatorView = UIView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = MusicFreeUIColorTokens.separator
            .withAlphaComponent(0.32)
        legacyMiniPlayerHostView.addSubview(separatorView)

        let heightConstraint = legacyMiniPlayerHostView.heightAnchor.constraint(
            equalToConstant: 0
        )
        legacyMiniPlayerHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            legacyMiniPlayerHostView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            legacyMiniPlayerHostView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            legacyMiniPlayerHostView.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            heightConstraint,
            separatorView.leadingAnchor.constraint(
                equalTo: legacyMiniPlayerHostView.leadingAnchor
            ),
            separatorView.trailingAnchor.constraint(
                equalTo: legacyMiniPlayerHostView.trailingAnchor
            ),
            separatorView.topAnchor.constraint(equalTo: legacyMiniPlayerHostView.topAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),
            miniPlayerController.view.leadingAnchor.constraint(
                equalTo: legacyMiniPlayerHostView.leadingAnchor
            ),
            miniPlayerController.view.trailingAnchor.constraint(
                equalTo: legacyMiniPlayerHostView.trailingAnchor
            ),
            miniPlayerController.view.topAnchor.constraint(
                equalTo: legacyMiniPlayerHostView.topAnchor
            ),
            miniPlayerController.view.heightAnchor.constraint(
                equalToConstant: Self.legacyMiniPlayerHeight
            ),
        ])
    }

    private func configureTabBarAppearance() {
        // Leave the iOS 26 system appearance intact so UIKit can provide the
        // native Liquid Glass backdrop and its scroll-driven transitions.
        tabBar.isTranslucent = true
        tabBar.tintColor = MusicFreeUIColorTokens.accent
        tabBar.unselectedItemTintColor = MusicFreeUIColorTokens.foregroundPrimary
    }

    @objc private func handleTabBarDoubleTap(_ gesture: UITapGestureRecognizer) {
        // iOS 26 lays out the floating tab items inside an inset capsule, so
        // dividing the full UITabBar width into equal columns identifies the
        // wrong item. The first tap has already selected the destination by
        // the time this recognizer completes; use UIKit's selected tab as the
        // authoritative route instead of reverse-engineering private chrome.
        guard gesture.state == .ended,
              tabBar.convert(tabBar.bounds, to: view)
              .insetBy(dx: -32, dy: -32)
              .contains(gesture.location(in: view)),
              selectedDescriptorIdentifier == AppRouter.Route.onlineSources.rawValue,
              let navigationController = rootViewController(for: .onlineSources)
              as? UINavigationController,
              navigationController.viewControllers.count > 1
        else {
            return
        }
        navigationController.popToRootViewController(animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !usesBottomAccessory, legacyMiniPlayerHostView.superview != nil {
            // Selecting a tab inserts the child's view above previously added
            // subviews, so restore the docked Mini Player and the tab bar to
            // the front on every layout pass.
            view.bringSubviewToFront(legacyMiniPlayerHostView)
            view.bringSubviewToFront(tabBar)
        }
        if !usesBottomAccessory {
            view.bringSubviewToFront(onlineAuditionController.view)
        }
        bindSelectedContentScrollView()
    }

    deinit {
        playbackObservationTask?.cancel()
        auditionObservationTask?.cancel()
    }

    private func updateMiniPlayerVisibility(for snapshot: PlaybackSessionSnapshot) {
        // Match the root surface's visibility contract. `currentItem` can be
        // nil only while a selected item is being prepared, and that state
        // must not remove the Mini Player or change the page's bottom inset.
        formalMiniPlayerRequested = snapshot.currentItemID != nil
            && snapshot.queue.currentEntryID != nil
            && snapshot.queue.currentItemID != nil
            && [.preparing, .buffering, .playing, .paused].contains(snapshot.phase)
        applyMiniPlayerVisibility()
    }

    private func updateAuditionVisibility(for snapshot: OnlineAuditionSnapshot) {
        guard isAuditionRetained != snapshot.hasRetainedSession else { return }
        isAuditionRetained = snapshot.hasRetainedSession
        applyMiniPlayerVisibility()
    }

    /// The formal session remains paused underneath a retained audition
    /// session. Making the formal Mini Player visible again only restores its
    /// control surface after the user explicitly ends the audition.
    private func applyMiniPlayerVisibility() {
        let isVisible = formalMiniPlayerRequested && !isAuditionRetained
        let visibilityChanged = isMiniPlayerVisible != isVisible
        isMiniPlayerVisible = isVisible
        miniPlayerController.view.isHidden = !isVisible
        miniPlayerController.view.accessibilityElementsHidden = !isVisible

        if #available(iOS 26.0, *) {
            // Swap only the content; UIKit retains ownership of the glass,
            // margins and the regular-to-inline transition for both players.
            if accessoryContainsAudition != isAuditionRetained {
                accessoryContainsAudition = isAuditionRetained
                miniPlayerAccessoryContainer.setContentView(
                    isAuditionRetained ? onlineAuditionController.view : miniPlayerController.view
                )
            }
            let needsAccessory = isVisible || isAuditionRetained
            miniPlayerAccessoryContainer.isHidden = !needsAccessory
            miniPlayerAccessoryContainer.accessibilityElementsHidden = !needsAccessory
            if needsAccessory != (bottomAccessory != nil) {
                setBottomAccessory(
                    needsAccessory ? UITabAccessory(contentView: miniPlayerAccessoryContainer) : nil,
                    // Hiding the child before an animated removal leaves an
                    // empty glass capsule. Remove the accessory immediately.
                    animated: needsAccessory && view.window != nil
                )
            }
        } else {
            legacyMiniPlayerHostView.isHidden = !isVisible
            legacyMiniPlayerHeightConstraint?.constant = isVisible ? Self.legacyMiniPlayerHeight : 0
            updateLegacyMiniPlayerSafeArea()
            if visibilityChanged {
                UIView.animate(withDuration: 0.2) { [weak self] in self?.view.layoutIfNeeded() }
            }
        }
        bindSelectedContentScrollView()
        DispatchQueue.main.async { [weak self] in self?.bindSelectedContentScrollView() }
    }

    /// The docked Mini Player is not part of UIKit's own chrome before iOS 26,
    /// so its height has to be pushed into every destination's safe area. This
    /// covers bottom-pinned static content as well as scrolling collections.
    private func updateLegacyMiniPlayerSafeArea() {
        let bottomInset = (isMiniPlayerVisible || isAuditionRetained) ? Self.legacyMiniPlayerHeight : 0
        for descriptor in descriptors {
            var insets = descriptor.controller.additionalSafeAreaInsets
            guard insets.bottom != bottomInset else { continue }
            insets.bottom = bottomInset
            descriptor.controller.additionalSafeAreaInsets = insets
        }
    }

    /// Explicitly register the selected feature's scroll view with UIKit's
    /// tab-bar chrome. Relying only on the heuristic works for a plain
    /// UINavigationController, but misses collection views installed by the
    /// migrated feature controllers. Without this binding the accessory is
    /// painted above the last rows and the tab bar never receives the scroll
    /// events that drive its inline collapse state.
    private func bindSelectedContentScrollView() {
        guard let scrollView = selectedContentViewController?.contentScrollView(
            for: .bottom
        ) else {
            restoreBoundContentScrollViewInsets()
            return
        }

        if boundContentScrollView !== scrollView {
            restoreBoundContentScrollViewInsets()
            boundContentScrollView = scrollView
            boundContentScrollViewBaseInsets = scrollView.contentInset
            boundContentScrollViewBaseIndicatorInsets = scrollView.verticalScrollIndicatorInsets
        }

        setContentScrollView(scrollView, for: .bottom)
        applyBoundContentScrollViewInsets()
    }

    private func applyBoundContentScrollViewInsets() {
        guard let scrollView = boundContentScrollView,
              let baseInsets = boundContentScrollViewBaseInsets,
              let baseIndicatorInsets = boundContentScrollViewBaseIndicatorInsets
        else {
            return
        }

        // UIKit's iOS 26 tab accessory does not consistently propagate its
        // covered height through a nested UINavigationController's
        // collection view. Keep the compensation small and only apply it
        // while the Mini Player is present; the tab bar's own safe-area
        // handling remains authoritative for the normal tab-bar inset.
        let accessoryInset: CGFloat
        if isMiniPlayerVisible || isAuditionRetained, usesBottomAccessory {
            let resolvedHeight = miniPlayerAccessoryContainer.bounds.height
            accessoryInset = max(96, resolvedHeight + 28)
        } else {
            // Before iOS 26 the docked Mini Player is compensated through the
            // destinations' additional safe area instead, so the scroll view's
            // own content inset stays untouched.
            accessoryInset = 0
        }

        var contentInsets = baseInsets
        contentInsets.bottom += accessoryInset
        scrollView.contentInset = contentInsets

        var indicatorInsets = baseIndicatorInsets
        indicatorInsets.bottom += accessoryInset
        scrollView.verticalScrollIndicatorInsets = indicatorInsets
    }

    private func restoreBoundContentScrollViewInsets() {
        guard let scrollView = boundContentScrollView else { return }
        if let baseInsets = boundContentScrollViewBaseInsets {
            scrollView.contentInset = baseInsets
        }
        if let baseIndicatorInsets = boundContentScrollViewBaseIndicatorInsets {
            scrollView.verticalScrollIndicatorInsets = baseIndicatorInsets
        }
        boundContentScrollView = nil
        boundContentScrollViewBaseInsets = nil
        boundContentScrollViewBaseIndicatorInsets = nil
    }

    @available(iOS 18.0, *)
    func tabBarController(
        _: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab _: UITab?
    ) {
        handleSelectionChange(identifier: selectedTab.identifier)
    }

    func tabBarController(_: UITabBarController, didSelect viewController: UIViewController) {
        // iOS 18 and later report selection through `didSelectTab`; ignoring the
        // legacy callback there keeps a single selection from being handled twice.
        if #available(iOS 18.0, *) { return }
        handleSelectionChange(
            identifier: descriptors.first { $0.controller === viewController }?.identifier
        )
    }

    private func handleSelectionChange(identifier: String?) {
        if let identifier, let route = AppRouter.Route(rawValue: identifier) {
            onSelectRoute?(route)
        }
        bindSelectedContentScrollView()
    }

    override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        if let scrollView = selectedContentViewController?.contentScrollView(for: edge) {
            return scrollView
        }
        return super.contentScrollView(for: edge)
    }
}

/// Navigation controller used inside the root tab bar.
///
/// iOS 26 drives `tabBarMinimizeBehavior` from the selected controller's
/// content scroll view. A navigation controller otherwise relies on a
/// heuristic, which misses collection views that are installed by migrated
/// UIKit feature controllers. Forward the feature-owned scroll view explicitly
/// so the tab bar can collapse into its inline state while scrolling.
@MainActor
private final class RootNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        applyAccentColor()
    }

    func applyAccentColor() {
        view.tintColor = MusicFreeUIColorTokens.accent
        navigationBar.tintColor = MusicFreeUIColorTokens.accent
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let scrollView = topViewController?.contentScrollView(for: .bottom) {
            setContentScrollView(scrollView, for: .bottom)
        }
    }

    override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        if let scrollView = topViewController?.contentScrollView(for: edge) {
            return scrollView
        }
        return super.contentScrollView(for: edge)
    }
}

@MainActor
private final class RootSidebarViewController: UITableViewController {
    var onSelectRoute: ((AppRouter.Route) -> Void)?

    private let routes: [AppRouter.Route]
    private var selectedRoute: AppRouter.Route

    init(routes: [AppRouter.Route], selectedRoute: AppRouter.Route) {
        self.routes = routes
        self.selectedRoute = selectedRoute
        super.init(style: .insetGrouped)
        title = L("app.name")
        restorationIdentifier = "root.sidebar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RootSidebarCell")
        tableView.accessibilityIdentifier = "app.sidebar.list"
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        routes.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "RootSidebarCell",
            for: indexPath
        )
        let route = routes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = route.title
        content.image = UIImage(systemName: route.systemImage)
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "app.route.\(route.rawValue)"
        cell.accessoryType = route == selectedRoute ? .checkmark : .none
        return cell
    }

    func selectRoute(_ route: AppRouter.Route) {
        guard routes.contains(route), selectedRoute != route else { return }
        selectedRoute = route
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    func reloadLocalizedContent() {
        title = L("app.name")
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectRoute(routes[indexPath.row])
        onSelectRoute?(selectedRoute)
    }
}

@MainActor
private final class SettingsCategoriesViewController: UITableViewController {
    var onSelectDestination: ((SettingsDestination) -> Void)?

    private let destinations = SettingsDestination.allCases
    private var selectedDestination: SettingsDestination = .general

    init(selectedDestination: SettingsDestination = .general) {
        self.selectedDestination = selectedDestination
        super.init(style: .insetGrouped)
        title = L("设置")
        restorationIdentifier = "settings.categories.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadLocalizedContent() {
        title = L("设置")
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    func selectDestination(_ destination: SettingsDestination) {
        guard destinations.contains(destination), selectedDestination != destination else {
            return
        }
        selectedDestination = destination
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsCategoryCell")
        tableView.accessibilityIdentifier = "settings.categories"
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        destinations.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "SettingsCategoryCell",
            for: indexPath
        )
        let destination = destinations[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = destination.title
        content.image = UIImage(systemName: destination.systemImage)
        content.imageProperties.tintColor = MusicFreeUIColorTokens.accent
        cell.contentConfiguration = content
        cell.accessoryType = destination == selectedDestination ? .checkmark : .none
        cell.accessibilityIdentifier = "settings.category.\(destination.rawValue)"
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedDestination = destinations[indexPath.row]
        tableView.reloadData()
        onSelectDestination?(selectedDestination)
    }
}

@MainActor
private final class MigrationPlaceholderViewController: UIViewController {
    private let titleText: String
    private let message: String
    private let systemImage: String
    private let placeholderAccessibilityIdentifier: String

    init(
        title: String,
        message: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) {
        titleText = title
        self.message = message
        self.systemImage = systemImage
        placeholderAccessibilityIdentifier = accessibilityIdentifier
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(MusicFreeColorTokens.backgroundPrimary)

        let imageView = UIImageView(image: UIImage(systemName: systemImage))
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42,
            weight: .medium
        )
        imageView.tintColor = MusicFreeUIColorTokens.accent

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.text = titleText

        let messageLabel = UILabel()
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.text = message

        let stackView = UIStackView(arrangedSubviews: [imageView, titleLabel, messageLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        view.accessibilityIdentifier = placeholderAccessibilityIdentifier
    }
}

/// Keeps an inactive navigation controller valid while its real child stack is
/// temporarily owned by the other App Shell layout.
@MainActor
private final class NavigationHandoffPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "app.navigation.handoffPlaceholder"
        view.accessibilityElementsHidden = true
    }
}

@MainActor
private final class StartupViewController: UIViewController {
    private let state: AppStartupState
    private let onRetry: () -> Void
    private var imageView: UIImageView?
    init(state: AppStartupState, onRetry: @escaping () -> Void) {
        self.state = state
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
        title = state.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(MusicFreeColorTokens.backgroundPrimary)

        let imageView = UIImageView(image: UIImage(systemName: state.systemImage))
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 80,
            weight: .medium
        )
        imageView.tintColor = MusicFreeUIColorTokens.accent
        self.imageView = imageView
        let stackView = UIStackView(arrangedSubviews: [imageView])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 12

        if state == .loading {
            let activityIndicator = UIActivityIndicatorView(style: .medium)
            activityIndicator.startAnimating()
            stackView.addArrangedSubview(activityIndicator)
        } else {
            let titleLabel = UILabel()
            titleLabel.font = .preferredFont(forTextStyle: .title2)
            titleLabel.textColor = .label
            titleLabel.textAlignment = .center
            titleLabel.text = state.title

            let messageLabel = UILabel()
            messageLabel.font = .preferredFont(forTextStyle: .body)
            messageLabel.textColor = .secondaryLabel
            messageLabel.textAlignment = .center
            messageLabel.numberOfLines = 0
            messageLabel.text = state.message

            stackView.addArrangedSubview(titleLabel)
            stackView.addArrangedSubview(messageLabel)

            let retryButton = UIButton(type: .system)
            retryButton.setTitle(L("重试启动"), for: .normal)
            retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
            retryButton.addAction(
                UIAction { [onRetry] _ in onRetry() },
                for: .primaryActionTriggered
            )
            stackView.addArrangedSubview(retryButton)
        }

        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        view.accessibilityIdentifier = "app.startup"
        view.accessibilityLabel = L("app.name")
        view.accessibilityValue = state == .loading ? L("正在启动") : state.message
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `.breathe` only exists from iOS 18; `.pulse` is the closest iOS 17
        // equivalent for this idle indicator.
        if let imageView {
            if #available(iOS 26.0, *) {
                imageView.addSymbolEffect(.drawOn)
            } else {
                imageView.addSymbolEffect(.appear)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // `.breathe` only exists from iOS 18; `.pulse` is the closest iOS 17
        // equivalent for this idle indicator.
        if let imageView {
            if #available(iOS 26.0, *) {
                imageView.addSymbolEffect(.drawOn)
            } else {
                imageView.addSymbolEffect(.disappear)
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
