import Foundation

/// Explicit configuration for the preferences store.
public struct PreferencesConfiguration: Equatable, Sendable {
    public enum Codec: String, Equatable, Sendable {
        case json
    }

    public enum DiagnosticPolicy: String, Equatable, Sendable {
        /// The adapter does not log persisted values or raw payloads.
        case silent
    }

    public static let defaultSuiteName = "com.musicfree.preferences"
    public static let defaultKey = "com.musicfree.app-settings"

    /// The production configuration. Tests should provide a unique suite.
    public static let `default` = Self(
        uncheckedSuiteName: Self.defaultSuiteName,
        uncheckedKey: Self.defaultKey,
        codec: .json,
        diagnosticPolicy: .silent
    )

    public let suiteName: String
    public let key: String
    public let codec: Codec
    public let diagnosticPolicy: DiagnosticPolicy

    public init(
        suiteName: String = PreferencesConfiguration.defaultSuiteName,
        key: String = PreferencesConfiguration.defaultKey,
        codec: Codec = .json,
        diagnosticPolicy: DiagnosticPolicy = .silent
    ) throws {
        guard !suiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PreferencesError.invalidSuiteName
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PreferencesError.invalidKey
        }

        self.suiteName = suiteName
        self.key = key
        self.codec = codec
        self.diagnosticPolicy = diagnosticPolicy
    }

    private init(
        uncheckedSuiteName suiteName: String,
        uncheckedKey key: String,
        codec: Codec,
        diagnosticPolicy: DiagnosticPolicy
    ) {
        self.suiteName = suiteName
        self.key = key
        self.codec = codec
        self.diagnosticPolicy = diagnosticPolicy
    }
}

/// Compatibility marker retained in a real module source file for the
/// existing package graph test. The standalone marker file is removed once
/// the adapter has real interfaces.
public enum PreferencesPersistenceAdapterModule {}
