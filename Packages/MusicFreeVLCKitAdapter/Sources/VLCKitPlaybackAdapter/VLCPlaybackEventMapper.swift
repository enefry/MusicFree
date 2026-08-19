import Foundation
import MusicDomain
import PlaybackAPI

internal enum VLCPlaybackStateCode {
  static let nothingSpecial = 0
  static let opening = 1
  static let playing = 2
  static let paused = 3
  static let stopped = 4
  static let stopping = 5
  static let error = 6
}

internal enum VLCPlaybackDelegateEvent: Equatable, Sendable {
  case state(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    code: Int
  )
  case buffering(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    progress: Float
  )
  case time(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    positionMilliseconds: Int64?,
    durationMilliseconds: Int64?
  )
}

internal enum VLCPlaybackEventMapper {
  static func phase(for stateCode: Int) -> PlaybackPhase? {
    switch stateCode {
    case VLCPlaybackStateCode.nothingSpecial:
      return .idle
    case VLCPlaybackStateCode.opening:
      return .preparing
    case VLCPlaybackStateCode.playing:
      return .playing
    case VLCPlaybackStateCode.paused:
      return .paused
    case VLCPlaybackStateCode.stopped, VLCPlaybackStateCode.stopping:
      return .stopped
    case VLCPlaybackStateCode.error:
      return .failed
    default:
      return nil
    }
  }

  static func events(
    for event: VLCPlaybackDelegateEvent,
    stopWasRequested: Bool,
    playbackStarted: Bool
  ) -> [PlaybackEvent] {
    switch event {
    case .state(let generation, let itemID, let code):
      guard let phase = phase(for: code) else {
        return []
      }
      var mapped: [PlaybackEvent] = [
        .phaseChanged(generation: generation, itemID: itemID, phase: phase)
      ]
      if code == VLCPlaybackStateCode.error {
        mapped.append(
          .failed(
            generation: generation,
            itemID: itemID,
            error: .engineFailure(code: "vlc_error")
          )
        )
      } else if (code == VLCPlaybackStateCode.stopping
                 || code == VLCPlaybackStateCode.stopped),
                !stopWasRequested,
                playbackStarted
      {
        mapped.append(
          .ended(
            generation: generation,
            itemID: itemID,
            reason: .ended
          )
        )
      }
      return mapped
    case .buffering(let generation, let itemID, let progress):
      guard progress.isFinite, progress >= 0 else {
        return []
      }
      return [
        .phaseChanged(
          generation: generation,
          itemID: itemID,
          phase: progress < 1 ? .buffering : .playing
        )
      ]
    case .time(
      let generation,
      let itemID,
      let positionMilliseconds,
      let durationMilliseconds
    ):
      guard let position = durationFromMilliseconds(positionMilliseconds), position >= .zero else {
        return []
      }
      return [
        .positionChanged(
          generation: generation,
          itemID: itemID,
          position: position,
          duration: durationFromMilliseconds(durationMilliseconds)
        )
      ]
    }
  }

  static func accepts(
    _ event: VLCPlaybackDelegateEvent,
    currentGeneration: PlaybackGeneration,
    currentItemID: MediaItemID?
  ) -> Bool {
    let eventGeneration: PlaybackGeneration
    let eventItemID: MediaItemID
    switch event {
    case .state(let generation, let itemID, _),
      .buffering(let generation, let itemID, _),
      .time(let generation, let itemID, _, _):
      eventGeneration = generation
      eventItemID = itemID
    }
    return eventGeneration == currentGeneration && eventItemID == currentItemID
  }

  static func durationFromMilliseconds(_ milliseconds: Int64?) -> Duration? {
    guard let milliseconds, milliseconds >= 0 else {
      return nil
    }
    return .milliseconds(milliseconds)
  }
}
