import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

/// The redacted error vocabulary exposed by application use cases.
public enum AppServiceError: Error, Equatable, Sendable, LocalizedError,
    CustomStringConvertible
{
    case invalidRequest(operation: String)
    case invalidCommand
    case missingDependency(String)
    case duplicateSource(MediaSourceID)
    case sourceNotFound(MediaSourceID)
    case incompatibleDependency(String)
    case operationInProgress(operation: String)
    case library(LibraryError)
    case mediaSource(MediaSourceError)
    case importFailed(MediaImportError)
    case removalFailed(MediaRemovalError)
    case playback(PlaybackError)
    case settings(SettingsError)
    case systemIntegration(SystemIntegrationError)
    case pendingRemoval(MediaRemovalTransaction)
    case cancelled
    case unknown(operation: String)

    public var isCancellation: Bool {
        switch self {
        case .cancelled:
            return true
        case .mediaSource(let error):
            return error.isCancellation
        case .importFailed(let error):
            return error.isCancellation
        case .removalFailed(let error):
            return error.isCancellation
        case .playback(let error):
            return error.isCancellation
        default:
            return false
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .library(let error):
            return error.isRetryable
        case .mediaSource(let error):
            return error.isRetryable
        case .importFailed(let error):
            return error.isRetryable
        case .removalFailed(let error):
            return error.isRetryable
        case .playback(let error):
            return error.isRetryable
        case .settings(let error):
            return error.isRetryable
        case .systemIntegration(let error):
            return error.isRetryable
        case .pendingRemoval, .incompatibleDependency, .operationInProgress,
             .missingDependency, .duplicateSource, .sourceNotFound,
             .invalidRequest, .invalidCommand, .cancelled:
            return false
        case .unknown:
            return true
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .invalidRequest:
            return "app.invalid_request"
        case .invalidCommand:
            return "app.invalid_command"
        case .missingDependency:
            return "app.missing_dependency"
        case .duplicateSource:
            return "app.duplicate_source"
        case .sourceNotFound:
            return "app.source_not_found"
        case .incompatibleDependency:
            return "app.incompatible_dependency"
        case .operationInProgress:
            return "app.operation_in_progress"
        case .library(let error):
            return error.diagnosticCode
        case .mediaSource(let error):
            return "media.\(error.diagnosticCode)"
        case .importFailed(let error):
            return "import.\(error.diagnosticCode)"
        case .removalFailed(let error):
            return "removal.\(error.diagnosticCode)"
        case .playback(let error):
            return "playback.\(error.diagnosticCode)"
        case .settings(let error):
            return "settings.\(String(describing: error))"
        case .systemIntegration(let error):
            return error.diagnosticCode
        case .pendingRemoval:
            return "app.pending_removal"
        case .cancelled:
            return "app.cancelled"
        case .unknown:
            return "app.unknown"
        }
    }

    public var failureReason: String {
        switch self {
        case .invalidRequest:
            return "The application request is invalid."
        case .invalidCommand:
            return "The playback command is invalid."
        case .missingDependency:
            return "A required application dependency is unavailable."
        case .duplicateSource:
            return "The media source is registered more than once."
        case .sourceNotFound:
            return "The media source could not be found."
        case .incompatibleDependency:
            return "The configured application dependencies are incompatible."
        case .operationInProgress:
            return "The same application operation is already in progress."
        case .library(let error):
            return error.failureReason
        case .mediaSource(let error):
            return error.userFacingReason
        case .importFailed(let error):
            return error.userFacingReason
        case .removalFailed(let error):
            return error.userFacingReason
        case .playback(let error):
            return error.userFacingReason
        case .settings(let error):
            return String(describing: error)
        case .systemIntegration(let error):
            return error.failureReason
        case .pendingRemoval:
            return "The media removal is waiting for storage finalization."
        case .cancelled:
            return "The operation was cancelled."
        case .unknown:
            return "The application operation could not be completed."
        }
    }

    public var errorDescription: String? {
        failureReason
    }

    public var description: String {
        "AppServiceError(\(diagnosticCode))"
    }

    /// Converts adapter errors at the application boundary without retaining
    /// framework errors, paths, URLs, or credentials.
    internal static func mapped(_ error: Error, operation: String) -> Self {
        if let error = error as? Self {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? MediaSourceError {
            if error.isCancellation { return .cancelled }
            switch error {
            case .importFailed(let importError):
                return .importFailed(importError)
            case .removalFailed(let removalError):
                return .removalFailed(removalError)
            case .sourceNotFound(let sourceID):
                return .sourceNotFound(sourceID)
            default:
                return .mediaSource(error)
            }
        }
        if let error = error as? MediaImportError {
            return error.isCancellation ? .cancelled : .importFailed(error)
        }
        if let error = error as? MediaRemovalError {
            return error.isCancellation ? .cancelled : .removalFailed(error)
        }
        if let error = error as? LibraryError {
            return .library(error)
        }
        if let error = error as? PlaybackError {
            return error.isCancellation ? .cancelled : .playback(error)
        }
        if let error = error as? SettingsError {
            return .settings(error)
        }
        if let error = error as? SystemIntegrationError {
            return .systemIntegration(error)
        }
        return .unknown(operation: operation)
    }
}

/// The clock needed by long-running application workflows.
public protocol AppClock: Sendable {
    func now() async -> Date
    func sleep(for duration: Duration) async throws
}

/// Wall-clock implementation used by production composition roots.
public struct WallAppClock: AppClock, Sendable {
    public init() {}

    public func now() async -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Explicit UUID generation boundary for deterministic application tests.
public protocol AppIDGenerating: Sendable {
    func nextUUID() async -> UUID
}

public struct UUIDAppIDGenerator: AppIDGenerating, Sendable {
    public init() {}

    public func nextUUID() async -> UUID {
        UUID()
    }
}

/// Explicit randomness boundary used for persisted shuffle order generation.
public protocol AppRandomSource: Sendable {
    func nextUInt64() async -> UInt64
}

public actor SystemAppRandomSource: AppRandomSource {
    public init() {}

    public func nextUInt64() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }
}
