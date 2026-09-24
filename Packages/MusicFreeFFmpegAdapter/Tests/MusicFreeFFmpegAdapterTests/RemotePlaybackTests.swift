import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

private func makeSource(
    _ resource: StubURLProtocol.Resource,
    maxBufferedBytes: Int = 64 * 1024
) -> (URLSessionByteSource, URL) {
    let url = StubURLProtocol.register(resource)
    let source = URLSessionByteSource(
        request: RemotePlaybackRequest(url: url, headers: ["Accept": "audio/*"]),
        configuration: StubURLProtocol.sessionConfiguration(),
        maxBufferedBytes: maxBufferedBytes
    )
    return (source, url)
}

private func readAll(_ source: URLSessionByteSource) throws -> Data {
    var output = Data()
    var chunk = [UInt8](repeating: 0, count: 10_000)
    while true {
        let count = try chunk.withUnsafeMutableBytes { try source.read(into: $0) }
        if count == 0 { return output }
        output.append(contentsOf: chunk[0 ..< count])
    }
}

private func decodedFrameCount(_ decoder: FFmpegAudioDecoder) throws -> Int {
    var total = 0
    while let buffer = try decoder.nextBuffer() {
        total += Int(buffer.frameLength)
    }
    return total
}

private func milliseconds(_ duration: Duration?) -> Int64? {
    duration.map { $0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000 }
}

@Suite struct URLSessionByteSourceTests {
    @Test func rangeResponseIsSeekableAndReadsExactBytes() throws {
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        let (source, url) = makeSource(.init(data: payload))
        defer { source.cancel() }

        try source.open()
        #expect(source.isSeekable)
        #expect(source.byteCount == 300_000)
        // 缓冲上限 64 KB，读完整个资源会经历多次挂起/恢复。
        #expect(try readAll(source) == payload)

        try source.seek(toOffset: 123_456)
        var bytes = [UInt8](repeating: 0, count: 4)
        let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0) }
        #expect(count == 4)
        #expect(bytes == Array(payload[123_456 ..< 123_460]))

        let ranges = StubURLProtocol.ranges(for: url)
        #expect(ranges.first == "bytes=0-")
        #expect(ranges.last == "bytes=123456-")
    }

    @Test func plainResponseIsSequentialOnly() throws {
        let payload = Data((0 ..< 50_000).map { UInt8($0 % 199) })
        let (source, _) = makeSource(.init(data: payload, supportsRange: false))
        defer { source.cancel() }

        try source.open()
        #expect(!source.isSeekable)
        #expect(source.byteCount == 50_000)
        #expect(try readAll(source) == payload)
        #expect(throws: URLSessionByteSource.SourceError.notSeekable) {
            try source.seek(toOffset: 0)
        }
    }

    @Test func httpErrorSurfacesStatusCode() {
        let (source, _) = makeSource(.init(data: Data(), status: 403))
        defer { source.cancel() }
        #expect(throws: URLSessionByteSource.SourceError.httpStatus(403)) {
            try source.open()
        }
    }

    @Test func cancelUnblocksPendingRead() async throws {
        let (source, _) = makeSource(.init(data: Data(count: 1024), stallAfterHeaders: true))
        try source.open()

        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 16)
                continuation.resume(returning: Result {
                    try buffer.withUnsafeMutableBytes { try source.read(into: $0) }
                })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                source.cancel()
            }
        }
        #expect(throws: URLSessionByteSource.SourceError.cancelled) {
            try result.get()
        }
    }
}

@Suite struct RemoteDecodeTests {
    private let frames = 88_200 // 2 秒 @ 44.1 kHz

    @Test func decodesAndSeeksWAVOverHTTP() throws {
        let (source, _) = makeSource(.init(data: WAVFixture.make(frames: frames)))
        defer { source.cancel() }
        try source.open()
        let decoder = try FFmpegAudioDecoder(byteSource: source, probeSize: 1024 * 1024)

        #expect(decoder.format.sampleRate == 44_100)
        #expect(decoder.format.channelCount == 2)
        let durationMs = try #require(milliseconds(decoder.duration))
        #expect(abs(durationMs - 2000) < 50)
        #expect(try decodedFrameCount(decoder) == frames)

        try decoder.seek(to: .seconds(1))
        let remaining = try decodedFrameCount(decoder)
        #expect(abs(remaining - frames / 2) < 2048)
    }

    @Test func decodesSequentialStreamWithoutRange() throws {
        let (source, _) = makeSource(.init(data: WAVFixture.make(frames: frames), supportsRange: false))
        defer { source.cancel() }
        try source.open()
        let decoder = try FFmpegAudioDecoder(byteSource: source)
        #expect(try decodedFrameCount(decoder) == frames)
    }
}

@MainActor
@Suite struct FFmpegPlaybackEngineRemoteTests {
    private func makeItem(url: URL) -> PlaybackItem {
        PlaybackItem(
            itemID: MediaItemID(sourceID: MediaSourceID("stub"), externalID: url.lastPathComponent),
            resource: .remote(RemotePlaybackRequest(url: url)),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Remote")
        )
    }

    @Test func seekableRemotePreparesAndSeeks() async throws {
        let url = StubURLProtocol.register(.init(data: WAVFixture.make(frames: 88_200)))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(makeItem(url: url), startAt: nil)
        #expect(engine.state.phase == .preparing)
        let durationMs = try #require(milliseconds(engine.state.duration))
        #expect(abs(durationMs - 2000) < 50)

        try await engine.seek(to: .seconds(1))
        #expect(engine.state.position == .seconds(1))

        engine.stop()
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.itemID == nil)
    }

    @Test func sequentialRemoteRejectsSeek() async throws {
        let url = StubURLProtocol.register(.init(data: WAVFixture.make(frames: 44_100), supportsRange: false))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(makeItem(url: url), startAt: nil)
        await #expect(throws: PlaybackError.unsupportedCapability(.seeking)) {
            try await engine.seek(to: .milliseconds(500))
        }
    }

    @Test func stopDuringStalledPrepareCancelsPromptly() async throws {
        let url = StubURLProtocol.register(.init(data: Data(count: 1024), stallAfterHeaders: true))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        let prepare = Task { try await engine.prepare(makeItem(url: url), startAt: nil) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state.phase == .preparing)
        engine.stop()

        await #expect(throws: CancellationError.self) {
            try await prepare.value
        }
        #expect(engine.state.phase == .stopped)
    }
}
