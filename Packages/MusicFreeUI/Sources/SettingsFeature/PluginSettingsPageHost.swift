import AppServices
import Foundation
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import SettingsAPI
import UIKit

/// App composition registers companions; Settings only consumes their entries.
@MainActor
public final class PluginSettingsPageHost {
    public let registry: PluginSettingsPageRegistry
    let model: PluginSettingsModel
    private let plugins: any PluginServing
    private let settings: any SettingsServing
    public var snapshots: [PluginSnapshot] { model.snapshots }

    public init(registry: PluginSettingsPageRegistry, plugins: any PluginServing, settings: any SettingsServing) {
        self.registry = registry; self.plugins = plugins; self.settings = settings
        model = PluginSettingsModel(plugins: plugins, settings: settings)
    }
    public func start() { model.start(); model.refresh() }

    public func entries(placement: PluginSettingsPlacement? = nil, pluginID: PluginID? = nil) -> [PluginSettingsEntry] {
        registry.entries(pluginID: pluginID, placement: placement).filter { entry in
            snapshots.contains { $0.id == entry.pluginID && $0.preference.isVisible && isAvailable($0) }
        }
    }
    private func isAvailable(_ snapshot: PluginSnapshot) -> Bool {
        ![.compiledOut, .incompatible, .invalidRegistration].contains(snapshot.state)
    }
    public func makePage(entryID: String) -> UIViewController? {
        guard let entry = registry.entries().first(where: { $0.id == entryID }),
              let snapshot = snapshots.first(where: { $0.id == entry.pluginID }), isAvailable(snapshot) else { return nil }
        return registry.makeViewController(entryID: entryID, context: context(for: snapshot.descriptor))
    }

    func context(for descriptor: PluginDescriptor) -> PluginSettingsContext {
        let plugins = plugins, settings = settings, model = model
        let id = descriptor.id
        return PluginSettingsContext(descriptor: descriptor,
            readPreference: {
                try Task.checkCancellation()
                let current = try await settings.load()
                return current.pluginPreferences.first { $0.pluginID == id } ?? PluginPreference(pluginID: id)
            }, saveConfiguration: { values, credential in
                try Task.checkCancellation()
                try descriptor.configuration.validate(values, credentialRecordID: credential)
                guard await model.saveConfiguration(descriptor, values: values, credentialRecordID: credential) else {
                    throw PluginError.unavailable
                }
            }, saveCredential: { data in
                try Task.checkCancellation()
                return try await plugins.saveCredential(data, pluginID: id, instanceID: "default")
            }, deleteCredential: { reference in
                try Task.checkCancellation()
                try await plugins.deleteCredential(recordID: reference, pluginID: id, instanceID: "default")
            }, setConsent: { granting in
                try Task.checkCancellation()
                guard await model.saveConsent(descriptor, granting: granting) else { throw PluginError.unavailable }
            }, sources: descriptor.kinds.contains(.onlineSource) ? sourceContext(for: descriptor) : nil)
    }

    private func sourceContext(for descriptor: PluginDescriptor) -> PluginSourceSettingsContext {
        let plugins = plugins, settings = settings, model = model
        let id = descriptor.id
        let provider = OnlineProviderKind(rawValue: descriptor.onlineProviderID ?? id.rawValue)
        return PluginSourceSettingsContext(readSources: {
            try Task.checkCancellation()
            let current = try await settings.load()
            let preference = current.pluginPreferences.first { $0.pluginID == id }
            return current.importPreferences.onlineSourcePreferences.sources.filter { $0.providerKind == provider }.map { source in
                let instance = preference?.instances.first { $0.instanceID == source.sourceID.rawValue }
                    ?? PluginInstanceConfiguration(instanceID: source.sourceID.rawValue, credentialRecordID: source.credentialRecordID,
                        acceptedPolicyVersion: source.privacyPolicyVersion, schemaVersion: descriptor.sourceConfiguration.version)
                return .init(id: source.sourceID.rawValue, displayName: source.displayName, isEnabled: source.isEnabled, configuration: instance)
            }
        }, saveSource: { record in
            try Task.checkCancellation()
            guard !record.id.isEmpty, record.id == record.configuration.instanceID,
                  record.configuration.schemaVersion == descriptor.sourceConfiguration.version,
                  record.configuration.acceptedPolicyVersion == nil || record.configuration.acceptedPolicyVersion == descriptor.policyVersion
            else { throw PluginError.invalidConfiguration }
            try descriptor.sourceConfiguration.validate(record.configuration.values, credentialRecordID: record.configuration.credentialRecordID)
            guard await model.saveSourceEdit({ current in
                let sourceID = MediaSourceID(rawValue: record.id)
                let old = current.importPreferences.onlineSourcePreferences.source(for: sourceID)
                guard old == nil || old?.providerKind == provider else { throw PluginError.invalidConfiguration }
                let source = try OnlineSourceConfiguration(sourceID: sourceID, providerKind: provider,
                    displayName: record.displayName, endpoint: old?.endpoint, rootObjectID: old?.rootObjectID,
                    googleDriveSelectedFiles: old?.googleDriveSelectedFiles ?? [], googleDriveClientID: old?.googleDriveClientID,
                    credentialRecordID: record.configuration.credentialRecordID,
                    privacyPolicyVersion: record.configuration.acceptedPolicyVersion, isEnabled: record.isEnabled)
                return try PluginConsentSettings.save(source: source, instance: record.configuration,
                    descriptor: descriptor, isNew: old == nil, current: current)
            }) else { throw PluginError.unavailable }
        }, removeSource: { instanceID in
            try Task.checkCancellation()
            var removedCredential: String?
            guard await model.saveSourceEdit({ current in
                let sourceID = MediaSourceID(rawValue: instanceID)
                guard let source = current.importPreferences.onlineSourcePreferences.source(for: sourceID),
                      source.providerKind == provider else { throw PluginError.invalidConfiguration }
                removedCredential = source.credentialRecordID
                var preferences = current.pluginPreferences
                if let index = preferences.firstIndex(where: { $0.pluginID == id }) {
                    preferences[index].instances.removeAll { $0.instanceID == instanceID }
                }
                return AppSettings(importPreferences: current.importPreferences.settingOnlineSourcePreferences(
                    current.importPreferences.onlineSourcePreferences.removing(sourceID)),
                    playbackPreferences: current.playbackPreferences, storagePreferences: current.storagePreferences,
                    loggingPreferences: current.loggingPreferences, pluginPreferences: preferences)
            }) else { throw PluginError.unavailable }
            if let removedCredential {
                try? await plugins.deleteCredential(recordID: removedCredential, pluginID: id, instanceID: instanceID)
            }
        }, saveCredential: { data, instanceID in
            try Task.checkCancellation()
            guard !instanceID.isEmpty else { throw PluginError.invalidConfiguration }
            return try await plugins.saveCredential(data, pluginID: id, instanceID: instanceID)
        }, deleteCredential: { reference, instanceID in
            try Task.checkCancellation()
            try await plugins.deleteCredential(recordID: reference, pluginID: id, instanceID: instanceID)
        })
    }
}
