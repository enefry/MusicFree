import Foundation
import SwiftData

@Model
final class LogicalTrackRecord {
    @Attribute(.unique) var storageKey: String
    var releaseID: String?
    var discID: String?
    var payload: Data

    init(storageKey: String, releaseID: String?, discID: String?, payload: Data) {
        self.storageKey = storageKey
        self.releaseID = releaseID
        self.discID = discID
        self.payload = payload
    }
}

@Model
final class MediaAssetRecord {
    @Attribute(.unique) var storageKey: String
    var sourceID: String
    var externalID: String
    var payload: Data

    init(storageKey: String, sourceID: String, externalID: String, payload: Data) {
        self.storageKey = storageKey
        self.sourceID = sourceID
        self.externalID = externalID
        self.payload = payload
    }
}

@Model
final class TrackVariantRecord {
    @Attribute(.unique) var storageKey: String
    var sourceID: String
    var externalID: String
    var logicalTrackID: String
    var assetStorageKey: String
    var payload: Data

    init(
        storageKey: String,
        sourceID: String,
        externalID: String,
        logicalTrackID: String,
        assetStorageKey: String,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.sourceID = sourceID
        self.externalID = externalID
        self.logicalTrackID = logicalTrackID
        self.assetStorageKey = assetStorageKey
        self.payload = payload
    }
}

@Model
final class AlbumGroupRecord {
    @Attribute(.unique) var storageKey: String
    var payload: Data

    init(storageKey: String, payload: Data) {
        self.storageKey = storageKey
        self.payload = payload
    }
}

@Model
final class AlbumReleaseRecord {
    @Attribute(.unique) var storageKey: String
    var legacyAlbumID: String?
    var groupID: String?
    var payload: Data

    init(storageKey: String, legacyAlbumID: String?, groupID: String?, payload: Data) {
        self.storageKey = storageKey
        self.legacyAlbumID = legacyAlbumID
        self.groupID = groupID
        self.payload = payload
    }
}

@Model
final class DiscRecord {
    @Attribute(.unique) var storageKey: String
    var releaseID: String
    var number: Int
    var payload: Data

    init(storageKey: String, releaseID: String, number: Int, payload: Data) {
        self.storageKey = storageKey
        self.releaseID = releaseID
        self.number = number
        self.payload = payload
    }
}

@Model
final class LibraryCollectionRecord {
    @Attribute(.unique) var storageKey: String
    var kind: String
    var payload: Data

    init(storageKey: String, kind: String, payload: Data) {
        self.storageKey = storageKey
        self.kind = kind
        self.payload = payload
    }
}

@Model
final class LibraryCollectionMemberRecord {
    @Attribute(.unique) var storageKey: String
    var collectionID: String
    var releaseID: String
    var position: Int
    var payload: Data

    init(storageKey: String, collectionID: String, releaseID: String, position: Int, payload: Data) {
        self.storageKey = storageKey
        self.collectionID = collectionID
        self.releaseID = releaseID
        self.position = position
        self.payload = payload
    }
}
