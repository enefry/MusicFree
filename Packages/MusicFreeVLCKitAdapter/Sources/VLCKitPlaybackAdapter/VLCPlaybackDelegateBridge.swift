import Foundation
import MusicDomain
import PlaybackAPI

#if canImport(VLCKit)
import VLCKit

/// Converts Objective-C callbacks into Sendable scalar events before hopping
/// to the engine's MainActor. The bridge owns no playback policy.
internal final class VLCPlaybackDelegateBridge: NSObject, VLCMediaPlayerDelegate {
  private let generation: PlaybackGeneration
  private let itemID: MediaItemID
  private let handler: @MainActor @Sendable (VLCPlaybackDelegateEvent) -> Void

  init(
    generation: PlaybackGeneration,
    itemID: MediaItemID,
    handler: @escaping @MainActor @Sendable (VLCPlaybackDelegateEvent) -> Void
  ) {
    self.generation = generation
    self.itemID = itemID
    self.handler = handler
    super.init()
  }

  func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
    send(.state(generation: generation, itemID: itemID, code: newState.rawValue))
  }

  func mediaPlayerBufferingChanged(_ progress: Float) {
    send(.buffering(generation: generation, itemID: itemID, progress: progress))
  }

  func mediaPlayerLengthChanged(_ length: Int64) {
    send(
      .time(
        generation: generation,
        itemID: itemID,
        positionMilliseconds: nil,
        durationMilliseconds: length
      )
    )
  }

  func mediaPlayerTimeChanged(_ notification: Notification) {
    guard let player = notification.object as? VLCMediaPlayer else {
      return
    }
    let position = Int64(player.time.intValue)
    let duration = player.media.map { Int64($0.length.intValue) }
    send(
      .time(
        generation: generation,
        itemID: itemID,
        positionMilliseconds: position,
        durationMilliseconds: duration
      )
    )
  }

  private func send(_ event: VLCPlaybackDelegateEvent) {
    Task { @MainActor [handler] in
      handler(event)
    }
  }
}
#endif
