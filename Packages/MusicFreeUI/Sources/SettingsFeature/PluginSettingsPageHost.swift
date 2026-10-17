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
    enum Category: CaseIterable { case playback, metadata }
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

    /// Discover new plugins without requiring a second category registration.
    /// Explicit category pages retain their placement and navigation identifiers.
    func categoryPlugins(category: Category) -> [PluginSnapshot] {
        snapshots.filter { snapshot in
            guard snapshot.preference.isEnabled, snapshot.preference.isVisible, isAvailable(snapshot),
                  !registry.entries(pluginID: snapshot.id).contains(where: { $0.placement != .pluginDetail })
            else { return false }
            return self.category(for: snapshot) == category
        }.sorted { $0.id < $1.id }
    }

    func categoryEntries(category: Category) -> [PluginSettingsEntry] {
        let placement: PluginSettingsPlacement = category == .playback ? .playback : .importing
        return entries(placement: placement).filter { entry in
            snapshots.contains {
                $0.id == entry.pluginID && !$0.descriptor.kinds.contains(.onlineSource)
                    && (category == .playback || self.category(for: $0) == category)
            }
        }
    }

    private func category(for snapshot: PluginSnapshot) -> Category? {
        let kinds = snapshot.descriptor.kinds
        if kinds.contains(.onlineSource) { return nil } // Managed by the dedicated online sources tab.
        if kinds.contains(.dsp) { return .playback }
        if kinds.contains(.metadata) || kinds.contains(.lyrics) { return .metadata }
        return nil
    }

    func makeSettingsPage(pluginID: PluginID) -> UIViewController? {
        guard let snapshot = snapshots.first(where: { $0.id == pluginID }),
              snapshot.preference.isEnabled, snapshot.preference.isVisible, isAvailable(snapshot) else { return nil }
        let entries = registry.entries(pluginID: pluginID)
        if let entry = entries.first(where: { $0.role == .configuration || $0.role == .accounts }) {
            return makePage(entryID: entry.id)
        }
        // Supplemental authorization pages coexist with configuration and consent
        // controls in the plugin detail, rather than hiding those controls.
        if entries.isEmpty, snapshot.descriptor.configuration.fields.contains(where: { $0.kind != .secret }) {
            return PluginConfigurationViewController(descriptor: snapshot.descriptor,
                initial: snapshot.preference.configuration, credentialRecordID: snapshot.preference.credentialRecordID) { [weak self] values in
                guard let self else { return false }
                return await self.model.saveConfiguration(snapshot.descriptor, values: values)
            }
        }
        return PluginSettingsViewController(plugins: plugins, settings: settings, pageHost: self, pluginID: pluginID)
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
