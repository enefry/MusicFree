import Foundation

public struct LogicalTrackID: RawRepresentable, Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "LogicalTrackID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(legacyVariantID: MediaItemID) {
        self.init(rawValue: "legacy:\(legacyVariantID.sourceID.rawValue):\(legacyVariantID.externalID)")
    }

    public var description: String {
        "LogicalTrackID(\(musicDomainDisplayToken(rawValue)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MediaAssetID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let sourceID: MediaSourceID
    public let externalID: String

    public init(sourceID: MediaSourceID, externalID: String) {
        self.sourceID = sourceID
        self.externalID = musicDomainIdentifier(externalID, typeName: "MediaAssetID.externalID")
    }

    public init(legacyVariantID: MediaItemID) {
        self.init(sourceID: legacyVariantID.sourceID, externalID: legacyVariantID.externalID)
    }

    public var mediaItemID: MediaItemID {
        MediaItemID(sourceID: sourceID, externalID: externalID)
    }

    public var description: String {
        "MediaAssetID(source: \(musicDomainDisplayToken(sourceID.rawValue)), external: \(musicDomainDisplayToken(externalID)))"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
        return lhs.externalID < rhs.externalID
    }
}

public struct AlbumGroupID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "AlbumGroupID")
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AlbumReleaseID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "AlbumReleaseID")
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(legacyAlbumID: AlbumID) { self.init(rawValue: "legacy:\(legacyAlbumID.rawValue)") }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DiscID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "DiscID")
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(releaseID: AlbumReleaseID, number: Int) {
        precondition(number > 0, "DiscID.number must be positive")
        self.init(rawValue: "\(releaseID.rawValue):disc:\(number)")
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LibraryCollectionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "LibraryCollectionID")
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
