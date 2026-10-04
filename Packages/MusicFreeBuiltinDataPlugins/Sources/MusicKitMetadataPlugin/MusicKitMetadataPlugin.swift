// Extracted from the legacy provider; original implementation is retained.
import Foundation
import MusicFreePluginAPI
import DataPluginSupport
import MusicKit

/// MusicKit is intentionally isolated to the infrastructure boundary. The
/// app uses Apple's managed authorization and catalog requests; no developer
/// token, private key, lyrics request, or local file URL crosses this type.
@available(iOS 15.0, *)
public actor MusicKitMetadataPlugin: CatalogProviding {

    private let artworkSession: URLSession
    private var artworkURLs: [String: URL] = [:]

    public init(artworkSession: URLSession = .shared) {
        self.artworkSession = artworkSession
    }

    public static func systemAuthorizationStatus() async -> PluginMetadataAuthorizationStatus {
        Self.mapAuthorization(MusicAuthorization.currentStatus)
    }
    public static func requestSystemAuthorization() async -> PluginMetadataAuthorizationStatus {
        Self.mapAuthorization(await MusicAuthorization.request())
    }
    public func authorizationStatus() async -> PluginMetadataAuthorizationStatus {
        await Self.systemAuthorizationStatus()
    }

    public func requestAuthorization() async -> PluginMetadataAuthorizationStatus {
        await Self.requestSystemAuthorization()
    }

    public func search(
        _ query: CatalogQuery
    ) async throws -> [CatalogCandidate] {
        guard !query.searchTerms.isEmpty else {
            return []
        }
        guard MusicAuthorization.currentStatus == .authorized else {
            throw PluginDataError.notAuthorized
        }
        try Task.checkCancellation()

        var allCandidates: [CatalogCandidate] = []
        for term in query.searchTerms.prefix(Self.maximumSearchVariants) {
            let candidates = try await search(term: term, query: query)
            appendUnique(candidates, to: &allCandidates)

            switch CatalogMatcher.match(query: query, candidates: candidates) {
            case .matched:
                // Do not spend extra requests broadening an already reliable
                // result. This keeps normal enrichment to one MusicKit call.
                return candidates
            case .noMatch, .ambiguous:
                continue
            }
        }
        return allCandidates
    }

    // The first term is the normal path. At most three fallback terms are
    // attempted for titles that need progressively broader matching.
    private static let maximumSearchVariants = 4

    private func search(
        term: String,
        query: CatalogQuery
    ) async throws -> [CatalogCandidate] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 10
        // We only consume songs. On affected iOS releases, top-results
        // materialization can parse incomplete related Album identifiers.
        request.includeTopResults = false

        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch let error as PluginDataError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw Self.mapRequestError(error)
        }

        let candidates = response.songs.compactMap { song -> CatalogCandidate? in
            let catalogID = song.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !catalogID.isEmpty else { return nil }
            if query.missingFields.contains(.artwork),
               let artworkURL = song.artwork?.url(width: 1_000, height: 1_000)
            {
                artworkURLs[catalogID] = artworkURL
                trimArtworkCache()
            }

            return CatalogCandidate(
                catalogID: catalogID,
                title: song.title,
                artistName: song.artistName,
                albumArtistName: song.artistName,
                albumName: song.albumTitle,
                genreName: song.genreNames.first,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber,
                year: song.releaseDate.flatMap { Self.releaseYear(from: $0) },
                durationSeconds: song.duration
            )
        }
        return Array(candidates)
    }

    private func appendUnique(
        _ candidates: [CatalogCandidate],
        to allCandidates: inout [CatalogCandidate]
    ) {
        var knownIDs = Set(allCandidates.map(\.catalogID))
        for candidate in candidates where knownIDs.insert(candidate.catalogID).inserted {
            allCandidates.append(candidate)
        }
    }

    public func artworkData(
        for candidate: CatalogCandidate
    ) async throws -> Data? {
        if let artworkData = candidate.artworkData {
            return artworkData
        }
        guard let artworkURL = try await artworkURL(for: candidate) else {
            return nil
        }
        try Task.checkCancellation()

        do {
            let (data, response) = try await artworkSession.data(
                from: artworkURL
            )
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode)
            {
                throw PluginDataError.requestFailed(
                    code: "artwork_http_\(response.statusCode)",
                    httpStatus: response.statusCode
                )
            }
            guard !data.isEmpty,
                  data.count <= ArtworkDataLimits.maximumByteCount
            else {
                throw PluginDataError.requestFailed(
                    code: "artwork_invalid_size",
                    httpStatus: nil
                )
            }
            return data
        } catch let error as PluginDataError {
            throw error
        } catch let error as URLError {
            try Task.checkCancellation()
            throw Self.mapURLSessionError(error, operation: "artwork")
        } catch {
            try Task.checkCancellation()
            throw PluginDataError.requestFailed(
                code: "artwork_download_failed",
                httpStatus: nil
            )
        }
    }

    /// Search responses normally include the artwork URL, but MusicKit can
    /// return a partial Song for some catalog results. Resolve the catalog item
    /// once more in that case so a metadata match does not silently lose its
    /// cover.
    private func artworkURL(
        for candidate: CatalogCandidate
    ) async throws -> URL? {
        let catalogID = candidate.catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !catalogID.isEmpty else { return nil }
        if let cachedURL = artworkURLs[catalogID] {
            return cachedURL
        }
        guard MusicAuthorization.currentStatus == .authorized else {
            throw PluginDataError.notAuthorized
        }
        try Task.checkCancellation()

        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1

        do {
            let response = try await request.response()
            guard let artworkURL = response.items.first?.artwork?.url(
                width: 1_000,
                height: 1_000
            ) else {
                return nil
            }
            artworkURLs[catalogID] = artworkURL
            trimArtworkCache()
            return artworkURL
        } catch let error as PluginDataError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw Self.mapRequestError(error)
        }
    }

    private func trimArtworkCache() {
        guard artworkURLs.count > 64 else { return }
        artworkURLs.removeValue(forKey: artworkURLs.keys.first!)
    }

    private static func mapAuthorization(
        _ status: MusicAuthorization.Status
    ) -> PluginMetadataAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    private static func releaseYear(from date: Date) -> Int? {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return (1...9_999).contains(year) ? year : nil
    }

    private static func mapRequestError(_ error: Error) -> PluginDataError {
        if let error = error as? MusicDataRequest.Error {
            let responseStatus = validHTTPStatus(error.originalResponse.urlResponse.statusCode)
            let serviceStatus = validHTTPStatus(error.status)
            if responseStatus == 429 || serviceStatus == 429 {
                return .rateLimited(
                    retryAfterSeconds: Self.retryAfterSeconds(from: error.originalResponse.urlResponse),
                    httpStatus: responseStatus ?? serviceStatus
                )
            }
            let diagnosticStatus = error.status > 0 ? String(error.status) : "unknown"
            let diagnosticCode = error.code > 0 ? "_code_\(error.code)" : ""
            return .requestFailed(
                code: "music_data_status_\(diagnosticStatus)\(diagnosticCode)",
                httpStatus: responseStatus
            )
        }
        if let status = inferredHTTPStatus(from: error) {
            if status == 429 {
                return .rateLimited(retryAfterSeconds: nil, httpStatus: status)
            }
            return .requestFailed(
                code: "music_data_\(status)",
                httpStatus: status
            )
        }
        if let error = error as? URLError {
            return mapURLSessionError(error, operation: "search")
        }
        if error is CancellationError {
            return .requestFailed(code: "cancelled", httpStatus: nil)
        }
        return .requestFailed(code: "music_data_request_failed", httpStatus: nil)
    }

    private static func validHTTPStatus(_ status: Int) -> Int? {
        (100...599).contains(status) ? status : nil
    }

    /// Some MusicKit catalog failures are surfaced as response parsing errors
    /// even though the framework logs the HTTP status. Keep that status in the
    /// durable record so authorization failures are not confused with an empty
    /// search result.
    private static func inferredHTTPStatus(from error: Error) -> Int? {
        let descriptions = [String(describing: error), error.localizedDescription]
        for description in descriptions {
            for token in description.split(whereSeparator: { !$0.isNumber }) {
                guard let status = Int(token), (100...599).contains(status) else {
                    continue
                }
                return status
            }
        }
        return nil
    }

    private static func retryAfterSeconds(
        from response: HTTPURLResponse
    ) -> Double? {
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
    ) -> PluginDataError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .timedOut:
            return .offline
        default:
            return .requestFailed(
                code: "\(operation)_network_\(error.code.rawValue)",
                httpStatus: nil
            )
        }
    }
}

extension MusicKitMetadataPlugin: MetadataPlugin {
    public static var descriptor: PluginDescriptor {
        .init(id: .init(rawValue: "builtin.metadata.musicKit"), name: "MusicKit Metadata", kinds: [.metadata], permissions: [.network], policyVersion: "1.2.0", dataProviderID: "musicKit")
    }
    public func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        try context.requireNetwork()
        let matches = try await search(CatalogQuery(title: query.title, artistName: query.artist, albumName: query.album,
            durationSeconds: query.durationSeconds, missingFields: fields))
        try Task.checkCancellation()
        return matches.map { $0.pluginCandidate(fields: fields) }
    }
    public func artwork(reference: String, context: PluginOperationContext) async throws -> Data? {
        try context.requireNetwork()
        return try await artworkData(for: CatalogCandidate(catalogID: reference, title: ""))
    }
}
