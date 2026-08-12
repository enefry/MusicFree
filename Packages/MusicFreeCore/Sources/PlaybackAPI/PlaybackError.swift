import Foundation

/// Classified failures exposed by the playback boundary.
///
/// Adapter-specific error objects, URLs, headers, and file paths must be
/// mapped to one of these cases before they cross the API boundary.
public enum PlaybackError: Error, Codable, Equatable, Hashable, Sendable,
  LocalizedError, CustomStringConvertible
{
  case unsupportedCapability(PlaybackCapabilities)
  case noCurrentItem
  case invalidState(expected: PlaybackPhase, actual: PlaybackPhase)
  case invalidPosition
  case invalidRate
  case invalidEffects
  case resourceUnavailable
  case engineFailure(code: String)
  case cancelled
  case unknown(code: String)

  public var isRetryable: Bool {
    switch self {
    case .resourceUnavailable, .engineFailure, .unknown:
      return true
    case .unsupportedCapability, .noCurrentItem, .invalidState,
      .invalidPosition, .invalidRate, .invalidEffects, .cancelled:
      return false
    }
  }

  public var isCancellation: Bool {
    if case .cancelled = self {
      return true
    }
    return false
  }

  public var diagnosticCode: String {
    switch self {
    case .unsupportedCapability:
      return "unsupported_capability"
    case .noCurrentItem:
      return "no_current_item"
    case .invalidState:
      return "invalid_state"
    case .invalidPosition:
      return "invalid_position"
    case .invalidRate:
      return "invalid_rate"
    case .invalidEffects:
      return "invalid_effects"
    case .resourceUnavailable:
      return "resource_unavailable"
    case .engineFailure:
      return "engine_failure"
    case .cancelled:
      return "cancelled"
    case .unknown:
      return "unknown"
    }
  }

  public var userFacingReason: String {
    switch self {
    case .unsupportedCapability:
      return "The playback engine does not support this capability."
    case .noCurrentItem:
      return "There is no current item to play."
    case .invalidState:
      return "The playback command is not valid in the current state."
    case .invalidPosition:
      return "The requested playback position is invalid."
    case .invalidRate:
      return "The requested playback rate is invalid."
    case .invalidEffects:
      return "The requested audio effects are invalid."
    case .resourceUnavailable:
      return "The playback resource is temporarily unavailable."
    case .engineFailure:
      return "The playback engine could not complete the operation."
    case .cancelled:
      return "Playback was cancelled."
    case .unknown:
      return "The playback operation could not be completed."
    }
  }

  public var errorDescription: String? {
    userFacingReason
  }

  /// The description intentionally omits adapter codes that may contain
  /// paths, URLs, or credentials.
  public var description: String {
    "PlaybackError(\(diagnosticCode))"
  }
}
