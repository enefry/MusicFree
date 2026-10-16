import Foundation
import Testing
import MusicFreePluginAPI
@testable import ChineseMusicCatalogSupport
import NetEaseLyricsPlugin
import NetEaseMetadataPlugin
import QQMusicLyricsPlugin
import QQMusicMetadataPlugin

private let catalogQuery = PluginTrackQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", durationSeconds: 269)
private func catalogContext(allowed: Bool = true) -> PluginOperationContext {
    .init(pluginID: .init(rawValue: "test.catalog"), instanceID: "default", generation: 1,
        permissions: allowed ? [.network, .credentials] : [], applicationPrivacyAccepted: allowed)
}
private var netEaseSong: [String: Any] { ["id": 186016, "name": "晴天", "ar": [["name": "周杰伦"]],
    "al": ["name": "叶惠美", "picUrl": "http://p1.music.126.net/cover.jpg"], "dt": 269000,
    "publishTime": 1059580800000, "no": 3, "cd": "1"] }
private var qqSong: [String: Any] { ["id": 97773, "mid": "0039MnYb0qxYhV", "title": "晴天",
    "singer": [["name": "周杰伦"]], "album": ["name": "叶惠美", "mid": "002eFUFm2XYZ7z"],
    "interval": 269, "time_public": "2003-07-31", "index_album": 3, "index_cd": 0] }
private func netEaseSearch(_ rows: [[String: Any]] = [netEaseSong]) -> [String: Any] {
    ["code": 200, "result": ["songs": rows, "songCount": rows.count]]
}
private func qqSearch(_ rows: [[String: Any]] = [qqSong]) -> [String: Any] {
    ["code": 0, "req_1": ["code": 0, "data": ["body": ["item_song": rows]]]]
}

@Suite(.serialized)
struct ChineseMusicPluginTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICFREE_LIVE_CATALOG_CHECK"] == "1"))
    func liveQQMusicLyricsMetadataAndArtwork() async throws {
        let metadata = QQMusicMetadataPlugin()
        let candidates = try await metadata.candidates(for: catalogQuery, fields: [.year, .trackNumber, .artwork], context: catalogContext())
        let match = try #require(candidates.first { catalogQuery.matches($0.track) })
        #expect(match.patch.numbers[.year] == 2003)
        #expect(match.patch.numbers[.trackNumber] == 3)
        let artwork = try await metadata.artwork(reference: #require(match.artworkReference), context: catalogContext())
        #expect(artwork?.isEmpty == false)
        let lyrics = try await QQMusicLyricsPlugin().candidates(for: catalogQuery, context: catalogContext())
        #expect(lyrics.first?.lines.isEmpty == false)
        #expect(lyrics.first?.rawText.contains("[" ) == true)
    }

    @Test func netEaseLyricsPreserveIdentityTranslationAndWords() async throws {
        CatalogFixtureProtocol.set([.json(netEaseSearch()), .json(["code": 200,
            "lrc": ["lyric": "[00:01.00]晴天"], "tlyric": ["lyric": "[00:01.00]Sunny day"],
            "yrc": ["lyric": "[1000,500](1000,200,0)晴(1200,300,0)天"]])])
        let plugin = NetEaseLyricsPlugin(session: catalogSession())
        let lyric = try #require(try await plugin.candidates(for: catalogQuery, context: catalogContext()).first)
        #expect(lyric.id == "netEase:186016")
        #expect(lyric.track == catalogQuery)
        #expect(lyric.rawText == "[00:01.00]晴天")
        #expect(lyric.lines.first?.translation == "Sunny day")
        #expect(lyric.lines.first?.words.map(\.text) == ["晴", "天"])
        #expect(lyric.lines.first?.words.last?.startMilliseconds == 1200)
        #expect(CatalogFixtureProtocol.requests.map { $0.url?.path } == ["/weapi/cloudsearch/get/web", "/weapi/song/lyric"])
    }

    @Test func netEaseMetadataHydratesRequestedFieldsAndDefersCover() async throws {
        CatalogFixtureProtocol.set([.json(netEaseSearch()), .json(["code": 200, "songs": [netEaseSong]]), .bytes(Data([1, 2, 3]))])
        let configuration = try await ChineseMusicConfiguration.from(.init(operation: catalogContext(),
            configuration: .init(credentialRecordID: "record"), credentials: CookieFixture(value: "test_cookie=fixture")))
        let plugin = NetEaseMetadataPlugin(configuration: configuration, session: catalogSession())
        let candidate = try #require(try await plugin.candidates(for: catalogQuery, fields: [.year, .trackNumber, .discNumber, .artwork], context: catalogContext()).first)
        #expect(candidate.track == catalogQuery)
        #expect(candidate.patch.numbers == [.year: 2003, .trackNumber: 3, .discNumber: 1])
        #expect(candidate.patch.text.isEmpty)
        #expect(CatalogFixtureProtocol.requests.count == 2)
        let cover = try #require(candidate.artworkReference)
        #expect(try await plugin.artwork(reference: cover, context: catalogContext()) == Data([1, 2, 3]))
        #expect(CatalogFixtureProtocol.requests.last?.url?.scheme == "https")
        #expect(CatalogFixtureProtocol.requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "test_cookie=fixture" })
        #expect(CatalogFixtureProtocol.requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func qqLyricsDecodeBase64EntitiesAndTranslation() async throws {
        let raw = "[offset:-100]\n[00:01.20]晴天 &amp; &#x4e2d;"
        CatalogFixtureProtocol.set([.json(qqSearch()), .json(["code": 0, "lyric": Data(raw.utf8).base64EncodedString(),
            "trans": Data("[00:01.10]Sunny day".utf8).base64EncodedString()])])
        let plugin = QQMusicLyricsPlugin(session: catalogSession())
        let candidate = try #require(try await plugin.candidates(for: catalogQuery, context: catalogContext()).first)
        #expect(candidate.track == catalogQuery)
        #expect(candidate.rawText.contains("晴天 & 中"))
        #expect(candidate.lines.first?.startMilliseconds == 1100)
        #expect(candidate.lines.first?.translation == "Sunny day")
        #expect(CatalogFixtureProtocol.requests.last?.url?.path == "/lyric/fcgi-bin/fcg_query_lyric_new.fcg")
    }

    @Test func qqMetadataFiltersFieldsAndProvidesDeferredArtwork() async throws {
        CatalogFixtureProtocol.set([.json(qqSearch()), .bytes(Data([4]))])
        let plugin = QQMusicMetadataPlugin(session: catalogSession())
        let candidate = try #require(try await plugin.candidates(for: catalogQuery, fields: [.album, .year, .trackNumber, .discNumber, .artwork], context: catalogContext()).first)
        #expect(candidate.patch.text == [.album: "叶惠美"])
        #expect(candidate.patch.numbers == [.year: 2003, .trackNumber: 3, .discNumber: 1])
        #expect(CatalogFixtureProtocol.requests.count == 1)
        #expect(try await plugin.artwork(reference: #require(candidate.artworkReference), context: catalogContext()) == Data([4]))
        #expect(CatalogFixtureProtocol.requests.last?.url?.host == "y.gtimg.cn")
    }

    @Test func unrelatedOrAmbiguousSearchNeverDownloadsLyrics() async throws {
        var wrong = qqSong; wrong["title"] = "同名的另一首歌"
        CatalogFixtureProtocol.set([.json(qqSearch([wrong]))])
        let plugin = QQMusicLyricsPlugin(session: catalogSession())
        #expect(try await plugin.candidates(for: catalogQuery, context: catalogContext()).isEmpty)
        #expect(CatalogFixtureProtocol.requests.count == 1)
        var duplicate = qqSong; duplicate["id"] = 123
        CatalogFixtureProtocol.set([.json(qqSearch([qqSong, duplicate]))])
        await #expect(throws: PluginError.ambiguous) { try await plugin.candidates(for: catalogQuery, context: catalogContext()) }
        #expect(CatalogFixtureProtocol.requests.count == 1)
    }

    @Test func malformedAndLoginResponsesRemainFailures() async throws {
        CatalogFixtureProtocol.set([.json(["code": 50000005])])
        await #expect(throws: PluginDataError.notAuthorized) {
            try await NetEaseMetadataPlugin(session: catalogSession()).candidates(for: catalogQuery, fields: [.year], context: catalogContext())
        }
        CatalogFixtureProtocol.set([.json(["code": 0, "req_1": ["code": 0]])])
        await #expect(throws: PluginDataError.invalidResponse) {
            try await QQMusicMetadataPlugin(session: catalogSession()).candidates(for: catalogQuery, fields: [.year], context: catalogContext())
        }
        CatalogFixtureProtocol.set([.json(qqSearch()), .json(["code": 0, "lyric": "invalid Base64!"])])
        await #expect(throws: PluginDataError.invalidResponse) {
            try await QQMusicLyricsPlugin(session: catalogSession()).candidates(for: catalogQuery, context: catalogContext())
        }
    }

    @Test func emptyResultsAndInstrumentalRemainNoMatch() async throws {
        CatalogFixtureProtocol.set([.json(netEaseSearch([])), .json(netEaseSearch([])), .json(netEaseSearch([]))])
        #expect(try await NetEaseLyricsPlugin(session: catalogSession()).candidates(for: catalogQuery, context: catalogContext()).isEmpty)
        CatalogFixtureProtocol.set([.json(netEaseSearch()), .json(["code": 200, "nolyric": true])])
        #expect(try await NetEaseLyricsPlugin(session: catalogSession()).candidates(for: catalogQuery, context: catalogContext()).isEmpty)
    }

    @Test func revokedConsentAndCancellationMakeNoRequests() async throws {
        CatalogFixtureProtocol.set([])
        let lyrics: [any LyricsPlugin] = [NetEaseLyricsPlugin(session: catalogSession()), QQMusicLyricsPlugin(session: catalogSession())]
        for plugin in lyrics {
            await #expect(throws: PluginError.permissionRequired) { try await plugin.candidates(for: catalogQuery, context: catalogContext(allowed: false)) }
        }
        let metadata: [any MetadataPlugin] = [NetEaseMetadataPlugin(session: catalogSession()), QQMusicMetadataPlugin(session: catalogSession())]
        for plugin in metadata {
            await #expect(throws: PluginError.permissionRequired) { try await plugin.candidates(for: catalogQuery, fields: [.year], context: catalogContext(allowed: false)) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lyrics[0].candidates(for: catalogQuery, context: catalogContext())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(CatalogFixtureProtocol.requests.isEmpty)
    }

    @Test func responseSizeAndRateLimitsAreBounded() async throws {
        CatalogFixtureProtocol.set([.init(status: 429, body: Data(), headers: ["Retry-After": "3"])])
        await #expect(throws: PluginDataError.rateLimited(retryAfterSeconds: 3, httpStatus: 429)) {
            try await QQMusicMetadataPlugin(session: catalogSession()).candidates(for: catalogQuery, fields: [], context: catalogContext())
        }
        CatalogFixtureProtocol.set([.bytes(Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1))])
        await #expect(throws: PluginDataError.payloadTooLarge) {
            try await NetEaseMetadataPlugin(session: catalogSession()).candidates(for: catalogQuery, fields: [], context: catalogContext())
        }
    }

    @Test func credentialsRequirePermissionAndRejectHeaderInjection() async throws {
        for cookie in ["session=value\r\nInjected: yes", String(repeating: "a", count: 8193)] {
            await #expect(throws: PluginError.invalidConfiguration) {
                try await ChineseMusicConfiguration.from(.init(operation: catalogContext(), configuration: .init(credentialRecordID: "record"), credentials: CookieFixture(value: cookie)))
            }
        }
        await #expect(throws: PluginError.invalidConfiguration) {
            try await ChineseMusicConfiguration.from(.init(operation: catalogContext(allowed: false), configuration: .init(credentialRecordID: "record"), credentials: CookieFixture(value: "session=value")))
        }
    }

    // Fixed vectors generated independently using OpenSSL and the upstream
    // public RSA modulus / byte substitution table.
    @Test func netEaseEncryptionAndOverseasSearchMatchFixedVectors() throws {
        let body = try NetEaseRequestEncryption.body(["id": "186016", "csrf_token": ""])
        let form = try #require(URLComponents(string: "https://fixture.test/?" + String(decoding: body, as: UTF8.self)))
        #expect(form.queryItems?.first { $0.name == "params" }?.value == "LP43BvK4wwiAu9W7qVl/eVzfcyB9zQpA4NysZx92TxsxH4g35nCU0kRaOs2VePdE")
        #expect(form.queryItems?.first { $0.name == "encSecKey" }?.value == "59092ace9f8046ed2bfa1fffc1eec9385ba32538e13ca35c05096a4f227555174f2dec95395bc8f25f9d2fbb563d0428d1d07ee38d6a9e2ae27fc23f6887d29bbeb7245c85e953184380d94ad3083934cad7d9c4258045e637f355d32f7c8134420705a36c6fc073fe9325b989a6631a12cf21966fe45d9ccd87bf9ea7e6f741")
        let decoded = try NetEaseSearchDecoding.decode("35b1748964af8a7c1d8827890d15d304a7f8894555ed7c1d3aaa65d68a0091b96fda7de353c246770d65d68a0091b96fda7de353c246770d65d68a0091b96fd3")
        #expect(String(decoding: decoded, as: UTF8.self) == #"{"songs":[],"songCount":0}"#)
        #expect(throws: PluginDataError.invalidResponse) { try NetEaseSearchDecoding.decode("invalid") }
    }

    @Test func lrcHandlesMultipleTimesAndRejectsOverflow() {
        let lines = ServiceLyrics.lines(raw: "[00:01.00][00:02.00]重复\n[999999999999999999999999:00.00]无效\n[00:60.00]无效", translation: "", wordTimed: nil)
        #expect(lines.map(\.startMilliseconds) == [1000, 2000])
        #expect(lines.map(\.text) == ["重复", "重复"])
    }
}

private struct CookieFixture: PluginCredentialAccess {
    let value: String
    func read(recordID: String, pluginID: PluginID, instanceID: String) async throws -> Data? { Data(value.utf8) }
}
private struct CatalogFixtureResponse: Sendable {
    let status: Int
    let body: Data
    var headers: [String: String] = [:]
    static func json(_ object: [String: Any]) -> Self { .init(status: 200, body: try! JSONSerialization.data(withJSONObject: object)) }
    static func bytes(_ data: Data) -> Self { .init(status: 200, body: data) }
}
private final class CatalogFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [CatalogFixtureResponse] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func set(_ values: [CatalogFixtureResponse]) { lock.withLock { responses = values; captured = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.lock.withLock {
            Self.captured.append(request)
            return Self.responses.isEmpty ? CatalogFixtureResponse(status: 500, body: Data()) : Self.responses.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: nil, headerFields: result.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func catalogSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogFixtureProtocol.self]
    return URLSession(configuration: configuration)
}
