import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI

enum PlaybackRecordMapper {
    static func makeHistory(_ value: PlaybackHistoryRecord) throws -> PlaybackHistoryRecordModel {
        PlaybackHistoryRecordModel(
            storageKey: PersistenceKey.history(value.sessionID),
            sessionID: value.sessionID.uuidString.lowercased(),
            sourceID: value.itemID.sourceID.rawValue,
            externalID: value.itemID.externalID,
            lastEventAt: value.lastEventAt,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: PlaybackHistoryRecordModel, from value: PlaybackHistoryRecord) throws {
        record.sessionID = value.sessionID.uuidString.lowercased()
        record.sourceID = value.itemID.sourceID.rawValue
        record.externalID = value.itemID.externalID
        record.lastEventAt = value.lastEventAt
        record.payload = try PersistenceCodec.encode(value)
    }

    static func history(from record: PlaybackHistoryRecordModel) throws -> PlaybackHistoryRecord {
        let value = try PersistenceCodec.decode(PlaybackHistoryRecord.self, from: record.payload)
        guard value.sessionID.uuidString.lowercased() == record.sessionID,
              value.itemID.sourceID.rawValue == record.sourceID,
              value.itemID.externalID == record.externalID,
              PersistenceKey.history(value.sessionID) == record.storageKey
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeQueue(_ value: PlaybackQueueSnapshot, version: Int64) throws -> PlaybackQueueRecord {
        PlaybackQueueRecord(
            storageKey: "current",
            version: version,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: PlaybackQueueRecord, from value: PlaybackQueueSnapshot, version: Int64) throws {
        record.version = version
        record.payload = try PersistenceCodec.encode(value)
    }

    static func queue(from record: PlaybackQueueRecord) throws -> PlaybackQueueSnapshot {
        guard record.storageKey == "current" else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return try PersistenceCodec.decode(PlaybackQueueSnapshot.self, from: record.payload)
    }
}
