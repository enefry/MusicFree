import Foundation

#if DEBUG && MUSICFREE_DEBUG_SUPPORT && canImport(MusicFreeDebugSupport)
import MusicFreeDebugSupport

// Keep the application-local name stable while the optional implementation
// lives outside the production project graph.
typealias DebugNetworkCapture = MusicFreeDebugSupport.DebugNetworkCapture
#else
@MainActor
enum DebugNetworkCapture {
    static let enabledDefaultsKey = "musicfree.debug.networkCapture.enabled"

    static var isAvailable: Bool { false }

    static func configureFromPreferences(
        defaults _: UserDefaults = .standard
    ) {}

    static func enable() {}
}
#endif
