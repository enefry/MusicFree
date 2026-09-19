import Foundation

/// The smallest URLSession seam shared by the real Provider transports.
/// Tests can replace it with URLProtocol-backed sessions without changing the
/// Provider contracts.
public protocol OnlineHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

public final class URLSessionOnlineHTTPClient: OnlineHTTPClient, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

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
