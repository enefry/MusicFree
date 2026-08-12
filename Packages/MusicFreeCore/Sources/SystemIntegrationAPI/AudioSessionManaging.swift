import Foundation

/// Coordinates the app's audio session without exposing a platform framework.
@MainActor
public protocol AudioSessionManaging: AnyObject {
    /// Applies the adapter's playback configuration before activation.
    func configureForPlayback() throws

    /// Activates the session and starts receiving system audio events.
    func activate() async throws

    /// Deactivates the session. Adapters must make this operation idempotent.
    func deactivate() async

    /// Returns the lifecycle stream owned by the adapter.
    ///
    /// The stream must finish when its consumer is cancelled or when the
    /// adapter is torn down. A second active subscription is an adapter
    /// lifecycle error rather than a second event tap.
    func makeEventStream() -> AsyncStream<AudioSessionEvent>
}
