import Foundation
import SwiftData

@Model
final class PlaybackHistoryRecordModel {
    @Attribute(.unique) var storageKey: String
    var sessionID: String
    var sourceID: String
    var externalID: String
    var lastEventAt: Date
    var payload: Data

    init(
        storageKey: String,
        sessionID: String,
        sourceID: String,
        externalID: String,
        lastEventAt: Date,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.externalID = externalID
        self.lastEventAt = lastEventAt
        self.payload = payload
    }
}
