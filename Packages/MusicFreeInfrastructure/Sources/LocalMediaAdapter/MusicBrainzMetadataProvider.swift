import Foundation
import LibraryAPI
import MediaSourceAPI
import OSLog

/// Runtime configuration for the public MusicBrainz and Cover Art Archive
/// services. MusicBrainz requires a descriptive User-Agent and asks clients to
/// keep requests around one second apart.
public struct MusicBrainzAPIConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let coverArtBaseURL: URL
    public let userAgent: String
    public let requestTimeout: TimeInterval
    public let minimumRequestInterval: TimeInterval

    public init?(
        baseURL: URL,
        coverArtBaseURL: URL,
        userAgent: String,
        requestTimeout: TimeInterval = 45,
        minimumRequestInterval: TimeInterval? = nil
    ) {
        let normalizedAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = minimumRequestInterval ?? 1.0
        guard Self.isValidBaseURL(baseURL),
              Self.isValidBaseURL(coverArtBaseURL),
              !normalizedAgent.isEmpty,
              !normalizedAgent.contains("\r"),
              !normalizedAgent.contains("\n"),
              requestTimeout.isFinite,
              requestTimeout > 0,
              interval.isFinite,
              interval >= 0
        else {
            return nil
        }

        self.baseURL = baseURL
        self.coverArtBaseURL = coverArtBaseURL
        self.userAgent = normalizedAgent
        self.requestTimeout = requestTimeout
        self.minimumRequestInterval = interval
    }

    /// Reads build-time settings from the application bundle. Missing or
    /// unresolved URLs keep this optional provider out of the composition.
    public static func from(bundle: Bundle = .main) -> Self? {
        guard let baseURL = urlValue(
            bundle.object(forInfoDictionaryKey: "MusicBrainzAPIBaseURL")
        ),
        let coverArtBaseURL = urlValue(
            bundle.object(forInfoDictionaryKey: "MusicBrainzCoverArtBaseURL")
        ) else {
            return nil
        }

        let displayName = stringValue(
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
        )
        let version = stringValue(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        )
        let fallbackAgent = [displayName, version]
            .compactMap { $0 }
            .joined(separator: "/")
        let userAgent = stringValue(
            bundle.object(forInfoDictionaryKey: "MusicBrainzAPIUserAgent")
        ) ?? (fallbackAgent.isEmpty ? "MusicFree/1.0" : fallbackAgent)
        let timeout = doubleValue(
            bundle.object(forInfoDictionaryKey: "MusicBrainzAPIRequestTimeout")
        ) ?? 45
        let interval = doubleValue(
            bundle.object(forInfoDictionaryKey: "MusicBrainzAPIMinimumRequestInterval")
        )

        return Self(
            baseURL: baseURL,
            coverArtBaseURL: coverArtBaseURL,
            userAgent: userAgent,
            requestTimeout: timeout,
            minimumRequestInterval: interval
        )
    }

    private static func isValidBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func urlValue(_ value: Any?) -> URL? {
        guard let string = stringValue(value),
              let url = URL(string: string),
              isValidBaseURL(url)
        else {
            return nil
        }
        return url
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !isUnresolvedBuildSetting(normalized)
        else {
            return nil
        }
        return normalized
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        guard let string = stringValue(value) else { return nil }
        return Double(string)
    }

    private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.contains("$(") || value.contains("${")
    }
}

/// Metadata enrichment backed by MusicBrainz recordings and Cover Art
/// Archive release artwork.
///
/// MusicBrainz is queried by recording title and artist only. Album and
/// duration stay in the shared local matcher because local tags can identify a
/// different release or contain stale values.
public actor MusicBrainzMetadataProvider: MetadataEnrichmentProviding {
    public let provider: MetadataEnrichmentProvider = .musicBrainz

    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "musicbrainz-api"
    )

    private let configuration: MusicBrainzAPIConfiguration
    private let session: URLSession
    private var lastRequestAt: Date?
    private var releaseIDs: [String: String] = [:]
    private var artworkURLs: [String: URL] = [:]
    private var artworkUnavailable: Set<String> = []

    public init(
        configuration: MusicBrainzAPIConfiguration,
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
        let artistName = Self.artistName(for: query)

        for (index, trackName) in trackNames.enumerated() {
            let queryValue = Self.recordingQuery(
                title: trackName,
                artistName: artistName
            )
            Self.logger.info(
                "search request title=\(trackName, privacy: .public) artist=\(artistName ?? "-", privacy: .public) variant=\(index + 1, privacy: .public)/\(trackNames.count, privacy: .public)"
            )
            let request = try makeRequest(
                baseURL: configuration.baseURL,
                pathComponents: ["recording"],
                queryItems: [
                    URLQueryItem(name: "query", value: queryValue),
                    URLQueryItem(name: "fmt", value: "json"),
                    URLQueryItem(name: "limit", value: "25"),
                    URLQueryItem(
                        name: "inc",
                        value: "artist-credits+releases+media"
                    )
                ],
                accept: "application/json",
                trailingSlash: true
            )
            guard let data = try await perform(
                request,
                operation: "search",
                allowNotFound: false
            ) else {
                continue
            }

            let response: MusicBrainzSearchResponse
            do {
                response = try JSONDecoder().decode(
                    MusicBrainzSearchResponse.self,
                    from: data
                )
            } catch {
                Self.logger.error(
                    "search response decode failed bytes=\(data.count, privacy: .public)"
                )
                throw MetadataEnrichmentError.requestFailed(
                    code: "musicbrainz_invalid_search_response",
                    httpStatus: 200
                )
            }

            let candidates = response.recordings.prefix(25).compactMap {
                makeCandidate(from: $0, query: query)
            }
            if !candidates.isEmpty {
                trimCaches()
                return Self.uniqueCandidates(candidates)
            }
        }

        trimCaches()
        return []
    }

    public func artworkData(
        for candidate: MetadataEnrichmentCandidate
    ) async throws -> Data? {
        if let artworkData = candidate.artworkData {
            return artworkData
        }

        guard let releaseID = releaseIDs[candidate.catalogID],
              !releaseID.isEmpty
        else {
            return nil
        }

        if artworkURLs[candidate.catalogID] == nil,
           !artworkUnavailable.contains(candidate.catalogID)
        {
            let request = try makeRequest(
                baseURL: configuration.coverArtBaseURL,
                pathComponents: ["release", releaseID],
                accept: "application/json"
            )
            guard let data = try await perform(
                request,
                operation: "cover_art_lookup",
                allowNotFound: true
            ) else {
                artworkUnavailable.insert(candidate.catalogID)
                return nil
            }

            let response: CoverArtArchiveResponse
            do {
                response = try JSONDecoder().decode(
                    CoverArtArchiveResponse.self,
                    from: data
                )
            } catch {
                throw MetadataEnrichmentError.requestFailed(
                    code: "musicbrainz_invalid_cover_art_response",
                    httpStatus: 200
                )
            }

            guard let artworkURL = Self.preferredArtworkURL(from: response) else {
                artworkUnavailable.insert(candidate.catalogID)
                return nil
            }
            artworkURLs[candidate.catalogID] = artworkURL
        }

        guard let artworkURL = artworkURLs[candidate.catalogID] else {
            return nil
        }
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
        guard !data.isEmpty,
              data.count <= ArtworkDataLimits.maximumByteCount
        else {
            throw MetadataEnrichmentError.requestFailed(
                code: "musicbrainz_artwork_invalid_size",
                httpStatus: nil
            )
        }
        return data
    }

    private func makeCandidate(
        from recording: MusicBrainzRecording,
        query: MetadataEnrichmentQuery
    ) -> MetadataEnrichmentCandidate? {
        guard let title = Self.normalized(recording.title),
              let recordingID = Self.normalized(recording.id)
        else {
            return nil
        }

        let release = Self.preferredRelease(
            from: recording.releases,
            albumName: query.albumName
        )
        let releaseID = Self.normalized(release?.id)
        let catalogID = if let releaseID {
            "musicbrainz:recording:\(recordingID):release:\(releaseID)"
        } else {
            "musicbrainz:recording:\(recordingID)"
        }
        if let releaseID {
            releaseIDs[catalogID] = releaseID
        }

        let artistName = Self.artistCreditName(recording.artistCredits)
        let position = release.flatMap {
            Self.trackPosition(
                recordingID: recordingID,
                recordingTitle: title,
                in: $0
            )
        }
        return MetadataEnrichmentCandidate(
            catalogID: catalogID,
            title: title,
            artistName: artistName,
            albumArtistName: artistName,
            albumName: Self.normalized(release?.title),
            trackNumber: position?.track,
            discNumber: position?.disc,
            year: Self.year(from: release?.date ?? recording.firstReleaseDate),
            durationSeconds: recording.length?.value.map { Double($0) / 1_000 }
        )
    }

    private func makeRequest(
        baseURL: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        accept: String,
        trailingSlash: Bool = false
    ) throws -> URLRequest {
        var url = baseURL
        for (index, component) in pathComponents.enumerated() {
            url = url.appendingPathComponent(
                component,
                isDirectory: trailingSlash && index == pathComponents.index(before: pathComponents.endIndex)
            )
        }
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw MetadataEnrichmentError.requestFailed(
                code: "musicbrainz_invalid_url",
                httpStatus: nil
            )
        }
        if trailingSlash, !components.path.hasSuffix("/") {
            components.path.append("/")
        }
        components.queryItems = queryItems
        guard let resolvedURL = components.url else {
            throw MetadataEnrichmentError.requestFailed(
                code: "musicbrainz_invalid_url",
                httpStatus: nil
            )
        }
        return try makeRequest(url: resolvedURL, accept: accept)
    }

    private func makeRequest(
        url: URL,
        accept: String
    ) throws -> URLRequest {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
            throw MetadataEnrichmentError.requestFailed(
                code: "musicbrainz_invalid_url",
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
                    code: "musicbrainz_invalid_response",
                    httpStatus: nil
                )
            }
            Self.logger.info(
                "request completed operation=\(operation, privacy: .public) path=\(httpResponse.url?.path ?? "-", privacy: .public) status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            if allowNotFound, httpResponse.statusCode == 404 {
                return nil
            }
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
                code: "musicbrainz_\(operation)_request_failed",
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
        guard releaseIDs.count > 256 else { return }
        let keep = Set(releaseIDs.keys.suffix(256))
        releaseIDs = releaseIDs.filter { keep.contains($0.key) }
        artworkURLs = artworkURLs.filter { keep.contains($0.key) }
        artworkUnavailable = artworkUnavailable.filter { keep.contains($0) }
    }

    private static func uniqueCandidates(
        _ candidates: [MetadataEnrichmentCandidate]
    ) -> [MetadataEnrichmentCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.catalogID).inserted }
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

    private static func recordingQuery(
        title: String,
        artistName: String?
    ) -> String {
        var parts = ["recording:\"\(escapedLucenePhrase(title))\""]
        if let artistName = normalized(artistName) {
            parts.append("artist:\"\(escapedLucenePhrase(artistName))\"")
        }
        return parts.joined(separator: " AND ")
    }

    private static func escapedLucenePhrase(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func preferredRelease(
        from releases: [MusicBrainzRelease],
        albumName: String?
    ) -> MusicBrainzRelease? {
        releases
            .filter { normalized($0.id) != nil && normalized($0.title) != nil }
            .sorted { lhs, rhs in
                let lhsAlbumScore = albumMatchScore(albumName, candidate: lhs.title)
                let rhsAlbumScore = albumMatchScore(albumName, candidate: rhs.title)
                if lhsAlbumScore != rhsAlbumScore {
                    return lhsAlbumScore > rhsAlbumScore
                }
                let lhsOfficial = lhs.status?.lowercased() == "official"
                let rhsOfficial = rhs.status?.lowercased() == "official"
                if lhsOfficial != rhsOfficial {
                    return lhsOfficial && !rhsOfficial
                }
                let lhsDate = lhs.date ?? "9999"
                let rhsDate = rhs.date ?? "9999"
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.id < rhs.id
            }
            .first
    }

    private static func albumMatchScore(
        _ localAlbum: String?,
        candidate: String?
    ) -> Int {
        guard let localAlbum = normalized(localAlbum),
              let candidate = normalized(candidate)
        else {
            return 0
        }
        let localValue = normalizedForComparison(localAlbum)
        let candidateValue = normalizedForComparison(candidate)
        if localValue == candidateValue { return 2 }
        if localValue.contains(candidateValue) || candidateValue.contains(localValue) {
            return 1
        }
        return 0
    }

    private static func artistCreditName(
        _ credits: [MusicBrainzArtistCredit]
    ) -> String? {
        let value = credits.reduce(into: "") { result, credit in
            guard let name = normalized(credit.name ?? credit.artist?.name) else {
                return
            }
            result.append(name)
            result.append(credit.joinPhrase ?? "")
        }
        return normalized(value)
    }

    private static func trackPosition(
        recordingID: String,
        recordingTitle: String,
        in release: MusicBrainzRelease
    ) -> (disc: Int?, track: Int?)? {
        for media in release.media ?? [] {
            for track in media.tracks ?? [] {
                let matchesRecording = track.recording?.id == recordingID
                let matchesTitle = normalizedForComparison(track.title) ==
                    normalizedForComparison(recordingTitle)
                guard matchesRecording || matchesTitle else { continue }
                let trackNumber = track.position?.value ?? track.number?.value
                let discNumber = media.position?.value
                guard discNumber != nil || trackNumber != nil else { continue }
                return (
                    disc: discNumber.flatMap { $0 > 0 ? $0 : nil },
                    track: trackNumber.flatMap { $0 > 0 ? $0 : nil }
                )
            }
        }
        return nil
    }

    private static func preferredArtworkURL(
        from response: CoverArtArchiveResponse
    ) -> URL? {
        let images = response.images.sorted { lhs, rhs in
            let lhsFront = lhs.front || lhs.types.contains {
                $0.caseInsensitiveCompare("Front") == .orderedSame
            }
            let rhsFront = rhs.front || rhs.types.contains {
                $0.caseInsensitiveCompare("Front") == .orderedSame
            }
            if lhsFront != rhsFront { return lhsFront && !rhsFront }
            return (lhs.image ?? "") < (rhs.image ?? "")
        }
        for image in images {
            let candidates = [
                image.thumbnails["large"],
                image.thumbnails["500"],
                image.thumbnails["250"],
                image.image
            ]
            for value in candidates.compactMap({ normalized($0) }) {
                guard let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      url.host != nil,
                      url.user == nil,
                      url.password == nil
                else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    private static func year(from value: String?) -> Int? {
        guard let value = normalized(value),
              let year = Int(value.prefix(4))
        else {
            return nil
        }
        return year
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

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedForComparison(_ value: String?) -> String {
        guard let value else { return "" }
        return value
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
        case 401, 403:
            return .notAuthorized
        case 429:
            return .rateLimited(
                retryAfterSeconds: retryAfterSeconds(from: response),
                httpStatus: statusCode
            )
        default:
            return .requestFailed(
                code: "musicbrainz_\(operation)_http_\(statusCode)",
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
                code: "musicbrainz_\(operation)_network_\(error.code.rawValue)",
                httpStatus: nil
            )
        }
    }
}

private struct MusicBrainzSearchResponse: Decodable {
    let recordings: [MusicBrainzRecording]

    private enum CodingKeys: String, CodingKey {
        case recordings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordings = try container.decodeIfPresent(
            [MusicBrainzRecording].self,
            forKey: .recordings
        ) ?? []
    }
}

private struct MusicBrainzRecording: Decodable {
    let id: String
    let title: String
    let length: MusicBrainzFlexibleInt?
    let artistCredits: [MusicBrainzArtistCredit]
    let firstReleaseDate: String?
    let releases: [MusicBrainzRelease]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case length
        case artistCredits = "artist-credit"
        case firstReleaseDate = "first-release-date"
        case releases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        length = try container.decodeIfPresent(
            MusicBrainzFlexibleInt.self,
            forKey: .length
        )
        artistCredits = try container.decodeIfPresent(
            [MusicBrainzArtistCredit].self,
            forKey: .artistCredits
        ) ?? []
        firstReleaseDate = try container.decodeIfPresent(
            String.self,
            forKey: .firstReleaseDate
        )
        releases = try container.decodeIfPresent(
            [MusicBrainzRelease].self,
            forKey: .releases
        ) ?? []
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    let name: String?
    let joinPhrase: String?
    let artist: MusicBrainzArtist?

    private enum CodingKeys: String, CodingKey {
        case name
        case joinPhrase = "joinphrase"
        case artist
    }
}

private struct MusicBrainzArtist: Decodable {
    let name: String?
}

private struct MusicBrainzRelease: Decodable {
    let id: String
    let title: String?
    let status: String?
    let date: String?
    let media: [MusicBrainzMedia]?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case date
        case media
    }
}

private struct MusicBrainzMedia: Decodable {
    let position: MusicBrainzFlexibleInt?
    let tracks: [MusicBrainzTrack]?

    private enum CodingKeys: String, CodingKey {
        case position
        case track
        case tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(
            MusicBrainzFlexibleInt.self,
            forKey: .position
        )
        tracks = try container.decodeIfPresent(
            [MusicBrainzTrack].self,
            forKey: .track
        ) ?? container.decodeIfPresent(
            [MusicBrainzTrack].self,
            forKey: .tracks
        )
    }
}

private struct MusicBrainzTrack: Decodable {
    let position: MusicBrainzFlexibleInt?
    let number: MusicBrainzFlexibleInt?
    let title: String?
    let recording: MusicBrainzTrackRecording?
}

private struct MusicBrainzTrackRecording: Decodable {
    let id: String?
}

private struct CoverArtArchiveResponse: Decodable {
    let images: [CoverArtArchiveImage]

    private enum CodingKeys: String, CodingKey {
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeIfPresent(
            [CoverArtArchiveImage].self,
            forKey: .images
        ) ?? []
    }
}

private struct CoverArtArchiveImage: Decodable {
    let front: Bool
    let types: [String]
    let image: String?
    let thumbnails: [String: String]

    private enum CodingKeys: String, CodingKey {
        case front
        case types
        case image
        case thumbnails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        front = try container.decodeIfPresent(Bool.self, forKey: .front) ?? false
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        image = try container.decodeIfPresent(String.self, forKey: .image)
        thumbnails = try container.decodeIfPresent(
            [String: String].self,
            forKey: .thumbnails
        ) ?? [:]
    }
}

private struct MusicBrainzFlexibleInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let integer = try? container.decode(Int.self) {
            value = integer
        } else if let string = try? container.decode(String.self) {
            value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}
