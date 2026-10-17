import Foundation

/// Display suppression is independent of plugin capability and entry visibility.
public enum PluginDisplaySettings {
    public static let suppressedPluginIDsStorageKey = "musicfree.plugins.suppressedPluginIDs"
    /// Plugins whose settings are not ready to be displayed by default.
    public static let defaultSuppressedPluginIDs = [
        "builtin.dsp.declick",
        "builtin.lyrics.netEase",
        "builtin.metadata.netEase",
        "builtin.lyrics.qqMusic",
        "builtin.metadata.qqMusic",
    ]

    static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [suppressedPluginIDsStorageKey: defaultSuppressedPluginIDs])
    }
}
