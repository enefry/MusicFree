import Foundation

/// 进程内的 HTTP 桩：通过 `URLProtocol` 拦截请求，按注册的资源返回数据，
/// 支持 `Range: bytes=N-`，可模拟 200/206/错误状态码与「响应头后停滞」。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Resource {
        var data: Data
        var supportsRange = true
        var status = 200
        /// 只发送响应头，不发送 body 也不结束，用于测试取消能否打断阻塞读。
        var stallAfterHeaders = false
        /// 从头请求时只发送前 N 字节后停滞；带非零 Range 的请求正常返回。
        var stallAfterBytes: Int?
        /// 测试背压：让每个 body 分块之间留出委托暂停下载的时间。
        var chunkDelay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resources: [URL: Resource] = [:]
    nonisolated(unsafe) private static var requestedRanges: [URL: [String?]] = [:]

    static func register(_ resource: Resource) -> URL {
        let url = URL(string: "https://stub.test/\(UUID().uuidString).wav")!
        lock.lock()
        resources[url] = resource
        lock.unlock()
        return url
    }

    static func update(_ url: URL, _ resource: Resource) {
        lock.lock()
        resources[url] = resource
        lock.unlock()
    }

    static func ranges(for url: URL) -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return requestedRanges[url] ?? []
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let resource = Self.resources[url]
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        Self.requestedRanges[url, default: []].append(rangeHeader)
        Self.lock.unlock()

        guard let resource else {
            respond(url: url, status: 404, headers: [:])
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if resource.status >= 400 {
            respond(url: url, status: resource.status, headers: [:])
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let total = resource.data.count
        var start = 0
        var status = 200
        var headers = ["Content-Type": "audio/wav"]
        if resource.supportsRange, let rangeHeader,
           rangeHeader.hasPrefix("bytes="), rangeHeader.hasSuffix("-"),
           let value = Int(rangeHeader.dropFirst("bytes=".count).dropLast())
        {
            guard value < total else {
                respond(url: url, status: 416, headers: ["Content-Range": "bytes */\(total)"])
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            start = value
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)"
            headers["Accept-Ranges"] = "bytes"
        }
        headers["Content-Length"] = String(total - start)
        respond(url: url, status: status, headers: headers)
        if resource.stallAfterHeaders { return }

        let chunk = 16 * 1024
        var offset = start
        let limit = start == 0 ? min(resource.stallAfterBytes ?? total, total) : total
        while offset < limit {
            let end = min(offset + chunk, limit)
            client?.urlProtocol(self, didLoad: resource.data.subdata(in: offset ..< end))
            offset = end
            if resource.chunkDelay > 0 { Thread.sleep(forTimeInterval: resource.chunkDelay) }
        }
        if limit < total { return }
        while offset < total {
            let end = min(offset + chunk, total)
            client?.urlProtocol(self, didLoad: resource.data.subdata(in: offset ..< end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

/// 生成 16-bit PCM WAV（正弦波），供解码端到端测试使用。
enum WAVFixture {
    static func make(
        frames: Int,
        sampleRate: Int = 44_100,
        channels: Int = 2,
        secondToneAtFrame: Int? = nil
    ) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerFrame = channels * 2
        let dataSize = frames * bytesPerFrame
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerFrame))
        append(UInt16(bytesPerFrame))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        for frame in 0 ..< frames {
            let frequency = frame >= (secondToneAtFrame ?? frames) ? 880.0 : 440.0
            let sample = Int16(sin(Double(frame) * 2 * .pi * frequency / Double(sampleRate)) * 8000)
            for _ in 0 ..< channels {
                append(sample)
            }
        }
        return data
    }
}
