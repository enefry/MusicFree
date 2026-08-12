import Foundation
import LibraryAPI
import MusicDomain

enum LibraryRecordMapper {
    static func makeTrack(_ value: Track, dateAddedAt: Date = Date()) throws -> TrackRecord {
        let record = TrackRecord(
            storageKey: PersistenceKey.item(value.id),
            sourceID: value.id.sourceID.rawValue,
            externalID: value.id.externalID,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: value.albumID?.rawValue,
            artistIDs: try PersistenceCodec.encode(value.artistIDs),
            genreIDs: try PersistenceCodec.encode(value.genreIDs),
            trackNumber: value.trackNumber,
            discNumber: value.discNumber,
            artworkID: value.artworkID?.rawValue,
            isFavorite: value.isFavorite,
            playCount: value.statistics.playCount,
            lastPlayedAt: value.statistics.lastPlayedAt,
            dateAddedAt: dateAddedAt,
            payload: try PersistenceCodec.encode(value)
        )
        return record
    }

    static func update(_ record: TrackRecord, from value: Track) throws {
        record.sourceID = value.id.sourceID.rawValue
        record.externalID = value.id.externalID
        record.title = value.title
        record.sortTitle = value.sortTitle
        record.albumID = value.albumID?.rawValue
        record.artistIDs = try PersistenceCodec.encode(value.artistIDs)
        record.genreIDs = try PersistenceCodec.encode(value.genreIDs)
        record.trackNumber = value.trackNumber
        record.discNumber = value.discNumber
        record.artworkID = value.artworkID?.rawValue
        record.isFavorite = value.isFavorite
        record.playCount = value.statistics.playCount
        record.lastPlayedAt = value.statistics.lastPlayedAt
        record.payload = try PersistenceCodec.encode(value)
    }

    static func track(from record: TrackRecord) throws -> Track {
        let value = try PersistenceCodec.decode(Track.self, from: record.payload)
        guard value.id.sourceID.rawValue == record.sourceID,
              value.id.externalID == record.externalID,
              PersistenceKey.item(value.id) == record.storageKey
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeAlbum(_ value: Album, dateAddedAt: Date = Date()) throws -> AlbumRecord {
        AlbumRecord(
            storageKey: value.id.rawValue,
            rawID: value.id.rawValue,
            title: value.title,
            sortTitle: value.sortTitle,
            artistIDs: try PersistenceCodec.encode(value.artistIDs),
            artworkID: value.artworkID?.rawValue,
            releaseYear: value.releaseYear,
            trackCount: value.trackCount,
            albumType: value.albumType?.code,
            dateAddedAt: dateAddedAt,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: AlbumRecord, from value: Album) throws {
        record.rawID = value.id.rawValue
        record.title = value.title
        record.sortTitle = value.sortTitle
        record.artistIDs = try PersistenceCodec.encode(value.artistIDs)
        record.artworkID = value.artworkID?.rawValue
        record.releaseYear = value.releaseYear
        record.trackCount = value.trackCount
        record.albumType = value.albumType?.code
        record.payload = try PersistenceCodec.encode(value)
    }

    static func album(from record: AlbumRecord) throws -> Album {
        let value = try PersistenceCodec.decode(Album.self, from: record.payload)
        guard value.id.rawValue == record.rawID,
              record.storageKey == value.id.rawValue
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeArtist(_ value: Artist, dateAddedAt: Date = Date()) throws -> ArtistRecord {
        ArtistRecord(
            storageKey: value.id.rawValue,
            rawID: value.id.rawValue,
            name: value.name,
            sortName: value.sortName,
            artworkID: value.artworkID?.rawValue,
            dateAddedAt: dateAddedAt,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: ArtistRecord, from value: Artist) throws {
        record.rawID = value.id.rawValue
        record.name = value.name
        record.sortName = value.sortName
        record.artworkID = value.artworkID?.rawValue
        record.payload = try PersistenceCodec.encode(value)
    }

    static func artist(from record: ArtistRecord) throws -> Artist {
        let value = try PersistenceCodec.decode(Artist.self, from: record.payload)
        guard value.id.rawValue == record.rawID,
              record.storageKey == value.id.rawValue
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeGenre(_ value: Genre, dateAddedAt: Date = Date()) throws -> GenreRecord {
        GenreRecord(
            storageKey: value.id.rawValue,
            rawID: value.id.rawValue,
            name: value.name,
            sortName: value.sortName,
            dateAddedAt: dateAddedAt,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: GenreRecord, from value: Genre) throws {
        record.rawID = value.id.rawValue
        record.name = value.name
        record.sortName = value.sortName
        record.payload = try PersistenceCodec.encode(value)
    }

    static func genre(from record: GenreRecord) throws -> Genre {
        let value = try PersistenceCodec.decode(Genre.self, from: record.payload)
        guard value.id.rawValue == record.rawID,
              record.storageKey == value.id.rawValue
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeArtwork(_ value: ArtworkReference) throws -> ArtworkRecord {
        ArtworkRecord(
            storageKey: PersistenceKey.artwork(value.id),
            rawID: value.id.rawValue,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: ArtworkRecord, from value: ArtworkReference) throws {
        record.rawID = value.id.rawValue
        record.payload = try PersistenceCodec.encode(value)
    }

    static func artwork(from record: ArtworkRecord) throws -> ArtworkReference {
        let value = try PersistenceCodec.decode(ArtworkReference.self, from: record.payload)
        guard value.id.rawValue == record.rawID,
              record.storageKey == PersistenceKey.artwork(value.id)
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makePlaylist(_ value: Playlist) throws -> PlaylistRecord {
        PlaylistRecord(
            storageKey: PersistenceKey.playlist(value.id),
            rawID: value.id.rawValue,
            name: value.name,
            sortName: value.sortName,
            artworkID: value.artworkID?.rawValue,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            payload: try PersistenceCodec.encode(value)
        )
    }

    static func update(_ record: PlaylistRecord, from value: Playlist) throws {
        record.rawID = value.id.rawValue
        record.name = value.name
        record.sortName = value.sortName
        record.artworkID = value.artworkID?.rawValue
        record.createdAt = value.createdAt
        record.updatedAt = value.updatedAt
        record.payload = try PersistenceCodec.encode(value)
    }

    static func playlist(from record: PlaylistRecord) throws -> Playlist {
        let value = try PersistenceCodec.decode(Playlist.self, from: record.payload)
        guard value.id.rawValue == record.rawID,
              record.storageKey == PersistenceKey.playlist(value.id)
        else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }

    static func makeEntry(_ value: PlaylistEntry) -> PlaylistEntryRecord {
        PlaylistEntryRecord(
            storageKey: PersistenceKey.entry(playlistID: value.playlistID, itemID: value.trackID),
            playlistID: value.playlistID.rawValue,
            sourceID: value.trackID.sourceID.rawValue,
            externalID: value.trackID.externalID,
            position: value.position
        )
    }

    static func entry(from record: PlaylistEntryRecord) throws -> PlaylistEntry {
        let value = PlaylistEntry(
            playlistID: PlaylistID(record.playlistID),
            trackID: MediaItemID(
                sourceID: MediaSourceID(record.sourceID),
                externalID: record.externalID
            ),
            position: record.position
        )
        guard PersistenceKey.entry(playlistID: value.playlistID, itemID: value.trackID) == record.storageKey else {
            throw LibraryPersistenceError.corruptedRecord
        }
        return value
    }
}
