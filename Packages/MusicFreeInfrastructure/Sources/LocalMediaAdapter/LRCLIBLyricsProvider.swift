import Foundation
import MusicDomain
import OSLog

private let logger = Logger(
    subsystem: "com.musicfree.app",
    category: "lrc-api"
)
/// Configuration for the public LRCLIB API. The configured URL may be either
/// the service root (`https://lrclib.net`) or the complete `/api/get` endpoint.
public struct LRCLIBAPIConfiguration: Sendable, Equatable {
    public let endpointURL: URL
    public let requestTimeout: TimeInterval

    public init?(
        baseURL: URL,
        requestTimeout: TimeInterval = 20
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

        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "api/get" {
            endpointURL = baseURL
        } else {
            endpointURL = baseURL
                .appendingPathComponent("api", isDirectory: true)
                .appendingPathComponent("get", isDirectory: false)
        }
        self.requestTimeout = requestTimeout
    }

    public static func from(bundle: Bundle = .main) -> Self? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "LRCLIBAPIBaseURL"
        ) as? String else {
            return nil
        }
        let baseString = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseString.isEmpty,
              !isUnresolvedBuildSetting(baseString),
              let baseURL = URL(string: baseString)
        else {
            return nil
        }

        let timeout = doubleValue(
            bundle.object(forInfoDictionaryKey: "LRCLIBAPIRequestTimeout")
        ) ?? 20
        return Self(baseURL: baseURL, requestTimeout: timeout)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        guard let string = value as? String,
              !isUnresolvedBuildSetting(string)
        else {
            return nil
        }
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.contains("$(") || value.contains("${")
    }
}

/// Lyrics adapter for the official LRCLIB `/api/get` endpoint.
public actor LRCLIBLyricsProvider: LyricsProviding {
    public let provider: LyricsProviderID = .lrclib

    private static let maximumPayloadByteCount = 2 * 1024 * 1024

    private let configuration: LRCLIBAPIConfiguration
    private let session: URLSession

    public init(
        configuration: LRCLIBAPIConfiguration,
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
            URLQueryItem(name: "artist_name", value: artistName),
        ]
        var constrainedQueryItems = baseQueryItems
        var hasOptionalConstraints = false
        if let albumName = query.albumName,
           !albumName.isEmpty {
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
        case 200 ... 299:
            break
        case 404:
            logger.info("req=\(request.url?.absoluteString ?? "nil"), res=\(httpResponse.statusCode), data=\(data.count)")
            return nil
        case 429:
            logger.info("req=\(request.url?.absoluteString ?? "nil"), res=\(httpResponse.statusCode), data=\(data.count)")
            throw LyricsProviderError.requestFailed(
                code: "lrclib_rate_limited",
                httpStatus: httpResponse.statusCode
            )
        default:
            logger.info("req=\(request.url?.absoluteString ?? "nil"), res=\(httpResponse.statusCode), data=\(data.count)")
            throw LyricsProviderError.requestFailed(
                code: "lrclib_http_\(httpResponse.statusCode)",
                httpStatus: httpResponse.statusCode
            )
        }

        guard !data.isEmpty else { return nil }
        let payload: LRCLIBResponse
        do {
            payload = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        } catch {
            throw LyricsProviderError.invalidResponse
        }

        guard !payload.instrumental else { return nil }
        let rawCandidates: [String?] = [
            payload.syncedLyrics,
            payload.lyricsFile,
            payload.lyricsfile,
            payload.plainLyrics,
        ]
        let rawLyrics = rawCandidates.compactMap { (value: String?) -> String? in
            guard let value else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        guard let rawLyrics = rawLyrics.first else { return nil }

        let lyrics = TrackLyrics(rawText: rawLyrics)
        return lyrics.isEmpty ? nil : lyrics
    }
}

private struct LRCLIBResponse: Decodable {
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
