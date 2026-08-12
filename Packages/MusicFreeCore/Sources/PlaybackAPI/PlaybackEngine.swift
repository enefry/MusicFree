import Foundation

/// Controls one current resource. Queue progression, persistence, and
/// repeat/shuffle policy remain owned by AppServices.
@MainActor
public protocol PlaybackEngine: AnyObject {
  var capabilities: PlaybackCapabilities { get }
  var equalizerDescriptor: EqualizerDescriptor? { get }
  var state: PlaybackState { get }

  /// A coordinator owns the one active subscription. Implementations must
  /// finish the stream when the engine is disposed or the subscription ends.
  func makeEventStream() -> AsyncStream<PlaybackEvent>

  /// Success means the resource entered the engine's playable lifecycle; it
  /// does not promise that audio output has started.
  func prepare(_ item: PlaybackItem, startAt: Duration?) async throws
  func play() throws
  func pause()
  func stop()
  func seek(to position: Duration) async throws
  func setRate(_ rate: Float) throws
  func apply(_ effects: AudioEffectConfiguration) throws

  /// Releases the engine-owned event stream and current media resources.
  /// The default implementation keeps lightweight test engines source
  /// compatible while concrete adapters can release framework objects.
  func dispose()
}

public extension PlaybackEngine {
  var equalizerDescriptor: EqualizerDescriptor? { nil }
  func dispose() {}
}

/// Optional output controls implemented by engines that own a software
/// volume/mute stage. The normalized range keeps Feature and AppServices
/// independent from a backend's native scalar (libVLC uses 0...200).
@MainActor
public protocol PlaybackAudioControlling: AnyObject {
  var volume: Float { get }
  var isMuted: Bool { get }
  func setVolume(_ volume: Float) throws
  func setMuted(_ isMuted: Bool) throws
}
