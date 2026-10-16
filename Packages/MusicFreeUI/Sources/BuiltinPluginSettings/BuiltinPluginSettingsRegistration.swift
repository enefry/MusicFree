import MediaSourceAPI
import DesignSystem
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import SettingsFeature
import UIKit

/// Built-in UI companions register lazily alongside their runtime plugins.
/// The host has no switch over built-in plugin IDs or page implementations.
@MainActor
public enum BuiltinPluginSettingsRegistration {
    public static func makeRegistry(settingsModel: SettingsSceneModel,
                                    onlineSources: OnlineSourcesSceneModel? = nil) throws -> PluginSettingsPageRegistry {
        var registry = PluginSettingsPageRegistry()
        let stereoBalanceID = PluginID(rawValue: "builtin.dsp.stereoBalance")
        try registry.register(.init(entry: .init(id: stereoBalanceID.rawValue + ".settings", pluginID: stereoBalanceID,
            title: "声道均衡", systemImage: "slider.horizontal.3")) { context in
            StereoBalancePluginSettingsViewController(context: context)
        })
        let equalizerID = PluginID(rawValue: "builtin.dsp.equalizer")
        try registry.register(.init(entry: .init(id: equalizerID.rawValue + ".settings", pluginID: equalizerID,
            title: "均衡器", systemImage: "slider.vertical.3", placement: .playback, navigationIdentifier: "settings.playback.equalizer.entry")) { _ in
            EqualizerPluginSettingsViewController(context: .init(model: settingsModel))
        })
        if let onlineSources {
            for (suffix, kind, image) in [("dsAudio", OnlineProviderKind.dsAudio, "externaldrive.connected.to.line.below"),
                                           ("googleDrive", .googleDrive, "externaldrive")] {
                let id = PluginID(rawValue: "builtin.source." + suffix)
                try registry.register(.init(entry: .init(id: id.rawValue + ".sources", pluginID: id,
                    title: "账户与来源", systemImage: image, role: .accounts)) { context in
                    let controller = OnlineSourcesViewController(model: onlineSources, providerKind: kind,
                        accessibilityIdentifier: "plugins.\(context.descriptor.id.rawValue).sources.form")
                    controller.title = context.descriptor.name
                    return controller
                })
            }
        }
        for providerID in ["musicKit", "musicBrainz", "metadataServer", "discogs"] {
            let id = PluginID(rawValue: "builtin.metadata." + providerID)
            try registry.register(.init(entry: .init(id: id.rawValue + ".service", pluginID: id,
                title: "服务与授权", systemImage: "person.badge.key", role: .supplement)) { context in
                MetadataPluginSettingsViewController(context: context,
                    authorization: .init(model: settingsModel, providerID: providerID),
                    requestsSystemAuthorization: providerID == "musicKit")
            })
        }
        for providerID in ["netEase", "qqMusic"] {
            for kind in ["lyrics", "metadata"] {
                let id = PluginID(rawValue: "builtin.\(kind).\(providerID)")
                try registry.register(.init(entry: .init(id: id.rawValue + ".cookie", pluginID: id,
                    title: "Cookie 配置", systemImage: "person.badge.key", role: .configuration)) { context in
                    MusicCatalogCookieSettingsViewController(context: context)
                })
            }
        }
        return registry
    }
}
