import AppServices
import Foundation
import MediaSourceAPI
import MusicDomain
import Network
import OnlineSourceAdapter
import PreferencesPersistenceAdapter
import Testing

@Test("URLSession downloads report intermediate byte progress and support cancellation")
func onlineDownloadProgressUsesRealURLSession() async throws {
    let server = try await DownloadProgressHTTPFixture.start()
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = URLSessionOnlineHTTPClient(session: session)
    let progress = DownloadProgressRecorder()
    let request = URLRequest(url: server.url)
    let (url, _) = try await client.download(for: request, progress: { progress.append($0) })
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try Data(contentsOf: url).count == DownloadProgressHTTPFixture.byteCount)
    #expect(progress.values.contains { $0.receivedBytes > 0 && $0.receivedBytes < Int64(DownloadProgressHTTPFixture.byteCount) })
    #expect(progress.values.last?.totalBytes == Int64(DownloadProgressHTTPFixture.byteCount))

    let cancelledProgress = DownloadProgressRecorder()
    let task = Task { try await client.download(for: request, progress: { cancelledProgress.append($0) }) }
    for _ in 0..<100 {
        if !cancelledProgress.values.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do {
        let unexpected = try await task.value
        try? FileManager.default.removeItem(at: unexpected.0)
        Issue.record("Cancelled download returned a completed file")
    } catch {
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
}

@Test("coalesced download persistence flushes the latest resumable state and clears durably")
func onlineDownloadQueueStoreFlushesLatestState() async throws {
    let suite = "MusicFree.DownloadQueueTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try UserDefaultsOnlineDownloadQueueStore(suiteName: suite)
    let id = SourceObjectID(sourceID: MediaSourceID("fixture"), externalID: "track")
    for bytes in 1...100 {
        var file = OnlineSourceDownloadSnapshot(itemID: id, displayName: "Track.m4a", phase: .cancelled)
        file.receivedBytes = Int64(bytes)
        var state = OnlineDownloadQueuePersistenceState(downloads: [file])
        state.resumableDownloads = [OnlineDownloadQueueDownloadTask(itemID: id, displayName: "Track.m4a", metadataHint: .init(title: "Track"))]
        store.save(state)
    }
    #expect(store.load()?.downloads.first?.receivedBytes == 100)
    await store.flush()
    let reopened = try UserDefaultsOnlineDownloadQueueStore(suiteName: suite)
    #expect(reopened.load()?.downloads.first?.receivedBytes == 100)
    #expect(reopened.load()?.resumableDownloads?.first?.itemID == id)
    store.clear()
    await store.flush()
    #expect(store.load() == nil)
    #expect(reopened.load() == nil)
}

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadProgress] = []
    var values: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: DownloadProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class DownloadProgressHTTPFixture: @unchecked Sendable {
    static let byteCount = 16 * 8192
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MusicFree.DownloadProgressHTTPFixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/track")! }

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() async throws -> DownloadProgressHTTPFixture {
        let server = try DownloadProgressHTTPFixture()
        server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(); server.listener.stateUpdateHandler = nil
                case .failed(let error): continuation.resume(throwing: error); server.listener.stateUpdateHandler = nil
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let connections = connections
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, error in
            guard error == nil, let self else { return }
            let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(Self.byteCount)\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                if error == nil { self?.sendChunk(connection, index: 0) }
            })
        }
    }

    private func sendChunk(_ connection: NWConnection, index: Int) {
        guard index < 16 else { connection.cancel(); return }
        connection.send(content: Data(repeating: 1, count: 8192), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.sendChunk(connection, index: index + 1) }
        })
    }
}
