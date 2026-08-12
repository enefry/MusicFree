import Foundation
import SwiftData

@Model
final class ArtistRecord {
    @Attribute(.unique) var storageKey: String
    var rawID: String
    var name: String
    var sortName: String?
    var artworkID: String?
    var dateAddedAt: Date
    var payload: Data

    init(
        storageKey: String,
        rawID: String,
        name: String,
        sortName: String?,
        artworkID: String?,
        dateAddedAt: Date,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.rawID = rawID
        self.name = name
        self.sortName = sortName
        self.artworkID = artworkID
        self.dateAddedAt = dateAddedAt
        self.payload = payload
    }
}
