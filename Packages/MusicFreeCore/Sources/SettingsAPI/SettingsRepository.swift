import Foundation

/// Persistence boundary for user settings.
///
/// Implementations must serialize load, save, and reset. `changes()` is a hot
/// stream with no initial emission: each active subscriber receives one current
/// settings value after each successful commit that changes the aggregate. A
/// failed commit emits nothing, and saving an equal value emits nothing.
@available(macOS 13.0, iOS 16.0, *)
public protocol SettingsRepository: Sendable {
    /// Returns current-schema settings, or `AppSettings.defaults` when empty.
    /// Supported legacy payloads are upgraded in memory before returning.
    func load() async throws -> AppSettings

    /// Validates and commits settings before publishing one change event.
    func save(_ settings: AppSettings) async throws

    /// Commits `AppSettings.defaults` and publishes it when it changes the value.
    func reset() async throws

    /// Observes successful, value-changing commits without emitting an initial value.
    func changes() -> AsyncStream<AppSettings>
}
