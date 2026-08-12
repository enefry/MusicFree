import Foundation
import MusicDomain

/// Per-item import failures are classified so a batch can continue without
/// turning an expected item failure into a stream failure.
public enum MediaImportError: Error, Codable, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case invalidRequest
  case inaccessibleInput
  case duplicate
  case unsupportedFormat
  case noDecodableAudioTrack
  case corruptedMedia
  case hashingFailed
  case copyFailed
  case insufficientStorage
  case persistenceFailed
  case cancelled
  case unknown

  public var isRetryable: Bool {
    switch self {
    case .inaccessibleInput, .hashingFailed, .copyFailed, .insufficientStorage,
      .persistenceFailed:
      return true
    case .invalidRequest, .duplicate, .unsupportedFormat, .noDecodableAudioTrack,
      .corruptedMedia, .cancelled, .unknown:
      return false
    }
  }

  public var isCancellation: Bool {
    self == .cancelled
  }

  public var diagnosticCode: String {
    switch self {
    case .invalidRequest: return "invalid_request"
    case .inaccessibleInput: return "inaccessible_input"
    case .duplicate: return "duplicate"
    case .unsupportedFormat: return "unsupported_format"
    case .noDecodableAudioTrack: return "no_decodable_audio_track"
    case .corruptedMedia: return "corrupted_media"
    case .hashingFailed: return "hashing_failed"
    case .copyFailed: return "copy_failed"
    case .insufficientStorage: return "insufficient_storage"
    case .persistenceFailed: return "persistence_failed"
    case .cancelled: return "cancelled"
    case .unknown: return "unknown"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .invalidRequest: return "The import request is invalid."
    case .inaccessibleInput: return "The selected media could not be accessed."
    case .duplicate: return "The media is already in the library."
    case .unsupportedFormat: return "The media format is not supported."
    case .noDecodableAudioTrack: return "No decodable audio track was found."
    case .corruptedMedia: return "The media appears to be damaged."
    case .hashingFailed: return "The media fingerprint could not be calculated."
    case .copyFailed: return "The media could not be copied into managed storage."
    case .insufficientStorage: return "There is not enough storage to import the media."
    case .persistenceFailed: return "The library record could not be saved."
    case .cancelled: return "The import was cancelled."
    case .unknown: return "The media could not be imported."
    }
  }

  public var errorDescription: String? {
    userFacingReason
  }

  public var description: String {
    diagnosticCode
  }
}

/// Probe failures are distinct from per-item import failures for adapter
/// diagnostics while still mapping cleanly to MediaSourceError.
public enum MediaProbeError: Error, Codable, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case noDecodableAudioTrack
  case corruptedMedia
  case unsupportedFormat
  case readFailed
  case timedOut
  case cancelled

  public var isRetryable: Bool {
    switch self {
    case .readFailed, .timedOut:
      return true
    case .noDecodableAudioTrack, .corruptedMedia, .unsupportedFormat, .cancelled:
      return false
    }
  }

  public var isCancellation: Bool {
    self == .cancelled
  }

  public var diagnosticCode: String {
    switch self {
    case .noDecodableAudioTrack: return "no_decodable_audio_track"
    case .corruptedMedia: return "corrupted_media"
    case .unsupportedFormat: return "unsupported_format"
    case .readFailed: return "read_failed"
    case .timedOut: return "timed_out"
    case .cancelled: return "cancelled"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .noDecodableAudioTrack: return "No decodable audio track was found."
    case .corruptedMedia: return "The media appears to be damaged."
    case .unsupportedFormat: return "The media format is not supported."
    case .readFailed: return "The media could not be read."
    case .timedOut: return "Media probing timed out."
    case .cancelled: return "Media probing was cancelled."
    }
  }

  public var errorDescription: String? {
    userFacingReason
  }

  public var description: String {
    diagnosticCode
  }
}

/// Errors for the recoverable managed-media removal state machine.
public enum MediaRemovalError: Error, Codable, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case unknownTransaction
  case alreadyCommitted
  case alreadyRolledBack
  case invalidState
  case moveFailed
  case deleteFailed
  case restoreConflict
  case cancelled

  public var isRetryable: Bool {
    switch self {
    case .unknownTransaction, .alreadyCommitted, .alreadyRolledBack, .invalidState,
      .restoreConflict, .cancelled:
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
    case .unknownTransaction: return "unknown_transaction"
    case .alreadyCommitted: return "already_committed"
    case .alreadyRolledBack: return "already_rolled_back"
    case .invalidState: return "invalid_state"
    case .moveFailed: return "move_failed"
    case .deleteFailed: return "delete_failed"
    case .restoreConflict: return "restore_conflict"
    case .cancelled: return "cancelled"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .unknownTransaction: return "The removal transaction is unknown."
    case .alreadyCommitted: return "The removal has already been committed."
    case .alreadyRolledBack: return "The removal has already been rolled back."
    case .invalidState: return "The removal transaction is not in a valid state."
    case .moveFailed: return "The media could not be moved to the recovery area."
    case .deleteFailed: return "The managed media could not be deleted."
    case .restoreConflict: return "The original media location is already occupied."
    case .cancelled: return "The removal was cancelled."
    }
  }

  public var errorDescription: String? {
    userFacingReason
  }

  public var description: String {
    diagnosticCode
  }
}

/// Classified errors exposed by source registries and media adapters.
public enum MediaSourceError: Error, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case sourceNotFound(MediaSourceID)
  case sourceUnavailable(MediaSourceID)
  case invalidResource
  case unsupportedCapability(String)
  case importFailed(MediaImportError)
  case probeFailed(MediaProbeError)
  case removalFailed(MediaRemovalError)
  case cancelled

  public static func unknownSource(_ sourceID: MediaSourceID) -> Self {
    .sourceNotFound(sourceID)
  }

  public var isRetryable: Bool {
    switch self {
    case .sourceNotFound, .invalidResource, .unsupportedCapability, .cancelled:
      return false
    case .sourceUnavailable:
      return true
    case .importFailed(let error):
      return error.isRetryable
    case .probeFailed(let error):
      return error.isRetryable
    case .removalFailed(let error):
      return error.isRetryable
    }
  }

  public var isCancellation: Bool {
    switch self {
    case .cancelled:
      return true
    case .importFailed(let error):
      return error.isCancellation
    case .probeFailed(let error):
      return error.isCancellation
    case .removalFailed(let error):
      return error.isCancellation
    case .sourceNotFound, .sourceUnavailable, .invalidResource, .unsupportedCapability:
      return false
    }
  }

  public var diagnosticCode: String {
    switch self {
    case .sourceNotFound: return "source_not_found"
    case .sourceUnavailable: return "source_unavailable"
    case .invalidResource: return "invalid_resource"
    case .unsupportedCapability: return "unsupported_capability"
    case .importFailed(let error): return "import_\(error.diagnosticCode)"
    case .probeFailed(let error): return "probe_\(error.diagnosticCode)"
    case .removalFailed(let error): return "removal_\(error.diagnosticCode)"
    case .cancelled: return "cancelled"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .sourceNotFound: return "The media source could not be found."
    case .sourceUnavailable: return "The media source is temporarily unavailable."
    case .invalidResource: return "The media resource is invalid."
    case .unsupportedCapability: return "The media source does not support this operation."
    case .importFailed(let error): return error.userFacingReason
    case .probeFailed(let error): return error.userFacingReason
    case .removalFailed(let error): return error.userFacingReason
    case .cancelled: return "The media operation was cancelled."
    }
  }

  public var errorDescription: String? {
    userFacingReason
  }

  public var description: String {
    diagnosticCode
  }
}
