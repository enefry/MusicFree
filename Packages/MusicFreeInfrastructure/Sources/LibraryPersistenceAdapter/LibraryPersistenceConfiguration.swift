import Foundation

/// Configuration for the library store without exposing SwiftData types.
public struct LibraryPersistenceConfiguration: Sendable, Equatable {
    public enum Location: Sendable, Equatable {
        case inMemory
        case file(URL)
    }

    public let location: Location

    public init() {
        self.location = .inMemory
    }

    /// Creates an in-memory configuration by default. A file URL makes the
    /// store durable across launches; setting both options is rejected.
    public init(
        storeURL: URL? = nil,
        isStoredInMemoryOnly: Bool = false
    ) throws {
        if storeURL != nil && isStoredInMemoryOnly {
            throw LibraryPersistenceError.invalidConfiguration
        }
        if let storeURL {
            guard storeURL.isFileURL, !storeURL.path.isEmpty else {
                throw LibraryPersistenceError.invalidConfiguration
            }
            self.location = .file(storeURL)
        } else {
            self.location = .inMemory
        }
    }

    public static let inMemory = Self()

    public var isStoredInMemoryOnly: Bool {
        if case .inMemory = location {
            return true
        }
        return false
    }

    public var storeURL: URL? {
        if case .file(let url) = location {
            return url
        }
        return nil
    }
}

/// Compatibility marker retained in a real public adapter file.
public enum LibraryPersistenceAdapterModule {}
