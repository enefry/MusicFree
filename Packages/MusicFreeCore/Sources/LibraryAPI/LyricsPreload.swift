import Foundation

public enum LyricsPreloadStatus: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case downloading
    case completed
    case cancelled
    case failed
}

/// Progress for the explicit local-library lyrics pre-download operation.
/// Successful results are persisted on each track as the operation advances.
public struct LyricsPreloadSnapshot: Codable, Equatable, Sendable {
    public let status: LyricsPreloadStatus
    public let total: Int
    public let processed: Int
    public let downloaded: Int
    public let cached: Int
    public let noLyrics: Int
    public let failed: Int
    public let currentTitle: String?
    public let errorCode: String?

    public init(
        status: LyricsPreloadStatus = .idle,
        total: Int = 0,
        processed: Int = 0,
        downloaded: Int = 0,
        cached: Int = 0,
        noLyrics: Int = 0,
        failed: Int = 0,
        currentTitle: String? = nil,
        errorCode: String? = nil
    ) {
        self.status = status
        self.total = max(0, total)
        self.processed = max(0, processed)
        self.downloaded = max(0, downloaded)
        self.cached = max(0, cached)
        self.noLyrics = max(0, noLyrics)
        self.failed = max(0, failed)
        self.currentTitle = currentTitle
        self.errorCode = errorCode
    }
}
