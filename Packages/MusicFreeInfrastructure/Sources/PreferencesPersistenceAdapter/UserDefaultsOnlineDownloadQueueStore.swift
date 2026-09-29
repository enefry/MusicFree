import AppServices
import Foundation

@available(macOS 13.0, iOS 16.0, *)
public final class UserDefaultsOnlineDownloadQueueStore: OnlineDownloadQueueStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private let writer = DispatchQueue(label: "MusicFree.OnlineDownloadQueuePersistence", qos: .utility)
    private var pendingState: OnlineDownloadQueuePersistenceState?
    private var latestState: OnlineDownloadQueuePersistenceState?
    private var isWriting = false

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
            if let latestState { return latestState }
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
        let shouldSchedule = withLock {
            pendingState = state
            latestState = state
            guard !isWriting else { return false }
            isWriting = true
            return true
        }
        if shouldSchedule { writer.async { [self] in drainWrites() } }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }

    private func drainWrites() {
        while let state = withLock({ () -> OnlineDownloadQueuePersistenceState? in
            guard let state = pendingState else { isWriting = false; return nil }
            pendingState = nil
            return state
        }) {
            guard let data = try? JSONEncoder().encode(state) else { continue }
            defaults.set(data, forKey: key)
        }
    }

    /// Test and migration support. Queue cancellation does not call this;
    /// completed history and redacted failures intentionally survive restart.
    public func clear() {
        writer.sync {
            withLock { pendingState = nil; latestState = nil }
            defaults.removeObject(forKey: key)
        }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
