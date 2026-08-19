import Foundation
import MusicDomain

/// The app-level metadata override for one album. It updates the library
/// representation only and deliberately does not write tags to media files.
///
/// `artistNames`, when supplied, replaces the complete album-artist
/// relationship. A nil value clears that relationship, matching the complete
/// replacement semantics used by the track metadata editor.
@available(macOS 13.0, iOS 16.0, *)
public struct AlbumMetadataUpdate: Sendable {
    public let albumID: AlbumID
    public let title: String
    public let artistNames: [String]?
    public let releaseYear: Int?

    public init(
        albumID: AlbumID,
        title: String,
        artistNames: [String]? = nil,
        releaseYear: Int? = nil
    ) {
        self.albumID = albumID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistNames = Self.normalizedList(artistNames)
        self.releaseYear = releaseYear
    }

    private static func normalizedList(_ values: [String]?) -> [String]? {
        guard let values else { return nil }
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
