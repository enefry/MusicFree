import Foundation
import MusicDomain

enum PersistenceCodec {
    private static let preciseDatePrefix = "ref:"

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        let preciseDatePrefix = Self.preciseDatePrefix
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                "\(preciseDatePrefix)\(date.timeIntervalSinceReferenceDate)"
            )
        }
        do {
            return try encoder.encode(value)
        } catch {
            throw LibraryPersistenceError.encodingFailed
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        let preciseDatePrefix = Self.preciseDatePrefix
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                guard value.hasPrefix(preciseDatePrefix),
                      let interval = Double(String(value.dropFirst(preciseDatePrefix.count))),
                      interval.isFinite
                else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid MusicFree reference-date value."
                    )
                }
                return Date(timeIntervalSinceReferenceDate: interval)
            }

            // Records written before the precision upgrade stored Unix time in
            // milliseconds. Keep those payloads readable during the migration.
            let milliseconds = try container.decode(Double.self)
            guard milliseconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid legacy millisecond date value."
                )
            }
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LibraryPersistenceError.corruptedRecord
        }
    }
}

enum PersistenceKey {
    static func item(_ itemID: MediaItemID) -> String {
        let source = itemID.sourceID.rawValue
        return "\(source.utf8.count):\(source)\(itemID.externalID)"
    }

    static func asset(_ assetID: MediaAssetID) -> String {
        item(assetID.mediaItemID)
    }

    static func collectionMember(_ value: LibraryCollectionMember) -> String {
        composite(
            namespace: "collection-member",
            components: [value.collectionID.rawValue, value.releaseID.rawValue]
        )
    }

    static func legacyCollectionMember(_ value: LibraryCollectionMember) -> String {
        "\(value.collectionID.rawValue)|\(value.releaseID.rawValue)"
    }

    static func playlist(_ playlistID: PlaylistID) -> String {
        playlistID.rawValue
    }

    static func artwork(_ artworkID: ArtworkID) -> String {
        artworkID.rawValue
    }

    static func history(_ sessionID: UUID) -> String {
        sessionID.uuidString.lowercased()
    }

    static func entry(playlistID: PlaylistID, itemID: MediaItemID) -> String {
        composite(
            namespace: "playlist-entry",
            components: [playlistID.rawValue, item(itemID)]
        )
    }

    static func legacyEntry(playlistID: PlaylistID, itemID: MediaItemID) -> String {
        "\(playlistID.rawValue)|\(item(itemID))"
    }

    private static func composite(namespace: String, components: [String]) -> String {
        let encodedComponents = components.map { component in
            let encoded = Data(component.utf8).base64EncodedString()
            return "\(encoded.utf8.count):\(encoded)"
        }
        return "v2:\(namespace):\(encodedComponents.joined())"
    }
}
