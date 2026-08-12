import AppServices
import PlaybackAPI

/// Compatibility spelling for the AppServices-owned software output boundary.
/// Production composition roots should inject `PlaybackAudioServing`; keeping
/// the alias preserves the package's preview/test API.
public typealias PlayerAudioServing = PlaybackAudioServing

@MainActor
public final class PlayerAudioStore: PlaybackAudioServing {
  public private(set) var volume: Float
  public private(set) var isMuted: Bool

  public init(volume: Float = 1, isMuted: Bool = false) {
    precondition(volume.isFinite && (0...1).contains(volume), "PlayerAudioStore.volume must be in 0...1")
    self.volume = volume
    self.isMuted = isMuted
  }

  public func setVolume(_ volume: Float) async {
    self.volume = min(max(volume, 0), 1)
  }

  public func setMuted(_ isMuted: Bool) async {
    self.isMuted = isMuted
  }
}

/// The coarse state used to choose loading, failure and unsupported UI.
public enum PlayerPresentationState: Equatable, Sendable {
  case empty
  case loading
  case buffering
  case playing
  case paused
  case stopped
  case failed(PlaybackError)
  case unsupported(PlaybackCapabilities)
}

/// Compatibility marker retained after the initial empty module shell.
public enum PlayerFeatureModule {}
