import Foundation
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

public struct BuiltInPluginRegistration: Sendable {
    public let descriptor: PluginDescriptor
    public let lyrics: LyricsPluginFactory?
    public let metadata: MetadataPluginFactory?
    public let metadataAuthorization: PluginMetadataAuthorizationHandlers?
    public let onlineSource: OnlineSourcePluginFactory?
    public let dsp: DSPPluginFactory?
    public init(descriptor: PluginDescriptor, lyrics: LyricsPluginFactory? = nil,
                metadata: MetadataPluginFactory? = nil, metadataAuthorization: PluginMetadataAuthorizationHandlers? = nil, onlineSource: OnlineSourcePluginFactory? = nil,
                dsp: DSPPluginFactory? = nil) {
        self.descriptor = descriptor; self.lyrics = lyrics; self.metadata = metadata; self.metadataAuthorization = metadataAuthorization
        self.onlineSource = onlineSource; self.dsp = dsp
    }
    var factoryKinds: Set<PluginKind> {
        var kinds: Set<PluginKind> = []
        if lyrics != nil { kinds.insert(.lyrics) }; if metadata != nil { kinds.insert(.metadata) }
        if onlineSource != nil { kinds.insert(.onlineSource) }; if dsp != nil { kinds.insert(.dsp) }
        return kinds
    }
}
public protocol BuiltInPluginRegistrationProvider: Sendable {
    var registrations: [BuiltInPluginRegistration] { get }
}

/// Validation has no factory/network side effects. Bad entries are isolated.
public struct PluginRegistry: Sendable {
    public let registrations: [PluginID: BuiltInPluginRegistration]
    public let unavailable: [PluginID: PluginLifecycleState]
    public let descriptors: [PluginID: PluginDescriptor]
    public init(_ entries: [BuiltInPluginRegistration], compiledOut: [PluginDescriptor] = []) {
        var registrations: [PluginID: BuiltInPluginRegistration] = [:]
        var unavailable: [PluginID: PluginLifecycleState] = [:]
        var descriptors: [PluginID: PluginDescriptor] = [:]
        let duplicatedProviders = Dictionary(grouping: entries.compactMap { $0.descriptor.onlineProviderID }, by: { $0 })
            .filter { $0.value.count > 1 }.keys
        for entry in entries {
            let descriptor = entry.descriptor
            if descriptors[descriptor.id] != nil {
                registrations[descriptor.id] = nil
                unavailable[descriptor.id] = .invalidRegistration
                continue
            }
            descriptors[descriptor.id] = descriptor
            guard !descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !descriptor.kinds.isEmpty, descriptor.kinds == entry.factoryKinds,
                  entry.metadataAuthorization == nil || entry.metadata != nil,
                  descriptor.dspPlacements == nil || (descriptor.kinds.contains(.dsp) && descriptor.dspPlacements?.isValid == true),
                  descriptor.configuration.version > 0,
                  descriptor.sourceConfiguration.version > 0,
                  Set(descriptor.configuration.fields.map(\.id)).count == descriptor.configuration.fields.count,
                  Set(descriptor.sourceConfiguration.fields.map(\.id)).count == descriptor.sourceConfiguration.fields.count,
                  !(descriptor.configuration.fields + descriptor.sourceConfiguration.fields).contains(where: { $0.kind == .secret }) || descriptor.permissions.contains(.credentials),
                  !descriptor.kinds.contains(.onlineSource) || descriptor.onlineProviderID?.isEmpty == false,
                  !duplicatedProviders.contains(descriptor.onlineProviderID ?? "") else {
                unavailable[descriptor.id] = .invalidRegistration; continue
            }
            guard descriptor.apiVersion.major == PluginAPIVersion.current.major,
                  descriptor.apiVersion.minor <= PluginAPIVersion.current.minor else {
                unavailable[descriptor.id] = .incompatible; continue
            }
            registrations[descriptor.id] = entry
        }
        for descriptor in compiledOut where descriptors[descriptor.id] == nil {
            descriptors[descriptor.id] = descriptor; unavailable[descriptor.id] = .compiledOut
        }
        self.registrations = registrations; self.unavailable = unavailable; self.descriptors = descriptors
    }
}
