import AppServices
import Foundation

@available(macOS 13.0, iOS 16.0, *)
public final class UserDefaultsOnlineDownloadQueueStore: OnlineDownloadQueueStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String

    public init(
        suiteName: String = PreferencesConfiguration.defaultSuiteName,
        key: String = PreferencesConfiguration.onlineDownloadQueueKey
    ) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PreferencesError.unavailableSuite
        }
        self.defaults = defaults
        self.key = key
    }

    public func load() -> OnlineDownloadQueuePersistenceState? {
        withLock {
            guard let data = defaults.data(forKey: key),
                  let state = try? JSONDecoder().decode(
                      OnlineDownloadQueuePersistenceState.self,
                      from: data
                  ),
                  state.schemaVersion == OnlineDownloadQueuePersistenceState.currentSchemaVersion
            else {
                return nil
            }
            return state
        }
    }

    public func save(_ state: OnlineDownloadQueuePersistenceState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        withLock {
            defaults.set(data, forKey: key)
        }
    }

    /// Test and migration support. Queue cancellation does not call this;
    /// completed history and redacted failures intentionally survive restart.
    public func clear() {
        withLock {
            defaults.removeObject(forKey: key)
        }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
