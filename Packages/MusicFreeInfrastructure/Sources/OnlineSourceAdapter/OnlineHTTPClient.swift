import Foundation
import MediaSourceAPI

/// The smallest URLSession seam shared by the real Provider transports.
/// Tests can replace it with URLProtocol-backed sessions without changing the
/// Provider contracts.
public protocol OnlineHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
    func download(for request: URLRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> (URL, HTTPURLResponse)
}

public extension OnlineHTTPClient {
    func download(for request: URLRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> (URL, HTTPURLResponse) {
        let result = try await download(for: request)
        if let size = (try? FileManager.default.attributesOfItem(atPath: result.0.path)[.size]) as? NSNumber {
            progress?(DownloadProgress(receivedBytes: size.int64Value, totalBytes: size.int64Value))
        }
        return result
    }
}

public final class URLSessionOnlineHTTPClient: OnlineHTTPClient, @unchecked Sendable {
    public let session: URLSession
    private let downloadDelegate: OnlineDownloadSessionDelegate
    private let downloadSession: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        let delegate = OnlineDownloadSessionDelegate()
        downloadDelegate = delegate
        downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { downloadSession.invalidateAndCancel() }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return (data, response)
    }

    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return (url, response)
    }

    public func download(for request: URLRequest, progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> (URL, HTTPURLResponse) {
        guard let progress else { return try await download(for: request) }
        let transfer = OnlineDownloadTransfer(report: progress)
        let (url, response): (URL, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadSession.downloadTask(with: request)
                downloadDelegate.register(transfer, for: task, completion: { continuation.resume(with: $0) })
                transfer.start(task)
            }
        } onCancel: { transfer.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return (url, response)
    }
}

private final class OnlineDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: OnlineDownloadTransfer] = [:]

    func register(_ transfer: OnlineDownloadTransfer, for task: URLSessionDownloadTask, completion: @escaping @Sendable (Result<(URL, URLResponse), Error>) -> Void) {
        transfer.completion = completion
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask, removing: Bool = false) -> OnlineDownloadTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return removing ? transfers.removeValue(forKey: task.taskIdentifier) : transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        transfer(for: downloadTask)?.record(receivedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        transfer(for: downloadTask)?.stage(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(for: task, removing: true)?.finish(error: error, response: task.response)
    }
}

private final class OnlineDownloadTransfer: @unchecked Sendable {
    private let report: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var lastTime = Date.timeIntervalSinceReferenceDate
    private var lastBytes: Int64 = 0
    private var task: URLSessionDownloadTask?
    private var isCancelled = false
    private var isFinished = false
    private var fileURL: URL?
    private var stagingError: Error?
    var completion: (@Sendable (Result<(URL, URLResponse), Error>) -> Void)?

    init(report: @escaping @Sendable (DownloadProgress) -> Void) { self.report = report }

    func start(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func stage(_ location: URL) {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicFreeOnlineTransfers", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            fileURL = destination
            lock.unlock()
        } catch {
            lock.lock()
            stagingError = error
            lock.unlock()
        }
    }

    func finish(error: Error?, response: URLResponse?) {
        lock.lock()
        isFinished = true
        let fileURL = fileURL
        let failure = isCancelled ? URLError(.cancelled) : error ?? stagingError
        let completion = completion
        self.completion = nil
        task = nil
        lock.unlock()
        if let failure {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            completion?(.failure(failure))
        } else if let fileURL, let response {
            completion?(.success((fileURL, response)))
        } else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            completion?(.failure(OnlineSourceAdapterError.invalidResponse))
        }
    }

    func record(receivedBytes: Int64, totalBytes: Int64) {
        lock.lock()
        guard !isFinished, !isCancelled else { lock.unlock(); return }
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastTime
        guard elapsed >= 0.2 || receivedBytes == totalBytes else { lock.unlock(); return }
        let speed = elapsed > 0 ? Double(max(0, receivedBytes - lastBytes)) / elapsed : nil
        lastTime = now
        lastBytes = receivedBytes
        lock.unlock()
        report(DownloadProgress(receivedBytes: receivedBytes, totalBytes: totalBytes, bytesPerSecond: speed))
    }
}

@inline(__always)
func validateOnlineHTTPStatus(_ response: HTTPURLResponse) throws {
    guard (200 ..< 300).contains(response.statusCode) else {
        switch response.statusCode {
        case 401:
            throw OnlineSourceAdapterError.authorizationRequired
        case 403:
            throw OnlineSourceAdapterError.permissionDenied
        case 404:
            throw OnlineSourceAdapterError.resourceNotFound
        case 429:
            throw OnlineSourceAdapterError.rateLimited
        default:
            throw OnlineSourceAdapterError.httpStatus(response.statusCode)
        }
    }
}

func sanitizedOnlineFileName(_ value: String?, fallback: String) -> String {
    let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = candidate?.isEmpty == false ? candidate! : fallback
    let invalid = CharacterSet(charactersIn: "/\\:\0")
    let sanitized = name.components(separatedBy: invalid).joined(separator: "_")
    return sanitized.isEmpty ? fallback : sanitized
}

func stageOnlineDownload(
    temporaryURL: URL,
    preferredFileName: String?,
    fallbackExtension: String
) throws -> (url: URL, byteCount: Int64?) {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("MusicFreeOnlineDownloads", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let fallback = "musicfree-\(UUID().uuidString.lowercased()).\(fallbackExtension)"
    var fileName = sanitizedOnlineFileName(preferredFileName, fallback: fallback)
    if URL(fileURLWithPath: fileName).pathExtension.isEmpty,
       !fallbackExtension.isEmpty {
        fileName += ".\(fallbackExtension)"
    }

    let preferredDestination = root.appendingPathComponent(fileName, isDirectory: false)
    let destination: URL
    do {
        try fileManager.moveItem(at: temporaryURL, to: preferredDestination)
        destination = preferredDestination
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
        let preferredURL = URL(fileURLWithPath: fileName)
        let stem = preferredURL.deletingPathExtension().lastPathComponent
        let fileExtension = preferredURL.pathExtension
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let uniqueName = fileExtension.isEmpty
            ? "\(stem)-\(suffix)"
            : "\(stem)-\(suffix).\(fileExtension)"
        let uniqueDestination = root.appendingPathComponent(
            uniqueName,
            isDirectory: false
        )
        try fileManager.moveItem(at: temporaryURL, to: uniqueDestination)
        destination = uniqueDestination
    }
    let byteCount = try? fileManager.attributesOfItem(atPath: destination.path)[
        .size
    ] as? NSNumber
    return (destination, byteCount?.int64Value)
}
