import AppServices
import DesignSystem
import SettingsFeature
import SwiftUI
import UIKit

#if DEBUG && MUSICFREE_DEBUG_SUPPORT && canImport(MusicFreeDebugSupport)
import MusicFreeDebugSupport
#endif

enum AppUserInterfacePreferences {
    static let appearanceStorageKey = "musicfree.appearance"
    static let didChangeNotification = Notification.Name(
        "MusicFreeUserInterfacePreferencesDidChange"
    )

    static var appearance: MusicFreeAppearance {
        MusicFreeAppearance(
            rawValue: UserDefaults.standard.string(forKey: appearanceStorageKey) ?? ""
        ) ?? .system
    }

    static var language: MusicFreeLanguage {
        MusicFreeLocalization.language
    }

    static var accentColorHex: String {
        MusicFreeAccentColorStore.hexValue
    }

    static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

extension MusicFreeAppearance {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            .unspecified
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

/// UIKit adapter for the one feature intentionally retained in SwiftUI.
@MainActor
final class SettingsHostingController: UIHostingController<UIKitSettingsRootView> {
    init(
        container: AppContainer,
        services: AppServiceContainer,
        model: SettingsSceneModel? = nil,
        layout: SettingsSceneLayout = .compact,
        initialDestination: SettingsDestination? = nil,
        onNavigationChange: ((SettingsDestination?) -> Void)? = nil
    ) {
        super.init(
            rootView: UIKitSettingsRootView(
                container: container,
                services: services,
                model: model,
                layout: layout,
                initialDestination: initialDestination,
                onNavigationChange: onNavigationChange
            )
        )
        title = L("settings.title")
        // The iOS 26 tab accessory can collapse inline with an opaque Tab Bar.
        // Keep the hosted Form's viewport extended beneath that chrome so the
        // transition does not leave the former regular-accessory safe-area as
        // an empty black band above the inline Mini Player. SwiftUI still
        // receives the live safe-area inset and keeps the last rows scrollable
        // above the controls.
        extendedLayoutIncludesOpaqueBars = true
        view.accessibilityIdentifier = "settings.host"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reuses the existing SwiftUI host when a regular-width Settings detail
    /// needs to be restored in compact width. Replacing the hosting controller
    /// would recreate its feature model and lose the form's loaded state.
    func updateNavigationDestination(_ destination: SettingsDestination?) {
        var updatedRootView = rootView
        switch rootView.layout {
        case .compact:
            guard rootView.initialDestination != destination else { return }
            updatedRootView.initialDestination = destination
        case .detail(let currentDestination):
            let nextDestination = destination ?? .general
            guard currentDestination != nextDestination else { return }
            updatedRootView.layout = .detail(nextDestination)
            updatedRootView.initialDestination = nil
        }
        rootView = updatedRootView
    }

    /// Forward the Form/List scroll view created by SwiftUI to the UIKit root
    /// shell.  Without this bridge the tab bar has no scroll source while the
    /// Settings tab is selected, so its bottom accessory remains in the
    /// floating state and cannot collapse into the inline tab-bar row.
    override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        findScrollView(in: view)
    }

    private func findScrollView(in root: UIView?) -> UIScrollView? {
        guard let root else { return nil }
        if let scrollView = root as? UIScrollView {
            return scrollView
        }
        for child in root.subviews {
            if let scrollView = findScrollView(in: child) {
                return scrollView
            }
        }
        return nil
    }
}

@MainActor
struct UIKitSettingsRootView: View {
    let container: AppContainer
    let services: AppServiceContainer
    var layout: SettingsSceneLayout
    var initialDestination: SettingsDestination?
    let onNavigationChange: ((SettingsDestination?) -> Void)?

    @State private var settingsModel: SettingsSceneModel
    @State private var isPresentingInitialDestination = false

    @AppStorage(AppUserInterfacePreferences.appearanceStorageKey) private var persistedAppearance =
        MusicFreeAppearance.system.rawValue
    @AppStorage(MusicFreeLocalization.languageStorageKey) private var persistedLanguage =
        MusicFreeLanguage.english.rawValue
    @AppStorage(MusicFreeAccentColorStore.storageKey) private var persistedAccentColor =
        MusicFreeAccentColorStore.defaultHex

    init(
        container: AppContainer,
        services: AppServiceContainer,
        model: SettingsSceneModel? = nil,
        layout: SettingsSceneLayout,
        initialDestination: SettingsDestination? = nil,
        onNavigationChange: ((SettingsDestination?) -> Void)? = nil
    ) {
        self.container = container
        self.services = services
        self.layout = layout
        self.initialDestination = initialDestination
        self.onNavigationChange = onNavigationChange
        if let model {
            _settingsModel = State(initialValue: model)
            return
        }
#if LYRICS_DISABLED
        let lyricsServing: (any LyricsServing)? = nil
#else
        let lyricsServing: (any LyricsServing)? = services.lyrics
#endif
        _settingsModel = State(initialValue: SettingsSceneModel(
            settingsServing: services.settingsServing,
            storageMaintenance: services.storageMaintenanceServing,
            metadataEnrichment: services.metadataEnrichmentServing,
            lyricsServing: lyricsServing
        ))
    }

    var body: some View {
        NavigationStack {
            settingsScene(layout: layout)
                .background {
                    initialDestinationLink
                }
        }
        .onAppear {
            guard let initialDestination,
                  !isPresentingInitialDestination
            else {
                return
            }
            onNavigationChange?(initialDestination)
            isPresentingInitialDestination = true
        }
        .onChange(of: initialDestination) { _, destination in
            guard let destination else {
                isPresentingInitialDestination = false
                return
            }
            onNavigationChange?(destination)
            isPresentingInitialDestination = true
        }
        .onChange(of: isPresentingInitialDestination) { _, isPresented in
            guard !isPresented else { return }
            onNavigationChange?(nil)
        }
        .tint(MusicFreeColorTokens.accent)
        .toolbarBackground(MusicFreeColorTokens.backgroundGrouped, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(appearance.colorScheme)
        .environment(\.locale, language.locale)
    }

    @ViewBuilder
    private func settingsScene(layout: SettingsSceneLayout) -> some View {
        SettingsScene<AnyView>(
                model: settingsModel,
                layout: layout,
                appearance: appearanceBinding,
                language: languageBinding,
                accentColor: accentColorBinding,
                releaseInfoProvider: AppReleaseInfoProvider(),
                diagnosticsProvider: AppDiagnosticsProvider(
                    exporter: container.diagnosticsExporter
                ),
                appIconOptions: appIconOptions,
                appIconProvider: AppAlternateIconProvider(),
                sleepTimerServing: services.sleepTimerServing,
                metadataServerEnabled: metadataServerEnabled,
                lyricsEnabled: lyricsEnabled,
                onNavigationChange: { destination in
                    // The compact root scene reports nil from its onAppear.
                    // While an externally requested category is being shown,
                    // that lifecycle callback must not clear the destination
                    // restored from the regular-width shell.
                    guard !(destination == nil && isPresentingInitialDestination) else {
                        return
                    }
                    onNavigationChange?(destination)
                },
                additionContent: { settingsAdditionContent }
            )
    }

    @ViewBuilder
    private var initialDestinationLink: some View {
        if let initialDestination {
            NavigationLink(
                isActive: $isPresentingInitialDestination
            ) {
                settingsScene(layout: .detail(initialDestination))
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    private var appearance: MusicFreeAppearance {
        MusicFreeAppearance(rawValue: persistedAppearance) ?? .system
    }

    private var language: MusicFreeLanguage {
        MusicFreeLanguage(rawValue: persistedLanguage) ?? .english
    }

    private var appearanceBinding: Binding<MusicFreeAppearance> {
        Binding(
            get: { appearance },
            set: {
                persistedAppearance = $0.rawValue
                AppUserInterfacePreferences.notifyChanged()
            }
        )
    }

    private var languageBinding: Binding<MusicFreeLanguage> {
        Binding(
            get: { language },
            set: {
                persistedLanguage = $0.rawValue
                AppUserInterfacePreferences.notifyChanged()
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { MusicFreeAccentColorStore.color(forHex: persistedAccentColor) },
            set: { newColor in
                persistedAccentColor = MusicFreeAccentColorStore.hexString(
                    for: UIColor(newColor)
                )
                AppUserInterfacePreferences.notifyChanged()
            }
        )
    }

    private var settingsAdditionContent: AnyView {
#if DEBUG && MUSICFREE_DEBUG_SUPPORT && canImport(MusicFreeDebugSupport)
        AnyView(DebugNetworkCaptureSettingsView())
#else
        AnyView(EmptyView())
#endif
    }

    private var appIconOptions: [SettingsAppIconOption] {
        [
            SettingsAppIconOption(
                id: "default",
                title: L("经典"),
                alternateIconName: nil,
                previewAssetName: "AppIcon-preview"
            ),
            SettingsAppIconOption(
                id: "music",
                title: L("手写"),
                alternateIconName: "AppIcon-music",
                previewAssetName: "AppIcon-music-preview"
            ),
            SettingsAppIconOption(
                id: "circle",
                title: L("唱片"),
                alternateIconName: "AppIcon-cicle",
                previewAssetName: "AppIcon-cicle-preview"
            ),
            SettingsAppIconOption(
                id: "circle2",
                title: L("唱片2"),
                alternateIconName: "AppIcon-cicle2",
                previewAssetName: "AppIcon-cicle2-preview"
            ),
        ]
    }

    private var metadataServerEnabled: Bool {
        #if METADATA_SERVER_DISABLED
            false
        #else
            true
        #endif
    }

    private var lyricsEnabled: Bool {
        #if LYRICS_DISABLED
            false
        #else
            true
        #endif
    }
}
