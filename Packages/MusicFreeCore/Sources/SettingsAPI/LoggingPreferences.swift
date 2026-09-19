import Foundation

/// User intent for optional persistent application logging.
public struct LoggingPreferences: Codable, Equatable, Hashable, Sendable {
    public let isFileLoggingEnabled: Bool

    public init(isFileLoggingEnabled: Bool = false) {
        self.isFileLoggingEnabled = isFileLoggingEnabled
    }

    public static let defaults = Self()
}
