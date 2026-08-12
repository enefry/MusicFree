import SwiftData

enum MusicFreeSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TrackRecord.self,
            AlbumRecord.self,
            ArtistRecord.self,
            GenreRecord.self,
            ArtworkRecord.self,
            PlaylistRecord.self,
            PlaylistEntryRecord.self,
            PlaybackHistoryRecordModel.self,
            PlaybackQueueRecord.self,
            StoreMetadataRecord.self
        ]
    }
}
