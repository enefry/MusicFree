import Foundation
import MusicDomain

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

    /// Derives `/api/v1/lyrics` from the configured `/api/v1/metadata` URL.
    public init?(metadataServerConfiguration: MetadataServerConfiguration) {
        guard var components = URLComponents(
            url: metadataServerConfiguration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        var pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathComponents.last == "metadata" else {
            return nil
        }
        pathComponents[pathComponents.count - 1] = "lyrics"
        components.path = "/" + pathComponents.joined(separator: "/")
        guard let lyricsBaseURL = components.url else {
            return nil
        }

        self.init(
            baseURL: lyricsBaseURL,
            requestTimeout: metadataServerConfiguration.requestTimeout
        )
    }

    public static func from(bundle: Bundle = .main) -> Self? {
        guard let metadataConfiguration = MetadataServerConfiguration.from(bundle: bundle) else {
            return nil
        }
        return Self(metadataServerConfiguration: metadataConfiguration)
    }
}

/// Lyrics adapter for the Metadata Server's LRCLIB-compatible `/get` route.
public actor MetadataServerLyricsProvider: LyricsProviding {
    public let provider: LyricsProviderID = .metadataServer

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

    public func fetchLyrics(for query: LyricsQuery) async throws -> TrackLyrics? {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let artistName = query.artistName,
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
        if let albumName = query.albumName {
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

    private func fetchLyrics(queryItems: [URLQueryItem]) async throws -> TrackLyrics? {
        var components = URLComponents(
            url: configuration.endpointURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw LyricsProviderError.unavailable
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
            throw LyricsProviderError.network
        }

        guard data.count <= Self.maximumPayloadByteCount else {
            throw LyricsProviderError.payloadTooLarge
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsProviderError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 404:
            return nil
        case 429:
            throw LyricsProviderError.requestFailed(
                code: "metadata_server_lyrics_rate_limited",
                httpStatus: httpResponse.statusCode
            )
        case 401:
            throw LyricsProviderError.requestFailed(
                code: "metadata_server_lyrics_unauthorized",
                httpStatus: httpResponse.statusCode
            )
        default:
            throw LyricsProviderError.requestFailed(
                code: "metadata_server_lyrics_http_\(httpResponse.statusCode)",
                httpStatus: httpResponse.statusCode
            )
        }

        guard !data.isEmpty else { return nil }
        let payload: MetadataServerLyricsResponse
        do {
            payload = try JSONDecoder().decode(MetadataServerLyricsResponse.self, from: data)
        } catch {
            throw LyricsProviderError.invalidResponse
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
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }).first else {
            return nil
        }

        let lyrics = TrackLyrics(rawText: rawLyrics)
        return lyrics.isEmpty ? nil : lyrics
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
