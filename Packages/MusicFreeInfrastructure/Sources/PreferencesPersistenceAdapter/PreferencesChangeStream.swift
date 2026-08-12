import Foundation
import SettingsAPI

@available(macOS 13.0, iOS 16.0, *)
internal final class PreferencesChangeStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    func makeStream() -> AsyncStream<AppSettings> {
        let subscriptionID = UUID()

        return AsyncStream { [weak self] continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeSubscription(subscriptionID)
            }

            guard let self else {
                continuation.finish()
                return
            }

            self.lock.lock()
            self.continuations[subscriptionID] = continuation
            self.lock.unlock()
        }
    }

    func publish(_ settings: AppSettings) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(settings)
        }
    }

    private func removeSubscription(_ subscriptionID: UUID) {
        lock.lock()
        continuations.removeValue(forKey: subscriptionID)
        lock.unlock()
    }
}
