import Foundation
import SwiftData

@Model
final class TrackRecord {
    @Attribute(.unique) var storageKey: String
    var sourceID: String
    var externalID: String
    var title: String
    var sortTitle: String?
    var albumID: String?
    var artistIDs: Data
    var genreIDs: Data
    var trackNumber: Int?
    var discNumber: Int?
    var artworkID: String?
    var isFavorite: Bool
    var playCount: Int
    var lastPlayedAt: Date?
    var dateAddedAt: Date
    var payload: Data

    init(
        storageKey: String,
        sourceID: String,
        externalID: String,
        title: String,
        sortTitle: String?,
        albumID: String?,
        artistIDs: Data,
        genreIDs: Data,
        trackNumber: Int?,
        discNumber: Int?,
        artworkID: String?,
        isFavorite: Bool,
        playCount: Int,
        lastPlayedAt: Date?,
        dateAddedAt: Date,
        payload: Data
    ) {
        self.storageKey = storageKey
        self.sourceID = sourceID
        self.externalID = externalID
        self.title = title
        self.sortTitle = sortTitle
        self.albumID = albumID
        self.artistIDs = artistIDs
        self.genreIDs = genreIDs
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artworkID = artworkID
        self.isFavorite = isFavorite
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.dateAddedAt = dateAddedAt
        self.payload = payload
    }
}
