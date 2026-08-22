import Foundation
import MusicDomain

/// User-controlled state for one lyrics provider.
public struct LyricsProviderPreference: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let provider: LyricsProviderID
    public let isEnabled: Bool

    public init(
        provider: LyricsProviderID,
        isEnabled: Bool = false
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
    }

    public var id: LyricsProviderID { provider }

    public func settingEnabled(_ enabled: Bool) -> Self {
        Self(provider: provider, isEnabled: enabled)
    }
}
