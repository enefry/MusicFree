// Protocol adaptation from jitwxs/163MusicLyrics (Apache-2.0).
// Reimplemented in Swift for permission-gated, cancellable plugin operations.
import Foundation
import MusicFreePluginAPI

public enum ChineseMusicService: String, Sendable {
    case netEase, qqMusic

    var referer: String { self == .netEase ? "https://music.163.com/" : "https://y.qq.com/" }
    var hosts: Set<String> {
        self == .netEase ? ["music.163.com", "p1.music.126.net", "p2.music.126.net", "p3.music.126.net", "p4.music.126.net"]
            : ["u.y.qq.com", "c.y.qq.com", "y.qq.com", "y.gtimg.cn"]
    }

    public func descriptor(kind: PluginKind) -> PluginDescriptor {
        let lyrics = kind == .lyrics
        let serviceName = self == .netEase ? "网易云音乐" : "QQ 音乐"
        return .init(id: .init(rawValue: "builtin.\(lyrics ? "lyrics" : "metadata").\(rawValue)"),
            name: serviceName + (lyrics ? "歌词" : "元数据"), kinds: [kind], permissions: [.network, .credentials],
            configuration: .init(fields: [.init(id: "cookie", title: "Cookie（可选）", kind: .secret)]),
            dataProviderID: rawValue)
    }
}

public struct ChineseMusicConfiguration: Sendable {
    let cookie: String?
    public static let anonymous = Self(cookie: nil)
    private init(cookie: String?) { self.cookie = cookie }

    public static func from(_ context: PluginLoadContext) async throws -> Self {
        try Task.checkCancellation()
        guard let record = context.configuration.credentialRecordID else { return .anonymous }
        guard context.operation.permissions.contains(.credentials), let credentials = context.credentials,
              let data = try await credentials.read(recordID: record, pluginID: context.operation.pluginID,
                  instanceID: context.operation.instanceID), data.count <= 8_192,
              let cookie = String(data: data, encoding: .utf8),
              !cookie.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { throw PluginError.invalidConfiguration }
        return .init(cookie: cookie.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let hosts: Set<String>
    init(hosts: Set<String>) { self.hosts = hosts }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // API requests and optional cookies cannot follow redirects to another host.
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
            && request.url?.host.map(hosts.contains) == true
        completionHandler(allowed ? request : nil)
    }
}

struct CatalogHTTPTransport: Sendable {
    let service: ChineseMusicService
    let configuration: ChineseMusicConfiguration
    let session: URLSession

    init(service: ChineseMusicService, configuration: ChineseMusicConfiguration, session: URLSession?) {
        self.service = service; self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil
        options.httpShouldSetCookies = false
        options.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: options, delegate: CatalogRedirectPolicy(hosts: service.hosts), delegateQueue: nil)
    }

    func request(_ url: URL, body: Data? = nil, contentType: String? = nil, artwork: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard url.scheme == "https", let host = url.host, service.hosts.contains(host), url.user == nil, url.password == nil else {
            throw PluginDataError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(service.referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 MusicFree/1.4", forHTTPHeaderField: "User-Agent")
        if !artwork { request.setValue(configuration.cookie, forHTTPHeaderField: "Cookie") }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .notConnectedToInternet { throw PluginDataError.offline }
        catch { throw PluginDataError.network }
        try Task.checkCancellation()
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PluginDataError.invalidResponse }
        if http.statusCode == 429 {
            throw PluginDataError.rateLimited(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init), httpStatus: 429)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PluginDataError.requestFailed(code: "\(service.rawValue)_http_\(http.statusCode)", httpStatus: http.statusCode)
        }
        let limit = (artwork ? 20 : 2) * 1_024 * 1_024
        guard response.expectedContentLength <= limit else { throw PluginDataError.payloadTooLarge }
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw PluginDataError.payloadTooLarge }
                data.append(byte)
            }
        } catch let error as PluginDataError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw PluginDataError.network }
        return data
    }
}

func formData(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(fields.sorted { $0.key < $1.key }.map {
        ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
            + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }.joined(separator: "&").utf8)
}
