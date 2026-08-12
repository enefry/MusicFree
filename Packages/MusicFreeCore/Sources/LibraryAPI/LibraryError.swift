import Foundation
import MusicDomain

/// Errors returned by library, playlist, and playback-history repositories.
public enum LibraryError: Error, LocalizedError, Sendable, Codable, Equatable {
    /// Query construction or cursor errors.
    public enum Query: Sendable, Codable, Equatable {
        case invalidPageSize(requested: Int, maximum: Int)
        case invalidCursor
        case expiredCursor
        case emptySearchText
        case unsupportedSort
    }

    /// Data-integrity and mutation-shape errors.
    public enum Constraint: Sendable, Codable, Equatable {
        case emptyTransaction
        case invalidIdempotencyKey
        case invalidPlaylistName
        case invalidPlaylistPosition
        case duplicatePlaylistMember
        case danglingReference
        case duplicateMutation
        case invalidStatisticsDelta
    }

    /// Optimistic-concurrency and idempotency errors.
    public enum Conflict: Sendable, Codable, Equatable {
        case revisionMismatch(expected: LibraryRevision?, actual: LibraryRevision)
        case transactionAlreadyApplied
        case transactionInProgress
    }

    /// Store schema and migration errors.
    public enum Migration: Sendable, Codable, Equatable {
        case required(currentVersion: Int, minimumVersion: Int)
        case failed(version: Int)
    }

    /// Capacity and storage availability errors.
    public enum Capacity: Sendable, Codable, Equatable {
        case pageLimitExceeded(requested: Int, maximum: Int)
        case resultTooLarge
        case storageUnavailable
    }

    case query(Query)
    case constraint(Constraint)
    case conflict(Conflict)
    case migration(Migration)
    case capacity(Capacity)

    /// Whether retrying the same operation may succeed without changing its input.
    public var isRetryable: Bool {
        switch self {
        case .query(.expiredCursor), .query(.invalidCursor), .query(.invalidPageSize),
             .query(.emptySearchText), .query(.unsupportedSort),
             .constraint, .migration, .capacity(.pageLimitExceeded),
             .capacity(.resultTooLarge):
            return false
        case .conflict(.revisionMismatch), .conflict(.transactionInProgress),
             .capacity(.storageUnavailable):
            return true
        case .conflict(.transactionAlreadyApplied):
            return false
        }
    }

    /// A safe, user-understandable reason that contains no paths or credentials.
    public var failureReason: String {
        switch self {
        case .query(.invalidPageSize):
            return "The requested page size is invalid."
        case .query(.invalidCursor), .query(.expiredCursor):
            return "The page cursor is no longer valid."
        case .query(.emptySearchText):
            return "The search text is empty."
        case .query(.unsupportedSort):
            return "The requested sort order is not supported."
        case .constraint(.emptyTransaction):
            return "The library transaction contains no mutations."
        case .constraint(.invalidIdempotencyKey):
            return "The transaction idempotency key is invalid."
        case .constraint(.invalidPlaylistName):
            return "The playlist name is invalid."
        case .constraint(.invalidPlaylistPosition):
            return "The playlist position is invalid."
        case .constraint(.duplicatePlaylistMember):
            return "The playlist contains a duplicate member."
        case .constraint(.danglingReference):
            return "The mutation references missing library data."
        case .constraint(.duplicateMutation):
            return "The transaction contains conflicting mutations."
        case .constraint(.invalidStatisticsDelta):
            return "The playback statistics change is invalid."
        case .conflict(.revisionMismatch):
            return "The library changed before this operation was saved."
        case .conflict(.transactionAlreadyApplied):
            return "This transaction has already been applied."
        case .conflict(.transactionInProgress):
            return "This transaction is already being applied."
        case .migration(.required), .migration(.failed):
            return "The library needs a compatible data migration."
        case .capacity(.pageLimitExceeded), .capacity(.resultTooLarge):
            return "The requested library result is too large."
        case .capacity(.storageUnavailable):
            return "The library storage is temporarily unavailable."
        }
    }

    /// Alias suitable for presentation layers that use the domain error vocabulary.
    public var userMessage: String { failureReason }

    /// A stable, non-sensitive code suitable for diagnostics and telemetry.
    public var diagnosticCode: String {
        switch self {
        case .query(.invalidPageSize): return "library.query.invalid_page_size"
        case .query(.invalidCursor): return "library.query.invalid_cursor"
        case .query(.expiredCursor): return "library.query.expired_cursor"
        case .query(.emptySearchText): return "library.query.empty_search"
        case .query(.unsupportedSort): return "library.query.unsupported_sort"
        case .constraint(.emptyTransaction): return "library.constraint.empty_transaction"
        case .constraint(.invalidIdempotencyKey): return "library.constraint.invalid_idempotency_key"
        case .constraint(.invalidPlaylistName): return "library.constraint.invalid_playlist_name"
        case .constraint(.invalidPlaylistPosition): return "library.constraint.invalid_playlist_position"
        case .constraint(.duplicatePlaylistMember): return "library.constraint.duplicate_playlist_member"
        case .constraint(.danglingReference): return "library.constraint.dangling_reference"
        case .constraint(.duplicateMutation): return "library.constraint.duplicate_mutation"
        case .constraint(.invalidStatisticsDelta): return "library.constraint.invalid_statistics_delta"
        case .conflict(.revisionMismatch): return "library.conflict.revision_mismatch"
        case .conflict(.transactionAlreadyApplied): return "library.conflict.transaction_already_applied"
        case .conflict(.transactionInProgress): return "library.conflict.transaction_in_progress"
        case .migration(.required): return "library.migration.required"
        case .migration(.failed): return "library.migration.failed"
        case .capacity(.pageLimitExceeded): return "library.capacity.page_limit_exceeded"
        case .capacity(.resultTooLarge): return "library.capacity.result_too_large"
        case .capacity(.storageUnavailable): return "library.capacity.storage_unavailable"
        }
    }

    /// A redacted diagnostic context; repository implementations may attach richer IDs.
    public var diagnosticContext: DiagnosticContext? {
        DiagnosticContext(code: diagnosticCode, operation: "library.repository")
    }

    public var errorDescription: String? { failureReason }
}
