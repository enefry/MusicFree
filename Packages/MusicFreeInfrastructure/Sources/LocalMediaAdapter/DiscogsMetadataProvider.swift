import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import OSLog

/// Configuration for the official Discogs API.
///
/// Discogs requires a descriptive User-Agent even for anonymous requests. A
/// personal token is optional and is sent only as an Authorization header when
/// configured. The token is never included in diagnostics or durable records.
public struct DiscogsAPIConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let userAgent: String
    public let token: String?
    public let requestTimeout: TimeInterval
    public let minimumRequestInterval: TimeInterval

    public init?(
        baseURL: URL,
        userAgent: String,
        token: String? = nil,
        requestTimeout: TimeInterval = 45,
        minimumRequestInterval: TimeInterval? = nil
    ) {
        let normalizedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = Self.normalizedSecret(token)
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              !normalizedAgent.isEmpty,
              !normalizedAgent.contains("\r"),
              !normalizedAgent.contains("\n"),
              requestTimeout.isFinite,
              requestTimeout > 0
        else {
            return nil
        }

        let interval = minimumRequestInterval ?? (
            normalizedToken == nil ? 60.0 / 25.0 : 60.0 / 60.0
        )
        guard interval.isFinite, interval >= 0 else { return nil }

        self.baseURL = baseURL
        self.userAgent = normalizedAgent
        self.token = normalizedToken
        self.requestTimeout = requestTimeout
        self.minimumRequestInterval = interval
    }

    /// Reads build-time configuration. An empty or unresolved base URL keeps
    /// the provider out of the composition graph.
    public static func from(bundle: Bundle = .main) -> Self? {
        guard let baseValue = bundle.object(
            forInfoDictionaryKey: "DiscogsAPIBaseURL"
        ) as? String else {
            return nil
        }
        let baseString = baseValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseString.isEmpty,
              !Self.isUnresolvedBuildSetting(baseString),
              let baseURL = URL(string: baseString)
        else {
            return nil
        }

        let displayName = (bundle.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAgent = [displayName, version]
            .compactMap { value in
                guard let value, !value.isEmpty, !Self.isUnresolvedBuildSetting(value) else {
                    return nil
                }
                return value
            }
            .joined(separator: "/")
        let userAgent = Self.stringValue(
            bundle.object(forInfoDictionaryKey: "DiscogsAPIUserAgent")
        ) ?? (fallbackAgent.isEmpty ? "MusicFree/1.0" : fallbackAgent)
        let token = Self.stringValue(
            bundle.object(forInfoDictionaryKey: "DiscogsAPIToken")
        )
        let timeout = Self.doubleValue(
            bundle.object(forInfoDictionaryKey: "DiscogsAPIRequestTimeout")
        ) ?? 45
        let interval = Self.doubleValue(
            bundle.object(forInfoDictionaryKey: "DiscogsAPIMinimumRequestInterval")
        )

        return Self(
            baseURL: baseURL,
            userAgent: userAgent,
            token: token,
            requestTimeout: timeout,
            minimumRequestInterval: interval
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isUnresolvedBuildSetting(normalized) else { return nil }
        return normalized
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        guard let string = stringValue(value) else { return nil }
        return Double(string)
    }

    private static func normalizedSecret(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !isUnresolvedBuildSetting(normalized),
              !normalized.contains("\r"),
              !normalized.contains("\n")
        else {
            return nil
        }
        return normalized
    }

    private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.contains("$(") || value.contains("${")
    }
}

/// Read-only metadata enrichment backed by the official Discogs API.
///
/// Discogs search indexes releases rather than individual tracks. The adapter
/// therefore searches releases with the track and artist filters, then reads
/// each small set of release details until a matching tracklist entry is found.
public actor DiscogsMetadataProvider: MetadataEnrichmentProviding {
    public let provider: MetadataEnrichmentProvider = .discogs

    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "discogs-api"
    )

    private let configuration: DiscogsAPIConfiguration
    private let session: URLSession
    private var lastRequestAt: Date?
    private var releaseDetails: [Int: DiscogsRelease] = [:]
    private var releaseIDs: [String: Int] = [:]
    private var artworkURLs: [String: URL] = [:]

    public init(
        configuration: DiscogsAPIConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
        .authorized
    }

    public func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        .authorized
    }

    public func search(
        _ query: MetadataEnrichmentQuery
    ) async throws -> [MetadataEnrichmentCandidate] {
        let trackNames = Self.trackNames(for: query)
        guard !trackNames.isEmpty else { return [] }

        var firstDetailError: MetadataEnrichmentError?
        for requestTrackName in trackNames {
            let queryItems = [
                URLQueryItem(name: "type", value: "release"),
                URLQueryItem(name: "track", value: requestTrackName),
                URLQueryItem(name: "artist", value: Self.artistName(for: query)),
                URLQueryItem(name: "per_page", value: "10")
            ].filter { $0.value != nil }

            Self.logger.info(
                "search request track=\(requestTrackName, privacy: .public) artist=\(query.artistName ?? "-", privacy: .public)"
            )
            let request = try makeRequest(
                pathComponents: ["database", "search"],
                queryItems: queryItems,
                accept: "application/vnd.discogs.v2.discogs+json"
            )
            guard let data = try await perform(
                request,
                operation: "search",
                allowNotFound: false
            ) else {
                continue
            }

            let searchResponse: DiscogsSearchResponse
            do {
                searchResponse = try JSONDecoder().decode(
                    DiscogsSearchResponse.self,
                    from: data
                )
            } catch {
                throw MetadataEnrichmentError.requestFailed(
                    code: "discogs_invalid_search_response",
                    httpStatus: 200
                )
            }

            var candidates: [MetadataEnrichmentCandidate] = []
            for result in searchResponse.results.prefix(10) {
                guard result.id > 0 else { continue }
                do {
                    guard let release = try await fetchRelease(id: result.id) else {
                        continue
                    }
                    candidates.append(contentsOf: makeCandidates(
                        from: release,
                        searchResult: result,
                        trackNames: trackNames
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MetadataEnrichmentError {
                    if firstDetailError == nil,
                       !Self.isNotFound(error)
                    {
                        firstDetailError = error
                    }
                    if Self.shouldAbortDetailSearch(error) {
                        throw error
                    }
                }
            }

            if !candidates.isEmpty {
                trimCaches()
                return candidates
            }
        }

        trimCaches()
        if let firstDetailError {
            throw firstDetailError
        }
        return []
    }

    public func artworkData(
        for candidate: MetadataEnrichmentCandidate
    ) async throws -> Data? {
        if let artworkData = candidate.artworkData {
            return artworkData
        }

        if artworkURLs[candidate.catalogID] == nil,
           let releaseID = releaseIDs[candidate.catalogID]
        {
            do {
                _ = try await fetchRelease(id: releaseID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }

        guard let artworkURL = artworkURLs[candidate.catalogID] else { return nil }
        let request = try makeRequest(
            url: artworkURL,
            accept: "image/*"
        )
        guard let data = try await perform(
            request,
            operation: "artwork",
            allowNotFound: true
        ) else {
            return nil
        }
        guard !data.isEmpty, data.count <= ArtworkDataLimits.maximumByteCount else {
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_artwork_invalid_size",
                httpStatus: nil
            )
        }
        return data
    }

    private func fetchRelease(id: Int) async throws -> DiscogsRelease? {
        if let cached = releaseDetails[id] { return cached }
        let request = try makeRequest(
            pathComponents: ["releases", String(id)],
            accept: "application/vnd.discogs.v2.discogs+json"
        )
        guard let data = try await perform(
            request,
            operation: "release",
            allowNotFound: true
        ) else {
            return nil
        }

        let release: DiscogsRelease
        do {
            release = try JSONDecoder().decode(DiscogsRelease.self, from: data)
        } catch {
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_invalid_release_response",
                httpStatus: 200
            )
        }
        releaseDetails[id] = release
        return release
    }

    private func makeCandidates(
        from release: DiscogsRelease,
        searchResult: DiscogsSearchResult,
        trackNames: [String]
    ) -> [MetadataEnrichmentCandidate] {
        let requestedTitles = Set(trackNames.map(Self.normalizedForComparison))
        let releaseArtistNames = release.artists.compactMap { Self.normalized($0.name) }
        let albumArtistName = releaseArtistNames.joined(separator: ", ")
        let albumName = Self.normalized(release.title)
            ?? Self.releaseTitle(searchResult.title)
        let year = release.year?.value ?? searchResult.year?.value
        let genreName = release.genres.first ?? release.styles.first

        return release.tracklist.compactMap { track in
            guard track.type == nil || track.type == "track",
                  let title = Self.normalized(track.title),
                  requestedTitles.contains(Self.normalizedForComparison(title))
            else {
                return nil
            }

            let position = Self.normalized(track.position) ?? "unknown"
            let catalogID = [
                "discogs",
                "release-\(release.id)",
                position,
                MusicContentIdentity.sha256Hex(Data(title.utf8))
            ].joined(separator: ":")
            releaseIDs[catalogID] = release.id
            if let imageURL = release.preferredImageURL {
                artworkURLs[catalogID] = imageURL
            }

            let trackArtists = track.artists.compactMap { Self.normalized($0.name) }
            let artistName = trackArtists.isEmpty
                ? Self.normalized(albumArtistName)
                : trackArtists.joined(separator: ", ")
            let parsedPosition = Self.parsePosition(position)

            return MetadataEnrichmentCandidate(
                catalogID: catalogID,
                title: title,
                artistName: artistName,
                albumArtistName: Self.normalized(albumArtistName),
                albumName: albumName,
                genreName: genreName,
                trackNumber: parsedPosition.track,
                discNumber: parsedPosition.disc,
                year: year,
                durationSeconds: Self.parseDuration(track.duration)
            )
        }
    }

    private func makeRequest(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        accept: String
    ) throws -> URLRequest {
        var url = configuration.baseURL
        for component in pathComponents {
            url = url.appendingPathComponent(component)
        }
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_invalid_url",
                httpStatus: nil
            )
        }
        components.queryItems = queryItems
        guard let resolvedURL = components.url else {
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_invalid_url",
                httpStatus: nil
            )
        }
        return try makeRequest(url: resolvedURL, accept: accept)
    }

    private func makeRequest(
        url: URL,
        accept: String
    ) throws -> URLRequest {
        guard url.scheme != nil, url.host != nil else {
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_invalid_url",
                httpStatus: nil
            )
        }
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token = configuration.token {
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        operation: String,
        allowNotFound: Bool
    ) async throws -> Data? {
        try await waitForRequestSlot()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MetadataEnrichmentError.requestFailed(
                    code: "discogs_invalid_response",
                    httpStatus: nil
                )
            }
            Self.logger.info(
                "request completed operation=\(operation, privacy: .public) path=\(httpResponse.url?.path ?? "-", privacy: .public) status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            if allowNotFound, httpResponse.statusCode == 404 { return nil }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw Self.mapHTTPError(
                    statusCode: httpResponse.statusCode,
                    response: httpResponse,
                    operation: operation
                )
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MetadataEnrichmentError {
            throw error
        } catch let error as URLError {
            try Task.checkCancellation()
            throw Self.mapURLSessionError(error, operation: operation)
        } catch {
            try Task.checkCancellation()
            throw MetadataEnrichmentError.requestFailed(
                code: "discogs_\(operation)_request_failed",
                httpStatus: nil
            )
        }
    }

    private func waitForRequestSlot() async throws {
        let interval = configuration.minimumRequestInterval
        if interval > 0, let lastRequestAt {
            let remaining = interval - Date().timeIntervalSince(lastRequestAt)
            if remaining > 0 {
                let nanoseconds = UInt64((remaining * 1_000_000_000).rounded(.up))
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        try Task.checkCancellation()
        lastRequestAt = Date()
    }

    private func trimCaches() {
        guard releaseIDs.count > 128 else { return }
        let keep = Set(releaseIDs.keys.suffix(128))
        releaseIDs = releaseIDs.filter { keep.contains($0.key) }
        artworkURLs = artworkURLs.filter { keep.contains($0.key) }
        let activeReleaseIDs = Set(releaseIDs.values)
        releaseDetails = releaseDetails.filter { activeReleaseIDs.contains($0.key) }
    }

    private static func trackNames(for query: MetadataEnrichmentQuery) -> [String] {
        let original = normalized(
            query.isFilenameFallback ? query.filenameTitle : query.title
        ) ?? normalized(query.filenameTitle) ?? normalized(query.filenameStem)
        guard let original else { return [] }

        var names: [String] = []
        if let suffix = leadingBracketSuffix(from: original) {
            names.append(suffix)
        }
        names.append(original)
        if let prefix = bracketSuffixPrefix(from: original) {
            names.append(prefix)
        }
        return names.reduce(into: []) { result, value in
            guard !result.contains(value) else { return }
            result.append(value)
        }
    }

    private static func artistName(for query: MetadataEnrichmentQuery) -> String? {
        normalized(query.artistName)
            ?? (query.isFilenameFallback ? normalized(query.filenameArtist) : nil)
    }

    private static func releaseTitle(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        guard let separator = value.range(of: " - ") else { return value }
        return normalized(String(value[separator.upperBound...])) ?? value
    }

    private static func leadingBracketSuffix(from value: String) -> String? {
        guard let opening = value.first,
              let closing = closingBracket(for: opening),
              let closingIndex = value.firstIndex(of: closing)
        else {
            return nil
        }
        let suffixStart = value.index(after: closingIndex)
        return normalized(String(value[suffixStart...]))
    }

    private static func bracketSuffixPrefix(from value: String) -> String? {
        guard let openingIndex = value.firstIndex(where: {
            closingBracket(for: $0) != nil
        }) else {
            return nil
        }
        return normalized(String(value[..<openingIndex]))
    }

    private static func closingBracket(for opening: Character) -> Character? {
        switch opening {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "（": return "）"
        case "【": return "】"
        default: return nil
        }
    }

    private static func parsePosition(
        _ value: String?
    ) -> (disc: Int?, track: Int?) {
        guard let value = normalized(value) else { return (nil, nil) }
        let parts = value.split { character in
            character == "-" || character == "/" || character == "–"
        }
        if parts.count >= 2,
           let disc = Int(parts[0]),
           let track = Int(parts[1])
        {
            return (disc > 0 ? disc : nil, track > 0 ? track : nil)
        }
        if parts.count == 1, let track = Int(parts[0]), track > 0 {
            return (nil, track)
        }
        return (nil, nil)
    }

    private static func parseDuration(_ value: String?) -> TimeInterval? {
        guard let value = normalized(value) else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }
        if parts.count == 1, let seconds = Double(parts[0]), seconds >= 0 {
            return seconds
        }
        guard parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count,
              numbers.dropFirst().allSatisfy({ (0 ..< 60).contains($0) })
        else {
            return nil
        }
        if numbers.count == 2 {
            return numbers[0] * 60 + numbers[1]
        }
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedForComparison(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func isNotFound(_ error: MetadataEnrichmentError) -> Bool {
        guard case let .requestFailed(code, status) = error else { return false }
        return status == 404 || code.hasSuffix("_http_404")
    }

    private static func shouldAbortDetailSearch(
        _ error: MetadataEnrichmentError
    ) -> Bool {
        switch error {
        case .notAuthorized, .rateLimited, .offline:
            return true
        case .unavailable, .requestFailed:
            return false
        }
    }

    private static func mapHTTPError(
        statusCode: Int,
        response: HTTPURLResponse,
        operation: String
    ) -> MetadataEnrichmentError {
        switch statusCode {
        case 401, 403:
            return .notAuthorized
        case 429:
            return .rateLimited(
                retryAfterSeconds: retryAfterSeconds(from: response),
                httpStatus: statusCode
            )
        default:
            return .requestFailed(
                code: "discogs_\(operation)_http_\(statusCode)",
                httpStatus: statusCode
            )
        }
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite,
              seconds >= 0
        else {
            return nil
        }
        return seconds
    }

    private static func mapURLSessionError(
        _ error: URLError,
        operation: String
    ) -> MetadataEnrichmentError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .timedOut:
            return .offline
        default:
            return .requestFailed(
                code: "discogs_\(operation)_network_\(error.code.rawValue)",
                httpStatus: nil
            )
        }
    }
}

private struct DiscogsSearchResponse: Decodable {
    let results: [DiscogsSearchResult]

    private enum CodingKeys: String, CodingKey {
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent(
            [DiscogsSearchResult].self,
            forKey: .results
        ) ?? []
    }
}

private struct DiscogsSearchResult: Decodable {
    let id: Int
    let title: String?
    let year: DiscogsFlexibleInt?
}

private struct DiscogsRelease: Decodable {
    let id: Int
    let title: String?
    let year: DiscogsFlexibleInt?
    let artists: [DiscogsNamedEntity]
    let genres: [String]
    let styles: [String]
    let tracklist: [DiscogsTrack]
    let images: [DiscogsImage]

    var preferredImageURL: URL? {
        images.first(where: { $0.type == "primary" })?.preferredURL
            ?? images.first?.preferredURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case year
        case artists
        case genres
        case styles
        case tracklist
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        year = try container.decodeIfPresent(DiscogsFlexibleInt.self, forKey: .year)
        artists = try container.decodeIfPresent(
            [DiscogsNamedEntity].self,
            forKey: .artists
        ) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        tracklist = try container.decodeIfPresent(
            [DiscogsTrack].self,
            forKey: .tracklist
        ) ?? []
        images = try container.decodeIfPresent(
            [DiscogsImage].self,
            forKey: .images
        ) ?? []
    }
}

private struct DiscogsTrack: Decodable {
    let position: String?
    let type: String?
    let title: String?
    let duration: String?
    let artists: [DiscogsNamedEntity]

    private enum CodingKeys: String, CodingKey {
        case position
        case type = "type_"
        case title
        case duration
        case artists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        duration = try container.decodeIfPresent(String.self, forKey: .duration)
        artists = try container.decodeIfPresent(
            [DiscogsNamedEntity].self,
            forKey: .artists
        ) ?? []
    }
}

private struct DiscogsNamedEntity: Decodable {
    let name: String?
}

private struct DiscogsImage: Decodable {
    let type: String?
    let uri: String?
    let resourceURL: String?
    let uri150: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case uri
        case resourceURL = "resource_url"
        case uri150
    }

    var preferredURL: URL? {
        [uri, resourceURL, uri150]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first
    }
}

private struct DiscogsFlexibleInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let string = try? container.decode(String.self) {
            self.value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            self.value = nil
        }
    }
}
