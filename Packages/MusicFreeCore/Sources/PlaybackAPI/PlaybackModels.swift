import Foundation
import MusicDomain

/// Identifies one logical playback session. A new prepare operation must use
/// a newer generation so late adapter events can be discarded safely.
public struct PlaybackGeneration: RawRepresentable, Codable, Hashable, Comparable,
  Sendable, CustomStringConvertible
{
  public let rawValue: UInt64

  public static let initial = Self(rawValue: 0)

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: UInt64) {
    self.init(rawValue: rawValue)
  }

  /// Returns the next generation without wrapping around.
  public func advanced() -> Self {
    precondition(rawValue < UInt64.max, "PlaybackGeneration cannot overflow")
    return Self(rawValue: rawValue + 1)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    "PlaybackGeneration(\(rawValue))"
  }
}

/// The normalized lifecycle phase of the current playback session.
public enum PlaybackPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case idle
  case preparing
  case buffering
  case playing
  case paused
  case stopped
  case failed
}

/// A value snapshot of the current engine session.
public struct PlaybackState: Codable, Equatable, Hashable, Sendable {
  public let phase: PlaybackPhase
  public let generation: PlaybackGeneration
  public let itemID: MediaItemID?
  public let position: Duration
  public let duration: Duration?
  public let error: PlaybackError?

  public init(
    phase: PlaybackPhase,
    generation: PlaybackGeneration,
    itemID: MediaItemID? = nil,
    position: Duration = .zero,
    duration: Duration? = nil,
    error: PlaybackError? = nil
  ) {
    precondition(position >= .zero, "PlaybackState.position cannot be negative")
    if let duration {
      precondition(duration >= .zero, "PlaybackState.duration cannot be negative")
    }

    self.phase = phase
    self.generation = generation
    self.itemID = itemID
    self.position = position
    self.duration = duration
    self.error = error
  }

  public static let idle = Self(
    phase: .idle,
    generation: .initial
  )

  /// Compatibility spelling for clients that use media terminology.
  public var length: Duration? {
    duration
  }
}

/// Events emitted by a playback engine. Every event belongs to a generation;
/// errors and terminal events also identify the item that produced them.
public enum PlaybackEvent: Codable, Equatable, Hashable, Sendable {
  case phaseChanged(
    generation: PlaybackGeneration,
    itemID: MediaItemID?,
    phase: PlaybackPhase
  )
  case positionChanged(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    position: Duration,
    duration: Duration?
  )
  case ended(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    reason: PlaybackCompletionReason
  )
  case failed(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    error: PlaybackError
  )

  public var generation: PlaybackGeneration {
    switch self {
    case .phaseChanged(let generation, _, _),
      .positionChanged(let generation, _, _, _),
      .ended(let generation, _, _),
      .failed(let generation, _, _):
      return generation
    }
  }

  public var itemID: MediaItemID? {
    switch self {
    case .phaseChanged(_, let itemID, _):
      return itemID
    case .positionChanged(_, let itemID, _, _),
      .ended(_, let itemID, _),
      .failed(_, let itemID, _):
      return itemID
    }
  }

  public var isTerminal: Bool {
    switch self {
    case .ended, .failed:
      return true
    case .phaseChanged, .positionChanged:
      return false
    }
  }
}
