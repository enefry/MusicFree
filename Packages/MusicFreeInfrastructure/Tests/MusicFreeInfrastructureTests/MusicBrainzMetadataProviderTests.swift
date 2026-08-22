import Foundation
import LibraryAPI
import LocalMediaAdapter
import MusicDomain
import Testing

@Suite(.serialized)
struct MusicBrainzMetadataProviderTests {
    @Test("MusicBrainz maps recordings and downloads Cover Art Archive artwork")
    func mapsRecordingAndArtwork() async throws {
        let searchResponse = Data(
            """
            {
              "recordings": [
                {
                  "id": "recording-1",
                  "title": "Example Song",
                  "length": 180000,
                  "first-release-date": "2024-01-02",
                  "artist-credit": [
                    {"name": "Example Artist", "joinphrase": ""}
                  ],
                  "releases": [
                    {
                      "id": "release-1",
                      "title": "Example Album",
                      "status": "Official",
                      "date": "2024-01-02",
                      "media": [
                        {
                          "position": 1,
                          "tracks": [
                            {
                              "position": 3,
                              "number": "3",
                              "title": "Example Song",
                              "recording": {"id": "recording-1"}
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        let coverArtResponse = Data(
            """
            {
              "images": [
                {
                  "front": true,
                  "types": ["Front"],
                  "image": "https://coverartarchive.test/release/release-1/original.jpg",
                  "thumbnails": {
                    "large": "https://coverartarchive.test/release/release-1/front-large.jpg"
                  }
                }
              ]
            }
            """.utf8
        )
        let artwork = Data([0x01, 0x02, 0x03])
        let requests = Locked<[URLRequest]>([])
        MusicBrainzURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            switch request.url?.path {
            case "/ws/2/recording", "/ws/2/recording/":
                return MusicBrainzStubResponse(statusCode: 200, data: searchResponse)
            case "/release/release-1":
                return MusicBrainzStubResponse(statusCode: 200, data: coverArtResponse)
            case "/release/release-1/front-large.jpg":
                return MusicBrainzStubResponse(statusCode: 200, data: artwork)
            default:
                return MusicBrainzStubResponse(statusCode: 404, data: Data())
            }
        }
        defer { MusicBrainzURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "musicbrainz-track"),
            title: "Example Song",
            artistName: "Example Artist",
            albumName: "A stale local album",
            durationSeconds: 999,
            missingFields: [.album, .year, .trackNumber, .discNumber, .artwork]
        )

        let candidates = try await provider.search(query)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.catalogID == "musicbrainz:recording:recording-1:release:release-1")
        #expect(candidate.title == "Example Song")
        #expect(candidate.artistName == "Example Artist")
        #expect(candidate.albumArtistName == "Example Artist")
        #expect(candidate.albumName == "Example Album")
        #expect(candidate.year == 2024)
        #expect(candidate.trackNumber == 3)
        #expect(candidate.discNumber == 1)
        #expect(candidate.durationSeconds == 180)
        #expect(try await provider.artworkData(for: candidate) == artwork)

        let capturedRequests = requests.value
        #expect(capturedRequests.map(\.url?.path) == [
            "/ws/2/recording",
            "/release/release-1",
            "/release/release-1/front-large.jpg"
        ])
        let searchRequest = try #require(capturedRequests.first)
        let searchURL = try #require(searchRequest.url)
        #expect(searchURL.absoluteString.contains("/ws/2/recording/?"))
        let queryItems = try #require(
            URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.map(\.name) == ["query", "fmt", "limit", "inc"])
        #expect(queryItems[0].value == "recording:\"Example Song\" AND artist:\"Example Artist\"")
        #expect(queryItems[1].value == "json")
        #expect(queryItems[2].value == "25")
        #expect(queryItems[3].value == "artist-credits+releases+media")
        #expect(searchRequest.value(forHTTPHeaderField: "User-Agent") == "MyMusicTests/1.0")
        #expect(
            capturedRequests[1].value(forHTTPHeaderField: "Accept") == "application/json"
        )
        #expect(
            capturedRequests[2].value(forHTTPHeaderField: "Accept") == "image/*"
        )
    }

    @Test("MusicBrainz maps rate limits and server failures")
    func mapsHTTPFailures() async throws {
        let query = MetadataEnrichmentQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "musicbrainz-status"),
            title: "Song",
            artistName: "Artist"
        )
        for statusCode in [429, 503] {
            MusicBrainzURLProtocol.setHandler { _ in
                MusicBrainzStubResponse(
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
        MusicBrainzURLProtocol.clearHandler()
    }

    @Test("MusicBrainz configuration defaults to courtesy rate limiting")
    func configurationDefaultsToCourtesyRateLimit() throws {
        let configuration = try #require(
            MusicBrainzAPIConfiguration(
                baseURL: URL(string: "https://musicbrainz.test/ws/2")!,
                coverArtBaseURL: URL(string: "https://coverartarchive.test")!,
                userAgent: "MyMusicTests/1.0"
            )
        )
        #expect(configuration.minimumRequestInterval == 1.0)
        #expect(configuration.requestTimeout == 45)
    }

    private func makeProvider() throws -> MusicBrainzMetadataProvider {
        let configuration = try #require(
            MusicBrainzAPIConfiguration(
                baseURL: URL(string: "https://musicbrainz.test/ws/2")!,
                coverArtBaseURL: URL(string: "https://coverartarchive.test")!,
                userAgent: "MyMusicTests/1.0",
                minimumRequestInterval: 0
            )
        )
        return MusicBrainzMetadataProvider(
            configuration: configuration,
            session: makeStubSession()
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicBrainzURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct MusicBrainzStubResponse {
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

private final class MusicBrainzURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> MusicBrainzStubResponse)?

    static func setHandler(_ handler: @escaping (URLRequest) -> MusicBrainzStubResponse) {
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
        ["musicbrainz.test", "coverartarchive.test"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: MusicBrainzStubResponse?
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
