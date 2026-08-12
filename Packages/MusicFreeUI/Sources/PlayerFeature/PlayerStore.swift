import AppServices

/// A small main-actor store useful for previews, tests and composition roots.
/// Production AppServices can conform its playback facade to PlaybackServing
/// without exposing repositories or engine objects to the feature.
@MainActor
public final class PlayerStore: PlaybackServing {
  public private(set) var snapshot: PlaybackSessionSnapshot

  private let commandHandler: @MainActor (PlaybackSessionCommand) async -> Void
  private var streamContinuation: AsyncStream<PlaybackSessionSnapshot>.Continuation?

  public init(
    snapshot: PlaybackSessionSnapshot = .init(),
    commandHandler: @escaping @MainActor (PlaybackSessionCommand) async -> Void = { _ in }
  ) {
    self.snapshot = snapshot
    self.commandHandler = commandHandler
  }

  public func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
    streamContinuation?.finish()

    let stream = AsyncStream<PlaybackSessionSnapshot> { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }

      self.streamContinuation = continuation
      continuation.yield(self.snapshot)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.streamContinuation = nil
        }
      }
    }
    return stream
  }

  public func send(_ command: PlaybackSessionCommand) async {
    await commandHandler(command)
  }

  /// Publishes a value returned by an application service or a test double.
  public func publish(_ snapshot: PlaybackSessionSnapshot) {
    self.snapshot = snapshot
    streamContinuation?.yield(snapshot)
  }
}
