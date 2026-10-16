#if canImport(UIKit)
import Foundation
import MusicFreePluginAPI

/// Persisted account metadata; secret values belong in the credential store.
public struct PluginSettingsSourceRecord: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let isEnabled: Bool
    public let configuration: PluginInstanceConfiguration
    public init(id: String, displayName: String, isEnabled: Bool, configuration: PluginInstanceConfiguration) {
        self.id = id; self.displayName = displayName; self.isEnabled = isEnabled; self.configuration = configuration
    }
}

/// A custom account page can manage multiple instances without seeing or
/// editing other plugins' accounts. Native builtins additionally use their
/// typed OAuth/OTP adapters supplied at app composition.
@MainActor
public struct PluginSourceSettingsContext {
    public let readSources: () async throws -> [PluginSettingsSourceRecord]
    public let saveSource: (PluginSettingsSourceRecord) async throws -> Void
    public let removeSource: (String) async throws -> Void
    public let saveCredential: (Data, String) async throws -> String
    public let deleteCredential: (String, String) async throws -> Void
    public init(readSources: @escaping () async throws -> [PluginSettingsSourceRecord],
                saveSource: @escaping (PluginSettingsSourceRecord) async throws -> Void,
                removeSource: @escaping (String) async throws -> Void,
                saveCredential: @escaping (Data, String) async throws -> String,
                deleteCredential: @escaping (String, String) async throws -> Void) {
        self.readSources = readSources; self.saveSource = saveSource; self.removeSource = removeSource
        self.saveCredential = saveCredential; self.deleteCredential = deleteCredential
    }
}
#endif
