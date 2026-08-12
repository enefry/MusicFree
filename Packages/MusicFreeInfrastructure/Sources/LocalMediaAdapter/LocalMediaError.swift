import Foundation
import MediaSourceAPI
import MusicDomain

/// Configuration failures that can be reported without exposing a filesystem path.
public enum LocalMediaConfigurationError: Error, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case rootMustBeFileURL
  case rootMustBeAbsolute
  case rootsOverlap
  case invalidEnumerationLimit
  case invalidFileSizeLimit

  public var diagnosticCode: String {
    switch self {
    case .rootMustBeFileURL: return "root_must_be_file_url"
    case .rootMustBeAbsolute: return "root_must_be_absolute"
    case .rootsOverlap: return "roots_overlap"
    case .invalidEnumerationLimit: return "invalid_enumeration_limit"
    case .invalidFileSizeLimit: return "invalid_file_size_limit"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .rootMustBeFileURL, .rootMustBeAbsolute:
      return "The local media storage roots are invalid."
    case .rootsOverlap:
      return "The local media storage roots must be separate."
    case .invalidEnumerationLimit:
      return "The local media enumeration limits are invalid."
    case .invalidFileSizeLimit:
      return "The local media file size limit is invalid."
    }
  }

  public var description: String { diagnosticCode }
}

/// Errors specific to the managed local-media implementation.
public enum LocalMediaError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
  case invalidConfiguration(LocalMediaConfigurationError)
  case inaccessibleInput
  case securityScopeUnavailable
  case bookmarkResolutionFailed
  case enumerationFailed
  case enumerationLimitExceeded
  case unsupportedInput
  case fileTooLarge
  case invalidItemID
  case itemNotFound
  case rootContainmentViolation
  case invalidRelativePath
  case destinationConflict
  case unknownTransaction
  case alreadyCommitted
  case alreadyRolledBack
  case invalidRemovalState
  case moveFailed
  case deleteFailed
  case restoreConflict
  case copyFailed
  case insufficientStorage
  case hashingFailed
  case probeFailed
  case metadataFailed
  case persistenceFailed
  case recoveryFailed
  case duplicate
  case cancelled

  public var isRetryable: Bool {
    switch self {
    case .inaccessibleInput, .enumerationFailed, .copyFailed, .insufficientStorage,
      .hashingFailed, .probeFailed, .metadataFailed, .persistenceFailed, .recoveryFailed:
      return true
    case .invalidConfiguration, .securityScopeUnavailable, .bookmarkResolutionFailed,
      .enumerationLimitExceeded, .unsupportedInput, .fileTooLarge, .invalidItemID,
      .itemNotFound, .rootContainmentViolation, .invalidRelativePath, .destinationConflict,
      .unknownTransaction, .alreadyCommitted, .alreadyRolledBack, .invalidRemovalState,
      .restoreConflict, .duplicate, .cancelled:
      return false
    case .moveFailed, .deleteFailed:
      return true
    }
  }

  public var isCancellation: Bool {
    self == .cancelled
  }

  public var diagnosticCode: String {
    switch self {
    case .invalidConfiguration(let error): return "invalid_configuration_\(error.diagnosticCode)"
    case .inaccessibleInput: return "inaccessible_input"
    case .securityScopeUnavailable: return "security_scope_unavailable"
    case .bookmarkResolutionFailed: return "bookmark_resolution_failed"
    case .enumerationFailed: return "enumeration_failed"
    case .enumerationLimitExceeded: return "enumeration_limit_exceeded"
    case .unsupportedInput: return "unsupported_input"
    case .fileTooLarge: return "file_too_large"
    case .invalidItemID: return "invalid_item_id"
    case .itemNotFound: return "item_not_found"
    case .rootContainmentViolation: return "root_containment_violation"
    case .invalidRelativePath: return "invalid_relative_path"
    case .destinationConflict: return "destination_conflict"
    case .unknownTransaction: return "unknown_transaction"
    case .alreadyCommitted: return "already_committed"
    case .alreadyRolledBack: return "already_rolled_back"
    case .invalidRemovalState: return "invalid_removal_state"
    case .moveFailed: return "move_failed"
    case .deleteFailed: return "delete_failed"
    case .restoreConflict: return "restore_conflict"
    case .copyFailed: return "copy_failed"
    case .insufficientStorage: return "insufficient_storage"
    case .hashingFailed: return "hashing_failed"
    case .probeFailed: return "probe_failed"
    case .metadataFailed: return "metadata_failed"
    case .persistenceFailed: return "persistence_failed"
    case .recoveryFailed: return "recovery_failed"
    case .duplicate: return "duplicate"
    case .cancelled: return "cancelled"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .invalidConfiguration: return "The local media storage configuration is invalid."
    case .inaccessibleInput: return "The selected media could not be accessed."
    case .securityScopeUnavailable: return "The selected media authorization is unavailable."
    case .bookmarkResolutionFailed: return "The selected media authorization could not be restored."
    case .enumerationFailed: return "The selected folder could not be read."
    case .enumerationLimitExceeded: return "The selected folder contains too many media files."
    case .unsupportedInput: return "The selected input is not a regular media file."
    case .fileTooLarge: return "The selected media file is too large."
    case .invalidItemID: return "The media identifier is invalid."
    case .itemNotFound: return "The managed media could not be found."
    case .rootContainmentViolation, .invalidRelativePath:
      return "The managed media location is invalid."
    case .destinationConflict: return "The managed media destination is already occupied."
    case .unknownTransaction: return "The removal transaction is unknown."
    case .alreadyCommitted: return "The removal has already been committed."
    case .alreadyRolledBack: return "The removal has already been rolled back."
    case .invalidRemovalState: return "The removal transaction is not valid."
    case .moveFailed: return "The managed media could not be moved."
    case .deleteFailed: return "The managed media could not be deleted."
    case .restoreConflict: return "The original managed media location is occupied."
    case .copyFailed: return "The media could not be copied into managed storage."
    case .insufficientStorage: return "There is not enough storage for the media operation."
    case .hashingFailed: return "The media fingerprint could not be calculated."
    case .probeFailed: return "The media could not be inspected."
    case .metadataFailed: return "The media metadata could not be read."
    case .persistenceFailed: return "The library record could not be saved."
    case .recoveryFailed: return "The managed media recovery state could not be updated."
    case .duplicate: return "The media is already in the library."
    case .cancelled: return "The media operation was cancelled."
    }
  }

  public var errorDescription: String? { userFacingReason }

  public var description: String { diagnosticCode }
}

extension LocalMediaError {
  var importError: MediaImportError {
    switch self {
    case .invalidConfiguration, .invalidItemID, .invalidRelativePath:
      return .invalidRequest
    case .inaccessibleInput, .securityScopeUnavailable, .enumerationFailed:
      return .inaccessibleInput
    case .bookmarkResolutionFailed:
      return .inaccessibleInput
    case .enumerationLimitExceeded, .unsupportedInput, .fileTooLarge:
      return .unsupportedFormat
    case .destinationConflict, .copyFailed:
      return .copyFailed
    case .unknownTransaction, .alreadyCommitted, .alreadyRolledBack, .invalidRemovalState,
      .moveFailed, .deleteFailed, .restoreConflict:
      return .copyFailed
    case .insufficientStorage:
      return .insufficientStorage
    case .hashingFailed:
      return .hashingFailed
    case .probeFailed:
      return .corruptedMedia
    case .metadataFailed:
      return .corruptedMedia
    case .persistenceFailed, .recoveryFailed:
      return .persistenceFailed
    case .rootContainmentViolation, .itemNotFound:
      return .copyFailed
    case .duplicate:
      return .duplicate
    case .cancelled:
      return .cancelled
    }
  }
}

/// A resolved security-scoped bookmark and its stale-state signal.
public struct LocalMediaBookmarkResolution: Sendable {
  public let url: URL
  public let isStale: Bool

  public init(url: URL, isStale: Bool) {
    self.url = url
    self.isStale = isStale
  }
}

/// A bookmark value that can be persisted by the application layer.
public struct LocalMediaBookmark: Codable, Equatable, Sendable {
  public let data: Data

  public init(data: Data) throws {
    guard !data.isEmpty else {
      throw LocalMediaError.bookmarkResolutionFailed
    }
    self.data = data
  }

  @available(macOS 10.15, iOS 13.0, *)
  public static func make(for url: URL) throws -> Self {
    guard url.isFileURL else {
      throw LocalMediaError.bookmarkResolutionFailed
    }
#if os(iOS) || os(macOS)
    do {
      #if os(macOS) || targetEnvironment(macCatalyst)
      let options: URL.BookmarkCreationOptions = [.withSecurityScope]
      #else
      // iOS bookmarks carry an implicit security scope by default; the
      // explicit creation option is unavailable on iOS.
      let options: URL.BookmarkCreationOptions = []
      #endif
      let data = try url.bookmarkData(
        options: options,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return try Self(data: data)
    } catch {
      throw LocalMediaError.bookmarkResolutionFailed
    }
#else
    throw LocalMediaError.bookmarkResolutionFailed
#endif
  }

  @available(macOS 10.15, iOS 13.0, *)
  public func resolve() throws -> LocalMediaBookmarkResolution {
#if os(iOS) || os(macOS)
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      return LocalMediaBookmarkResolution(url: url, isStale: isStale)
    } catch {
      throw LocalMediaError.bookmarkResolutionFailed
    }
#else
    throw LocalMediaError.bookmarkResolutionFailed
#endif
  }
}

/// Compatibility marker retained in a real module source file for the
/// existing package graph test.
public enum LocalMediaAdapterModule {}

/// Construction-time limits and roots for the managed local source.
public struct LocalMediaConfiguration: Equatable, Sendable {
  public let managedRoot: URL
  public let stagingRoot: URL
  public let quarantineRoot: URL
  public let maximumDepth: Int
  public let maximumFileCount: Int
  public let maximumFileSize: Int64?
  public let duplicatePolicy: MediaImportDuplicatePolicy

  public init(
    managedRoot: URL,
    stagingRoot: URL,
    quarantineRoot: URL,
    maximumDepth: Int = 32,
    maximumFileCount: Int = 10_000,
    maximumFileSize: Int64? = nil,
    duplicatePolicy: MediaImportDuplicatePolicy = .skip
  ) throws {
    let managedRoot = try Self.normalizedRoot(managedRoot)
    let stagingRoot = try Self.normalizedRoot(stagingRoot)
    let quarantineRoot = try Self.normalizedRoot(quarantineRoot)

    guard maximumDepth >= 0, maximumFileCount > 0 else {
      throw LocalMediaError.invalidConfiguration(.invalidEnumerationLimit)
    }
    if let maximumFileSize, maximumFileSize <= 0 {
      throw LocalMediaError.invalidConfiguration(.invalidFileSizeLimit)
    }
    guard !Self.contains(managedRoot, stagingRoot),
          !Self.contains(stagingRoot, managedRoot),
          !Self.contains(managedRoot, quarantineRoot),
          !Self.contains(quarantineRoot, managedRoot),
          !Self.contains(stagingRoot, quarantineRoot),
          !Self.contains(quarantineRoot, stagingRoot)
    else {
      throw LocalMediaError.invalidConfiguration(.rootsOverlap)
    }

    self.managedRoot = managedRoot
    self.stagingRoot = stagingRoot
    self.quarantineRoot = quarantineRoot
    self.maximumDepth = maximumDepth
    self.maximumFileCount = maximumFileCount
    self.maximumFileSize = maximumFileSize
    self.duplicatePolicy = duplicatePolicy
  }

  private static func normalizedRoot(_ url: URL) throws -> URL {
    guard url.isFileURL else {
      throw LocalMediaError.invalidConfiguration(.rootMustBeFileURL)
    }
    let normalized = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    guard normalized.path.hasPrefix("/") else {
      throw LocalMediaError.invalidConfiguration(.rootMustBeAbsolute)
    }
    return normalized
  }

  private static func contains(_ root: URL, _ candidate: URL) -> Bool {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }
}
