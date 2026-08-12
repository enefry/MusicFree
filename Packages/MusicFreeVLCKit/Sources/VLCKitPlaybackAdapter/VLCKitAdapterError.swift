import Foundation
import PlaybackAPI

/// Configuration and lifecycle failures owned by the VLCKit adapter.
///
/// Error values intentionally contain only stable field names and diagnostic
/// codes. URLs, header values, paths, and raw libVLC messages never cross the
/// adapter boundary.
public enum VLCKitAdapterError: Error, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case invalidConfiguration(field: String)
  case invalidOption(field: String)
  case binaryUnavailable
  case invalidResource
  case expiredResource
  case unsupportedHeader(name: String)
  case invalidHeader(name: String)
  case mediaCreationFailed
  case parserFailed
  case parserTimedOut
  case cancelled
  case engineFailure(code: String)

  public var diagnosticCode: String {
    switch self {
    case .invalidConfiguration:
      return "invalid_configuration"
    case .invalidOption:
      return "invalid_option"
    case .binaryUnavailable:
      return "binary_unavailable"
    case .invalidResource:
      return "invalid_resource"
    case .expiredResource:
      return "expired_resource"
    case .unsupportedHeader:
      return "unsupported_header"
    case .invalidHeader:
      return "invalid_header"
    case .mediaCreationFailed:
      return "media_creation_failed"
    case .parserFailed:
      return "parser_failed"
    case .parserTimedOut:
      return "parser_timed_out"
    case .cancelled:
      return "cancelled"
    case .engineFailure:
      return "engine_failure"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration, .invalidOption:
      return "The VLCKit adapter configuration is invalid."
    case .binaryUnavailable:
      return "The VLCKit binary is not linked into this target."
    case .invalidResource, .expiredResource:
      return "The playback resource is invalid or expired."
    case .unsupportedHeader:
      return "The playback resource contains an unsupported header."
    case .invalidHeader:
      return "The playback resource contains an invalid header."
    case .mediaCreationFailed:
      return "VLCKit could not create the media resource."
    case .parserFailed:
      return "VLCKit could not parse the media resource."
    case .parserTimedOut:
      return "VLCKit media parsing timed out."
    case .cancelled:
      return "The VLCKit operation was cancelled."
    case .engineFailure:
      return "VLCKit could not complete the playback operation."
    }
  }

  public var isCancellation: Bool {
    self == .cancelled
  }

  public var description: String {
    "VLCKitAdapterError(\(diagnosticCode))"
  }
}

internal enum VLCPlaybackErrorMapper {
  static func playbackError(from error: Error) -> PlaybackError {
    if let playbackError = error as? PlaybackError {
      return playbackError
    }
    if error is CancellationError {
      return .cancelled
    }
    if let adapterError = error as? VLCKitAdapterError {
      switch adapterError {
      case .cancelled:
        return .cancelled
      case .invalidResource, .expiredResource, .mediaCreationFailed:
        return .resourceUnavailable
      case .unsupportedHeader, .invalidHeader, .invalidConfiguration,
        .invalidOption:
        return .engineFailure(code: adapterError.diagnosticCode)
      case .binaryUnavailable, .parserFailed, .parserTimedOut,
        .engineFailure:
        return .engineFailure(code: adapterError.diagnosticCode)
      }
    }
    return .unknown(code: "vlckit_unknown")
  }

  static func adapterError(from error: Error) -> VLCKitAdapterError {
    if let adapterError = error as? VLCKitAdapterError {
      return adapterError
    }
    if error is CancellationError {
      return .cancelled
    }
    if let playbackError = error as? PlaybackError {
      return .engineFailure(code: playbackError.diagnosticCode)
    }
    return .engineFailure(code: "unknown")
  }
}
