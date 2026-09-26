import FFmpegAudioKit
import Foundation
import MediaSourceAPI

/// 基于 URLSession 的 `FFmpegByteSource`：把远程 HTTP(S) 资源以阻塞读的方式
/// 提供给 ffmpeg。
///
/// - 每次请求都带 `Range: bytes=N-`。首个响应为 206 即视为可 seek（总长取自
///   `Content-Range`）；为 200 表示服务端忽略 Range，按不可 seek 的顺序流处理。
/// - 下载数据先进入内存缓冲，超过上限时挂起任务，读走一半后恢复。可 seek 流上限
///   为 `maxBufferedBytes`；顺序流无法续传，挂起期间连接若被服务端断开就无法恢复，
///   故用更大的 `maxSequentialBufferedBytes`，通常足以容纳整首转码输出。
/// - 网络瞬断时从已缓冲末尾续传，最多 `maxRetries` 次（仅可 seek 的资源）。
/// - 地址过期（`expiresAt` 已过）或收到 401/403 时，经
///   `RemotePlaybackRequest.refreshed()` 异步换取新地址后从同一偏移继续；
///   每次失败最多续签 `maxRefreshAttempts` 次。
/// - `cancel()` 永久终止；`interruptReads()` 只打断当前阻塞读（供 seek 使用），
///   `resumeReads()` 后可继续使用。均可从任意线程调用。
final class URLSessionByteSource: NSObject, FFmpegByteSource, @unchecked Sendable {
    enum SourceError: Error, Equatable {
        case cancelled
        case interrupted
        case httpStatus(Int)
        case invalidResponse
        case notSeekable
        case network(URLError.Code)
    }

    private let maxBufferedBytes: Int
    private let maxSequentialBufferedBytes: Int
    private let maxRetries: Int
    private let maxRefreshAttempts = 1
    private let timeout: TimeInterval
    private var session: URLSession!

    // 以下状态均由 `condition` 保护。
    private let condition = NSCondition()
    private var currentRequest: RemotePlaybackRequest
    private var task: URLSessionDataTask?
    private var pending = Data()
    private var pendingOffset = 0
    /// 下一个交给 `read` 调用方的字节在资源中的偏移。
    private var readPosition: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var responseReceived = false
    private var finished = false
    private var failure: Error?
    private var cancelled = false
    private var readsInterrupted = false
    private var suspended = false
    private var retries = 0
    private var refreshing = false
    private var refreshAttempts = 0
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var opened = false
    private var seekable = false
    private var totalBytes: Int64?

    init(
        request: RemotePlaybackRequest,
        configuration: URLSessionConfiguration = .default,
        maxBufferedBytes: Int = 4 * 1024 * 1024,
        maxSequentialBufferedBytes: Int = 32 * 1024 * 1024,
        maxRetries: Int = 2,
        timeout: TimeInterval = 15
    ) {
        currentRequest = request
        self.maxBufferedBytes = maxBufferedBytes
        self.maxSequentialBufferedBytes = maxSequentialBufferedBytes
        self.maxRetries = maxRetries
        self.timeout = timeout
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.musicfree.ffmpeg.urlsession"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// 发出首个请求并阻塞到拿到响应头，确定可 seek 性与总长。
    /// 必须在交给解码器之前调用。
    func open() throws {
        condition.lock()
        defer { condition.unlock() }
        if cancelled { throw SourceError.cancelled }
        startRequest(at: 0, preservingBuffer: false)
        while !responseReceived, failure == nil, !cancelled {
            condition.wait()
        }
        if cancelled { throw SourceError.cancelled }
        if let failure { throw failure }
        opened = true
    }

    func cancel() {
        condition.lock()
        cancelled = true
        refreshTask?.cancel()
        refreshTask = nil
        task?.cancel()
        task = nil
        condition.broadcast()
        condition.unlock()
        // URLSession 强引用 delegate，必须失效才能打破循环。
        session.invalidateAndCancel()
    }

    /// 让当前及后续 `read` 立即抛出 `.interrupted`，直到 `resumeReads()`。
    /// 用于 seek：旧的解码任务可能正阻塞在网络读取上，不打断就要等到超时。
    func interruptReads() {
        condition.lock()
        readsInterrupted = true
        condition.broadcast()
        condition.unlock()
    }

    func resumeReads() {
        condition.lock()
        readsInterrupted = false
        condition.unlock()
    }

    /// 已下载但尚未被读走的字节数（测试用）。
    var bufferedByteCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count - pendingOffset
    }

    // MARK: - FFmpegByteSource

    var isSeekable: Bool {
        condition.lock()
        defer { condition.unlock() }
        return seekable
    }

    var byteCount: Int64? {
        condition.lock()
        defer { condition.unlock() }
        return totalBytes
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { throw SourceError.cancelled }
            if readsInterrupted { throw SourceError.interrupted }
            let available = pending.count - pendingOffset
            if available > 0 {
                let count = min(available, buffer.count)
                pending.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(
                        rebasing: src[pendingOffset ..< pendingOffset + count]
                    ))
                }
                pendingOffset += count
                readPosition += Int64(count)
                if suspended, pending.count - pendingOffset <= bufferLimit / 2 {
                    suspended = false
                    task?.resume()
                }
                return count
            }
            if let failure { throw failure }
            if finished { return 0 }
            condition.wait()
        }
    }

    func seek(toOffset offset: Int64) throws {
        condition.lock()
        defer { condition.unlock() }
        if cancelled { throw SourceError.cancelled }
        guard seekable else { throw SourceError.notSeekable }

        let available = Int64(pending.count - pendingOffset)
        if offset >= readPosition, offset - readPosition <= available {
            pendingOffset += Int(offset - readPosition)
            readPosition = offset
            if suspended, pending.count - pendingOffset <= bufferLimit / 2 {
                suspended = false
                task?.resume()
            }
            return
        }
        if let totalBytes, offset >= totalBytes {
            task?.cancel()
            task = nil
            clearBuffer()
            readPosition = offset
            failure = nil
            finished = true
            return
        }
        startRequest(at: offset, preservingBuffer: false)
    }

    // MARK: - Private（调用方持有 condition）

    private var bufferLimit: Int {
        seekable ? maxBufferedBytes : maxSequentialBufferedBytes
    }

    private var canRefreshAfterAuthFailure: Bool {
        currentRequest.canRefresh && refreshAttempts < maxRefreshAttempts
    }

    private func startRequest(at offset: Int64, preservingBuffer: Bool) {
        task?.cancel()
        task = nil
        if !preservingBuffer {
            clearBuffer()
            readPosition = offset
        }
        requestedOffset = offset
        responseReceived = false
        finished = false
        failure = nil
        suspended = false

        if currentRequest.isExpired(at: Date()), currentRequest.canRefresh {
            beginRefresh()
        } else {
            issueRequest()
        }
    }

    private func issueRequest() {
        var urlRequest = URLRequest(
            url: currentRequest.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        for (name, value) in currentRequest.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: urlRequest)
        self.task = task
        task.resume()
    }

    /// 异步换取新地址，完成后从最新的 `requestedOffset` 重新请求。续签期间发生的
    /// seek 只改写 `requestedOffset`，不会并发发起第二次续签。
    private func beginRefresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshAttempts += 1
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let request = currentRequest
        refreshTask = Task { [weak self] in
            let result: Result<RemotePlaybackRequest, Error>
            do {
                result = .success(try await request.refreshed())
            } catch {
                result = .failure(error)
            }
            self?.finishRefresh(result, generation: generation)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishRefresh(
                .failure(SourceError.network(.timedOut)), generation: generation
            )
        }
    }

    private func finishRefresh(
        _ result: Result<RemotePlaybackRequest, Error>, generation: UInt64
    ) {
        condition.lock()
        defer { condition.unlock() }
        guard refreshing, generation == refreshGeneration else { return }
        refreshing = false
        refreshTask?.cancel()
        refreshTask = nil
        guard !cancelled else { return }
        switch result {
        case let .success(next):
            currentRequest = next
            issueRequest()
        case let .failure(error):
            failure = error
            condition.broadcast()
        }
    }

    private func clearBuffer() {
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
    }

    private func append(_ data: Data) {
        if pendingOffset > 0, pendingOffset >= pending.count / 2 {
            pending.removeSubrange(0 ..< pendingOffset)
            pendingOffset = 0
        }
        pending.append(data)
    }

    /// 解析 `Content-Range: bytes start-end/total`，返回 (start, total)。
    private static func parseContentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let dash = parts[0].firstIndex(of: "-"),
              let start = Int64(parts[0][..<dash].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (start, Int64(parts[1].trimmingCharacters(in: .whitespaces)))
    }
}

extension URLSessionByteSource: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()
        defer { condition.unlock() }
        guard dataTask === task, !cancelled else {
            completionHandler(.cancel)
            return
        }
        defer { condition.broadcast() }
        guard let http = response as? HTTPURLResponse else {
            failure = SourceError.invalidResponse
            completionHandler(.cancel)
            return
        }

        switch http.statusCode {
        case 206:
            let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == requestedOffset else {
                failure = SourceError.invalidResponse
                completionHandler(.cancel)
                return
            }
            if !opened {
                seekable = true
                totalBytes = range.total
            }
        case 200:
            // 服务端忽略了 Range：只有从头读时才能接受。
            guard requestedOffset == 0 else {
                failure = SourceError.notSeekable
                completionHandler(.cancel)
                return
            }
            if !opened {
                seekable = false
                totalBytes = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            }
        case 416:
            // 请求起点已越过资源末尾，按正常结束处理。
            responseReceived = true
            finished = true
            completionHandler(.cancel)
            return
        case 401 where canRefreshAfterAuthFailure, 403 where canRefreshAfterAuthFailure:
            // 签名地址失效：丢弃本次任务，续签后从同一偏移重新请求。
            task = nil
            completionHandler(.cancel)
            beginRefresh()
            return
        default:
            failure = SourceError.httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        responseReceived = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard dataTask === task, !cancelled else { return }
        append(data)
        retries = 0
        refreshAttempts = 0
        if !suspended, pending.count - pendingOffset >= bufferLimit {
            suspended = true
            dataTask.suspend()
        }
        condition.broadcast()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard task === self.task, !cancelled else { return }
        defer { condition.broadcast() }
        self.task = nil
        guard let error else {
            finished = true
            return
        }
        if failure != nil || finished { return }

        let urlError = error as? URLError
        if let urlError, seekable, retries < maxRetries, urlError.code != .cancelled {
            retries += 1
            let resumeOffset = readPosition + Int64(pending.count - pendingOffset)
            startRequest(at: resumeOffset, preservingBuffer: true)
            return
        }
        failure = urlError.map { SourceError.network($0.code) } ?? error
    }
}
