import Foundation
import SwiftData

@Model
final class AlbumRecord {
    @Attribute(.unique) var storageKey: String
    var rawID: String
    var title: String
    var sortTitle: String?
    var artistIDs: Data
    var artworkID: String?
    var releaseYear: Int?
    var trackCount: Int?
    var albumType: String?
    var dateAddedAt: Date
    var payload: Data

    init(
        storageKey: String,
        rawID: String,
        title: String,
        sortTitle: String?,
        artistIDs: Data,
        artworkID: String?,
        releaseYear: Int?,
        trackCount: Int?,
        albumType: String?,
        dateAddedAt: Date,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.rawID = rawID
        self.title = title
        self.sortTitle = sortTitle
        self.artistIDs = artistIDs
        self.artworkID = artworkID
        self.releaseYear = releaseYear
        self.trackCount = trackCount
        self.albumType = albumType
        self.dateAddedAt = dateAddedAt
        self.payload = payload
    }
}
