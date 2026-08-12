import Foundation

/// A storage or rendering variant of an artwork reference.
public enum ArtworkVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case thumbnail
    case medium
    case original

    /// Alias for the smallest commonly rendered variant.
    public static let small = Self.thumbnail

    /// Alias for the largest source variant.
    public static let large = Self.original
}

/// A lightweight reference to artwork. Image bytes and URLs never enter this model.
public struct ArtworkReference: Codable, Equatable, Hashable, Sendable {
    public let id: ArtworkID
    public let variants: [ArtworkVariant]
    public let preferredVariant: ArtworkVariant?

    /// Creates an artwork reference with optional known derived variants.
    public init(
        id: ArtworkID,
        variants: [ArtworkVariant] = [],
        preferredVariant: ArtworkVariant? = nil
    ) {
        self.id = id
        self.variants = musicDomainUnique(variants)
        self.preferredVariant = preferredVariant
    }

    /// The identifier under which the artwork is stored.
    public var artworkID: ArtworkID {
        id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case variants
        case preferredVariant
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ArtworkID.self, forKey: .id),
            variants: try container.decodeIfPresent([ArtworkVariant].self, forKey: .variants) ?? [],
            preferredVariant: try container.decodeIfPresent(ArtworkVariant.self, forKey: .preferredVariant)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(variants, forKey: .variants)
        try container.encodeIfPresent(preferredVariant, forKey: .preferredVariant)
    }
}
