import Foundation

/// The action taken when an imported item matches an existing library item.
public enum DuplicateImportPolicy: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case skipExisting
    case replaceExisting
    case keepBoth
}

/// User intent for importing media into the library.
public struct ImportPreferences: Codable, Equatable, Hashable, Sendable {
    public let duplicatePolicy: DuplicateImportPolicy
    public let useMusicKitMetadataEnrichment: Bool

    public init(
        duplicatePolicy: DuplicateImportPolicy = .skipExisting,
        useMusicKitMetadataEnrichment: Bool = false
    ) {
        self.duplicatePolicy = duplicatePolicy
        self.useMusicKitMetadataEnrichment = useMusicKitMetadataEnrichment
    }

    public static let defaults = Self()

    private enum CodingKeys: String, CodingKey {
        case duplicatePolicy
        case useMusicKitMetadataEnrichment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            duplicatePolicy: try container.decodeIfPresent(
                DuplicateImportPolicy.self,
                forKey: .duplicatePolicy
            ) ?? .skipExisting,
            useMusicKitMetadataEnrichment: try container.decodeIfPresent(
                Bool.self,
                forKey: .useMusicKitMetadataEnrichment
            ) ?? false
        )
    }

    public func settingMusicKitMetadataEnrichment(_ enabled: Bool) -> Self {
        Self(
            duplicatePolicy: duplicatePolicy,
            useMusicKitMetadataEnrichment: enabled
        )
    }
}
