import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

private func makeSource(
    _ resource: StubURLProtocol.Resource,
    maxBufferedBytes: Int = 64 * 1024,
    maxSequentialBufferedBytes: Int = 32 * 1024 * 1024
) -> (URLSessionByteSource, URL) {
    let url = StubURLProtocol.register(resource)
    let source = URLSessionByteSource(
        request: RemotePlaybackRequest(url: url, headers: ["Accept": "audio/*"]),
        configuration: StubURLProtocol.sessionConfiguration(),
        maxBufferedBytes: maxBufferedBytes,
        maxSequentialBufferedBytes: maxSequentialBufferedBytes
    )
    return (source, url)
}

private func readInBackground(
    _ source: URLSessionByteSource,
    thenAfter delay: TimeInterval,
    _ action: @escaping @Sendable () -> Void
) async -> Result<Int, Error> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 16)
            continuation.resume(returning: Result {
                try buffer.withUnsafeMutableBytes { try source.read(into: $0) }
            })
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action)
    }
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

    @Test func seekAcrossBufferedBytesResumesPausedDownload() async throws {
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        let (source, _) = makeSource(
            .init(data: payload, chunkDelay: 0.025), maxBufferedBytes: 16 * 1024
        )
        defer { source.cancel() }
        try source.open()

        for _ in 0 ..< 100 where source.bufferedByteCount < 16 * 1024 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let buffered = source.bufferedByteCount
        #expect(buffered >= 16 * 1024)
        let offset = buffered - 512
        try source.seek(toOffset: Int64(offset))

        let result: Result<Data, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Result { try readAll(source) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { source.cancel() }
        }
        #expect(try result.get() == payload.subdata(in: offset ..< payload.count))
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

    @Test func cancelBeforeOpenDoesNotUseInvalidatedSession() {
        let (source, url) = makeSource(.init(data: Data(count: 1024)))
        source.cancel()
        #expect(throws: URLSessionByteSource.SourceError.cancelled) {
            try source.open()
        }
        #expect(StubURLProtocol.ranges(for: url).isEmpty)
    }

    @Test func interruptUnblocksStalledReadAndSourceStaysUsable() async throws {
        let (source, _) = makeSource(.init(data: Data(count: 1024), stallAfterHeaders: true))
        defer { source.cancel() }
        try source.open()

        let result = await readInBackground(source, thenAfter: 0.1) { source.interruptReads() }
        #expect(throws: URLSessionByteSource.SourceError.interrupted) {
            try result.get()
        }

        source.resumeReads()
        try source.seek(toOffset: 512)
        let again = await readInBackground(source, thenAfter: 0.1) { source.cancel() }
        #expect(throws: URLSessionByteSource.SourceError.cancelled) {
            try again.get()
        }
    }

    @Test func authFailureRefreshesRequestAndContinues() throws {
        let payload = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        let expiredURL = StubURLProtocol.register(.init(data: Data(), status: 403))
        let freshURL = StubURLProtocol.register(.init(data: payload))
        let request = RemotePlaybackRequest(url: expiredURL).withRefresher {
            RemotePlaybackRequest(url: freshURL)
        }
        let source = URLSessionByteSource(
            request: request,
            configuration: StubURLProtocol.sessionConfiguration()
        )
        defer { source.cancel() }

        try source.open()
        #expect(source.isSeekable)
        #expect(try readAll(source) == payload)
        #expect(StubURLProtocol.ranges(for: expiredURL) == ["bytes=0-"])
        #expect(StubURLProtocol.ranges(for: freshURL).first == "bytes=0-")
    }

    @Test func expiredRequestRefreshesBeforeRequesting() throws {
        let payload = Data((0 ..< 10_000).map { UInt8($0 % 13) })
        let staleURL = StubURLProtocol.register(.init(data: payload))
        let freshURL = StubURLProtocol.register(.init(data: payload))
        let request = RemotePlaybackRequest(url: staleURL, expiresAt: Date(timeIntervalSinceNow: -60))
            .withRefresher { RemotePlaybackRequest(url: freshURL) }
        let source = URLSessionByteSource(
            request: request,
            configuration: StubURLProtocol.sessionConfiguration()
        )
        defer { source.cancel() }

        try source.open()
        #expect(try readAll(source) == payload)
        #expect(StubURLProtocol.ranges(for: staleURL).isEmpty)
        #expect(StubURLProtocol.ranges(for: freshURL) == ["bytes=0-"])
    }

    @Test func stalledRefreshTimesOutAndUnblocksOpen() async throws {
        let staleURL = StubURLProtocol.register(.init(data: Data(), status: 403))
        let freshURL = StubURLProtocol.register(.init(data: Data(count: 1024)))
        let request = RemotePlaybackRequest(
            url: staleURL, expiresAt: Date(timeIntervalSinceNow: -60)
        ).withRefresher {
            try await Task.sleep(for: .seconds(10))
            return RemotePlaybackRequest(url: freshURL)
        }
        let source = URLSessionByteSource(
            request: request,
            configuration: StubURLProtocol.sessionConfiguration(),
            timeout: 0.2
        )
        defer { source.cancel() }

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Result { try source.open() })
            }
        }
        #expect(throws: URLSessionByteSource.SourceError.network(.timedOut)) {
            try result.get()
        }
        #expect(StubURLProtocol.ranges(for: staleURL).isEmpty)
        #expect(StubURLProtocol.ranges(for: freshURL).isEmpty)
    }

    @Test func persistentAuthFailureSurfacesStatusAfterOneRefresh() {
        let deniedURL = StubURLProtocol.register(.init(data: Data(), status: 401))
        let request = RemotePlaybackRequest(url: deniedURL).withRefresher {
            RemotePlaybackRequest(url: deniedURL)
        }
        let source = URLSessionByteSource(
            request: request,
            configuration: StubURLProtocol.sessionConfiguration()
        )
        defer { source.cancel() }

        #expect(throws: URLSessionByteSource.SourceError.httpStatus(401)) {
            try source.open()
        }
        #expect(StubURLProtocol.ranges(for: deniedURL).count == 2)
    }

    @Test func sequentialStreamIsBoundedAndComplete() throws {
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 199) })
        let (source, _) = makeSource(
            .init(data: payload, supportsRange: false),
            maxSequentialBufferedBytes: 32 * 1024
        )
        defer { source.cancel() }

        try source.open()
        #expect(!source.isSeekable)
        #expect(try readAll(source) == payload)
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

    @Test func mp3HTTPReplayFromZeroRestoresDecoderAndByteSource() throws {
        let file = try #require(Bundle.module.url(
            forResource: "cue-seek-chirp", withExtension: "mp3"
        ))
        let (source, _) = makeSource(.init(data: try Data(contentsOf: file)))
        defer { source.cancel() }
        try source.open()
        let decoder = try FFmpegAudioDecoder(byteSource: source)
        let originalFrames = try decodedFrameCount(decoder)
        #expect(originalFrames > 100_000)

        try decoder.seek(to: .zero)
        #expect(try decodedFrameCount(decoder) == originalFrames)
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
    private func makeItem(url: URL, range: PlaybackRange? = nil) -> PlaybackItem {
        PlaybackItem(
            itemID: MediaItemID(sourceID: MediaSourceID("stub"), externalID: url.lastPathComponent),
            resource: .remote(RemotePlaybackRequest(url: url)),
            selection: PlaybackSelection(range: range),
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

    @Test func expiredRemoteRequestRefreshesDuringEnginePrepare() async throws {
        let data = WAVFixture.make(frames: 44_100)
        let staleURL = StubURLProtocol.register(.init(data: data, status: 403))
        let freshURL = StubURLProtocol.register(.init(data: data))
        let request = RemotePlaybackRequest(
            url: staleURL, expiresAt: Date(timeIntervalSinceNow: -60)
        ).withRefresher { RemotePlaybackRequest(url: freshURL) }
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: MediaSourceID("stub"), externalID: "expired"),
            resource: .remote(request),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Expired remote")
        )
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(item, startAt: nil)
        #expect(engine.state.phase == .preparing)
        #expect(StubURLProtocol.ranges(for: staleURL).isEmpty)
        #expect(!StubURLProtocol.ranges(for: freshURL).isEmpty)
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

    @Test func sequentialRemoteZeroStartCUEPlaysToSelectedEnd() async throws {
        let url = StubURLProtocol.register(.init(
            data: WAVFixture.make(frames: 44_100), supportsRange: false
        ))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .zero, end: .milliseconds(300))

        try await engine.prepare(makeItem(url: url, range: range), startAt: nil)
        #expect(!engine.capabilities.contains(.seeking))
        #expect(engine.state.duration == range.duration)
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
    }

    @Test func sequentialRemoteReopensStalledReadAfterConfigurationChange() async throws {
        let data = WAVFixture.make(frames: 576_000, sampleRate: 192_000)
        let url = StubURLProtocol.register(.init(
            data: data, supportsRange: false, stallAfterBytes: 1_200_000
        ))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .zero, end: .milliseconds(2_200))

        try await engine.prepare(makeItem(url: url, range: range), startAt: nil)
        try engine.play()
        for _ in 0 ..< 100 where engine.state.position < .milliseconds(1_200) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let positionBeforeChange = engine.state.position
        #expect(positionBeforeChange >= .milliseconds(1_200))

        StubURLProtocol.update(url, .init(data: data, supportsRange: false))
        engine.audioEngine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: engine.audioEngine
        )
        for _ in 0 ..< 200 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
        #expect(StubURLProtocol.ranges(for: url).count >= 2)
    }

    @Test func pauseDuringSequentialRouteRecoveryKeepsDecoderReady() async throws {
        let data = WAVFixture.make(frames: 132_300)
        let url = StubURLProtocol.register(.init(data: data, supportsRange: false))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(makeItem(url: url), startAt: nil)
        try engine.play()
        for _ in 0 ..< 100 where engine.state.position < .milliseconds(250) {
            try await Task.sleep(for: .milliseconds(20))
        }
        StubURLProtocol.update(url, .init(
            data: data, supportsRange: false, chunkDelay: 0.01
        ))
        engine.audioEngine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: engine.audioEngine
        )
        #expect(engine.state.phase == .preparing)
        engine.pause()
        for _ in 0 ..< 100 where engine.state.phase != .paused {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.state.phase == .paused)
        try engine.play()
        for _ in 0 ..< 200 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.state.phase == .stopped)
    }

    @Test func playAndStopDuringSequentialRouteRecoveryRespectLatestIntent() async throws {
        let data = WAVFixture.make(frames: 88_200)
        let url = StubURLProtocol.register(.init(data: data, supportsRange: false))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(makeItem(url: url), startAt: nil)
        try engine.play()
        for _ in 0 ..< 100 where engine.state.position < .milliseconds(250) {
            try await Task.sleep(for: .milliseconds(20))
        }
        StubURLProtocol.update(url, .init(
            data: data, supportsRange: false, stallAfterHeaders: true
        ))
        engine.audioEngine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: engine.audioEngine
        )
        #expect(engine.state.phase == .preparing)
        engine.pause()
        try engine.play()
        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.itemID == nil)
    }

    @Test func sequentialRemoteReopensAfterLogicalEnd() async throws {
        let url = StubURLProtocol.register(.init(
            data: WAVFixture.make(frames: 44_100), supportsRange: false
        ))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .zero, end: .milliseconds(250))

        try await engine.prepare(makeItem(url: url, range: range), startAt: nil)
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped)
        let firstGeneration = engine.state.generation
        let firstRequestCount = StubURLProtocol.ranges(for: url).count

        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.generation != firstGeneration,
               engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.generation != firstGeneration)
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
        #expect(StubURLProtocol.ranges(for: url).count > firstRequestCount)
    }

    @Test func stopCancelsSequentialReplayWhileReopening() async throws {
        let data = WAVFixture.make(frames: 44_100)
        let url = StubURLProtocol.register(.init(data: data, supportsRange: false))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .zero, end: .milliseconds(250))

        try await engine.prepare(makeItem(url: url, range: range), startAt: nil)
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped)

        StubURLProtocol.update(url, .init(
            data: data, supportsRange: false, stallAfterHeaders: true
        ))
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .preparing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.phase == .preparing)
        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.itemID == nil)
    }

    @Test func sequentialRemoteNonzeroStartCUERequiresRangeSupport() async throws {
        let url = StubURLProtocol.register(.init(
            data: WAVFixture.make(frames: 44_100), supportsRange: false
        ))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .milliseconds(200), end: .milliseconds(500))

        await #expect(throws: PlaybackError.unsupportedCapability(.seeking)) {
            try await engine.prepare(makeItem(url: url, range: range), startAt: nil)
        }
    }

    @Test func seekableRemoteCUEStartsAtAbsolutePositionAndEndsAtRangeEnd() async throws {
        let url = StubURLProtocol.register(.init(data: WAVFixture.make(frames: 44_100)))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }
        let range = PlaybackRange(start: .milliseconds(200), end: .milliseconds(600))

        try await engine.prepare(makeItem(url: url, range: range), startAt: .milliseconds(100))
        #expect(engine.state.duration == range.duration)
        #expect(engine.state.position == .milliseconds(100))
        #expect(engine.capabilities.contains(.seeking))
        try await engine.seek(to: .milliseconds(200))
        #expect(engine.state.position == .milliseconds(200))
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
        #expect(StubURLProtocol.ranges(for: url).count >= 2)
    }

    @Test func sequentialResumeReportsPlaybackFromStart() async throws {
        let url = StubURLProtocol.register(.init(data: WAVFixture.make(frames: 88_200), supportsRange: false))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        try await engine.prepare(makeItem(url: url), startAt: .seconds(1))
        #expect(engine.state.position == .zero)
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

    @Test func taskCancellationDuringStalledPrepareStopsEngine() async throws {
        let url = StubURLProtocol.register(.init(data: Data(count: 1024), stallAfterHeaders: true))
        let engine = FFmpegPlaybackEngine(remoteSessionConfiguration: StubURLProtocol.sessionConfiguration())
        defer { engine.dispose() }

        let prepare = Task { try await engine.prepare(makeItem(url: url), startAt: nil) }
        for _ in 0 ..< 100 where StubURLProtocol.ranges(for: url).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!StubURLProtocol.ranges(for: url).isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.state.phase == .preparing)
        let start = ContinuousClock.now
        prepare.cancel()
        await #expect(throws: CancellationError.self) {
            try await prepare.value
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.itemID == nil)
    }
}
