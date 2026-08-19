import Foundation
import LocalMediaAdapter
import MusicDomain
import Testing

@Suite(.serialized)
struct LRCLIBLyricsProviderTests {
    @Test("LRCLIB sends the documented lookup parameters and prefers synced lyrics")
    func sendsLookupParametersAndPrefersSyncedLyrics() async throws {
        let requests = Locked<[URLRequest]>([])
        LRCLIBURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            return LRCLIBStubResponse(
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
        defer { LRCLIBURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = LyricsQuery(
            itemID: MediaItemID(sourceID: .local, externalID: "lrclib-request"),
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
        let url = try #require(request.url)
        #expect(url.path == "/api/get")
        let queryItems = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(queryItems.map(\.name) == [
            "track_name", "artist_name", "album_name", "duration"
        ])
        #expect(queryItems.map(\.value) == ["Song", "Artist", "Album", "180.400"])
    }

    @Test("LRCLIB retries without stale album and duration constraints")
    func retriesWithoutOptionalConstraints() async throws {
        let requests = Locked<[URLRequest]>([])
        LRCLIBURLProtocol.setHandler { request in
            requests.withValue { $0.append(request) }
            let queryItems = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
                ?? []
            let hasOptionalConstraint = queryItems.contains {
                $0.name == "album_name" || $0.name == "duration"
            }
            return hasOptionalConstraint
                ? LRCLIBStubResponse(statusCode: 404, data: Data())
                : LRCLIBStubResponse(
                    statusCode: 200,
                    data: Data("{\"plainLyrics\":\"Fallback line\"}".utf8)
                )
        }
        defer { LRCLIBURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let lyrics = try await provider.fetchLyrics(
            for: LyricsQuery(
                itemID: MediaItemID(sourceID: .local, externalID: "lrclib-fallback"),
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

    @Test("LRCLIB accepts plain text and legacy lyrics file field names")
    func acceptsPlainAndLegacyLyricsFields() async throws {
        let payloads = [
            "{\"plainLyrics\":\"Plain line\"}",
            "{\"lyricsFile\":\"[00:02.00]Upper legacy\"}",
            "{\"lyricsfile\":\"[00:03.00]Lower legacy\"}"
        ]
        let payloadIndex = Locked(0)
        LRCLIBURLProtocol.setHandler { _ in
            let index = payloadIndex.withValue { value in
                defer { value += 1 }
                return value
            }
            return LRCLIBStubResponse(
                statusCode: 200,
                data: Data(payloads[min(index, payloads.count - 1)].utf8)
            )
        }
        defer { LRCLIBURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = makeQuery()
        #expect(try await provider.fetchLyrics(for: query)?.rawText == "Plain line")
        #expect(
            try await provider.fetchLyrics(for: query)?.rawText ==
                "[00:02.00]Upper legacy"
        )
        #expect(
            try await provider.fetchLyrics(for: query)?.rawText ==
                "[00:03.00]Lower legacy"
        )
    }

    @Test("LRCLIB treats instrumental tracks and empty lyric fields as no match")
    func handlesInstrumentalAndEmptyResults() async throws {
        let response = Locked(
            Data("{\"instrumental\":true,\"plainLyrics\":\"Should be ignored\"}".utf8)
        )
        LRCLIBURLProtocol.setHandler { _ in
            LRCLIBStubResponse(statusCode: 200, data: response.value)
        }
        defer { LRCLIBURLProtocol.clearHandler() }

        let provider = try makeProvider()
        #expect(try await provider.fetchLyrics(for: makeQuery()) == nil)

        response.withValue { $0 = Data("{\"plainLyrics\":\"   \"}".utf8) }
        #expect(try await provider.fetchLyrics(for: makeQuery()) == nil)
    }

    @Test("LRCLIB maps not found, rate limit, server, and invalid responses")
    func mapsHTTPAndDecodeFailures() async throws {
        let statusCode = Locked(404)
        LRCLIBURLProtocol.setHandler { _ in
            let currentStatus = statusCode.value
            let data = currentStatus == 200
                ? Data("{\"plainLyrics\":\"Valid\"}".utf8)
                : Data()
            return LRCLIBStubResponse(statusCode: currentStatus, data: data)
        }
        defer { LRCLIBURLProtocol.clearHandler() }

        let provider = try makeProvider()
        let query = makeQuery()
        #expect(try await provider.fetchLyrics(for: query) == nil)

        for currentStatus in [429, 500] {
            statusCode.withValue { $0 = currentStatus }
            do {
                _ = try await provider.fetchLyrics(for: query)
                Issue.record("HTTP \(currentStatus) must fail")
            } catch let error as LyricsProviderError {
                #expect(
                    error == .requestFailed(
                        code: currentStatus == 429
                            ? "lrclib_rate_limited"
                            : "lrclib_http_500",
                        httpStatus: currentStatus
                    )
                )
            }
        }

        statusCode.withValue { $0 = 200 }
        LRCLIBURLProtocol.setHandler { _ in
            LRCLIBStubResponse(statusCode: 200, data: Data("{invalid".utf8))
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
            itemID: MediaItemID(sourceID: .local, externalID: "lrclib-test"),
            title: "Song",
            artistName: "Artist"
        )
    }

    private func makeProvider() throws -> LRCLIBLyricsProvider {
        let configuration = try #require(
            LRCLIBAPIConfiguration(
                baseURL: URL(string: "https://lrclib.test")!,
                requestTimeout: 4
            )
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LRCLIBURLProtocol.self]
        return LRCLIBLyricsProvider(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
    }
}

private struct LRCLIBStubResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

private final class LRCLIBURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> LRCLIBStubResponse)?

    static func setHandler(_ handler: @escaping (URLRequest) -> LRCLIBStubResponse) {
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
        request.url?.host == "lrclib.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response: LRCLIBStubResponse?
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

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
