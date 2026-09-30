import Foundation

public enum TrackContentRating: String, Codable, CaseIterable, Sendable {
    case unknown
    case clean
    case explicit
}

public struct TrackDetailMetadata: Codable, Equatable, Hashable, Sendable {
    public let composers: [String]
    public let additionalArtists: [String]
    public let contentRating: TrackContentRating

    public init(
        composers: [String] = [],
        additionalArtists: [String] = [],
        contentRating: TrackContentRating = .unknown
    ) {
        self.composers = musicDomainUnique(composers.compactMap(musicDomainOptionalMetadataText))
        self.additionalArtists = musicDomainUnique(additionalArtists.compactMap(musicDomainOptionalMetadataText))
        self.contentRating = contentRating
    }
}

public struct AlbumDetailMetadata: Codable, Equatable, Hashable, Sendable {
    public let summary: String?
    public let additionalArtists: [String]
    public let releaseDate: Date?
    public let genres: [String]
    public let discCount: Int?
    public let format: String?
    public let recordLabel: String?
    public let copyright: String?

    public init(
        summary: String? = nil,
        additionalArtists: [String] = [],
        releaseDate: Date? = nil,
        genres: [String] = [],
        discCount: Int? = nil,
        format: String? = nil,
        recordLabel: String? = nil,
        copyright: String? = nil
    ) {
        self.summary = musicDomainOptionalMetadataText(summary)
        self.additionalArtists = musicDomainUnique(additionalArtists.compactMap(musicDomainOptionalMetadataText))
        self.releaseDate = releaseDate
        self.genres = musicDomainUnique(genres.compactMap(musicDomainOptionalMetadataText))
        self.discCount = discCount.flatMap { $0 > 0 ? $0 : nil }
        self.format = musicDomainOptionalMetadataText(format)
        self.recordLabel = musicDomainOptionalMetadataText(recordLabel)
        self.copyright = musicDomainOptionalMetadataText(copyright)
    }
}

public struct ArtistDetailMetadata: Codable, Equatable, Hashable, Sendable {
    public let origin: String?
    public let birthDate: Date?
    public let biography: String?

    public init(origin: String? = nil, birthDate: Date? = nil, biography: String? = nil) {
        self.origin = musicDomainOptionalMetadataText(origin)
        self.birthDate = birthDate
        self.biography = musicDomainOptionalMetadataText(biography)
    }
}

// Source scans and older clients omit supplemental fields. Keep user edits
// during those upserts; an explicit empty details value still clears them.
@available(macOS 13.0, *)
public extension Track {
    func preservingDetails(from previous: Track?) -> Track {
        guard details == nil, let previousDetails = previous?.details else { return self }
        return Track(
            id: id, logicalTrackID: logicalTrackID, assetID: assetID,
            playbackSelection: playbackSelection, title: title, sortTitle: sortTitle,
            albumID: albumID, artistIDs: artistIDs, genreIDs: genreIDs,
            trackNumber: trackNumber, trackTotal: trackTotal,
            discNumber: discNumber, discTotal: discTotal,
            fileName: fileName, folderPath: folderPath, duration: duration,
            technicalInfo: technicalInfo, year: year, comment: comment,
            lyrics: lyrics, artwork: artwork, isFavorite: isFavorite,
            statistics: statistics, details: previousDetails
        )
    }
}

public extension Album {
    func preservingDetails(from previous: Album?) -> Album {
        guard details == nil, let previousDetails = previous?.details else { return self }
        return Album(
            id: id, title: title, sortTitle: sortTitle, artistIDs: artistIDs,
            artwork: artwork, releaseYear: previousDetails.releaseDate == nil ? releaseYear : previous?.releaseYear,
            trackCount: trackCount, albumType: previous?.albumType ?? albumType,
            isFavorite: isFavorite, details: previousDetails
        )
    }
}

public extension Artist {
    func preservingDetails(from previous: Artist?) -> Artist {
        guard details == nil, let previousDetails = previous?.details else { return self }
        return Artist(
            id: id, name: previous?.name ?? name, sortName: previous?.sortName ?? sortName,
            artwork: artwork ?? previous?.artwork, details: previousDetails
        )
    }
}
