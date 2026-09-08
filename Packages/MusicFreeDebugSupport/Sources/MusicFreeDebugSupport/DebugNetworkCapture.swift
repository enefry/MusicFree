import Foundation

#if DEBUG && canImport(Pulse) && canImport(PulseProxy)
import Pulse
import PulseProxy
#endif

@MainActor
public enum DebugNetworkCapture {
    public static let enabledDefaultsKey = "musicfree.debug.networkCapture.enabled"

    private static var isProxyEnabled = false

    public static var isAvailable: Bool {
#if DEBUG && canImport(Pulse) && canImport(PulseProxy)
        true
#else
        false
#endif
    }

    public static func configureFromPreferences(
        defaults: UserDefaults = .standard
    ) {
        guard isAvailable, defaults.bool(forKey: enabledDefaultsKey) else { return }
        enable()
    }

    public static func enable() {
#if DEBUG && canImport(Pulse) && canImport(PulseProxy)
        guard !isProxyEnabled else { return }
        NetworkLogger.enableProxy()
        isProxyEnabled = true
#endif
    }
}
