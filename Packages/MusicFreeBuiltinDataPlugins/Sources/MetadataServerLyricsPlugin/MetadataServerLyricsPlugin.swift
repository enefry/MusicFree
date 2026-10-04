// Extracted from the legacy provider; original implementation is retained.
import Foundation
import MusicFreePluginAPI
import DataPluginSupport

/// Configuration for the lyrics service exposed beside the Metadata Server.
/// The metadata and lyrics services share a host and public API prefix, but
/// retain separate endpoint paths.
public struct MetadataServerLyricsConfiguration: Sendable, Equatable {
    public let endpointURL: URL
    public let requestTimeout: TimeInterval

    public init?(
        baseURL: URL,
        requestTimeout: TimeInterval = 45
    ) {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              requestTimeout.isFinite,
              requestTimeout > 0
        else {
            return nil
        }

        let pathComponents = baseURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if pathComponents.last == "get" {
            endpointURL = baseURL
        } else {
            endpointURL = baseURL.appendingPathComponent("get")
        }
        self.requestTimeout = requestTimeout
    }


}

/// Lyrics adapter for the Metadata Server's LRCLIB-compatible `/get` route.
public actor MetadataServerLyricsPlugin: LyricsPlugin {

    private static let maximumPayloadByteCount = 2 * 1024 * 1024

    private let configuration: MetadataServerLyricsConfiguration
    private let session: URLSession

    public init(
        configuration: MetadataServerLyricsConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    private func fetchLyrics(for query: PluginTrackQuery) async throws -> String? {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let artistName = query.artist,
              !artistName.isEmpty
        else {
            return nil
        }

        let baseQueryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artistName)
        ]
        var constrainedQueryItems = baseQueryItems
        var hasOptionalConstraints = false
        if let albumName = query.album {
            constrainedQueryItems.append(URLQueryItem(name: "album_name", value: albumName))
            hasOptionalConstraints = true
        }
        if let duration = query.durationSeconds,
           duration > 0,
           duration <= 3_600 {
            constrainedQueryItems.append(
                URLQueryItem(
                    name: "duration",
                    value: String(
                        format: "%.3f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        duration
                    )
                )
            )
            hasOptionalConstraints = true
        }

        let queryVariants = !hasOptionalConstraints
            ? [baseQueryItems]
            : [constrainedQueryItems, baseQueryItems]
        for queryItems in queryVariants {
            if let lyrics = try await fetchLyrics(queryItems: queryItems) {
                return lyrics
            }
        }
        return nil
    }

    private func fetchLyrics(queryItems: [URLQueryItem]) async throws -> String? {
        var components = URLComponents(
            url: configuration.endpointURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw PluginDataError.unavailable
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MusicFree/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginDataError.network
        }

        guard data.count <= Self.maximumPayloadByteCount else {
            throw PluginDataError.payloadTooLarge
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginDataError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 404:
            return nil
        case 429:
            throw PluginDataError.requestFailed(
                code: "metadata_server_lyrics_rate_limited",
                httpStatus: httpResponse.statusCode
            )
        case 401:
            throw PluginDataError.requestFailed(
                code: "metadata_server_lyrics_unauthorized",
                httpStatus: httpResponse.statusCode
            )
        default:
            throw PluginDataError.requestFailed(
                code: "metadata_server_lyrics_http_\(httpResponse.statusCode)",
                httpStatus: httpResponse.statusCode
            )
        }

        guard !data.isEmpty else { return nil }
        let payload: MetadataServerLyricsResponse
        do {
            payload = try JSONDecoder().decode(MetadataServerLyricsResponse.self, from: data)
        } catch {
            throw PluginDataError.invalidResponse
        }

        guard !payload.instrumental else { return nil }
        let rawCandidates: [String?] = [
            payload.syncedLyrics,
            payload.lyricsfile,
            payload.lyricsFile,
            payload.plainLyrics
        ]
        guard let rawLyrics = rawCandidates.compactMap({ (value: String?) -> String? in
            guard let value else { return nil }
            let normalized = MetadataTextRepair.repair(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }).first else {
            return nil
        }

        return rawLyrics.isEmpty ? nil : rawLyrics
    }
}

private struct MetadataServerLyricsResponse: Decodable {
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let lyricsfile: String?
    let lyricsFile: String?

    private enum CodingKeys: String, CodingKey {
        case instrumental
        case plainLyrics
        case syncedLyrics
        case lyricsfile
        case lyricsFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instrumental = try container.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        plainLyrics = try container.decodeIfPresent(String.self, forKey: .plainLyrics)
        syncedLyrics = try container.decodeIfPresent(String.self, forKey: .syncedLyrics)
        lyricsfile = try container.decodeIfPresent(String.self, forKey: .lyricsfile)
        lyricsFile = try container.decodeIfPresent(String.self, forKey: .lyricsFile)
    }
}

extension MetadataServerLyricsPlugin {
    public static var descriptor: PluginDescriptor {
        .init(id: .init(rawValue: "builtin.lyrics.metadataServer"), name: "Metadata Server Lyrics", kinds: [.lyrics], permissions: [.network], policyVersion: "1.2.0", dataProviderID: "metadataServer")
    }
    public func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        try context.requireNetwork()
        guard let text = try await fetchLyrics(for: query) else { return [] }
        try Task.checkCancellation()
        return [.init(id: Self.descriptor.id.rawValue, track: query, rawText: text)]
    }
}
