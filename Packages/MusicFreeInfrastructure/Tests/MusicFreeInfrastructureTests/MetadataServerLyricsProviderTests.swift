import Foundation
import LocalMediaAdapter
import MusicDomain
import Testing

@Suite(.serialized)
struct MetadataServerLyricsProviderTests {
    @Test("Metadata Server lyrics derives its endpoint and sends documented parameters")
    func sendsLookupParametersAndPrefersSyncedLyrics() async throws {
        let metadataConfiguration = try #require(
            MetadataServerConfiguration(
                baseURL: URL(string: "https://metadata.test/api/v1/metadata")!,
                requestTimeout: 4
            )
        )
        let configuration = try #require(
            MetadataServerLyricsConfiguration(
                metadataServerConfiguration: metadataConfiguration
            )
        )
        #expect(configuration.endpointURL.absoluteString == "https://metadata.test/api/v1/lyrics/get")

        let requests = MetadataServerLyricsLocked<[URLRequest]>([])
        MetadataServerLyricsURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            return MetadataServerLyricsStubResponse(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "instrumental": false,
                      "syncedLyrics": "[00:01.00]Synced line",
                      "plainLyrics": "Plain fallback"
                    }
                    """.utf8
                )
            )
        }
        defer { MetadataServerLyricsURLProtocol.clearHandler() }

        let provider = MetadataServerLyricsProvider(
            configuration: configuration,
            session: makeStubSession()
        )
        let query = LyricsQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "metadata-server-lyrics"),
            title: "  Song  ",
            artistName: " Artist ",
            albumName: " Album ",
            durationSeconds: 180.4
        )

        let lyrics = try await provider.fetchLyrics(for: query)
        #expect(lyrics?.rawText == "[00:01.00]Synced line")
        #expect(lyrics?.timedLines.map(\.text) == ["Synced line"])

        let request = try #require(requests.value.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MusicFree/1.0")
        let requestURL = try #require(request.url)
        let queryItems = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.map(\.name) == [
            "track_name", "artist_name", "album_name", "duration"
        ])
        #expect(queryItems.map(\.value) == ["Song", "Artist", "Album", "180.400"])
    }

    @Test("Metadata Server lyrics retries without stale album and duration constraints")
    func retriesWithoutOptionalConstraints() async throws {
        let requests = MetadataServerLyricsLocked<[URLRequest]>([])
        MetadataServerLyricsURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            let queryItems = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
                ?? []
            let hasOptionalConstraint = queryItems.contains {
                $0.name == "album_name" || $0.name == "duration"
            }
            return hasOptionalConstraint
                ? MetadataServerLyricsStubResponse(statusCode: 404, data: Data())
                : MetadataServerLyricsStubResponse(
                    statusCode: 200,
                    data: Data("{\"plainLyrics\":\"Fallback line\"}".utf8)
                )
        }
        defer { MetadataServerLyricsURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let lyrics = try await provider.fetchLyrics(
            for: LyricsQuery(
                itemID: MediaItemID(sourceID: .local, externalID: "metadata-server-fallback"),
                title: "Song",
                artistName: "Artist",
                albumName: "Stale Album",
                durationSeconds: 180
            )
        )

        #expect(lyrics?.rawText == "Fallback line")
        #expect(requests.value.count == 2)
        let firstQueryItems = try #require(
            requests.value[0].url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            }
        )
        let secondQueryItems = try #require(
            requests.value[1].url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            }
        )
        #expect(firstQueryItems.map(\.name) == [
            "track_name", "artist_name", "album_name", "duration"
        ])
        #expect(secondQueryItems.map(\.name) == ["track_name", "artist_name"])
    }

    @Test("Metadata Server lyrics accepts lyricsfile and treats instrumental tracks as no match")
    func acceptsLegacyLyricsFileAndInstrumentalResults() async throws {
        let response = MetadataServerLyricsLocked(
            Data("{\"lyricsfile\":\"[00:02.00]Legacy line\"}".utf8)
        )
        MetadataServerLyricsURLProtocol.setHandler { _ in
            MetadataServerLyricsStubResponse(statusCode: 200, data: response.value)
        }
        defer { MetadataServerLyricsURLProtocol.clearHandler() }

        let provider = try makeProvider()
        #expect(try await provider.fetchLyrics(for: makeQuery())?.rawText == "[00:02.00]Legacy line")

        response.withValue {
            $0 = Data("{\"instrumental\":true,\"plainLyrics\":\"Ignored\"}".utf8)
        }
        #expect(try await provider.fetchLyrics(for: makeQuery()) == nil)
    }

    @Test("Metadata Server lyrics maps not found, rate limit, and invalid responses")
    func mapsHTTPAndDecodeFailures() async throws {
        let statusCode = MetadataServerLyricsLocked(404)
        MetadataServerLyricsURLProtocol.setHandler { _ in
            let currentStatus = statusCode.value
            let data = currentStatus == 200
                ? Data("{\"plainLyrics\":\"Valid\"}".utf8)
                : Data()
            return MetadataServerLyricsStubResponse(statusCode: currentStatus, data: data)
        }
        defer { MetadataServerLyricsURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = makeQuery()
        #expect(try await provider.fetchLyrics(for: query) == nil)

        statusCode.withValue { $0 = 429 }
        do {
            _ = try await provider.fetchLyrics(for: query)
            Issue.record("HTTP 429 must fail")
        } catch let error as LyricsProviderError {
            #expect(
                error == .requestFailed(
                    code: "metadata_server_lyrics_rate_limited",
                    httpStatus: 429
                )
            )
        }

        statusCode.withValue { $0 = 200 }
        MetadataServerLyricsURLProtocol.setHandler { _ in
            MetadataServerLyricsStubResponse(statusCode: 200, data: Data("{invalid".utf8))
        }
        do {
            _ = try await provider.fetchLyrics(for: query)
            Issue.record("Invalid JSON must fail")
        } catch let error as LyricsProviderError {
            #expect(error == .invalidResponse)
        }
    }

    private func makeQuery() -> LyricsQuery {
        LyricsQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "metadata-server-lyrics-test"),
            title: "Song",
            artistName: "Artist"
        )
    }

    private func makeProvider() throws -> MetadataServerLyricsProvider {
        let configuration = try #require(
            MetadataServerLyricsConfiguration(
                baseURL: URL(string: "https://metadata.test/api/v1/lyrics")!,
                requestTimeout: 4
            )
        )
        return MetadataServerLyricsProvider(
            configuration: configuration,
            session: makeStubSession()
        )
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataServerLyricsURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct MetadataServerLyricsStubResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

private final class MetadataServerLyricsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        ((URLRequest) -> MetadataServerLyricsStubResponse)?

    static func setHandler(
        _ handler: @escaping (URLRequest) -> MetadataServerLyricsStubResponse
    ) {
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
        request.url?.host == "metadata.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: MetadataServerLyricsStubResponse?
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
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
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

private final class MetadataServerLyricsLocked<Value>: @unchecked Sendable {
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

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
