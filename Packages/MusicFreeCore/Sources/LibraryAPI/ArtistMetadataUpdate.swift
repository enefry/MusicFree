import Foundation
import MusicDomain

public struct ArtistMetadataUpdate: Sendable {
    public let artistID: ArtistID
    public let name: String
    public let details: ArtistDetailMetadata
    public let artwork: ArtworkEdit

    public init(
        artistID: ArtistID,
        name: String,
        details: ArtistDetailMetadata,
        artwork: ArtworkEdit = .keep
    ) {
        self.artistID = artistID
        self.name = MetadataTextRepair.repair(name).trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details
        self.artwork = artwork
    }
}
