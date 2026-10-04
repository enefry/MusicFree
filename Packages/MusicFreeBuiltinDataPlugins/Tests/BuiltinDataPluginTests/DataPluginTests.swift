import Foundation
import Testing
import MusicFreePluginAPI
import LRCLIBLyricsPlugin
import MetadataServerLyricsPlugin
import MusicKitMetadataPlugin
import MusicBrainzMetadataPlugin
import MetadataServerMetadataPlugin
import DiscogsMetadataPlugin

private func context(allowed: Bool = true) -> PluginOperationContext {
    .init(pluginID: .init(rawValue: "test"), instanceID: "default", generation: 1,
          permissions: allowed ? [.network] : [], applicationPrivacyAccepted: allowed)
}
private let query = PluginTrackQuery(title: "Example Song", artist: "Example Artist", album: "Example Album", durationSeconds: 180)

@Suite(.serialized)
struct DataPluginTests {
    @Test func sixIndependentNetworkDescriptors() {
        let descriptors = [LRCLIBLyricsPlugin.descriptor, MetadataServerLyricsPlugin.descriptor,
            MusicKitMetadataPlugin.descriptor, MusicBrainzMetadataPlugin.descriptor,
            MetadataServerMetadataPlugin.descriptor, DiscogsMetadataPlugin.descriptor]
        #expect(Set(descriptors.map(\.id)).count == 6)
        #expect(descriptors.filter { $0.kinds == [.lyrics] }.count == 2)
        #expect(descriptors.filter { $0.kinds == [.metadata] }.count == 4)
        #expect(descriptors.allSatisfy { $0.permissions == [.network] })
    }

    @Test(arguments: [false, true]) func bothLyricsServicesPreserveLRCAndQuery(metadataServer: Bool) async throws {
        FixtureProtocol.response = .init(status: 200, body: Data(#"{"syncedLyrics":"[offset:-100]\n[00:01.25]中文歌词"}"#.utf8))
        let session = fixtureSession()
        let plugin: any LyricsPlugin = metadataServer
            ? MetadataServerLyricsPlugin(configuration: try #require(MetadataServerLyricsConfiguration(baseURL: URL(string: "https://fixture.test/api/v1/lyrics")!)), session: session)
            : LRCLIBLyricsPlugin(configuration: try #require(LRCLIBAPIConfiguration(baseURL: URL(string: "https://fixture.test")!)), session: session)
        let result = try #require(try await plugin.candidates(for: query, context: context()).first)
        #expect(result.track == query)
        #expect(result.rawText == "[offset:-100]\n[00:01.25]中文歌词")
        #expect(FixtureProtocol.requests.first?.url?.path == (metadataServer ? "/api/v1/lyrics/get" : "/api/get"))
    }

    @Test(arguments: [404, 429, 500, 200]) func lyricsDistinguishNoMatchAndFailure(status: Int) async throws {
        FixtureProtocol.response = .init(status: status, body: Data("invalid".utf8))
        let plugin = LRCLIBLyricsPlugin(configuration: try #require(LRCLIBAPIConfiguration(baseURL: URL(string: "https://fixture.test")!)), session: fixtureSession())
        if status == 404 {
            #expect(try await plugin.candidates(for: query, context: context()).isEmpty)
        } else {
            do {
                _ = try await plugin.candidates(for: query, context: context())
                Issue.record("Expected failure")
            } catch let error as PluginDataError {
                if status == 200 { #expect(error == .invalidResponse) }
                else { #expect(error == .requestFailed(code: status == 429 ? "lrclib_rate_limited" : "lrclib_http_\(status)", httpStatus: status)) }
            }
        }
    }

    @Test func revokedPrivacyMakesNoRequest() async throws {
        FixtureProtocol.response = .init(status: 200, body: Data())
        let session = fixtureSession()
        let lyrics = LRCLIBLyricsPlugin(configuration: try #require(LRCLIBAPIConfiguration(baseURL: URL(string: "https://fixture.test")!)), session: session)
        let metadata = MusicBrainzMetadataPlugin(configuration: try #require(MusicBrainzAPIConfiguration(baseURL: URL(string: "https://fixture.test")!, coverArtBaseURL: URL(string: "https://fixture.test")!, userAgent: "Tests", minimumRequestInterval: 0)), session: session)
        await #expect(throws: PluginError.permissionRequired) { try await lyrics.candidates(for: query, context: context(allowed: false)) }
        await #expect(throws: PluginError.permissionRequired) { try await metadata.candidates(for: query, fields: [.year], context: context(allowed: false)) }
        #expect(FixtureProtocol.requests.isEmpty)
    }
}

private struct FixtureResponse: Sendable { let status: Int; let body: Data }
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedResponse = FixtureResponse(status: 200, body: Data())
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []
    static var response: FixtureResponse {
        get { lock.withLock { storedResponse } }
        set { lock.withLock { storedResponse = newValue; storedRequests = [] } }
    }
    static var requests: [URLRequest] { lock.withLock { storedRequests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { Self.storedRequests.append(request); return Self.storedResponse }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func fixtureSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProtocol.self]
    return URLSession(configuration: configuration)
}
