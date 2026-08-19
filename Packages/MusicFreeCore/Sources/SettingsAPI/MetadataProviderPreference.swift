import Foundation
import MusicDomain

/// User-controlled state for one metadata provider.
public struct MetadataProviderPreference: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let provider: MetadataProviderID
    public let isEnabled: Bool

    public init(
        provider: MetadataProviderID,
        isEnabled: Bool = false
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
    }

    public var id: MetadataProviderID { provider }

    public func settingEnabled(_ enabled: Bool) -> Self {
        Self(provider: provider, isEnabled: enabled)
    }
}
