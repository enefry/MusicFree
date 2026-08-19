import Foundation
import LibraryAPI
import LocalMediaAdapter
import MusicDomain
import Testing

@Suite(.serialized)
struct DiscogsMetadataProviderTests {
    @Test("Discogs maps release tracklist, detail metadata, and signed artwork")
    func mapsOfficialReleaseResponse() async throws {
        let searchResponse = Data(
            """
            {
              "pagination": {"page": 1, "pages": 1, "per_page": 10, "items": 1},
              "results": [
                {
                  "id": 123456,
                  "title": "Example Artist - Example Album",
                  "year": "2024"
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
                  "type_": "track",
                  "title": "Example Song",
                  "duration": "3:00",
                  "artists": []
                }
              ],
              "images": [
                {
                  "type": "primary",
                  "uri": "https://images.discogs.test/example.jpg",
                  "uri150": "https://images.discogs.test/example-150.jpg"
                }
              ]
            }
            """.utf8
        )
        let artwork = Data([0x01, 0x02, 0x03])
        let requests = Locked<[URLRequest]>([])
        DiscogsURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            switch request.url?.path {
            case "/database/search":
                return DiscogsStubResponse(statusCode: 200, data: searchResponse)
            case "/releases/123456":
                return DiscogsStubResponse(statusCode: 200, data: releaseResponse)
            case "/example.jpg":
                return DiscogsStubResponse(statusCode: 200, data: artwork)
            default:
                return DiscogsStubResponse(statusCode: 404, data: Data())
            }
        }
        defer { DiscogsURLProtocol.clearHandler() }

        let configuration = try #require(
            DiscogsAPIConfiguration(
                baseURL: URL(string: "https://api.discogs.test")!,
                userAgent: "MyMusicTests/1.0",
                token: "test-token",
                minimumRequestInterval: 0
            )
        )
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = DiscogsMetadataProvider(
            configuration: configuration,
            session: session
        )
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "discogs-track"),
            title: "Example Song",
            artistName: "Example Artist",
            albumName: "A local album with a different title",
            durationSeconds: 180.4,
            missingFields: [.albumArtist, .genre, .year, .trackNumber, .discNumber, .artwork]
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
            "/database/search",
            "/releases/123456",
            "/example.jpg"
        ])
        let searchRequest = try #require(capturedRequests.first)
        let searchURL = try #require(searchRequest.url)
        let queryItems = try #require(
            URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.map(\.name) == ["type", "track", "artist", "per_page"])
        #expect(queryItems.map(\.value) == [
            "release", "Example Song", "Example Artist", "10"
        ])
        #expect(searchRequest.value(forHTTPHeaderField: "User-Agent") == "MyMusicTests/1.0")
        #expect(
            searchRequest.value(forHTTPHeaderField: "Authorization") ==
                "Discogs token=test-token"
        )
        #expect(
            searchRequest.value(forHTTPHeaderField: "Accept") ==
                "application/vnd.discogs.v2.discogs+json"
        )
    }

    @Test("Discogs sends the leading bracket title variant first")
    func supportsLeadingBracketTitleVariants() async throws {
        let requests = Locked<[URLRequest]>([])
        DiscogsURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            switch request.url?.path {
            case "/database/search":
                return DiscogsStubResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        {"results":[{"id":7,"title":"Carpenters - Close To You","year":"1970"}]}
                        """.utf8
                    )
                )
            case "/releases/7":
                return DiscogsStubResponse(
                    statusCode: 200,
                    data: Data(
                        """
                        {"id":7,"title":"Close To You","artists":[{"name":"Carpenters"}],"tracklist":[{"position":"1","title":"Close To You","duration":"3:00"}]}
                        """.utf8
                    )
                )
            default:
                return DiscogsStubResponse(statusCode: 404, data: Data())
            }
        }
        defer { DiscogsURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "discogs-leading-bracket"),
            title: "(They Long to Be) Close To You",
            artistName: "Carpenters"
        )

        let candidates = try await provider.search(query)
        #expect(candidates.first?.title == "Close To You")
        let searchRequest = try #require(requests.value.first)
        let queryItems = try #require(
            URLComponents(url: searchRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.first(where: { $0.name == "track" })?.value == "Close To You")
    }

    @Test("Discogs maps authorization, rate limit, and server failures")
    func mapsHTTPFailures() async throws {
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "discogs-status"),
            title: "Song",
            artistName: "Artist"
        )
        for statusCode in [401, 403, 404, 429, 503] {
            DiscogsURLProtocol.setHandler { _ in
                DiscogsStubResponse(
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
                case (401, .notAuthorized), (403, .notAuthorized):
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
        DiscogsURLProtocol.clearHandler()
    }

    @Test("Discogs defaults to anonymous and authenticated rate limits")
    func configurationChoosesRateLimitInterval() throws {
        let anonymous = try #require(
            DiscogsAPIConfiguration(
                baseURL: URL(string: "https://api.discogs.test")!,
                userAgent: "MyMusicTests/1.0"
            )
        )
        let authenticated = try #require(
            DiscogsAPIConfiguration(
                baseURL: URL(string: "https://api.discogs.test")!,
                userAgent: "MyMusicTests/1.0",
                token: "test-token"
            )
        )
        #expect(anonymous.minimumRequestInterval == 60.0 / 25.0)
        #expect(authenticated.minimumRequestInterval == 1.0)
    }

    private func makeProvider() throws -> DiscogsMetadataProvider {
        let configuration = try #require(
            DiscogsAPIConfiguration(
                baseURL: URL(string: "https://api.discogs.test")!,
                userAgent: "MyMusicTests/1.0",
                minimumRequestInterval: 0
            )
        )
        return DiscogsMetadataProvider(
            configuration: configuration,
            session: makeStubSession()
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscogsURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct DiscogsStubResponse {
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

private final class DiscogsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> DiscogsStubResponse)?

    static func setHandler(_ handler: @escaping (URLRequest) -> DiscogsStubResponse) {
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
        ["api.discogs.test", "images.discogs.test"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: DiscogsStubResponse?
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
