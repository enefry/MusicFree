#if canImport(UIKit)
import Foundation
import MusicFreePluginAPI
import UIKit

/// UIKit-only companion contract. Runtime plugins never depend on this module.
public enum PluginSettingsPlacement: String, Sendable {
    case playback, importing, pluginDetail
}

/// Explicit replacement keeps an auxiliary page from accidentally hiding an
/// account editor, and keeps a complete custom editor from duplicating a form.
public enum PluginSettingsPageRole: String, Sendable {
    case configuration, accounts, supplement
}

public struct PluginSettingsEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let pluginID: PluginID
    public let title: String
    public let systemImage: String
    public let placement: PluginSettingsPlacement
    public let role: PluginSettingsPageRole
    public let navigationIdentifier: String
    public let order: Int

    public init(id: String, pluginID: PluginID, title: String, systemImage: String,
                placement: PluginSettingsPlacement = .pluginDetail, order: Int = 0,
                role: PluginSettingsPageRole = .configuration, navigationIdentifier: String? = nil) {
        self.id = id; self.pluginID = pluginID; self.title = title
        self.systemImage = systemImage; self.placement = placement; self.order = order
        self.navigationIdentifier = navigationIdentifier ?? id
        self.role = role
    }
}

/// The host binds these operations to one plugin. No global settings or service
/// container is handed to a page. Secrets stay in the host credential store.
@MainActor
public struct PluginSettingsContext {
    public let descriptor: PluginDescriptor
    public let readPreference: () async throws -> PluginPreference
    public let saveConfiguration: ([String: PluginConfigurationValue], String?) async throws -> Void
    public let saveCredential: (Data) async throws -> String
    public let deleteCredential: (String) async throws -> Void
    public let setConsent: (Bool) async throws -> Void
    public let sources: PluginSourceSettingsContext?

    public init(descriptor: PluginDescriptor,
                readPreference: @escaping () async throws -> PluginPreference,
                saveConfiguration: @escaping ([String: PluginConfigurationValue], String?) async throws -> Void,
                saveCredential: @escaping (Data) async throws -> String,
                deleteCredential: @escaping (String) async throws -> Void,
                setConsent: @escaping (Bool) async throws -> Void,
                sources: PluginSourceSettingsContext? = nil) {
        self.descriptor = descriptor; self.readPreference = readPreference
        self.saveConfiguration = saveConfiguration; self.saveCredential = saveCredential
        self.deleteCredential = deleteCredential; self.setConsent = setConsent
        self.sources = sources
    }
}

@MainActor
public struct PluginSettingsPageRegistration {
    public let entry: PluginSettingsEntry
    public let makeViewController: (PluginSettingsContext) -> UIViewController

    public init(entry: PluginSettingsEntry,
                makeViewController: @escaping (PluginSettingsContext) -> UIViewController) {
        self.entry = entry; self.makeViewController = makeViewController
    }
}

public enum PluginSettingsRegistrationError: Error, Equatable {
    case invalidEntry(String), duplicateEntry(String), duplicateNavigationIdentifier(String)
}

/// Registration is data-only until navigation invokes a factory. Invalid
/// companions fail at composition, before duplicate table identifiers appear.
@MainActor
public struct PluginSettingsPageRegistry {
    private var registrations: [String: PluginSettingsPageRegistration] = [:]
    public init() {}

    public mutating func register(_ page: PluginSettingsPageRegistration) throws {
        let entry = page.entry
        guard entry.id.hasPrefix(entry.pluginID.rawValue + "."),
              entry.id.count > entry.pluginID.rawValue.count + 1,
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.systemImage.isEmpty else {
            throw PluginSettingsRegistrationError.invalidEntry(entry.id)
        }
        guard registrations[entry.id] == nil else {
            throw PluginSettingsRegistrationError.duplicateEntry(entry.id)
        }
        guard !registrations.values.contains(where: { $0.entry.navigationIdentifier == entry.navigationIdentifier }) else {
            throw PluginSettingsRegistrationError.duplicateNavigationIdentifier(entry.navigationIdentifier)
        }
        registrations[entry.id] = page
    }

    public func entries(pluginID: PluginID? = nil, placement: PluginSettingsPlacement? = nil) -> [PluginSettingsEntry] {
        registrations.values.map(\.entry).filter {
            (pluginID == nil || $0.pluginID == pluginID) && (placement == nil || $0.placement == placement)
        }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    public func makeViewController(entryID: String, context: PluginSettingsContext) -> UIViewController? {
        guard let page = registrations[entryID], page.entry.pluginID == context.descriptor.id else { return nil }
        let controller = page.makeViewController(context)
        controller.restorationIdentifier = page.entry.id
        controller.navigationItem.largeTitleDisplayMode = .never
        if controller.title == nil { controller.title = page.entry.title }
        return controller
    }
}
#endif
