import Foundation
import SwiftData

@Model
final class GenreRecord {
    @Attribute(.unique) var storageKey: String
    var rawID: String
    var name: String
    var sortName: String?
    var dateAddedAt: Date
    var payload: Data

    init(
        storageKey: String,
        rawID: String,
        name: String,
        sortName: String?,
        dateAddedAt: Date,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.rawID = rawID
        self.name = name
        self.sortName = sortName
        self.dateAddedAt = dateAddedAt
        self.payload = payload
    }
}
