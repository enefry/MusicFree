import Foundation

@available(macOS 13.0, iOS 16.0, *)
public struct PlaybackRange: Codable, Equatable, Hashable, Sendable {
    public let start: Duration
    public let end: Duration

    public init(start: Duration, end: Duration) {
        precondition(start >= .zero, "PlaybackRange.start cannot be negative")
        precondition(end > start, "PlaybackRange.end must be after start")
        self.start = start
        self.end = end
    }

    public var duration: Duration { end - start }

    public func absolutePosition(forLogicalPosition position: Duration) -> Duration {
        precondition(position >= .zero && position <= duration)
        return start + position
    }

    public func logicalPosition(forAbsolutePosition position: Duration) -> Duration {
        min(max(position - start, .zero), duration)
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Duration.self, forKey: .start)
        let end = try container.decode(Duration.self, forKey: .end)
        guard start >= .zero, end > start else {
            throw musicDomainDecodingFailure(decoder, field: "PlaybackRange")
        }
        self.init(start: start, end: end)
    }
}

public struct AudioStreamID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainIdentifier(rawValue, typeName: "AudioStreamID")
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

public struct AudioStreamSignature: Codable, Equatable, Hashable, Sendable {
    public let language: String?
    public let title: String?
    public let codec: String?
    public let channelCount: Int?
    public let indexHint: Int?

    public init(
        language: String? = nil,
        title: String? = nil,
        codec: String? = nil,
        channelCount: Int? = nil,
        indexHint: Int? = nil
    ) {
        if let channelCount { precondition(channelCount > 0) }
        if let indexHint { precondition(indexHint >= 0) }
        self.language = musicDomainOptionalText(language)
        self.title = musicDomainOptionalText(title)
        self.codec = musicDomainOptionalText(codec)
        self.channelCount = channelCount
        self.indexHint = indexHint
    }
}

public struct AudioStreamSelection: Codable, Equatable, Hashable, Sendable {
    public let streamID: AudioStreamID?
    public let fallbackSignature: AudioStreamSignature

    public init(streamID: AudioStreamID?, fallbackSignature: AudioStreamSignature) {
        self.streamID = streamID
        self.fallbackSignature = fallbackSignature
    }

    /// Source compatibility for schema-v1 callers and persisted integer selections.
    public init(index: Int) {
        precondition(index >= 0, "AudioStreamSelection.index cannot be negative")
        self.init(
            streamID: nil,
            fallbackSignature: AudioStreamSignature(indexHint: index)
        )
    }

    public var index: Int { fallbackSignature.indexHint ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case fallbackSignature
    }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(Int.self) {
            guard legacy >= 0 else {
                throw musicDomainDecodingFailure(decoder, field: "AudioStreamSelection.index")
            }
            self.init(index: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let signature = try container.decode(AudioStreamSignature.self, forKey: .fallbackSignature)
        guard signature.channelCount == nil || signature.channelCount! > 0,
              signature.indexHint == nil || signature.indexHint! >= 0
        else {
            throw musicDomainDecodingFailure(decoder, field: "AudioStreamSelection.fallbackSignature")
        }
        self.init(
            streamID: try container.decodeIfPresent(AudioStreamID.self, forKey: .streamID),
            fallbackSignature: signature
        )
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct PlaybackSelection: Codable, Equatable, Hashable, Sendable {
    public let range: PlaybackRange?
    public let audioStream: AudioStreamSelection?

    public init(range: PlaybackRange? = nil, audioStream: AudioStreamSelection? = nil) {
        self.range = range
        self.audioStream = audioStream
    }

    public static let wholeFile = Self()

    public var logicalDuration: Duration? { range?.duration }
}

@available(macOS 13.0, *)
public struct MediaAsset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: MediaAssetID
    public let contentRevision: String?
    public let fileName: String?
    public let folderPath: String?
    public let byteCount: Int64?
    public let technicalInfo: MediaTechnicalInfo?

    public init(
        id: MediaAssetID,
        contentRevision: String? = nil,
        fileName: String? = nil,
        folderPath: String? = nil,
        byteCount: Int64? = nil,
        technicalInfo: MediaTechnicalInfo? = nil
    ) {
        if let byteCount { precondition(byteCount >= 0, "MediaAsset.byteCount cannot be negative") }
        self.id = id
        self.contentRevision = musicDomainOptionalText(contentRevision)
        self.fileName = musicDomainOptionalText(fileName)
        self.folderPath = musicDomainOptionalText(folderPath)
        self.byteCount = byteCount
        self.technicalInfo = technicalInfo
    }
}

public enum TrackVariantAvailability: String, Codable, Equatable, Hashable, Sendable {
    case available
    case missing
    case unsupported
}

/// Source-owned metadata captured when a variant is imported.
///
/// The snapshot lets a later source refresh distinguish untouched source
/// values from library metadata that the user or an enrichment provider has
/// changed. Playback statistics and favorites are intentionally excluded.
@available(macOS 13.0, iOS 16.0, *)
public struct AlbumSourceMetadataSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: AlbumID
    public let title: String
    public let sortTitle: String?
    public let artistIDs: [ArtistID]
    public let artwork: ArtworkReference?
    public let releaseYear: Int?
    public let albumType: AlbumType?

    public init(album: Album) {
        id = album.id
        title = album.title
        sortTitle = album.sortTitle
        artistIDs = album.artistIDs
        artwork = album.artwork
        releaseYear = album.releaseYear
        albumType = album.albumType
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct TrackSourceMetadataSnapshot: Codable, Equatable, Hashable, Sendable {
    public let playbackSelection: PlaybackSelection
    public let title: String
    public let sortTitle: String?
    public let albumID: AlbumID?
    public let artistIDs: [ArtistID]
    public let genreIDs: [GenreID]
    public let trackNumber: Int?
    public let trackTotal: Int?
    public let discNumber: Int?
    public let discTotal: Int?
    public let year: Int?
    public let comment: String?
    public let lyrics: TrackLyrics?
    public let artwork: ArtworkReference?
    public let album: AlbumSourceMetadataSnapshot?

    public init(track: Track, album: Album? = nil) {
        playbackSelection = track.playbackSelection
        title = track.title
        sortTitle = track.sortTitle
        albumID = track.albumID
        artistIDs = track.artistIDs
        genreIDs = track.genreIDs
        trackNumber = track.trackNumber
        trackTotal = track.trackTotal
        discNumber = track.discNumber
        discTotal = track.discTotal
        year = track.year
        comment = track.comment
        lyrics = track.lyrics
        artwork = track.artwork
        self.album = album.map(AlbumSourceMetadataSnapshot.init(album:))
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct TrackVariant: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: MediaItemID
    public let logicalTrackID: LogicalTrackID
    public let assetID: MediaAssetID
    public let selection: PlaybackSelection
    public let availability: TrackVariantAvailability
    /// Opaque, non-path source hint used only to rediscover a moved or replaced source object.
    public let sourceIdentityHint: String?
    /// Opaque provider revision for the source metadata snapshot.
    public let sourceMetadataRevision: String?
    public let sourceMetadata: TrackSourceMetadataSnapshot?

    public init(
        id: MediaItemID,
        logicalTrackID: LogicalTrackID,
        assetID: MediaAssetID,
        selection: PlaybackSelection = .wholeFile,
        availability: TrackVariantAvailability = .available,
        sourceIdentityHint: String? = nil,
        sourceMetadataRevision: String? = nil,
        sourceMetadata: TrackSourceMetadataSnapshot? = nil
    ) {
        precondition(id.sourceID == assetID.sourceID, "TrackVariant and MediaAsset must share a source")
        self.id = id
        self.logicalTrackID = logicalTrackID
        self.assetID = assetID
        self.selection = selection
        self.availability = availability
        self.sourceIdentityHint = musicDomainOptionalText(sourceIdentityHint)
        self.sourceMetadataRevision = musicDomainOptionalText(sourceMetadataRevision)
        self.sourceMetadata = sourceMetadata
    }
}

@available(macOS 13.0, *)
public struct LogicalTrack: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: LogicalTrackID
    public let releaseID: AlbumReleaseID?
    public let discID: DiscID?
    public let title: String
    public let artistIDs: [ArtistID]
    public let genreIDs: [GenreID]
    public let trackNumber: Int?
    public let trackTotal: Int?
    public let discNumber: Int?
    public let discTotal: Int?
    public let duration: Duration?
    public let artwork: ArtworkReference?
    public let isFavorite: Bool
    public let statistics: PlaybackStatistics

    public init(
        id: LogicalTrackID,
        releaseID: AlbumReleaseID? = nil,
        discID: DiscID? = nil,
        title: String,
        artistIDs: [ArtistID] = [],
        genreIDs: [GenreID] = [],
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        duration: Duration? = nil,
        artwork: ArtworkReference? = nil,
        isFavorite: Bool = false,
        statistics: PlaybackStatistics = .empty
    ) {
        for value in [trackNumber, trackTotal, discNumber, discTotal].compactMap({ $0 }) {
            precondition(value > 0, "LogicalTrack numbering must be positive")
        }
        if let duration { precondition(duration >= .zero, "LogicalTrack.duration cannot be negative") }
        self.id = id
        self.releaseID = releaseID
        self.discID = discID
        self.title = musicDomainRequiredText(title, field: "LogicalTrack.title")
        self.artistIDs = musicDomainUnique(artistIDs)
        self.genreIDs = musicDomainUnique(genreIDs)
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.duration = duration
        self.artwork = artwork
        self.isFavorite = isFavorite
        self.statistics = statistics
    }
}

public struct AlbumGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: AlbumGroupID
    public let title: String
    public let artistIDs: [ArtistID]

    public init(id: AlbumGroupID, title: String, artistIDs: [ArtistID] = []) {
        self.id = id
        self.title = musicDomainRequiredText(title, field: "AlbumGroup.title")
        self.artistIDs = musicDomainUnique(artistIDs)
    }
}

public struct AlbumRelease: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: AlbumReleaseID
    public let legacyAlbumID: AlbumID?
    public let groupID: AlbumGroupID?
    public let title: String
    public let artistIDs: [ArtistID]
    public let releaseYear: Int?
    public let editionTitle: String?
    public let albumType: AlbumType?
    public let artwork: ArtworkReference?

    public init(
        id: AlbumReleaseID,
        legacyAlbumID: AlbumID? = nil,
        groupID: AlbumGroupID? = nil,
        title: String,
        artistIDs: [ArtistID] = [],
        releaseYear: Int? = nil,
        editionTitle: String? = nil,
        albumType: AlbumType? = nil,
        artwork: ArtworkReference? = nil
    ) {
        if let releaseYear { precondition((1...9_999).contains(releaseYear)) }
        self.id = id
        self.legacyAlbumID = legacyAlbumID
        self.groupID = groupID
        self.title = musicDomainRequiredText(title, field: "AlbumRelease.title")
        self.artistIDs = musicDomainUnique(artistIDs)
        self.releaseYear = releaseYear
        self.editionTitle = musicDomainOptionalText(editionTitle)
        self.albumType = albumType
        self.artwork = artwork
    }
}

public struct Disc: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: DiscID
    public let releaseID: AlbumReleaseID
    public let number: Int
    public let title: String?
    public let trackCount: Int?

    public init(id: DiscID, releaseID: AlbumReleaseID, number: Int, title: String? = nil, trackCount: Int? = nil) {
        precondition(number > 0, "Disc.number must be positive")
        if let trackCount { precondition(trackCount >= 0, "Disc.trackCount cannot be negative") }
        self.id = id
        self.releaseID = releaseID
        self.number = number
        self.title = musicDomainOptionalText(title)
        self.trackCount = trackCount
    }
}

public enum LibraryCollectionKind: String, Codable, Equatable, Hashable, Sendable {
    case boxSet
    case importedFolder
    case user
}

public struct LibraryCollection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: LibraryCollectionID
    public let kind: LibraryCollectionKind
    public let title: String
    public let artwork: ArtworkReference?

    public init(id: LibraryCollectionID, kind: LibraryCollectionKind, title: String, artwork: ArtworkReference? = nil) {
        self.id = id
        self.kind = kind
        self.title = musicDomainRequiredText(title, field: "LibraryCollection.title")
        self.artwork = artwork
    }
}

public struct LibraryCollectionMember: Codable, Equatable, Hashable, Sendable {
    public let collectionID: LibraryCollectionID
    public let releaseID: AlbumReleaseID
    public let position: Int

    public init(collectionID: LibraryCollectionID, releaseID: AlbumReleaseID, position: Int) {
        precondition(position >= 0, "LibraryCollectionMember.position cannot be negative")
        self.collectionID = collectionID
        self.releaseID = releaseID
        self.position = position
    }
}

@available(macOS 13.0, *)
public extension Track {
    var logicalTrackProjection: LogicalTrack {
        let releaseID = albumID.map(AlbumReleaseID.init(legacyAlbumID:))
        let normalizedDiscNumber = discNumber ?? (releaseID == nil ? nil : 1)
        let discID = releaseID.flatMap { releaseID in
            normalizedDiscNumber.map { DiscID(releaseID: releaseID, number: $0) }
        }
        return LogicalTrack(
            id: logicalTrackID,
            releaseID: releaseID,
            discID: discID,
            title: title,
            artistIDs: artistIDs,
            genreIDs: genreIDs,
            trackNumber: trackNumber,
            trackTotal: trackTotal,
            discNumber: discNumber,
            discTotal: discTotal,
            duration: duration,
            artwork: artwork,
            isFavorite: isFavorite,
            statistics: statistics
        )
    }

    var mediaAssetProjection: MediaAsset {
        MediaAsset(
            id: assetID,
            contentRevision: assetID.externalID,
            fileName: fileName,
            folderPath: folderPath,
            byteCount: technicalInfo?.fileSizeBytes,
            technicalInfo: technicalInfo
        )
    }

    var trackVariantProjection: TrackVariant {
        TrackVariant(
            id: id,
            logicalTrackID: logicalTrackID,
            assetID: assetID,
            selection: playbackSelection
        )
    }

    var discProjection: Disc? {
        guard let albumID else { return nil }
        let releaseID = AlbumReleaseID(legacyAlbumID: albumID)
        let number = discNumber ?? 1
        return Disc(
            id: DiscID(releaseID: releaseID, number: number),
            releaseID: releaseID,
            number: number
        )
    }
}

public extension Album {
    var releaseProjection: AlbumRelease {
        AlbumRelease(
            id: AlbumReleaseID(legacyAlbumID: id),
            legacyAlbumID: id,
            title: title,
            artistIDs: artistIDs,
            releaseYear: releaseYear,
            albumType: albumType,
            artwork: artwork
        )
    }
}
