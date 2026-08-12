import Foundation
import SwiftData

@Model
final class PlaylistRecord {
    @Attribute(.unique) var storageKey: String
    var rawID: String
    var name: String
    var sortName: String?
    var artworkID: String?
    var createdAt: Date?
    var updatedAt: Date?
    var payload: Data

    init(
        storageKey: String,
        rawID: String,
        name: String,
        sortName: String?,
        artworkID: String?,
        createdAt: Date?,
        updatedAt: Date?,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.rawID = rawID
        self.name = name
        self.sortName = sortName
        self.artworkID = artworkID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payload = payload
    }
}
