import Foundation

/// The reason recorded for the most recent playback completion.
public enum PlaybackCompletionReason: Codable, Equatable, Hashable, Sendable {
    case ended
    case skipped
    case stopped
    case interrupted
    case failed
    case unknown(String)

    /// Compatibility spelling for a natural end.
    public static var completed: Self {
        .ended
    }

    /// Compatibility spelling for a natural end.
    public static var naturalEnd: Self {
        .ended
    }

    /// Compatibility spelling for an error completion.
    public static var error: Self {
        .failed
    }

    public var code: String {
        switch self {
        case .ended:
            return "ended"
        case .skipped:
            return "skipped"
        case .stopped:
            return "stopped"
        case .interrupted:
            return "interrupted"
        case .failed:
            return "failed"
        case .unknown(let value):
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        switch code {
        case "ended":
            self = .ended
        case "skipped":
            self = .skipped
        case "stopped":
            self = .stopped
        case "interrupted":
            self = .interrupted
        case "failed":
            self = .failed
        default:
            self = .unknown(code)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

/// A compact, persistent summary of a track's playback history.
@available(macOS 13.0, *)
public struct PlaybackStatistics: Codable, Equatable, Hashable, Sendable {
    public let playCount: Int
    public let completionCount: Int
    public let skipCount: Int
    public let lastPlayedAt: Date?
    public let lastCompletionReason: PlaybackCompletionReason?
    public let totalListeningDuration: Duration

    public static let empty = Self()

    /// Creates statistics with non-negative counters and listening duration.
    public init(
        playCount: Int = 0,
        completionCount: Int = 0,
        skipCount: Int = 0,
        lastPlayedAt: Date? = nil,
        lastCompletionReason: PlaybackCompletionReason? = nil,
        totalListeningDuration: Duration = .zero
    ) {
        self.playCount = musicDomainNonNegative(playCount, field: "playCount")
        self.completionCount = musicDomainNonNegative(completionCount, field: "completionCount")
        self.skipCount = musicDomainNonNegative(skipCount, field: "skipCount")
        self.lastPlayedAt = lastPlayedAt
        self.lastCompletionReason = lastCompletionReason
        self.totalListeningDuration = musicDomainNonNegativeDuration(
            totalListeningDuration,
            field: "totalListeningDuration"
        )
    }

    public var completedCount: Int {
        completionCount
    }

    public var skippedCount: Int {
        skipCount
    }

    private enum CodingKeys: String, CodingKey {
        case playCount
        case completionCount
        case skipCount
        case lastPlayedAt
        case lastCompletionReason
        case totalListeningDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        let completionCount = try container.decodeIfPresent(Int.self, forKey: .completionCount) ?? 0
        let skipCount = try container.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        let totalListeningDuration = try container.decodeIfPresent(
            Duration.self,
            forKey: .totalListeningDuration
        ) ?? .zero
        guard playCount >= 0,
              completionCount >= 0,
              skipCount >= 0,
              totalListeningDuration >= .zero
        else {
            throw musicDomainDecodingFailure(decoder, field: "PlaybackStatistics")
        }
        self.init(
            playCount: playCount,
            completionCount: completionCount,
            skipCount: skipCount,
            lastPlayedAt: try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt),
            lastCompletionReason: try container.decodeIfPresent(
                PlaybackCompletionReason.self,
                forKey: .lastCompletionReason
            ),
            totalListeningDuration: totalListeningDuration
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playCount, forKey: .playCount)
        try container.encode(completionCount, forKey: .completionCount)
        try container.encode(skipCount, forKey: .skipCount)
        try container.encodeIfPresent(lastPlayedAt, forKey: .lastPlayedAt)
        try container.encodeIfPresent(lastCompletionReason, forKey: .lastCompletionReason)
        try container.encode(totalListeningDuration, forKey: .totalListeningDuration)
    }
}
