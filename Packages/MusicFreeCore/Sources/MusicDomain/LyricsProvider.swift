import Foundation

/// Stable identifier for a lyrics provider implementation.
public struct LyricsProviderID: RawRepresentable, Codable, Hashable, Comparable, Sendable, Identifiable {
    public static let metadataServer = Self(rawValue: "metadataServer")
    public static let lrclib = Self(rawValue: "lrclib")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = musicDomainRequiredText(rawValue, field: "LyricsProviderID")
    }

    public var id: Self { self }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Metadata used to look up lyrics without exposing a source URL or local
/// filesystem path to an online provider.
@available(macOS 13.0, iOS 16.0, *)
public struct LyricsQuery: Hashable, Sendable {
    public let itemID: MediaItemID
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let durationSeconds: TimeInterval?

    public init(
        itemID: MediaItemID,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        self.itemID = itemID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistName = Self.normalized(artistName)
        self.albumName = Self.normalized(albumName)
        self.durationSeconds = durationSeconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public enum LyricsProviderError: Error, Equatable, Sendable {
    case unavailable
    case noMatch
    case network
    case requestFailed(code: String, httpStatus: Int?)
    case invalidResponse
    case payloadTooLarge
}

/// Provider boundary for online or otherwise external lyrics services.
@available(macOS 13.0, iOS 16.0, *)
public protocol LyricsProviding: Sendable {
    var provider: LyricsProviderID { get }
    func fetchLyrics(for query: LyricsQuery) async throws -> TrackLyrics?
}
