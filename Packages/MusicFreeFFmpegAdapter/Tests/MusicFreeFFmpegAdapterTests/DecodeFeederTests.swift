import AVFoundation
import FFmpegAudioKit
import Foundation
import Testing
@testable import FFmpegPlaybackAdapter

private final class ScheduledPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(AVAudioPlayerNodeCompletionCallbackType, @Sendable () -> Void)] = []
    private var frames = 0
    private var renderedBuffers = 0
    private var terminalBuffers = 0
    private var ended = false
    private var failed = false

    func schedule(
        _ buffer: AVAudioPCMBuffer,
        type: AVAudioPlayerNodeCompletionCallbackType,
        completion: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        frames += Int(buffer.frameLength)
        if type == .dataRendered { renderedBuffers += 1 }
        if type == .dataPlayedBack { terminalBuffers += 1 }
        pending.append((type, completion))
        lock.unlock()
    }

    func finishRenderedBuffer() -> Bool {
        lock.lock()
        guard pending.first?.0 == .dataRendered else {
            lock.unlock()
            return false
        }
        let completion = pending.removeFirst().1
        lock.unlock()
        completion()
        return true
    }

    func finishTerminalBuffer() -> Bool {
        lock.lock()
        guard pending.count == 1, pending.first?.0 == .dataPlayedBack else {
            lock.unlock()
            return false
        }
        let completion = pending.removeFirst().1
        lock.unlock()
        completion()
        return true
    }

    func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    func fail() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    func snapshot() -> (frames: Int, rendered: Int, terminal: Int, ended: Bool, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, renderedBuffers, terminalBuffers, ended, failed)
    }
}

@MainActor
@Suite(.serialized)
struct DecodeFeederTests {
    @Test(arguments: [4096, 8192, 8193, 8 * 8192])
    func refillDoesNotWaitForDevicePlaybackAndEOFWaitsForLastBuffer(frames: Int) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-feeder-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try WAVFixture.make(frames: frames).write(to: file)
        let decoder = try FFmpegAudioDecoder(localFileURL: file)
        let scheduled = ScheduledPCM()
        let feeder = DecodeFeeder(
            decoder: decoder,
            playerNode: AVAudioPlayerNode(),
            queue: DispatchQueue(label: "com.musicfree.ffmpeg.feeder-test"),
            initialSeek: nil,
            maxInFlight: 3,
            scheduleBuffer: { buffer, type, completion in
                scheduled.schedule(buffer, type: type, completion: completion)
            },
            onEnd: { scheduled.finish() },
            onError: { _ in scheduled.fail() },
            onStarvationChanged: { _ in }
        )
        defer { feeder.cancel() }
        feeder.start()

        // The simulated device withholds played-back callbacks. Rendering ordinary
        // buffers must still refill the entire file, including exact buffer boundaries.
        for _ in 0..<200 {
            if !scheduled.finishRenderedBuffer(), scheduled.snapshot().terminal == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let beforePlaybackFinished = scheduled.snapshot()
        #expect(!beforePlaybackFinished.failed)
        #expect(beforePlaybackFinished.frames == frames)
        #expect(beforePlaybackFinished.rendered == (frames - 1) / 8192)
        #expect(beforePlaybackFinished.terminal == 1)
        #expect(!beforePlaybackFinished.ended)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!scheduled.snapshot().ended)

        #expect(scheduled.finishTerminalBuffer())
        for _ in 0..<100 where !scheduled.snapshot().ended {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduled.snapshot().ended)
    }
}
