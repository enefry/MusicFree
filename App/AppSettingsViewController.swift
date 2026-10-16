import BuiltinPluginSettings
import AppServices
import DesignSystem
import SettingsFeature
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

/// App composition for the native Settings feature.
@MainActor
final class AppSettingsViewController: SettingsViewController {
    private var capabilitiesTask: Task<Void, Never>?

    init(
        container: AppContainer,
        services: AppServiceContainer,
        model: SettingsSceneModel? = nil,
        onlineSourcesModel: OnlineSourcesSceneModel? = nil,
        layout: SettingsSceneLayout = .compact,
        initialDestination: SettingsDestination? = nil,
        onNavigationChange: ((SettingsDestination?) -> Void)? = nil
    ) {
#if LYRICS_DISABLED
        let lyricsServing: (any LyricsServing)? = nil
#else
        let lyricsServing: (any LyricsServing)? = services.lyrics
#endif
        let model = model ?? SettingsSceneModel(
            settingsServing: services.settingsServing,
            storageMaintenance: services.storageMaintenanceServing,
            metadataEnrichment: services.metadataEnrichmentServing,
            lyricsServing: lyricsServing
        )
        let pageHost: PluginSettingsPageHost?
        if let plugins = services.plugins {
            do {
                pageHost = PluginSettingsPageHost(registry: try BuiltinPluginSettingsRegistration.makeRegistry(
                    settingsModel: model, onlineSources: onlineSourcesModel), plugins: plugins, settings: services.settingsServing)
            } catch { preconditionFailure("Invalid built-in settings registration: \(error)") }
        } else { pageHost = nil }
        var additions: [SettingsViewController.Addition] = []
        if let plugins = services.plugins {
            additions.append(.init(title: "插件", systemImage: "puzzlepiece.extension",
                identifier: "settings.plugins.entry") {
                PluginSettingsViewController(plugins: plugins, settings: services.settingsServing, pageHost: pageHost)
            })
        }
#if DEBUG && MUSICFREE_DEBUG_SUPPORT && canImport(MusicFreeDebugSupport)
        additions.append(.init(title: "网络抓包", systemImage: "network", identifier: "settings.debug.networkCapture") {
            DebugNetworkCaptureSettingsViewController()
        })
#endif
        super.init(
            model: model, layout: layout,
            appearance: { AppUserInterfacePreferences.appearance },
            setAppearance: {
                UserDefaults.standard.set($0.rawValue, forKey: AppUserInterfacePreferences.appearanceStorageKey)
                AppUserInterfacePreferences.notifyChanged()
            },
            language: { AppUserInterfacePreferences.language },
            setLanguage: {
                UserDefaults.standard.set($0.rawValue, forKey: MusicFreeLocalization.languageStorageKey)
                AppUserInterfacePreferences.notifyChanged()
            },
            setAccentColor: {
                MusicFreeAccentColorStore.setHexValue(MusicFreeAccentColorStore.hexString(for: $0))
                AppUserInterfacePreferences.notifyChanged()
            },
            releaseInfoProvider: AppReleaseInfoProvider(),
            diagnosticsProvider: AppDiagnosticsProvider(exporter: container.diagnosticsExporter),
            appIconOptions: Self.iconOptions,
            appIconProvider: AppAlternateIconProvider(),
            sleepTimerServing: services.sleepTimerServing,
            libraryConversion: services.libraryConversionServing,
            metadataServerEnabled: Self.metadataServerEnabled,
            lyricsEnabled: Self.lyricsEnabled,
            additions: additions, pluginPages: pageHost,
            onNavigationChange: onNavigationChange
        )
        self.initialDestination = initialDestination
        capabilitiesTask = Task {
            await model.observeTransitionCapabilities(services.playbackServing.makeSnapshotStream())
        }
    }

    private var initialDestination: SettingsDestination?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let initialDestination {
            self.initialDestination = nil
            updateNavigationDestination(initialDestination)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { capabilitiesTask?.cancel() }

    private static var iconOptions: [SettingsAppIconOption] {
        [
            .init(id: "default", title: "经典", alternateIconName: nil, previewAssetName: "AppIcon-preview"),
            .init(id: "music", title: "手写", alternateIconName: "AppIcon-music", previewAssetName: "AppIcon-music-preview"),
            .init(id: "circle", title: "唱片", alternateIconName: "AppIcon-cicle", previewAssetName: "AppIcon-cicle-preview"),
            .init(id: "circle2", title: "唱片2", alternateIconName: "AppIcon-cicle2", previewAssetName: "AppIcon-cicle2-preview")
        ]
    }
    private static var metadataServerEnabled: Bool {
#if METADATA_SERVER_DISABLED
        false
#else
        true
#endif
    }
    private static var lyricsEnabled: Bool {
#if LYRICS_DISABLED
        false
#else
        true
#endif
    }
}
