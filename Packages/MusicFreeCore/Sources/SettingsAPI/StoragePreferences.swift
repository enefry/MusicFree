import Foundation

/// A validated byte limit used by storage maintenance policies.
public struct StorageByteLimit: Codable, Equatable, Hashable, Sendable, Comparable {
    public static let minimumBytes: Int64 = 64 * 1_024 * 1_024
    public static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024 * 1_024

    public let bytes: Int64

    public init(bytes: Int64) throws {
        guard (Self.minimumBytes...Self.maximumBytes).contains(bytes) else {
            throw SettingsError.invalidValue(field: "storage.cacheLimit.bytes", reason: .outOfRange)
        }
        self.bytes = bytes
    }

    private init(unchecked bytes: Int64) {
        self.bytes = bytes
    }

    public static let fiveGiB = Self(unchecked: 5 * 1_024 * 1_024 * 1_024)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes < rhs.bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(bytes: container.decode(Int64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

/// Storage maintenance intent. It does not perform cleanup itself.
@available(macOS 13.0, iOS 16.0, *)
public struct StoragePreferences: Codable, Equatable, Hashable, Sendable {
    public static let maximumStagingRetention = Duration.seconds(30 * 24 * 60 * 60)

    public let cacheLimit: StorageByteLimit
    public let automaticallyPruneCache: Bool
    public let stagingRetention: Duration

    public init(
        cacheLimit: StorageByteLimit = .fiveGiB,
        automaticallyPruneCache: Bool = true,
        stagingRetention: Duration = Duration.seconds(7 * 24 * 60 * 60)
    ) throws {
        guard stagingRetention >= .zero,
              stagingRetention <= Self.maximumStagingRetention
        else {
            throw SettingsError.invalidValue(
                field: "storage.stagingRetention",
                reason: .outOfRange
            )
        }
        self.init(
            uncheckedCacheLimit: cacheLimit,
            uncheckedAutomaticallyPruneCache: automaticallyPruneCache,
            uncheckedStagingRetention: stagingRetention
        )
    }

    private init(
        uncheckedCacheLimit cacheLimit: StorageByteLimit,
        uncheckedAutomaticallyPruneCache automaticallyPruneCache: Bool,
        uncheckedStagingRetention stagingRetention: Duration
    ) {
        self.cacheLimit = cacheLimit
        self.automaticallyPruneCache = automaticallyPruneCache
        self.stagingRetention = stagingRetention
    }

    public static let defaults = Self(
        uncheckedCacheLimit: .fiveGiB,
        uncheckedAutomaticallyPruneCache: true,
        uncheckedStagingRetention: Duration.seconds(7 * 24 * 60 * 60)
    )

    private enum CodingKeys: String, CodingKey {
        case cacheLimit
        case automaticallyPruneCache
        case stagingRetention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cacheLimit: try container.decodeIfPresent(StorageByteLimit.self, forKey: .cacheLimit)
                ?? .fiveGiB,
            automaticallyPruneCache: try container.decodeIfPresent(
                Bool.self,
                forKey: .automaticallyPruneCache
            ) ?? true,
            stagingRetention: try container.decodeIfPresent(Duration.self, forKey: .stagingRetention)
                ?? Duration.seconds(7 * 24 * 60 * 60)
        )
    }
}
