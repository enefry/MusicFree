import AVFoundation
import FFmpegAudioKit
import Foundation

/// 把 `FFmpegAudioDecoder` 解出的 PCM 持续投喂给 `AVAudioPlayerNode`。
///
/// 单一串行队列独占解码器，事件驱动、不阻塞队列：最多 `maxInFlight` 个 buffer
/// 在飞（已排队但未播放完）。每个 buffer 播放完（`.dataPlayedBack`）后回到队列
/// 补上下一块。全部解码完且全部播放完时回调 `onEnd`；解码出错回调 `onError`。
/// 回调都在解码队列触发，由调用方 hop 回 MainActor。
///
/// 解码队列绝不能被阻塞等待：播放完成回调与后继 feeder 的 `start` 都要排到同一
/// 队列上执行，阻塞即死锁（表现为进度照走但完全无声）。网络输入的 `read` 会在
/// 本队列上阻塞等数据，但其等待由字节源自身的取消/超时兜底，不依赖本队列的其它任务。
///
/// 饥饿（starved）：在飞 buffer 为 0 且尚未解码完。起始即处于饥饿；排满
/// `maxInFlight` 个或解码完时解除。状态变化经 `onStarvationChanged` 通知，
/// 引擎据此暂停/恢复 playerNode，避免输出空转导致时间轴漂移。
///
/// 非并发安全：除 `cancel()` 外约定仅在 `queue` 上访问，故标注 `@unchecked Sendable`。
final class DecodeFeeder: @unchecked Sendable {
    private let decoder: FFmpegAudioDecoder
    private let playerNode: AVAudioPlayerNode
    private let queue: DispatchQueue
    private let initialSeek: Duration?
    private let maxInFlight: Int
    private let onEnd: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let onStarvationChanged: @Sendable (Bool) -> Void

    // `cancel()` 在调用方线程同步置位；调度 buffer 时持同一把锁，保证 `cancel()`
    // 返回后旧 feeder 不会再往 playerNode 塞 buffer（调用方紧接着会 `stop()`）。
    private let cancelLock = NSLock()
    private var cancelled = false

    // 以下状态仅在 `queue` 上访问。
    private var inFlight = 0
    private var decodeFinished = false
    private var endReported = false
    private var starved = true

    init(
        decoder: FFmpegAudioDecoder,
        playerNode: AVAudioPlayerNode,
        queue: DispatchQueue,
        initialSeek: Duration?,
        maxInFlight: Int = 3,
        onEnd: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onStarvationChanged: @escaping @Sendable (Bool) -> Void
    ) {
        self.decoder = decoder
        self.playerNode = playerNode
        self.queue = queue
        self.initialSeek = initialSeek
        self.maxInFlight = maxInFlight
        self.onEnd = onEnd
        self.onError = onError
        self.onStarvationChanged = onStarvationChanged
    }

    func start() {
        queue.async { [self] in
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

            let buffer: AVAudioPCMBuffer?
            do {
                buffer = try decoder.nextBuffer()
            } catch {
                reportError(error)
                return
            }
            guard let buffer else {
                decodeFinished = true
                break
            }
            guard schedule(buffer) else { return }
            inFlight += 1
        }
        setStarved(false)
        checkEnd()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard !cancelled else { return false }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.bufferPlayed() }
        }
        return true
    }

    private func bufferPlayed() {
        inFlight -= 1
        if inFlight == 0, !decodeFinished {
            setStarved(true)
        }
        fill()
    }

    private func setStarved(_ value: Bool) {
        guard starved != value, !isCancelled else { return }
        starved = value
        onStarvationChanged(value)
    }

    private func checkEnd() {
        guard !isCancelled, !endReported else { return }
        guard decodeFinished, inFlight == 0 else { return }
        endReported = true
        onEnd()
    }

    private func reportError(_ error: Error) {
        guard !isCancelled, !endReported else { return }
        endReported = true
        onError(error)
    }
}
