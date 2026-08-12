import Foundation

/// Configuration failures that prevent the preferences adapter from opening.
///
/// Persisted-operation failures use the `SettingsError` contract from
/// `SettingsAPI`. These configuration cases intentionally do not include the
/// suite or key, so diagnostics cannot disclose storage identifiers.
public enum PreferencesError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidSuiteName
    case invalidKey
    case unavailableSuite

    public var description: String {
        switch self {
        case .invalidSuiteName:
            return "PreferencesError.invalidSuiteName"
        case .invalidKey:
            return "PreferencesError.invalidKey"
        case .unavailableSuite:
            return "PreferencesError.unavailableSuite"
        }
    }
}
