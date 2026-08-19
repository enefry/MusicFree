import Foundation
import LibraryAPI
import LocalMediaAdapter
import MusicDomain
import Testing

@Suite(.serialized)
struct MetadataServerMetadataProviderTests {
    @Test("Metadata Server does not hard-filter local album and duration")
    func doesNotSendOptionalLocalConstraints() async throws {
        let requests = Locked<[URLRequest]>([])
        MetadataServerURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            return StubResponse(
                statusCode: 200,
                data: Data("{\"results\":[]}".utf8)
            )
        }
        defer { MetadataServerURLProtocol.clearHandler() }

        let configuration = try #require(
            MetadataServerConfiguration(
                baseURL: URL(string: "https://metadata.test/api/v1/metadata")!
            )
        )
        let provider = MetadataServerMetadataProvider(
            configuration: configuration,
            session: makeStubSession(),
            durationProvider: { _ in 222.813 }
        )
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "stale-duration"),
            title: "Song",
            artistName: "Artist",
            durationSeconds: 12.5
        )

        _ = try await provider.search(query)
        let request = try #require(requests.value.first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        let queryItems = try #require(
            components.queryItems
        )
        #expect(queryItems.map(\.name) == ["track_name", "artist_name"])
        #expect(queryItems.map(\.value) == ["Song", "Artist"])
    }

    @Test("Metadata Server supports leading bracket title variants")
    func supportsLeadingBracketTitleVariants() async throws {
        let requests = Locked<[URLRequest]>([])
        MetadataServerURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            let queryItems = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            let trackName = queryItems.first(where: { $0.name == "track_name" })?.value
            guard trackName == "Close To You" else {
                return StubResponse(
                    statusCode: 200,
                    data: Data("{\"results\":[]}".utf8)
                )
            }
            return StubResponse(
                statusCode: 200,
                data: Data(
                    """
                    {"artistName":"Carpenters","results":[{"releaseId":7,"track":{"position":"1-1.5","title":"Close To You","artists":[{"name":"Carpenters"}]}}]}
                    """.utf8
                )
            )
        }
        defer { MetadataServerURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "leading-bracket-title"),
            title: "(They Long to Be) Close To You",
            artistName: "Carpenters",
            missingFields: [.album]
        )

        let candidates = try await provider.search(query)
        let candidate = try #require(candidates.first)
        #expect(candidate.title == "Close To You")

        let trackRequests = requests.value.filter {
            $0.url?.path == "/api/v1/metadata/track"
        }
        let trackNames = trackRequests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "track_name" })?
                .value
        }
        #expect(trackNames == ["Close To You"])
    }

    @Test("Metadata Server maps track, release detail, and artwork")
    func mapsTrackAndReleaseDetails() async throws {
        let trackResponse = Data(
            """
            {
              "trackName": "Example Song",
              "artistName": "Example Artist",
              "albumName": "Example Album",
              "results": [
                {
                  "releaseId": 123456,
                  "masterId": 654321,
                  "releaseTitle": "Example Album",
                  "year": 2024,
                  "country": "US",
                  "track": {
                    "position": "1-1",
                    "title": "Example Song",
                    "duration": "3:00",
                    "artists": [{"name": "Example Artist"}]
                  }
                }
              ]
            }
            """.utf8
        )
        let releaseResponse = Data(
            """
            {
              "id": 123456,
              "title": "Example Album",
              "year": 2024,
              "artists": [{"name": "Example Artist"}],
              "genres": ["Electronic"],
              "styles": ["House"],
              "tracklist": [
                {
                  "position": "1-1",
                  "title": "Example Song",
                  "duration": "3:00",
                  "artists": []
                }
              ],
              "images": [
                {
                  "type": "primary",
                  "uri": "https://images.test/example.jpg",
                  "uri150": "https://images.test/example-150.jpg"
                }
              ]
            }
            """.utf8
        )
        let artwork = Data([0x01, 0x02, 0x03])
        let requests = Locked<[URLRequest]>([])
        MetadataServerURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            switch request.url?.path {
            case "/api/v1/metadata/track":
                return StubResponse(statusCode: 200, data: trackResponse)
            case "/api/v1/metadata/releases/123456":
                return StubResponse(statusCode: 200, data: releaseResponse)
            case "/example.jpg":
                return StubResponse(statusCode: 200, data: artwork)
            default:
                return StubResponse(statusCode: 404, data: Data())
            }
        }
        defer { MetadataServerURLProtocol.clearHandler() }

        let configuration = try #require(
            MetadataServerConfiguration(
                baseURL: URL(string: "https://metadata.test/api/v1/metadata")!
            )
        )
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = MetadataServerMetadataProvider(
            configuration: configuration,
            session: session
        )
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "metadata-server-track"),
            title: "Example Song",
            artistName: "Example Artist",
            albumName: "Example Album",
            durationSeconds: 180.4,
            missingFields: [
                .albumArtist, .genre, .year, .trackNumber, .discNumber, .artwork
            ]
        )

        let candidates = try await provider.search(query)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.title == "Example Song")
        #expect(candidate.artistName == "Example Artist")
        #expect(candidate.albumArtistName == "Example Artist")
        #expect(candidate.albumName == "Example Album")
        #expect(candidate.genreName == "Electronic")
        #expect(candidate.year == 2024)
        #expect(candidate.trackNumber == 1)
        #expect(candidate.discNumber == 1)
        #expect(candidate.durationSeconds == 180)

        #expect(try await provider.artworkData(for: candidate) == artwork)

        let capturedRequests = requests.value
        #expect(capturedRequests.map(\.url?.path) == [
            "/api/v1/metadata/track",
            "/api/v1/metadata/releases/123456",
            "/example.jpg"
        ])
        let trackRequest = try #require(capturedRequests.first)
        let trackURL = try #require(trackRequest.url)
        let queryItems = try #require(
            URLComponents(url: trackURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.map(\.name) == ["track_name", "artist_name"])
        #expect(queryItems.map(\.value) == ["Example Song", "Example Artist"])

        #expect(trackRequest.value(forHTTPHeaderField: "X-Lrclib-Client-Id") == nil)
        #expect(trackRequest.value(forHTTPHeaderField: "X-Lrclib-Signature") == nil)
    }

    @Test("Metadata Server keeps a track match when release details fail")
    func releaseDetailsAreOptional() async throws {
        MetadataServerURLProtocol.setHandler { request in
            if request.url?.path == "/api/v1/metadata/track" {
                return StubResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        {"results":[{"releaseId":7,"releaseTitle":"Album","year":2020,"track":{"position":"2-4","title":"Song","duration":"4:05","artists":[{"name":"Artist"}]}}]}
                        """.utf8
                    )
                )
            }
            return StubResponse(statusCode: 503, data: Data())
        }
        defer { MetadataServerURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "optional-details"),
            title: "Song",
            artistName: "Artist",
            missingFields: [.genre, .artwork]
        )
        let candidates = try await provider.search(query)
        let candidate = try #require(candidates.first)
        #expect(candidate.title == "Song")
        #expect(candidate.genreName == nil)
        #expect(candidate.trackNumber == 4)
        #expect(candidate.discNumber == 2)
    }

    @Test("Metadata Server maps documented HTTP failures")
    func mapsHTTPFailures() async throws {
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "status-track"),
            title: "Song",
            artistName: "Artist",
            missingFields: [.genre]
        )
        for statusCode in [401, 404, 429, 503] {
            MetadataServerURLProtocol.setHandler { _ in
                StubResponse(
                    statusCode: statusCode,
                    data: Data(),
                    headers: statusCode == 429 ? ["Retry-After": "7"] : [:]
                )
            }
            let provider = try makeProvider()
            do {
                _ = try await provider.search(query)
                Issue.record("HTTP \(statusCode) must fail")
            } catch let error as MetadataEnrichmentError {
                switch (statusCode, error) {
                case (401, .notAuthorized):
                    break
                case (404, .requestFailed(_, let httpStatus)):
                    #expect(httpStatus == 404)
                case (429, .rateLimited(let retryAfter, let httpStatus)):
                    #expect(retryAfter == 7)
                    #expect(httpStatus == 429)
                case (503, .requestFailed(_, let httpStatus)):
                    #expect(httpStatus == 503)
                default:
                    Issue.record("Unexpected error for HTTP \(statusCode): \(error)")
                }
            }
        }
        MetadataServerURLProtocol.clearHandler()
    }

    private func makeProvider() throws -> MetadataServerMetadataProvider {
        let configuration = try #require(
            MetadataServerConfiguration(
                baseURL: URL(string: "https://metadata.test/api/v1/metadata")!
            )
        )
        return MetadataServerMetadataProvider(
            configuration: configuration,
            session: makeStubSession()
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataServerURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

private final class MetadataServerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> StubResponse)?

    static func setHandler(_ handler: @escaping (URLRequest) -> StubResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func clearHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["metadata.test", "images.test"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: StubResponse?
        Self.lock.lock()
        response = Self.handler?(request)
        Self.lock.unlock()
        guard let response,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
