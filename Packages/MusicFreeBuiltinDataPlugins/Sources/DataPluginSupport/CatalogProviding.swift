import Foundation
import MusicFreePluginAPI

/// Package implementation boundary; only SDK DTOs cross into the application.
public protocol CatalogProviding: Sendable {
    func search(_ query: CatalogQuery) async throws -> [CatalogCandidate]
    func artworkData(for candidate: CatalogCandidate) async throws -> Data?
}

public extension PluginOperationContext {
    func requireNetwork() throws {
        try Task.checkCancellation()
        guard permissions.contains(.network), applicationPrivacyAccepted else {
            throw PluginError.permissionRequired
        }
    }
}

public extension CatalogCandidate {
    func pluginCandidate(fields: Set<PluginMetadataField>) -> PluginMetadataCandidate {
        var text: [PluginMetadataField: String] = [:]
        var numbers: [PluginMetadataField: Int] = [:]
        for (field, value) in [(PluginMetadataField.title, title), (.artist, artistName),
            (.albumArtist, albumArtistName), (.album, albumName), (.genre, genreName)] {
            if fields.contains(field), let value { text[field] = value }
        }
        for (field, value) in [(PluginMetadataField.year, year), (.trackNumber, trackNumber), (.discNumber, discNumber)] {
            if fields.contains(field), let value { numbers[field] = value }
        }
        return .init(id: catalogID,
            track: .init(title: title, artist: artistName, album: albumName, durationSeconds: durationSeconds),
            patch: .init(text: text, numbers: numbers), artworkReference: fields.contains(.artwork) ? catalogID : nil)
    }
}

public enum ArtworkDataLimits {
    public static let maximumByteCount = 20 * 1024 * 1024
}
