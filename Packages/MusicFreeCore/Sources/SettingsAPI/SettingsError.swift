import Foundation

/// The reason a setting value failed validation.
public enum SettingsValidationReason: String, Codable, Equatable, Hashable, Sendable {
    case empty
    case nonFinite
    case outOfRange
    case duplicate
}

/// Stable failures exposed by the settings contract.
public enum SettingsError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The persisted bytes could not be decoded as settings.
    case decoding

    /// The payload was written by a newer schema than this build understands.
    case unsupportedSchemaVersion(found: Int, current: Int)

    /// A setting value does not satisfy the API invariant.
    case invalidValue(field: String, reason: SettingsValidationReason)

    /// A supported schema could not be upgraded to the current schema.
    case migrationFailed(from: Int, to: Int)

    /// The repository could not read its backing store.
    case readFailed

    /// The repository could not commit a new settings value.
    case writeFailed

    /// The repository could not commit the default settings.
    case resetFailed

    /// Whether retrying the same repository operation may succeed later.
    public var isRetryable: Bool {
        switch self {
        case .readFailed, .writeFailed, .resetFailed:
            return true
        case .decoding, .unsupportedSchemaVersion, .invalidValue, .migrationFailed:
            return false
        }
    }

    public var description: String {
        switch self {
        case .decoding:
            return "SettingsError.decoding"
        case .unsupportedSchemaVersion(let found, let current):
            return "SettingsError.unsupportedSchemaVersion(found: \(found), current: \(current))"
        case .invalidValue(let field, let reason):
            return "SettingsError.invalidValue(field: \(field), reason: \(reason.rawValue))"
        case .migrationFailed(let from, let to):
            return "SettingsError.migrationFailed(from: \(from), to: \(to))"
        case .readFailed:
            return "SettingsError.readFailed"
        case .writeFailed:
            return "SettingsError.writeFailed"
        case .resetFailed:
            return "SettingsError.resetFailed"
        }
    }
}
