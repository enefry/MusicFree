import Foundation
import SettingsAPI

/// An actor-backed settings repository that preserves the hot-stream
/// contract: no initial value, one event per successful value-changing save,
/// and no event for validation or write failures.
@available(macOS 13.0, iOS 16.0, *)
public actor InMemorySettingsRepository: SettingsRepository {
    private var value: AppSettings
    private var failureScript: InMemorySettingsFailureScript
    private let changeHub: TestAsyncStreamHub<AppSettings>

    public private(set) var saveCalls: [AppSettings] = []
    public private(set) var resetCallCount = 0
    public private(set) var publishedChangeCount = 0

    public init(
        value: AppSettings = .defaults,
        failureScript: InMemorySettingsFailureScript = .init()
    ) {
        self.value = value
        self.failureScript = failureScript
        changeHub = TestAsyncStreamHub()
    }

    public func load() async throws -> AppSettings {
        if let error = failureScript.readError { throw error }
        return value
    }

    public func save(_ settings: AppSettings) async throws {
        saveCalls.append(settings)
        let validated = try settings.validated()
        if let error = failureScript.writeError { throw error }
        guard value != validated else { return }
        value = validated
        publishedChangeCount += 1
        changeHub.yield(validated)
    }

    public func reset() async throws {
        resetCallCount += 1
        if let error = failureScript.resetError { throw error }
        try await save(.defaults)
    }

    nonisolated public func changes() -> AsyncStream<AppSettings> {
        changeHub.makeStream()
    }

    public func setFailureScript(_ script: InMemorySettingsFailureScript) {
        failureScript = script
    }

    public func currentValue() -> AppSettings {
        value
    }

    public func close() {
        changeHub.finish()
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct InMemorySettingsFailureScript: Sendable {
    public var readError: SettingsError?
    public var writeError: SettingsError?
    public var resetError: SettingsError?

    public init(
        readError: SettingsError? = nil,
        writeError: SettingsError? = nil,
        resetError: SettingsError? = nil
    ) {
        self.readError = readError
        self.writeError = writeError
        self.resetError = resetError
    }
}
