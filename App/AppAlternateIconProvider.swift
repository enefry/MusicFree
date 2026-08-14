import SettingsFeature
import UIKit

@MainActor
final class AppAlternateIconProvider: SettingsAppIconProviding {
    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    var alternateIconName: String? {
        UIApplication.shared.alternateIconName
    }

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            UIApplication.shared.setAlternateIconName(alternateIconName) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
