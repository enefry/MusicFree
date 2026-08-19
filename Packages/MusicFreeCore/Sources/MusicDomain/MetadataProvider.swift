import Foundation

/// Stable identifier for a metadata provider implementation.
///
/// This is intentionally an extensible value instead of an enum so a newer
/// app can add providers without making older persisted settings undecodable.
public struct MetadataProviderID: RawRepresentable, Codable, Hashable, Comparable, Sendable, Identifiable, CustomStringConvertible {
    public static let musicKit = Self(rawValue: "musicKit")
    public static let metadataServer = Self(rawValue: "metadataServer")
    public static let discogs = Self(rawValue: "discogs")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainRequiredText(rawValue, field: "MetadataProviderID")
    }

    public init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let rawValue = try? singleValue.decode(String.self) {
            guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: singleValue,
                    debugDescription: "Decoded MetadataProviderID cannot be empty"
                )
            }
            self.init(rawValue: rawValue)
            return
        }

        // Accept the object representation emitted by an early development
        // build before IDs were standardized as strings.
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try keyed.decode(String.self, forKey: .rawValue)
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: keyed,
                debugDescription: "Decoded MetadataProviderID cannot be empty"
            )
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: Self { self }

    public var description: String {
        "MetadataProviderID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }
}
