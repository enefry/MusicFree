import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicKit

/// MusicKit is intentionally isolated to the infrastructure boundary. The
/// app uses Apple's managed authorization and catalog requests; no developer
/// token, private key, lyrics request, or local file URL crosses this type.
@available(iOS 15.0, *)
public actor MusicKitMetadataProvider: MetadataEnrichmentProviding {
    public let provider: MetadataEnrichmentProvider = .musicKit

    private let artworkSession: URLSession
    private var artworkURLs: [String: URL] = [:]

    public init(artworkSession: URLSession = .shared) {
        self.artworkSession = artworkSession
    }

    public func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
        Self.mapAuthorization(MusicAuthorization.currentStatus)
    }

    public func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        Self.mapAuthorization(await MusicAuthorization.request())
    }

    public func search(
        _ query: MetadataEnrichmentQuery
    ) async throws -> [MetadataEnrichmentCandidate] {
        guard let term = query.searchTerm else {
            return []
        }
        guard MusicAuthorization.currentStatus == .authorized else {
            throw MetadataEnrichmentError.notAuthorized
        }
        try Task.checkCancellation()

        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 10
        // We only consume songs. On affected iOS releases, top-results
        // materialization can parse incomplete related Album identifiers.
        request.includeTopResults = false

        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch let error as MetadataEnrichmentError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw Self.mapRequestError(error)
        }

        let candidates = response.songs.compactMap { song -> MetadataEnrichmentCandidate? in
            let catalogID = song.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !catalogID.isEmpty else { return nil }
            if query.missingFields.contains(.artwork),
               let artworkURL = song.artwork?.url(width: 1_000, height: 1_000)
            {
                artworkURLs[catalogID] = artworkURL
                trimArtworkCache()
            }

            return MetadataEnrichmentCandidate(
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

    public func artworkData(
        for candidate: MetadataEnrichmentCandidate
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
                throw MetadataEnrichmentError.requestFailed(
                    code: "artwork_http_\(response.statusCode)",
                    httpStatus: response.statusCode
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

    /// Search responses normally include the artwork URL, but MusicKit can
    /// return a partial Song for some catalog results. Resolve the catalog item
    /// once more in that case so a metadata match does not silently lose its
    /// cover.
    private func artworkURL(
        for candidate: MetadataEnrichmentCandidate
    ) async throws -> URL? {
        let catalogID = candidate.catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !catalogID.isEmpty else { return nil }
        if let cachedURL = artworkURLs[catalogID] {
            return cachedURL
        }
        guard MusicAuthorization.currentStatus == .authorized else {
            throw MetadataEnrichmentError.notAuthorized
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
        } catch let error as MetadataEnrichmentError {
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
    ) -> MetadataEnrichmentAuthorizationStatus {
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

    private static func mapRequestError(_ error: Error) -> MetadataEnrichmentError {
        if let error = error as? MusicDataRequest.Error {
            if error.status == 429 {
                return .rateLimited(
                    retryAfterSeconds: Self.retryAfterSeconds(from: error.originalResponse.urlResponse),
                    httpStatus: error.status
                )
            }
            return .requestFailed(
                code: "music_data_\(error.status)",
                httpStatus: error.status > 0 ? error.status : nil
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
    ) -> MetadataEnrichmentError {
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
