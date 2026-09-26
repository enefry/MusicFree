import AppServices
import Foundation
import MediaSourceAPI
import MusicDomain
import Network
import OnlineSourceAdapter
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

private struct LoopbackDSCredentialProvider: OnlineCredentialProviding {
    let secretValue: String

    func secret(for recordID: String) async throws -> String {
        secretValue
    }
}

private actor LoopbackDSAPIClient: OnlineHTTPClient {
    private(set) var loginCount = 0
    private(set) var infoCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            .queryItems ?? []
        let api = query.first { $0.name == "api" }?.value
        let body: String
        switch api {
        case "SYNO.API.Auth":
            loginCount += 1
            #expect(query.first { $0.name == "method" }?.value == "login")
            body = "{\"success\":true,\"data\":{\"sid\":\"loopback-sid-\(loginCount)\"}}"
        case "SYNO.API.Info":
            infoCount += 1
            #expect(query.first { $0.name == "_sid" }?.value?.hasPrefix("loopback-sid-") == true)
            body = #"{"success":true,"data":{"SYNO.AudioStation.Stream":{"path":"AudioStation/stream.cgi","minVersion":1,"maxVersion":2}}}"#
        default:
            Issue.record("Unexpected DS Audio API request")
            throw URLError(.badServerResponse)
        }
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

private struct LoopbackDSOnlineSources: OnlineSourceServing {
    let transport: DSAudioHTTPTransport
    let configuration: DSAudioSourceConfiguration

    func snapshot() async -> OnlineSourceSnapshot {
        OnlineSourceSnapshot(isApplicationPrivacyAccepted: true)
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        AsyncStream { continuation in
            continuation.yield(OnlineSourceSnapshot(isApplicationPrivacyAccepted: true))
            continuation.finish()
        }
    }

    func authenticate(sourceID: MediaSourceID, oneTimeCode: String) async throws {
        throw URLError(.unsupportedURL)
    }

    func browse(
        sourceID: MediaSourceID, request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        throw URLError(.unsupportedURL)
    }

    func search(
        sourceID: MediaSourceID, request: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw URLError(.unsupportedURL)
    }

    func download(
        sourceID: MediaSourceID, itemID: SourceObjectID, options: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw URLError(.unsupportedURL)
    }

    func playbackAccess(
        sourceID: MediaSourceID, itemID: SourceObjectID, purpose: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        try await transport.playbackAccess(
            configuration: configuration, itemID: itemID, purpose: purpose
        )
    }
}

private final class LoopbackAudioHTTPServer: @unchecked Sendable {
    enum ServerError: Error { case notReady }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.musicfree.tests.loopback-audio")
    private let ready = DispatchSemaphore(value: 0)
    private let audio: Data
    private let supportsRange: Bool
    private let contentType: String
    private let deniedFileName: String?
    private let deniedSessionID: String?
    private let denyOnlyWhenActivated: Bool
    private let requestLock = NSLock()
    private var rangeOffsets: [Int] = []
    private var deniedRequests = 0
    private var denialActivated = false

    var observedRangeOffsets: [Int] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return rangeOffsets
    }

    var deniedRequestCount: Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return deniedRequests
    }

    func activateDenial() {
        requestLock.lock()
        denialActivated = true
        requestLock.unlock()
    }

    init(
        audio: Data,
        supportsRange: Bool = false,
        contentType: String = "audio/mpeg",
        deniedFileName: String? = nil,
        deniedSessionID: String? = nil,
        denyOnlyWhenActivated: Bool = false
    ) throws {
        self.audio = audio
        self.supportsRange = supportsRange
        self.contentType = contentType
        self.deniedFileName = deniedFileName
        self.deniedSessionID = deniedSessionID
        self.denyOnlyWhenActivated = denyOnlyWhenActivated
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(fileName: String = "fixture.mp3") throws -> URL {
        listener.stateUpdateHandler = { [ready] state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(fileName)")
        else { throw ServerError.notReady }
        return url
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, bytes: Data())
    }

    private func receiveRequest(on connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = bytes
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard !complete, error == nil, request.count < 16_384 else {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, bytes: request)
                return
            }
            let response = self.response(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: Data) -> Data {
        let headers = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        if let deniedSessionID,
           headers.first?.contains("_sid=\(deniedSessionID)") == true {
            requestLock.lock()
            deniedRequests += 1
            requestLock.unlock()
            return Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        if let deniedFileName,
           headers.first?.hasPrefix("GET /\(deniedFileName) ") == true {
            requestLock.lock()
            let shouldDeny = !denyOnlyWhenActivated || denialActivated
            if shouldDeny { deniedRequests += 1 }
            requestLock.unlock()
            if shouldDeny {
                return Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
        }
        let rangeHeader = headers.first { $0.lowercased().hasPrefix("range:") }
        let rangeValue = rangeHeader?.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard supportsRange else {
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(audio.count)\r\nConnection: close\r\n\r\n".utf8
            )
            response.append(audio)
            return response
        }
        guard let rangeValue, rangeValue.hasPrefix("bytes="),
              let offset = Int(rangeValue.dropFirst(6).prefix(while: { $0 != "-" })),
              (0 ..< audio.count).contains(offset)
        else {
            return Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        requestLock.lock()
        rangeOffsets.append(offset)
        requestLock.unlock()
        let body = audio.subdata(in: offset ..< audio.count)
        var response = Data(
            "HTTP/1.1 206 Partial Content\r\nContent-Type: \(contentType)\r\nContent-Range: bytes \(offset)-\(audio.count - 1)/\(audio.count)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(body)
        return response
    }
}

private final class LoopbackFixtureBundleMarker {}

private func makeLongWAV() -> Data {
    let sampleRate = 44_100
    let channels = 2
    let frames = sampleRate * 30
    let dataSize = frames * channels * 2
    var data = Data(capacity: 44 + dataSize)
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + dataSize))
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(channels))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * channels * 2))
    append(UInt16(channels * 2))
    append(UInt16(16))
    data.append(contentsOf: "data".utf8)
    append(UInt32(dataSize))
    for frame in 0 ..< frames {
        let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 8000)
        append(sample)
        append(sample)
    }
    return data
}

@MainActor
@Suite struct FFmpegLoopbackPlaybackTests {
    @Test("DS Audio playback access streams through the FFmpeg App engine")
    func dsAudioPlaybackAccessUsesRealHTTP() async throws {
        let bundle = Bundle(for: LoopbackFixtureBundleMarker.self)
        let fixture = try #require(bundle.url(
            forResource: "cue-seek-chirp", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        let server = try LoopbackAudioHTTPServer(audio: Data(contentsOf: fixture))
        let serverURL = try server.start()
        defer { server.stop() }

        let credential = try DSAudioCredential(account: "fixture", password: "fixture")
        let client = LoopbackDSAPIClient()
        let transport = DSAudioHTTPTransport(
            credentialProvider: LoopbackDSCredentialProvider(secretValue: credential.encodedSecret),
            httpClient: client
        )
        let sourceID = MediaSourceID("dsaudio.loopback")
        let configuration = try DSAudioSourceConfiguration(
            sourceID: sourceID, displayName: "Loopback DS Audio",
            endpoint: serverURL.deletingLastPathComponent(),
            credentialRecordID: "loopback-credential"
        )
        let access = try await transport.playbackAccess(
            configuration: configuration,
            itemID: SourceObjectID(sourceID: sourceID, externalID: "song-1"),
            purpose: .audition
        )
        guard case .http(let request, let transcode) = access else {
            Issue.record("DS Audio did not provide an HTTP playback request")
            return
        }
        #expect(transcode == nil)
        let query = try #require(URLComponents(
            url: request.url, resolvingAgainstBaseURL: false
        )?.queryItems)
        #expect(request.url.path == "/webapi/AudioStation/stream.cgi")
        #expect(query.first { $0.name == "_sid" }?.value == "loopback-sid-1")
        #expect(query.first { $0.name == "method" }?.value == "stream")
        #expect(query.first { $0.name == "id" }?.value == "song-1")
        try await playRange(
            request: request,
            range: PlaybackRange(start: .zero, end: .milliseconds(300)),
            isSeekable: false
        )

        let virtualAccess = try await transport.playbackAccess(
            configuration: configuration,
            itemID: SourceObjectID(sourceID: sourceID, externalID: "music_v_song-2"),
            purpose: .audition
        )
        guard case .http(let virtualRequest, let virtualTranscode) = virtualAccess else {
            Issue.record("DS Audio virtual item did not provide an HTTP request")
            return
        }
        #expect(virtualTranscode?.container == "mp3")
        #expect(virtualRequest.url.path == "/webapi/AudioStation/stream.cgi/0.mp3")
        let virtualQuery = try #require(URLComponents(
            url: virtualRequest.url, resolvingAgainstBaseURL: false
        )?.queryItems)
        #expect(virtualQuery.first { $0.name == "method" }?.value == "transcode")
        #expect(virtualQuery.first { $0.name == "format" }?.value == "mp3")
        try await playRange(
            request: virtualRequest,
            range: PlaybackRange(start: .zero, end: .milliseconds(300)),
            isSeekable: false
        )
        #expect(await client.loginCount == 1)
        #expect(await client.infoCount == 1)
    }

    @MainActor
    @Test("DS Audio audition coordinator plays through FFmpeg")
    func dsAudioAuditionUsesFFmpegEngine() async throws {
        let bundle = Bundle(for: LoopbackFixtureBundleMarker.self)
        let fixture = try #require(bundle.url(
            forResource: "cue-seek-chirp", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        let server = try LoopbackAudioHTTPServer(audio: Data(contentsOf: fixture))
        let serverURL = try server.start()
        defer { server.stop() }

        let credential = try DSAudioCredential(account: "fixture", password: "fixture")
        let transport = DSAudioHTTPTransport(
            credentialProvider: LoopbackDSCredentialProvider(secretValue: credential.encodedSecret),
            httpClient: LoopbackDSAPIClient()
        )
        let sourceID = MediaSourceID("dsaudio.audition.loopback")
        let configuration = try DSAudioSourceConfiguration(
            sourceID: sourceID, displayName: "Loopback DS Audio",
            endpoint: serverURL.deletingLastPathComponent(),
            credentialRecordID: "loopback-credential"
        )
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let coordinator = OnlineAuditionCoordinator(
            onlineSources: LoopbackDSOnlineSources(
                transport: transport, configuration: configuration
            ),
            engine: engine
        )
        let itemID = SourceObjectID(sourceID: sourceID, externalID: "song-1")
        try await coordinator.audition(
            sourceID: sourceID,
            item: SourceCatalogItem(
                id: itemID, kind: .track, displayName: "Fixture Song", isPlayable: true
            )
        )
        #expect(coordinator.snapshot.itemID == itemID)
        #expect(coordinator.snapshot.phase == .playing || coordinator.snapshot.phase == .buffering)
        #expect(engine.state.itemID?.externalID == itemID.externalID)
        for _ in 0 ..< 125 {
            if coordinator.snapshot.phase == .ended || coordinator.snapshot.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(coordinator.snapshot.phase == .ended)
        #expect(engine.state.phase == .stopped)
        await coordinator.stop()
        #expect(coordinator.snapshot.phase == .stopped)
    }

    @MainActor
    @Test("DS Audio replaces a rejected stream session during audition")
    func dsAudioAuditionRenewsRejectedSession() async throws {
        let bundle = Bundle(for: LoopbackFixtureBundleMarker.self)
        let fixture = try #require(bundle.url(
            forResource: "cue-seek-chirp", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        let server = try LoopbackAudioHTTPServer(
            audio: Data(contentsOf: fixture), deniedSessionID: "loopback-sid-1"
        )
        let serverURL = try server.start()
        defer { server.stop() }

        let credential = try DSAudioCredential(account: "fixture", password: "fixture")
        let client = LoopbackDSAPIClient()
        let transport = DSAudioHTTPTransport(
            credentialProvider: LoopbackDSCredentialProvider(secretValue: credential.encodedSecret),
            httpClient: client
        )
        let sourceID = MediaSourceID("dsaudio.renewal.loopback")
        let configuration = try DSAudioSourceConfiguration(
            sourceID: sourceID, displayName: "Loopback DS Audio",
            endpoint: serverURL.deletingLastPathComponent(),
            credentialRecordID: "loopback-credential"
        )
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let coordinator = OnlineAuditionCoordinator(
            onlineSources: LoopbackDSOnlineSources(
                transport: transport, configuration: configuration
            ),
            engine: engine
        )
        let itemID = SourceObjectID(sourceID: sourceID, externalID: "song-1")
        try await coordinator.audition(
            sourceID: sourceID,
            item: SourceCatalogItem(
                id: itemID, kind: .track, displayName: "Fixture Song", isPlayable: true
            )
        )
        for _ in 0 ..< 125 {
            if coordinator.snapshot.phase == .ended || coordinator.snapshot.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(coordinator.snapshot.phase == .ended)
        #expect(server.deniedRequestCount > 0)
        #expect(await client.loginCount == 2)
        await coordinator.stop()
    }

    @Test("App-host URLSession plays loopback HTTP audio through FFmpeg")
    func sequentialHTTPCUEWithEqualizer() async throws {
        let bundle = Bundle(for: LoopbackFixtureBundleMarker.self)
        let fixture = try #require(bundle.url(
            forResource: "cue-seek-chirp", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        let server = try LoopbackAudioHTTPServer(audio: Data(contentsOf: fixture))
        let url = try server.start()
        defer { server.stop() }

        try await playRange(
            request: RemotePlaybackRequest(url: url),
            range: PlaybackRange(start: .zero, end: .milliseconds(300)),
            isSeekable: false
        )
    }

    @Test("App-host URLSession seeks WAV over HTTP Range into a CUE segment")
    func rangeHTTPSeekWithEqualizer() async throws {
        let server = try LoopbackAudioHTTPServer(
            audio: makeLongWAV(), supportsRange: true, contentType: "audio/wav"
        )
        let url = try server.start(fileName: "fixture.wav")
        defer { server.stop() }

        try await playRange(
            request: RemotePlaybackRequest(url: url),
            range: PlaybackRange(start: .seconds(25), end: .milliseconds(25_300)),
            isSeekable: true
        )
    }

    @Test("Real URLSession byte source requests a nonzero HTTP Range")
    func byteSourceRequestsNonzeroRange() throws {
        let audio = makeLongWAV()
        let server = try LoopbackAudioHTTPServer(
            audio: audio, supportsRange: true, contentType: "audio/wav"
        )
        let url = try server.start(fileName: "fixture.wav")
        defer { server.stop() }
        let source = URLSessionByteSource(request: RemotePlaybackRequest(url: url))
        defer { source.cancel() }

        try source.open()
        #expect(source.isSeekable)
        let offset = 4_800_000
        try source.seek(toOffset: Int64(offset))
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0) }
        #expect(count == bytes.count)
        #expect(bytes == Array(audio[offset ..< offset + bytes.count]))
        #expect(server.observedRangeOffsets.contains(offset))
    }

    @Test("App-host URLSession refreshes a 403 audio URL and resumes HTTP Range playback")
    func authFailureRefreshesURLAndPlaysCUE() async throws {
        let bundle = Bundle(for: LoopbackFixtureBundleMarker.self)
        let fixture = try #require(bundle.url(
            forResource: "current", withExtension: "m4a", subdirectory: "Fixtures"
        ))
        let server = try LoopbackAudioHTTPServer(
            audio: Data(contentsOf: fixture), supportsRange: true,
            contentType: "audio/mp4", deniedFileName: "expired.m4a"
        )
        let expiredURL = try server.start(fileName: "expired.m4a")
        defer { server.stop() }
        let freshURL = expiredURL.deletingLastPathComponent().appendingPathComponent("fresh.m4a")
        let request = RemotePlaybackRequest(url: expiredURL).withRefresher {
            RemotePlaybackRequest(url: freshURL)
        }

        try await playRange(
            request: request,
            range: PlaybackRange(start: .seconds(100), end: .milliseconds(100_300)),
            isSeekable: true
        )
        #expect(server.deniedRequestCount == 1)
    }

    @Test("Active URLSession byte source refreshes a 403 response to a Range request")
    func activeByteSourceRefreshes403Range() throws {
        let audio = makeLongWAV()
        let server = try LoopbackAudioHTTPServer(
            audio: audio, supportsRange: true, contentType: "audio/wav",
            deniedFileName: "expiring.wav", denyOnlyWhenActivated: true
        )
        let expiringURL = try server.start(fileName: "expiring.wav")
        defer { server.stop() }
        let freshURL = expiringURL.deletingLastPathComponent().appendingPathComponent("renewed.wav")
        let request = RemotePlaybackRequest(url: expiringURL).withRefresher {
            RemotePlaybackRequest(url: freshURL)
        }
        let source = URLSessionByteSource(request: request)
        defer { source.cancel() }

        try source.open()
        server.activateDenial()
        let offset = 4_800_000
        try source.seek(toOffset: Int64(offset))
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0) }
        #expect(count == bytes.count)
        #expect(bytes == Array(audio[offset ..< offset + bytes.count]))
        #expect(server.deniedRequestCount == 1)
        #expect(server.observedRangeOffsets.contains(offset))
    }

    private func playRange(
        request: RemotePlaybackRequest,
        range: PlaybackRange,
        isSeekable: Bool
    ) async throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: MediaSourceID("loopback"), externalID: request.url.lastPathComponent),
            resource: .remote(request),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: request.url.lastPathComponent)
        )

        try await engine.prepare(item, startAt: nil)
        #expect(engine.capabilities.contains(.seeking) == isSeekable)
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
    }
}
