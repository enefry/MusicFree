import CryptoKit
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import OSLog

/// Runtime configuration for the Discogs metadata service documented in
/// `Docs/music-metadata-server-api/API.md`.
///
/// The base URL is intentionally supplied by the app bundle instead of being
/// hard-coded here. The public documentation uses an example hostname, not a
/// deployment endpoint.
public struct MetadataServerConfiguration: Sendable, Equatable {
    public let baseURL: URL
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

        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// Reads optional build-time settings from the application bundle. An
    /// empty or missing base URL means that the provider is not registered.
    public static func from(bundle: Bundle = .main) -> Self? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "MetadataServerBaseURL"
        ) as? String,
            let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        let timeoutValue = bundle.object(
            forInfoDictionaryKey: "MetadataServerRequestTimeout"
        )
        let timeout: TimeInterval
        if let number = timeoutValue as? NSNumber {
            timeout = number.doubleValue
        } else if let string = timeoutValue as? String,
                  let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            timeout = value
        } else {
            timeout = 45
        }

        return Self(
            baseURL: url,
            requestTimeout: timeout
        )
    }

    fileprivate static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Metadata Server adapter for the local Discogs snapshot service.
///
/// Search uses `/track` and enriches the selected release from its details
/// endpoint. The provider caches only bounded release IDs, image URLs, and
/// decoded detail fields; raw response data is never persisted.
public actor MetadataServerMetadataProvider: MetadataEnrichmentProviding {
    public let provider: MetadataEnrichmentProvider = .metadataServer
    public typealias DurationProvider = @Sendable (MediaItemID) async -> TimeInterval?

    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "metadata-server"
    )

    private let configuration: MetadataServerConfiguration
    private let session: URLSession
    private let durationProvider: DurationProvider?
    private var releaseIDs: [String: Int] = [:]
    private var releaseDetails: [Int: ReleaseDetail] = [:]
    private var artworkURLs: [String: URL] = [:]

    public init(
        configuration: MetadataServerConfiguration,
        session: URLSession = .shared,
        durationProvider: DurationProvider? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.durationProvider = durationProvider
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
        guard !trackNames.isEmpty,
              let artistName = Self.artistName(for: query)
        else {
            // The service requires both fields. A local track without an
            // artist cannot produce a valid Metadata Server request.
            return []
        }

        let refreshedDuration = await durationProvider?(query.itemID)
        let effectiveDuration = refreshedDuration ?? query.durationSeconds
        let matchingQuery = MetadataEnrichmentQuery(
            itemID: query.itemID,
            title: query.title,
            artistName: query.artistName,
            albumName: query.albumName,
            fileName: query.fileName,
            durationSeconds: effectiveDuration,
            missingFields: query.missingFields,
            isFilenameFallback: query.isFilenameFallback
        )
        let durationSource = refreshedDuration == nil ? "library" : "probe"
        let durationDescription = effectiveDuration.map {
            String(format: "%.3f", $0)
        } ?? "none"
        var candidates: [MetadataEnrichmentCandidate] = []
        for (index, requestTrackName) in trackNames.enumerated() {
            Self.logger.info(
                "search request title=\(requestTrackName, privacy: .public) artist=\(artistName, privacy: .public) album=\(query.albumName ?? "-", privacy: .public) duration=\(durationDescription, privacy: .public) durationSource=\(durationSource, privacy: .public) variant=\(index + 1, privacy: .public)/\(trackNames.count, privacy: .public)"
            )

            // Album and duration are intentionally used by the shared matcher,
            // not as server-side constraints. Local tags can point at a
            // different release and Discogs often omits track durations, so
            // sending either value can discard an otherwise valid match.
            let queryItems = [
                URLQueryItem(name: "track_name", value: requestTrackName),
                URLQueryItem(name: "artist_name", value: artistName)
            ]
            let request = try makeMetadataRequest(
                pathComponents: ["track"],
                queryItems: queryItems
            )
            let response = try await perform(
                request,
                operation: "track",
                allowNotFound: false
            )
            guard let response else { continue }

            let envelope: TrackSearchResponse
            do {
                envelope = try JSONDecoder().decode(TrackSearchResponse.self, from: response)
            } catch {
                Self.logger.error(
                    "track response decode failed bytes=\(response.count, privacy: .public)"
                )
                throw MetadataEnrichmentError.requestFailed(
                    code: "metadata_invalid_response",
                    httpStatus: 200
                )
            }

            candidates = envelope.results.compactMap {
                (result: TrackResult) -> MetadataEnrichmentCandidate? in
                guard result.track != nil else { return nil }
                return makeCandidate(
                    from: result,
                    fallbackArtistName: envelope.artistName,
                    fallbackAlbumName: envelope.albumName
                )
            }
            if !candidates.isEmpty { break }
        }
        trimCaches()

        // Details are only needed for the candidate that the shared matcher
        // can actually select. A detail outage therefore cannot turn a valid
        // `/track` match into a provider failure.
        if case let .matched(matched) = MetadataEnrichmentMatcher.match(
            query: matchingQuery,
            candidates: candidates
        ),
            let index = candidates.firstIndex(where: { $0.catalogID == matched.catalogID }),
            let releaseID = releaseIDs[matched.catalogID] {
            do {
                if let detail = try await fetchReleaseDetail(releaseID) {
                    candidates[index] = merge(detail: detail, into: candidates[index])
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Search results remain usable without optional release data.
            }
        }

        return candidates
    }

    public func artworkData(
        for candidate: MetadataEnrichmentCandidate
    ) async throws -> Data? {
        if let artworkData = candidate.artworkData {
            return artworkData
        }

        if artworkURLs[candidate.catalogID] == nil,
           let releaseID = releaseIDs[candidate.catalogID] {
            do {
                _ = try await fetchReleaseDetail(releaseID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }

        guard let artworkURL = artworkURLs[candidate.catalogID] else {
            return nil
        }

        var request = URLRequest(
            url: artworkURL,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MetadataEnrichmentError.requestFailed(
                    code: "artwork_invalid_response",
                    httpStatus: nil
                )
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 404 { return nil }
                throw Self.mapHTTPError(
                    statusCode: httpResponse.statusCode,
                    response: httpResponse,
                    operation: "artwork"
                )
            }
            guard !data.isEmpty,
                  data.count <= ArtworkDataLimits.maximumByteCount
            else {
                throw MetadataEnrichmentError.requestFailed(
                    code: "artwork_invalid_size",
                    httpStatus: nil
                )
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MetadataEnrichmentError {
            throw error
        } catch let error as URLError {
            try Task.checkCancellation()
            throw Self.mapURLSessionError(error, operation: "artwork")
        } catch {
            try Task.checkCancellation()
            throw MetadataEnrichmentError.requestFailed(
                code: "artwork_download_failed",
                httpStatus: nil
            )
        }
    }

    private func makeMetadataRequest(
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
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
                code: "metadata_invalid_url",
                httpStatus: nil
            )
        }
        components.queryItems = queryItems
        guard let resolvedURL = components.url else {
            throw MetadataEnrichmentError.requestFailed(
                code: "metadata_invalid_url",
                httpStatus: nil
            )
        }

        var request = URLRequest(
            url: resolvedURL,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(
        _ request: URLRequest,
        operation: String,
        allowNotFound: Bool
    ) async throws -> Data? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MetadataEnrichmentError.requestFailed(
                    code: "metadata_invalid_response",
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
                code: "metadata_request_failed",
                httpStatus: nil
            )
        }
    }

    private func fetchReleaseDetail(_ releaseID: Int) async throws -> ReleaseDetail? {
        if let cached = releaseDetails[releaseID] {
            return cached
        }
        let request = try makeMetadataRequest(
            pathComponents: ["releases", String(releaseID)]
        )
        guard let response = try await perform(
            request,
            operation: "release",
            allowNotFound: true
        ) else {
            return nil
        }

        let detail: ReleaseDetail
        do {
            detail = try JSONDecoder().decode(ReleaseDetail.self, from: response)
        } catch {
            throw MetadataEnrichmentError.requestFailed(
                code: "metadata_invalid_release_response",
                httpStatus: 200
            )
        }
        releaseDetails[releaseID] = detail
        if let imageURL = detail.preferredImageURL {
            for (catalogID, id) in releaseIDs where id == releaseID {
                artworkURLs[catalogID] = imageURL
            }
        }
        trimCaches()
        return detail
    }

    private func makeCandidate(
        from result: TrackResult,
        fallbackArtistName: String?,
        fallbackAlbumName: String?
    ) -> MetadataEnrichmentCandidate? {
        guard let releaseID = result.releaseID,
              releaseID > 0,
              let track = result.track,
              let title = Self.normalized(track.title)
        else {
            return nil
        }

        let position = Self.normalized(track.position) ?? "unknown"
        let catalogID = [
            "metadata-server",
            "release-\(releaseID)",
            position,
            MetadataServerConfiguration.hex(SHA256.hash(data: Data(title.utf8))),
        ].joined(separator: ":")
        releaseIDs[catalogID] = releaseID

        let trackArtists = track.artists.compactMap { Self.normalized($0.name) }
        let artistName = trackArtists.isEmpty
            ? Self.normalized(fallbackArtistName)
            : trackArtists.joined(separator: ", ")
        let parsedPosition = Self.parsePosition(position)

        return MetadataEnrichmentCandidate(
            catalogID: catalogID,
            title: title,
            artistName: artistName,
            albumArtistName: artistName,
            albumName: Self.normalized(result.releaseTitle) ?? Self.normalized(fallbackAlbumName),
            trackNumber: parsedPosition.track,
            discNumber: parsedPosition.disc,
            year: result.year,
            durationSeconds: Self.parseDuration(track.duration)
        )
    }

    private func merge(
        detail: ReleaseDetail,
        into candidate: MetadataEnrichmentCandidate
    ) -> MetadataEnrichmentCandidate {
        let albumArtistName = detail.artists
            .compactMap { Self.normalized($0.name) }
            .joined(separator: ", ")
        let detailTrack = detail.tracklist.first {
            guard let title = Self.normalized($0.title) else { return false }
            return Self.normalizedForComparison(title) ==
                Self.normalizedForComparison(candidate.title)
        }
        let detailPosition = detailTrack.flatMap { Self.parsePosition($0.position) }
        let imageURL = detail.preferredImageURL
        if let imageURL {
            artworkURLs[candidate.catalogID] = imageURL
        }

        return MetadataEnrichmentCandidate(
            catalogID: candidate.catalogID,
            title: candidate.title,
            artistName: candidate.artistName,
            albumArtistName: albumArtistName.isEmpty
                ? candidate.albumArtistName
                : albumArtistName,
            albumName: candidate.albumName ?? Self.normalized(detail.title),
            genreName: detail.genres.first ?? detail.styles.first,
            trackNumber: candidate.trackNumber ?? detailPosition?.track,
            discNumber: candidate.discNumber ?? detailPosition?.disc,
            year: candidate.year ?? detail.year,
            durationSeconds: candidate.durationSeconds
                ?? detailTrack.flatMap { Self.parseDuration($0.duration) }
        )
    }

    private func trimCaches() {
        if releaseIDs.count > 128 {
            let keep = Set(releaseIDs.keys.suffix(128))
            releaseIDs = releaseIDs.filter { keep.contains($0.key) }
            artworkURLs = artworkURLs.filter { keep.contains($0.key) }
        }
        let activeReleaseIDs = Set(releaseIDs.values)
        releaseDetails = releaseDetails.filter { activeReleaseIDs.contains($0.key) }
    }

    private static func trackName(for query: MetadataEnrichmentQuery) -> String? {
        normalized(query.isFilenameFallback ? query.filenameTitle : query.title)
            ?? normalized(query.filenameTitle)
            ?? normalized(query.filenameStem)
    }

    private static func trackNames(for query: MetadataEnrichmentQuery) -> [String] {
        guard let original = trackName(for: query) else { return [] }

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

    private static func artistName(for query: MetadataEnrichmentQuery) -> String? {
        normalized(query.artistName)
            ?? (query.isFilenameFallback ? normalized(query.filenameArtist) : nil)
    }

    private static func validDuration(_ value: TimeInterval?) -> Int? {
        guard let value, value.isFinite, (1 ... 3600).contains(value) else {
            return nil
        }
        return max(1, Int(value.rounded()))
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
           let track = Int(parts[1]) {
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

        guard parts.dropFirst().allSatisfy({ Int($0) != nil }) else {
            return nil
        }
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

    private static func mapHTTPError(
        statusCode: Int,
        response: HTTPURLResponse,
        operation: String
    ) -> MetadataEnrichmentError {
        switch statusCode {
        case 401:
            return .notAuthorized
        case 429:
            return .rateLimited(
                retryAfterSeconds: retryAfterSeconds(from: response),
                httpStatus: statusCode
            )
        default:
            return .requestFailed(
                code: "metadata_\(operation)_http_\(statusCode)",
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
                code: "metadata_\(operation)_network_\(error.code.rawValue)",
                httpStatus: nil
            )
        }
    }
}

private struct TrackSearchResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let results: [TrackResult]

    private enum CodingKeys: String, CodingKey {
        case trackName
        case artistName
        case albumName
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackName = try container.decodeIfPresent(String.self, forKey: .trackName)
        artistName = try container.decodeIfPresent(String.self, forKey: .artistName)
        albumName = try container.decodeIfPresent(String.self, forKey: .albumName)
        results = try container.decodeIfPresent([TrackResult].self, forKey: .results) ?? []
    }
}

private struct TrackResult: Decodable {
    let releaseID: Int?
    let releaseTitle: String?
    let year: Int?
    let track: DiscogsTrack?

    private enum CodingKeys: String, CodingKey {
        case releaseID = "releaseId"
        case releaseTitle
        case year
        case track
    }
}

private struct ReleaseDetail: Decodable {
    let id: Int?
    let title: String?
    let year: Int?
    let artists: [NamedEntity]
    let genres: [String]
    let styles: [String]
    let tracklist: [DiscogsTrack]
    let images: [DiscogsImage]

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
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        artists = try container.decodeIfPresent([NamedEntity].self, forKey: .artists) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        tracklist = try container.decodeIfPresent([DiscogsTrack].self, forKey: .tracklist) ?? []
        images = try container.decodeIfPresent([DiscogsImage].self, forKey: .images) ?? []
    }

    var preferredImageURL: URL? {
        images
            .sorted {
                ($0.type?.lowercased() == "primary") &&
                    ($1.type?.lowercased() != "primary")
            }
            .compactMap(\.preferredURL)
            .first
    }
}

private struct NamedEntity: Decodable {
    let name: String?
}

private struct DiscogsTrack: Decodable {
    let position: String?
    let title: String?
    let duration: String?
    let artists: [NamedEntity]

    private enum CodingKeys: String, CodingKey {
        case position
        case title
        case duration
        case artists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        duration = try container.decodeIfPresent(String.self, forKey: .duration)
        artists = try container.decodeIfPresent([NamedEntity].self, forKey: .artists) ?? []
    }
}

private struct DiscogsImage: Decodable {
    let type: String?
    let uri: String?
    let uri150: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case uri
        case uri150
    }

    var preferredURL: URL? {
        for value in [uri, uri150] {
            guard let value,
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else {
                continue
            }
            return url
        }
        return nil
    }
}
