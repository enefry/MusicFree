import Foundation

/// Identifies one installed media source.
public struct MediaSourceID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The stable identifier reserved for the built-in local source.
    public static let local = Self(rawValue: "local")

    public let rawValue: String

    /// Creates a source identifier without interpreting it as a file path or URL.
    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "MediaSourceID")
    }

    /// Creates a source identifier from its stable external value.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "MediaSourceID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "MediaSourceID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}

/// Identifies a media item within a source. The pair remains stable across imports and restarts.
public struct MediaItemID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let sourceID: MediaSourceID
    public let externalID: String

    /// Creates an item identifier from its source and source-owned stable key.
    public init(sourceID: MediaSourceID, externalID: String) {
        self.sourceID = sourceID
        self.externalID = musicDomainIdentifier(externalID, typeName: "MediaItemID.externalID")
    }

    public var description: String {
        "MediaItemID(source: \(musicDomainDisplayToken(sourceID.rawValue)), external: \(musicDomainDisplayToken(externalID)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID < rhs.sourceID
        }
        return lhs.externalID < rhs.externalID
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID
        case externalID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceID: try container.decode(MediaSourceID.self, forKey: .sourceID),
            externalID: try container.decode(String.self, forKey: .externalID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(externalID, forKey: .externalID)
    }
}

/// Strongly typed identifier for an album.
public struct AlbumID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "AlbumID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "AlbumID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "AlbumID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}

/// Strongly typed identifier for an artist.
public struct ArtistID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "ArtistID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "ArtistID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "ArtistID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}

/// Strongly typed identifier for a genre.
public struct GenreID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "GenreID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "GenreID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "GenreID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}

/// Strongly typed identifier for a playlist.
public struct PlaylistID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "PlaylistID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "PlaylistID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "PlaylistID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}

/// Strongly typed identifier for artwork stored outside domain models.
public struct ArtworkID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "ArtworkID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String {
        "ArtworkID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try musicDomainDecodedIdentifier(from: decoder, typeName: "ArtworkID"))
    }

    public func encode(to encoder: Encoder) throws {
        try musicDomainEncodeIdentifier(rawValue, to: encoder)
    }
}
