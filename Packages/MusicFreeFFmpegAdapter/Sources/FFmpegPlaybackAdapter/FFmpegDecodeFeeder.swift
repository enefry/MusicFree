import AVFoundation
import FFmpegAudioKit
import Foundation
import OSLog

/// 把 `FFmpegAudioDecoder` 解出的 PCM 持续投喂给 `AVAudioPlayerNode`。
///
/// 单一串行队列独占解码器，事件驱动、不阻塞队列：最多 `maxInFlight` 个 buffer
/// 在飞（已排队但尚未渲染完）。普通 buffer 通过 `.dataRendered` 回到队列补货，
/// 不等待下游设备的播放延迟；预读一块以识别末块，末块通过 `.dataPlayedBack`
/// 确认实际播放完成后回调 `onEnd`。解码出错回调 `onError`。
/// 回调都在解码队列触发，由调用方 hop 回 MainActor。
///
/// 解码队列绝不能被阻塞等待：播放完成回调与后继 feeder 的 `start` 都要排到同一
/// 队列上执行，阻塞即死锁（表现为进度照走但完全无声）。网络输入的 `read` 会在
/// 本队列上阻塞等数据，但其等待由字节源自身的取消/超时兜底，不依赖本队列的其它任务。
///
/// 饥饿（starved）：在飞 buffer 为 0 且尚未解码完。起始即处于饥饿；排满
/// 最少三块或解码完时解除。状态变化经 `onStarvationChanged` 通知，
/// 引擎据此暂停/恢复 playerNode，避免输出空转导致时间轴漂移。
///
/// 非并发安全：除 `cancel()` 外约定仅在 `queue` 上访问，故标注 `@unchecked Sendable`。
final class DecodeFeeder: @unchecked Sendable {
    typealias BufferScheduler = (
        AVAudioPCMBuffer, AVAudioPlayerNodeCompletionCallbackType,
        @escaping @Sendable () -> Void
    ) -> Void
    private static let logger = Logger(
        subsystem: "win.tools4me.music",
        category: "ffmpeg-buffering"
    )
    static let bufferFrameCapacity = 8192
    private static let minimumReadyBufferCount = 3
    private static let slowDecodeThresholdMilliseconds = 100.0
    private static let slowDecodeLogIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let summaryIntervalNanoseconds: UInt64 = 5_000_000_000

    private let decoder: FFmpegAudioDecoder
    private let playerNode: AVAudioPlayerNode
    private let queue: DispatchQueue
    private let initialSeek: Duration?
    /// Maximum PCM frames to output after the seek. A CUE range ends on this
    /// frame, independently of the physical file's EOF or UI timer cadence.
    private let frameLimit: Int64?
    private let maxInFlight: Int
    private let onEnd: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let onStarvationChanged: @Sendable (Bool) -> Void
    private let scheduleBufferOverride: BufferScheduler?

    // `cancel()` 在调用方线程同步置位；调度 buffer 时持同一把锁，保证 `cancel()`
    // 返回后旧 feeder 不会再往 playerNode 塞 buffer（调用方紧接着会 `stop()`）。
    private let cancelLock = NSLock()
    private var cancelled = false

    // 以下状态仅在 `queue` 上访问。
    private var inFlight = 0
    private var decodeFinished = false
    private var pendingBuffer: AVAudioPCMBuffer?
    private var endReported = false
    private var starved = true
    private var framesRemaining: Int64?
    private var inFlightFrames: Int64 = 0
    private var scheduledBufferCount: UInt64 = 0
    private var completedBufferCount: UInt64 = 0
    private var starvationCount: UInt64 = 0
    private var startedAtNanoseconds: UInt64?
    private var lastCompletionAtNanoseconds: UInt64?
    private var starvationStartedAtNanoseconds: UInt64?
    private var lastSlowDecodeLogAtNanoseconds: UInt64?
    private var lastSummaryAtNanoseconds: UInt64?
    private var lastDecodeMilliseconds = 0.0
    private var maximumDecodeMilliseconds = 0.0
    private var maximumCompletionGapMilliseconds = 0.0
    private var maximumCallbackQueueDelayMilliseconds = 0.0

    init(
        decoder: FFmpegAudioDecoder,
        playerNode: AVAudioPlayerNode,
        queue: DispatchQueue,
        initialSeek: Duration?,
        playbackDuration: Duration? = nil,
        maxInFlight: Int = 3,
        scheduleBuffer: BufferScheduler? = nil,
        onEnd: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onStarvationChanged: @escaping @Sendable (Bool) -> Void
    ) {
        self.decoder = decoder
        self.playerNode = playerNode
        self.queue = queue
        self.initialSeek = initialSeek
        if let playbackDuration {
            let components = playbackDuration.components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let count = (seconds * decoder.format.sampleRate).rounded(.up)
            frameLimit = Int64(min(max(0, count), 9_000_000_000_000_000))
        } else {
            frameLimit = nil
        }
        framesRemaining = frameLimit
        self.maxInFlight = maxInFlight
        scheduleBufferOverride = scheduleBuffer
        self.onEnd = onEnd
        self.onError = onError
        self.onStarvationChanged = onStarvationChanged
    }

    func start() {
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            startedAtNanoseconds = now
            lastSummaryAtNanoseconds = now
            let nominalQueuedMilliseconds = Double(
                Self.bufferFrameCapacity * maxInFlight
            ) / decoder.format.sampleRate * 1_000
            Self.logger.info(
                "feeder start refillCallback=dataRendered endCallback=dataPlayedBack sampleRate=\(self.decoder.format.sampleRate, privacy: .public) channels=\(self.decoder.format.channelCount, privacy: .public) bufferFrames=\(Self.bufferFrameCapacity, privacy: .public) maxInFlight=\(self.maxInFlight, privacy: .public) nominalQueuedMs=\(nominalQueuedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
            )
            if let seek = initialSeek {
                do {
                    try decoder.seek(to: seek)
                } catch {
                    reportError(error)
                    return
                }
            }
            fill()
        }
    }

    /// 取消投喂。已排队的 buffer 由 `playerNode.stop()`（调用方负责）丢弃。
    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    // MARK: - Private (queue-only)

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    private func fill() {
        while !decodeFinished, inFlight < maxInFlight {
            if isCancelled { return }
            let buffer: AVAudioPCMBuffer
            do {
                guard let next = try pendingBuffer ?? readBuffer() else {
                    decodeFinished = true
                    break
                }
                buffer = next
                // One-buffer lookahead identifies physical EOF or the exact CUE boundary.
                pendingBuffer = try readBuffer()
                decodeFinished = pendingBuffer == nil
            } catch {
                reportError(error)
                return
            }
            guard schedule(buffer, isFinal: decodeFinished) else { return }
            inFlight += 1
            inFlightFrames += Int64(buffer.frameLength)
            scheduledBufferCount += 1
            if starved, inFlight >= min(Self.minimumReadyBufferCount, maxInFlight) {
                setStarved(false)
            }
        }
        setStarved(false)
        logPeriodicSummaryIfNeeded()
        checkEnd()
    }

    private func readBuffer() throws -> AVAudioPCMBuffer? {
        guard framesRemaining != 0 else { return nil }
        let capacity = AVAudioFrameCount(min(
            framesRemaining ?? Int64(Self.bufferFrameCapacity),
            Int64(Self.bufferFrameCapacity)
        ))
        let started = DispatchTime.now().uptimeNanoseconds
        let buffer = try decoder.nextBuffer(frameCapacity: capacity)
        let finished = DispatchTime.now().uptimeNanoseconds
        lastDecodeMilliseconds = Self.milliseconds(from: started, to: finished)
        maximumDecodeMilliseconds = max(maximumDecodeMilliseconds, lastDecodeMilliseconds)
        if lastDecodeMilliseconds >= Self.slowDecodeThresholdMilliseconds,
           shouldLogSlowDecode(at: finished) {
            lastSlowDecodeLogAtNanoseconds = finished
            Self.logger.warning(
                "slow PCM decode durationMs=\(self.lastDecodeMilliseconds, format: .fixed(precision: 1), privacy: .public) inFlight=\(self.inFlight, privacy: .public) queuedMs=\(self.queuedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
            )
        }
        if let buffer, let framesRemaining {
            self.framesRemaining = framesRemaining - Int64(buffer.frameLength)
        }
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, isFinal: Bool) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard !cancelled else { return false }
        let frameLength = Int64(buffer.frameLength)
        let callbackType: AVAudioPlayerNodeCompletionCallbackType = isFinal ? .dataPlayedBack : .dataRendered
        let completion: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            self.queue.async {
                self.bufferCompleted(frameLength: frameLength, receivedAt: receivedAt)
            }
        }
        if let scheduleBufferOverride {
            scheduleBufferOverride(buffer, callbackType, completion)
        } else {
            playerNode.scheduleBuffer(buffer, completionCallbackType: callbackType) { _ in
                completion()
            }
        }
        return true
    }

    private func bufferCompleted(frameLength: Int64, receivedAt: UInt64) {
        guard !isCancelled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        maximumCallbackQueueDelayMilliseconds = max(
            maximumCallbackQueueDelayMilliseconds,
            Self.milliseconds(from: receivedAt, to: now)
        )
        let completionGapMilliseconds = lastCompletionAtNanoseconds.map {
            Self.milliseconds(from: $0, to: receivedAt)
        }
        if let completionGapMilliseconds {
            maximumCompletionGapMilliseconds = max(
                maximumCompletionGapMilliseconds,
                completionGapMilliseconds
            )
        }
        lastCompletionAtNanoseconds = receivedAt
        inFlight -= 1
        inFlightFrames = max(0, inFlightFrames - frameLength)
        completedBufferCount += 1
        if inFlight == 0, !decodeFinished {
            let gap = completionGapMilliseconds ?? 0
            Self.logger.warning(
                "PCM queue exhausted completionGapMs=\(gap, format: .fixed(precision: 1), privacy: .public) lastDecodeMs=\(self.lastDecodeMilliseconds, format: .fixed(precision: 1), privacy: .public) scheduled=\(self.scheduledBufferCount, privacy: .public) completed=\(self.completedBufferCount, privacy: .public)"
            )
            setStarved(true)
        }
        fill()
    }

    private func setStarved(_ value: Bool) {
        guard starved != value, !isCancelled else { return }
        starved = value
        let now = DispatchTime.now().uptimeNanoseconds
        if value {
            starvationCount += 1
            starvationStartedAtNanoseconds = now
        } else if let starvationStartedAtNanoseconds {
            let duration = Self.milliseconds(from: starvationStartedAtNanoseconds, to: now)
            Self.logger.info(
                "PCM queue recovered starvationMs=\(duration, format: .fixed(precision: 1), privacy: .public) starvationCount=\(self.starvationCount, privacy: .public) inFlight=\(self.inFlight, privacy: .public) queuedMs=\(self.queuedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
            )
            self.starvationStartedAtNanoseconds = nil
        }
        onStarvationChanged(value)
    }

    private func checkEnd() {
        guard !isCancelled, !endReported else { return }
        guard decodeFinished, inFlight == 0 else { return }
        endReported = true
        logSummary(event: "ended")
        onEnd()
    }

    private func reportError(_ error: Error) {
        guard !isCancelled, !endReported else { return }
        endReported = true
        logSummary(event: "failed")
        onError(error)
    }

    private var queuedMilliseconds: Double {
        Double(inFlightFrames) / decoder.format.sampleRate * 1_000
    }

    private func logPeriodicSummaryIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let lastSummaryAtNanoseconds,
              now >= lastSummaryAtNanoseconds,
              now - lastSummaryAtNanoseconds >= Self.summaryIntervalNanoseconds
        else { return }
        self.lastSummaryAtNanoseconds = now
        logSummary(event: "periodic")
    }

    private func shouldLogSlowDecode(at now: UInt64) -> Bool {
        guard let lastSlowDecodeLogAtNanoseconds else { return true }
        return now >= lastSlowDecodeLogAtNanoseconds
            && now - lastSlowDecodeLogAtNanoseconds >= Self.slowDecodeLogIntervalNanoseconds
    }

    private func logSummary(event: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = startedAtNanoseconds.map {
            Self.milliseconds(from: $0, to: now)
        } ?? 0
        Self.logger.info(
            "feeder summary event=\(event, privacy: .public) elapsedMs=\(elapsed, format: .fixed(precision: 1), privacy: .public) inFlight=\(self.inFlight, privacy: .public) queuedMs=\(self.queuedMilliseconds, format: .fixed(precision: 1), privacy: .public) scheduled=\(self.scheduledBufferCount, privacy: .public) completed=\(self.completedBufferCount, privacy: .public) starvations=\(self.starvationCount, privacy: .public) maxDecodeMs=\(self.maximumDecodeMilliseconds, format: .fixed(precision: 1), privacy: .public) maxCompletionGapMs=\(self.maximumCompletionGapMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
        Self.logger.info(
            "feeder timing event=\(event, privacy: .public) maxCallbackQueueDelayMs=\(self.maximumCallbackQueueDelayMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }
}
