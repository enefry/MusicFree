import Foundation

/// Errors raised while opening or using the library persistence store.
public enum LibraryPersistenceError: Error, LocalizedError, Codable, Equatable, Sendable {
    case invalidConfiguration
    case openFailed
    case migrationFailed(version: Int)
    case corruptedStore
    case corruptedRecord
    case encodingFailed
    case closed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The library persistence configuration is invalid."
        case .openFailed:
            return "The library persistence store could not be opened."
        case .migrationFailed:
            return "The library persistence store could not be migrated."
        case .corruptedStore:
            return "The library persistence store is corrupted."
        case .corruptedRecord:
            return "The library persistence store contains an invalid record."
        case .encodingFailed:
            return "A library value could not be encoded for persistence."
        case .closed:
            return "The library persistence store is closed."
        }
    }
}
