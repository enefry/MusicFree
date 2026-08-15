import Foundation
import MusicDomain

/// The app-level metadata override. It changes the library representation only;
/// writing tags back into the original media file is deliberately out of scope.
///
/// This is a complete replacement request, not a partial patch: an omitted
/// optional value clears that field or relationship. Callers that want to
/// preserve existing values must provide them explicitly. The editor follows
/// this contract by loading the current relationship values before saving.
@available(macOS 13.0, iOS 16.0, *)
public struct TrackMetadataUpdate: Sendable {
    public let itemID: MediaItemID
    public let title: String
    public let artistName: String?
    /// When supplied, replaces the complete artist relationship list. `nil`
    /// keeps the legacy single-value `artistName` behavior.
    public let artistNames: [String]?
    public let albumArtistName: String?
    /// When supplied, preserves or replaces all album-artist relationships.
    public let albumArtistNames: [String]?
    public let albumName: String?
    public let genreName: String?
    /// When supplied, replaces the complete genre relationship list.
    public let genreNames: [String]?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let comment: String?
    public let lyrics: TrackLyrics?
    public let artwork: ArtworkEdit

    public init(
        itemID: MediaItemID,
        title: String,
        artistName: String? = nil,
        artistNames: [String]? = nil,
        albumArtistName: String? = nil,
        albumArtistNames: [String]? = nil,
        albumName: String? = nil,
        genreName: String? = nil,
        genreNames: [String]? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        comment: String? = nil,
        lyrics: TrackLyrics? = nil,
        artwork: ArtworkEdit = .keep
    ) {
        self.itemID = itemID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistName = Self.normalized(artistName)
        self.artistNames = Self.normalizedList(artistNames)
        self.albumArtistName = Self.normalized(albumArtistName)
        self.albumArtistNames = Self.normalizedList(albumArtistNames)
        self.albumName = Self.normalized(albumName)
        self.genreName = Self.normalized(genreName)
        self.genreNames = Self.normalizedList(genreNames)
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.comment = Self.normalized(comment)
        self.lyrics = lyrics
        self.artwork = artwork
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedList(_ values: [String]?) -> [String]? {
        guard let values else { return nil }
        var seen = Set<String>()
        return values.compactMap(normalized).filter { seen.insert($0).inserted }
    }
}

public enum ArtworkEdit: Sendable, Equatable {
    case keep
    case remove
    case replace(Data)
}
