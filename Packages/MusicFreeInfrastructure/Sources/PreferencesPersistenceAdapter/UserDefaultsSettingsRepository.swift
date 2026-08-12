import Foundation
import SettingsAPI

@available(macOS 13.0, iOS 16.0, *)
public final class UserDefaultsSettingsRepository: SettingsRepository, @unchecked Sendable {
    private let storage: PreferencesStorage

    public init(configuration: PreferencesConfiguration = .default) throws {
        self.storage = try PreferencesStorage(configuration: configuration)
    }

    public convenience init(
        suiteName: String,
        key: String = PreferencesConfiguration.defaultKey
    ) throws {
        try self.init(configuration: PreferencesConfiguration(suiteName: suiteName, key: key))
    }

    public func load() async throws -> AppSettings {
        try storage.load()
    }

    public func save(_ settings: AppSettings) async throws {
        try storage.save(settings)
    }

    public func reset() async throws {
        try storage.reset()
    }

    public func changes() -> AsyncStream<AppSettings> {
        storage.changes()
    }
}

private final class PreferencesStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private let changeStream = PreferencesChangeStream()

    init(configuration: PreferencesConfiguration) throws {
        guard let defaults = UserDefaults(suiteName: configuration.suiteName) else {
            throw PreferencesError.unavailableSuite
        }

        self.defaults = defaults
        self.key = configuration.key
    }

    func load() throws -> AppSettings {
        try withLock {
            guard let data = defaults.data(forKey: key) else {
                return .defaults
            }
            return try SettingsMigration.decode(data)
        }
    }

    func save(_ settings: AppSettings) throws {
        let validated = try settings.validated()
        let encoded: Data
        do {
            encoded = try SettingsMigration.encode(validated)
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.writeFailed
        }

        try withLock {
            let previous = try currentValueForSave()
            guard previous != validated else {
                return
            }
            try commit(
                encoded,
                value: validated,
                previous: previous,
                failure: .writeFailed
            )
        }
    }

    func reset() throws {
        let defaultsValue = AppSettings.defaults
        let encoded: Data
        do {
            encoded = try SettingsMigration.encode(defaultsValue)
        } catch {
            throw SettingsError.resetFailed
        }

        try withLock {
            let previous = currentValueForReset()
            guard previous != defaultsValue else {
                return
            }
            try commit(
                encoded,
                value: defaultsValue,
                previous: previous,
                failure: .resetFailed
            )
        }
    }

    func changes() -> AsyncStream<AppSettings> {
        changeStream.makeStream()
    }

    private func currentValueForSave() throws -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        // Saving over unreadable data would silently discard the only
        // recoverable copy. Callers must choose reset() explicitly instead.
        return try SettingsMigration.decode(data)
    }

    private func currentValueForReset() -> AppSettings? {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        return try? SettingsMigration.decode(data)
    }

    private func commit(
        _ data: Data,
        value: AppSettings,
        previous: AppSettings?,
        failure: SettingsError
    ) throws {
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw failure
        }

        guard previous != value else {
            return
        }
        // The stream is driven only by this successful commit. We do not
        // subscribe to UserDefaults notifications, avoiding self-write
        // duplicates and cross-suite test noise.
        changeStream.publish(value)
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
