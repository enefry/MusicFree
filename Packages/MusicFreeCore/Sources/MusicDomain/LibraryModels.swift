import Foundation

/// A stable, immutable library track model.
@available(macOS 13.0, *)
public struct Track: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: MediaItemID
    public let logicalTrackID: LogicalTrackID
    public let assetID: MediaAssetID
    public let playbackSelection: PlaybackSelection
    public let title: String
    public let sortTitle: String?
    public let albumID: AlbumID?
    public let artistIDs: [ArtistID]
    public let genreIDs: [GenreID]
    /// The one-based position within a disc, when supplied by the media source.
    public let trackNumber: Int?
    public let trackTotal: Int?
    /// The one-based disc position within a multi-disc release.
    public let discNumber: Int?
    public let discTotal: Int?
    /// The source file name without exposing an absolute path.
    public let fileName: String?
    /// A source-provided logical folder, never an absolute filesystem path.
    /// It is nil for individually selected files or sources without folders.
    public let folderPath: String?
    public let duration: Duration?
    public let technicalInfo: MediaTechnicalInfo?
    public let year: Int?
    public let comment: String?
    public let lyrics: TrackLyrics?
    public let artwork: ArtworkReference?
    public let isFavorite: Bool
    public let statistics: PlaybackStatistics

    /// Creates a track. Missing metadata is represented by `nil` or an empty relationship list.
    public init(
        id: MediaItemID,
        logicalTrackID: LogicalTrackID? = nil,
        assetID: MediaAssetID? = nil,
        playbackSelection: PlaybackSelection = .wholeFile,
        title: String,
        sortTitle: String? = nil,
        albumID: AlbumID? = nil,
        artistIDs: [ArtistID] = [],
        genreIDs: [GenreID] = [],
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        fileName: String? = nil,
        folderPath: String? = nil,
        duration: Duration? = nil,
        technicalInfo: MediaTechnicalInfo? = nil,
        year: Int? = nil,
        comment: String? = nil,
        lyrics: TrackLyrics? = nil,
        artwork: ArtworkReference? = nil,
        isFavorite: Bool = false,
        statistics: PlaybackStatistics = .empty
    ) {
        if let duration {
            _ = musicDomainNonNegativeDuration(duration, field: "duration")
        }
        if let trackNumber {
            precondition(trackNumber > 0, "Track.trackNumber must be positive")
        }
        if let trackTotal {
            precondition(trackTotal > 0, "Track.trackTotal must be positive")
        }
        if let discNumber {
            precondition(discNumber > 0, "Track.discNumber must be positive")
        }
        if let discTotal {
            precondition(discTotal > 0, "Track.discTotal must be positive")
        }
        if let year {
            precondition((1...9_999).contains(year), "Track.year is out of range")
        }

        self.id = id
        self.logicalTrackID = logicalTrackID ?? LogicalTrackID(legacyVariantID: id)
        self.assetID = assetID ?? MediaAssetID(legacyVariantID: id)
        precondition(self.assetID.sourceID == id.sourceID, "Track and MediaAsset must share a source")
        self.playbackSelection = playbackSelection
        self.title = musicDomainRequiredText(title, field: "Track.title")
        self.sortTitle = musicDomainOptionalText(sortTitle)
        self.albumID = albumID
        self.artistIDs = musicDomainUnique(artistIDs)
        self.genreIDs = musicDomainUnique(genreIDs)
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.fileName = Self.normalizedFileName(fileName)
        self.folderPath = Self.normalizedFolderPath(folderPath)
        self.duration = duration
        self.technicalInfo = technicalInfo
        self.year = year
        self.comment = musicDomainOptionalText(comment)
        self.lyrics = lyrics.flatMap { $0.isEmpty ? nil : $0 }
        self.artwork = artwork
        self.isFavorite = isFavorite
        self.statistics = statistics
    }

    public var artworkID: ArtworkID? {
        artwork?.id
    }

    public var artistID: ArtistID? {
        artistIDs.first
    }

    public var genreID: GenreID? {
        genreIDs.first
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case logicalTrackID
        case assetID
        case playbackSelection
        case title
        case sortTitle
        case albumID
        case artistIDs
        case genreIDs
        case trackNumber
        case trackTotal
        case discNumber
        case discTotal
        case fileName
        case folderPath
        case duration
        case technicalInfo
        case year
        case comment
        case lyrics
        case artwork
        case isFavorite
        case statistics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(MediaItemID.self, forKey: .id)
        let assetID = try container.decodeIfPresent(MediaAssetID.self, forKey: .assetID)
        let title = try container.decode(String.self, forKey: .title)
        let duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
        let trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        let trackTotal = try container.decodeIfPresent(Int.self, forKey: .trackTotal)
        let discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        let discTotal = try container.decodeIfPresent(Int.self, forKey: .discTotal)
        let year = try container.decodeIfPresent(Int.self, forKey: .year)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assetID == nil || assetID!.sourceID == id.sourceID,
              duration == nil || duration! >= .zero,
              trackNumber == nil || trackNumber! > 0,
              trackTotal == nil || trackTotal! > 0,
              discNumber == nil || discNumber! > 0,
              discTotal == nil || discTotal! > 0,
              year == nil || (1...9_999).contains(year!)
        else {
            throw musicDomainDecodingFailure(decoder, field: "Track")
        }
        self.init(
            id: id,
            logicalTrackID: try container.decodeIfPresent(LogicalTrackID.self, forKey: .logicalTrackID),
            assetID: assetID,
            playbackSelection: try container.decodeIfPresent(PlaybackSelection.self, forKey: .playbackSelection) ?? .wholeFile,
            title: title,
            sortTitle: try container.decodeIfPresent(String.self, forKey: .sortTitle),
            albumID: try container.decodeIfPresent(AlbumID.self, forKey: .albumID),
            artistIDs: try container.decodeIfPresent([ArtistID].self, forKey: .artistIDs) ?? [],
            genreIDs: try container.decodeIfPresent([GenreID].self, forKey: .genreIDs) ?? [],
            trackNumber: trackNumber,
            trackTotal: trackTotal,
            discNumber: discNumber,
            discTotal: discTotal,
            fileName: try container.decodeIfPresent(String.self, forKey: .fileName),
            folderPath: try container.decodeIfPresent(String.self, forKey: .folderPath),
            duration: duration,
            technicalInfo: try container.decodeIfPresent(MediaTechnicalInfo.self, forKey: .technicalInfo),
            year: year,
            comment: try container.decodeIfPresent(String.self, forKey: .comment),
            lyrics: try container.decodeIfPresent(TrackLyrics.self, forKey: .lyrics),
            artwork: try container.decodeIfPresent(ArtworkReference.self, forKey: .artwork),
            isFavorite: try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            statistics: try container.decodeIfPresent(PlaybackStatistics.self, forKey: .statistics) ?? .empty
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(logicalTrackID, forKey: .logicalTrackID)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(playbackSelection, forKey: .playbackSelection)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(sortTitle, forKey: .sortTitle)
        try container.encodeIfPresent(albumID, forKey: .albumID)
        try container.encode(artistIDs, forKey: .artistIDs)
        try container.encode(genreIDs, forKey: .genreIDs)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(trackTotal, forKey: .trackTotal)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(discTotal, forKey: .discTotal)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(technicalInfo, forKey: .technicalInfo)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
        try container.encodeIfPresent(artwork, forKey: .artwork)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(statistics, forKey: .statistics)
    }

    private static func normalizedFolderPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let components = value.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components.joined(separator: "/")
    }

    private static func normalizedFileName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("/"),
              !normalized.contains("\\"),
              normalized != ".",
              normalized != ".."
        else { return nil }
        return normalized
    }

    public var relativePath: String? {
        guard let fileName else { return folderPath }
        if let folderPath { return "\(folderPath)/\(fileName)" }
        return fileName
    }
}

/// A format-neutral release classification suitable for persistence and UI policy.
public enum AlbumType: Codable, Equatable, Hashable, Sendable {
    case album
    case single
    case extendedPlay
    case compilation
    case soundtrack
    case live
    case unknown(String)

    public var code: String {
        switch self {
        case .album:
            return "album"
        case .single:
            return "single"
        case .extendedPlay:
            return "extended-play"
        case .compilation:
            return "compilation"
        case .soundtrack:
            return "soundtrack"
        case .live:
            return "live"
        case .unknown(let code):
            return code
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        switch code {
        case "album":
            self = .album
        case "single":
            self = .single
        case "extended-play":
            self = .extendedPlay
        case "compilation":
            self = .compilation
        case "soundtrack":
            self = .soundtrack
        case "live":
            self = .live
        default:
            self = .unknown(code)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

/// A logical source folder derived from imported directory structure.
public struct LibraryFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let path: String
    public let trackCount: Int

    public var id: String { path }

    public init(path: String, trackCount: Int) {
        let components = path.split(separator: "/").map(String.init)
        precondition(!components.isEmpty && components.allSatisfy { $0 != "." && $0 != ".." })
        precondition(trackCount >= 0)
        self.path = components.joined(separator: "/")
        self.trackCount = trackCount
    }
}

/// An immutable album and its known relationships.
public struct Album: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: AlbumID
    public let title: String
    public let sortTitle: String?
    public let artistIDs: [ArtistID]
    public let artwork: ArtworkReference?
    public let releaseYear: Int?
    public let trackCount: Int?
    public let albumType: AlbumType?

    public init(
        id: AlbumID,
        title: String,
        sortTitle: String? = nil,
        artistIDs: [ArtistID] = [],
        artwork: ArtworkReference? = nil,
        releaseYear: Int? = nil,
        trackCount: Int? = nil,
        albumType: AlbumType? = nil
    ) {
        if let releaseYear {
            precondition((1...9_999).contains(releaseYear), "Album.releaseYear is out of range")
        }
        if let trackCount {
            _ = musicDomainNonNegative(trackCount, field: "trackCount")
        }

        self.id = id
        self.title = musicDomainRequiredText(title, field: "Album.title")
        self.sortTitle = musicDomainOptionalText(sortTitle)
        self.artistIDs = musicDomainUnique(artistIDs)
        self.artwork = artwork
        self.releaseYear = releaseYear
        self.trackCount = trackCount
        self.albumType = albumType
    }

    public var artworkID: ArtworkID? {
        artwork?.id
    }

    public var artistID: ArtistID? {
        artistIDs.first
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sortTitle
        case artistIDs
        case artwork
        case releaseYear
        case trackCount
        case albumType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let releaseYear = try container.decodeIfPresent(Int.self, forKey: .releaseYear)
        let trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              releaseYear == nil || (1...9_999).contains(releaseYear!),
              trackCount == nil || trackCount! >= 0
        else {
            throw musicDomainDecodingFailure(decoder, field: "Album")
        }
        self.init(
            id: try container.decode(AlbumID.self, forKey: .id),
            title: title,
            sortTitle: try container.decodeIfPresent(String.self, forKey: .sortTitle),
            artistIDs: try container.decodeIfPresent([ArtistID].self, forKey: .artistIDs) ?? [],
            artwork: try container.decodeIfPresent(ArtworkReference.self, forKey: .artwork),
            releaseYear: releaseYear,
            trackCount: trackCount,
            albumType: try container.decodeIfPresent(AlbumType.self, forKey: .albumType)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(sortTitle, forKey: .sortTitle)
        try container.encode(artistIDs, forKey: .artistIDs)
        try container.encodeIfPresent(artwork, forKey: .artwork)
        try container.encodeIfPresent(releaseYear, forKey: .releaseYear)
        try container.encodeIfPresent(trackCount, forKey: .trackCount)
        try container.encodeIfPresent(albumType, forKey: .albumType)
    }
}

/// An immutable artist model.
public struct Artist: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ArtistID
    public let name: String
    public let sortName: String?
    public let artwork: ArtworkReference?

    public init(
        id: ArtistID,
        name: String,
        sortName: String? = nil,
        artwork: ArtworkReference? = nil
    ) {
        self.id = id
        self.name = musicDomainRequiredText(name, field: "Artist.name")
        self.sortName = musicDomainOptionalText(sortName)
        self.artwork = artwork
    }

    public var artworkID: ArtworkID? {
        artwork?.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortName
        case artwork
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw musicDomainDecodingFailure(decoder, field: "Artist.name")
        }
        self.init(
            id: try container.decode(ArtistID.self, forKey: .id),
            name: name,
            sortName: try container.decodeIfPresent(String.self, forKey: .sortName),
            artwork: try container.decodeIfPresent(ArtworkReference.self, forKey: .artwork)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sortName, forKey: .sortName)
        try container.encodeIfPresent(artwork, forKey: .artwork)
    }
}

/// An immutable genre model.
public struct Genre: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: GenreID
    public let name: String
    public let sortName: String?

    public init(id: GenreID, name: String, sortName: String? = nil) {
        self.id = id
        self.name = musicDomainRequiredText(name, field: "Genre.name")
        self.sortName = musicDomainOptionalText(sortName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw musicDomainDecodingFailure(decoder, field: "Genre.name")
        }
        self.init(
            id: try container.decode(GenreID.self, forKey: .id),
            name: name,
            sortName: try container.decodeIfPresent(String.self, forKey: .sortName)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sortName, forKey: .sortName)
    }
}

/// Playlist metadata. Entries are stored separately and ordered by their position.
public struct Playlist: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: PlaylistID
    public let name: String
    public let sortName: String?
    public let artwork: ArtworkReference?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: PlaylistID,
        name: String,
        sortName: String? = nil,
        artwork: ArtworkReference? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        if let createdAt, let updatedAt {
            precondition(updatedAt >= createdAt, "Playlist.updatedAt cannot precede createdAt")
        }

        self.id = id
        self.name = musicDomainRequiredText(name, field: "Playlist.name")
        self.sortName = musicDomainOptionalText(sortName)
        self.artwork = artwork
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var artworkID: ArtworkID? {
        artwork?.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortName
        case artwork
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              createdAt == nil || updatedAt == nil || updatedAt! >= createdAt!
        else {
            throw musicDomainDecodingFailure(decoder, field: "Playlist")
        }
        self.init(
            id: try container.decode(PlaylistID.self, forKey: .id),
            name: name,
            sortName: try container.decodeIfPresent(String.self, forKey: .sortName),
            artwork: try container.decodeIfPresent(ArtworkReference.self, forKey: .artwork),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sortName, forKey: .sortName)
        try container.encodeIfPresent(artwork, forKey: .artwork)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// A playlist member whose integer position is the ordering source of truth.
public struct PlaylistEntry: Codable, Equatable, Hashable, Comparable, Sendable {
    public let playlistID: PlaylistID
    public let trackID: MediaItemID
    public let position: Int

    public init(playlistID: PlaylistID, trackID: MediaItemID, position: Int) {
        self.playlistID = playlistID
        self.trackID = trackID
        self.position = musicDomainNonNegative(position, field: "PlaylistEntry.position")
    }

    /// Orders entries by playlist, then position, then track ID for deterministic ties.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.playlistID != rhs.playlistID {
            return lhs.playlistID < rhs.playlistID
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        return lhs.trackID < rhs.trackID
    }

    private enum CodingKeys: String, CodingKey {
        case playlistID
        case trackID
        case position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let position = try container.decode(Int.self, forKey: .position)
        guard position >= 0 else {
            throw musicDomainDecodingFailure(decoder, field: "PlaylistEntry.position")
        }
        self.init(
            playlistID: try container.decode(PlaylistID.self, forKey: .playlistID),
            trackID: try container.decode(MediaItemID.self, forKey: .trackID),
            position: position
        )
    }
}
