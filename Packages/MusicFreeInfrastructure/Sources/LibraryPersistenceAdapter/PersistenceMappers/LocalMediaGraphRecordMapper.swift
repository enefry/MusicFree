import Foundation
import MusicDomain

enum LocalMediaGraphRecordMapper {
    static func makeLogicalTrack(_ value: LogicalTrack) throws -> LogicalTrackRecord {
        LogicalTrackRecord(
            storageKey: value.id.rawValue,
            releaseID: value.releaseID?.rawValue,
            discID: value.discID?.rawValue,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: LogicalTrackRecord, from value: LogicalTrack) throws {
        record.releaseID = value.releaseID?.rawValue
        record.discID = value.discID?.rawValue
        record.payload = try PersistenceCodec.encode(value)
    }

    static func logicalTrack(from record: LogicalTrackRecord) throws -> LogicalTrack {
        let value = try PersistenceCodec.decode(LogicalTrack.self, from: record.payload)
        guard value.id.rawValue == record.storageKey,
              value.releaseID?.rawValue == record.releaseID,
              value.discID?.rawValue == record.discID
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func makeAlbumGroup(_ value: AlbumGroup) throws -> AlbumGroupRecord {
        AlbumGroupRecord(
            storageKey: value.id.rawValue,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: AlbumGroupRecord, from value: AlbumGroup) throws {
        record.payload = try PersistenceCodec.encode(value)
    }

    static func albumGroup(from record: AlbumGroupRecord) throws -> AlbumGroup {
        let value = try PersistenceCodec.decode(AlbumGroup.self, from: record.payload)
        guard value.id.rawValue == record.storageKey else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeAsset(_ value: MediaAsset) throws -> MediaAssetRecord {
        MediaAssetRecord(
            storageKey: PersistenceKey.asset(value.id),
            sourceID: value.id.sourceID.rawValue,
            externalID: value.id.externalID,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: MediaAssetRecord, from value: MediaAsset) throws {
        record.sourceID = value.id.sourceID.rawValue
        record.externalID = value.id.externalID
        record.payload = try PersistenceCodec.encode(value)
    }

    static func asset(from record: MediaAssetRecord) throws -> MediaAsset {
        let value = try PersistenceCodec.decode(MediaAsset.self, from: record.payload)
        guard PersistenceKey.asset(value.id) == record.storageKey,
              value.id.sourceID.rawValue == record.sourceID,
              value.id.externalID == record.externalID
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func makeVariant(_ value: TrackVariant) throws -> TrackVariantRecord {
        TrackVariantRecord(
            storageKey: PersistenceKey.item(value.id),
            sourceID: value.id.sourceID.rawValue,
            externalID: value.id.externalID,
            logicalTrackID: value.logicalTrackID.rawValue,
            assetStorageKey: PersistenceKey.asset(value.assetID),
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: TrackVariantRecord, from value: TrackVariant) throws {
        record.sourceID = value.id.sourceID.rawValue
        record.externalID = value.id.externalID
        record.logicalTrackID = value.logicalTrackID.rawValue
        record.assetStorageKey = PersistenceKey.asset(value.assetID)
        record.payload = try PersistenceCodec.encode(value)
    }

    static func variant(from record: TrackVariantRecord) throws -> TrackVariant {
        let value = try PersistenceCodec.decode(TrackVariant.self, from: record.payload)
        guard PersistenceKey.item(value.id) == record.storageKey,
              value.logicalTrackID.rawValue == record.logicalTrackID,
              PersistenceKey.asset(value.assetID) == record.assetStorageKey
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func makeRelease(_ value: AlbumRelease) throws -> AlbumReleaseRecord {
        AlbumReleaseRecord(
            storageKey: value.id.rawValue,
            legacyAlbumID: value.legacyAlbumID?.rawValue,
            groupID: value.groupID?.rawValue,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: AlbumReleaseRecord, from value: AlbumRelease) throws {
        record.legacyAlbumID = value.legacyAlbumID?.rawValue
        record.groupID = value.groupID?.rawValue
        record.payload = try PersistenceCodec.encode(value)
    }

    static func release(from record: AlbumReleaseRecord) throws -> AlbumRelease {
        let value = try PersistenceCodec.decode(AlbumRelease.self, from: record.payload)
        guard value.id.rawValue == record.storageKey,
              value.legacyAlbumID?.rawValue == record.legacyAlbumID,
              value.groupID?.rawValue == record.groupID
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func makeDisc(_ value: Disc) throws -> DiscRecord {
        DiscRecord(
            storageKey: value.id.rawValue,
            releaseID: value.releaseID.rawValue,
            number: value.number,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: DiscRecord, from value: Disc) throws {
        record.releaseID = value.releaseID.rawValue
        record.number = value.number
        record.payload = try PersistenceCodec.encode(value)
    }

    static func disc(from record: DiscRecord) throws -> Disc {
        let value = try PersistenceCodec.decode(Disc.self, from: record.payload)
        guard value.id.rawValue == record.storageKey,
              value.releaseID.rawValue == record.releaseID,
              value.number == record.number
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func collection(from record: LibraryCollectionRecord) throws -> LibraryCollection {
        let value = try PersistenceCodec.decode(LibraryCollection.self, from: record.payload)
        guard value.id.rawValue == record.storageKey, value.kind.rawValue == record.kind else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeCollection(_ value: LibraryCollection) throws -> LibraryCollectionRecord {
        LibraryCollectionRecord(
            storageKey: value.id.rawValue,
            kind: value.kind.rawValue,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: LibraryCollectionRecord, from value: LibraryCollection) throws {
        record.kind = value.kind.rawValue
        record.payload = try PersistenceCodec.encode(value)
    }

    static func member(from record: LibraryCollectionMemberRecord) throws -> LibraryCollectionMember {
        let value = try PersistenceCodec.decode(LibraryCollectionMember.self, from: record.payload)
        guard value.collectionID.rawValue == record.collectionID,
              value.releaseID.rawValue == record.releaseID,
              value.position == record.position,
              (PersistenceKey.collectionMember(value) == record.storageKey
                || PersistenceKey.legacyCollectionMember(value) == record.storageKey)
        else { throw LibraryPersistenceError.corruptedRecord }
        return value
    }

    static func makeMember(_ value: LibraryCollectionMember) throws -> LibraryCollectionMemberRecord {
        LibraryCollectionMemberRecord(
            storageKey: PersistenceKey.collectionMember(value),
            collectionID: value.collectionID.rawValue,
            releaseID: value.releaseID.rawValue,
            position: value.position,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(
        _ record: LibraryCollectionMemberRecord,
        from value: LibraryCollectionMember
    ) throws {
        record.collectionID = value.collectionID.rawValue
        record.releaseID = value.releaseID.rawValue
        record.position = value.position
        record.payload = try PersistenceCodec.encode(value)
    }
}
