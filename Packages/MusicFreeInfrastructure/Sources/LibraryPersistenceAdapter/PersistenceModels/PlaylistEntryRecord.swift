import Foundation
import SwiftData

@Model
final class PlaylistEntryRecord {
    @Attribute(.unique) var storageKey: String
    var playlistID: String
    var sourceID: String
    var externalID: String
    var position: Int

    init(
        storageKey: String,
        playlistID: String,
        sourceID: String,
        externalID: String,
        position: Int
    ) {
        self.storageKey = storageKey
        self.playlistID = playlistID
        self.sourceID = sourceID
        self.externalID = externalID
        self.position = position
    }
}
