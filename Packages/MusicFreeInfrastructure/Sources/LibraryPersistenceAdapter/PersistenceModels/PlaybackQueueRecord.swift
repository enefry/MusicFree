import Foundation
import SwiftData

@Model
final class PlaybackQueueRecord {
    @Attribute(.unique) var storageKey: String
    var version: Int64
    var payload: Data

    init(storageKey: String, version: Int64, payload: Data) {
        self.storageKey = storageKey
        self.version = version
        self.payload = payload
    }
}
