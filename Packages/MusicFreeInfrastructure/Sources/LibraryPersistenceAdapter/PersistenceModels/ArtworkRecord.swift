import Foundation
import SwiftData

@Model
final class ArtworkRecord {
    @Attribute(.unique) var storageKey: String
    var rawID: String
    var payload: Data

    init(storageKey: String, rawID: String, payload: Data) {
        self.storageKey = storageKey
        self.rawID = rawID
        self.payload = payload
    }
}
