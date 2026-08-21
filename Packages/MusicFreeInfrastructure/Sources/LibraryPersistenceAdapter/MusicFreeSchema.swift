import SwiftData

enum MusicFreeSchemaV1: VersionedSchema {
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

enum MusicFreeSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        MusicFreeSchemaV1.models + [
            LogicalTrackRecord.self,
            MediaAssetRecord.self,
            TrackVariantRecord.self,
            AlbumGroupRecord.self,
            AlbumReleaseRecord.self,
            DiscRecord.self,
            LibraryCollectionRecord.self,
            LibraryCollectionMemberRecord.self
        ]
    }
}

enum MusicFreeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MusicFreeSchemaV1.self, MusicFreeSchema.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MusicFreeSchemaV1.self, toVersion: MusicFreeSchema.self)
        ]
    }
}
