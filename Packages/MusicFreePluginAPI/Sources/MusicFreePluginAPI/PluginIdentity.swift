import Foundation

public struct PluginID: RawRepresentable, Codable, Hashable, Comparable, Sendable, Identifiable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: Self { self }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PluginKind: String, Codable, CaseIterable, Sendable { case lyrics, metadata, onlineSource, dsp }
public struct PluginPermission: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let network = Self(rawValue: "network")
    public static let credentials = Self(rawValue: "credentials")
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}
public struct PluginAPIVersion: Codable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public init(major: Int = 1, minor: Int = 0) { self.major = major; self.minor = minor }
    public static let current = Self()
}

public struct PluginDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: PluginID
    public let name: String
    public let version: String
    public let apiVersion: PluginAPIVersion
    public let kinds: Set<PluginKind>
    public let permissions: Set<PluginPermission>
    public let policyVersion: String
    public let configuration: PluginConfigurationSchema
    public let sourceConfiguration: PluginConfigurationSchema
    /// Stable host provider identity for settings, consent and enrichment records.
    public let dataProviderID: String?
    public let onlineProviderID: String?
    public let onlineCapabilities: Set<PluginOnlineCapability>
    public let dspPlacements: PluginDSPPlacementOptions?
    public init(id: PluginID, name: String, version: String = "1.0.0",
                apiVersion: PluginAPIVersion = .current, kinds: Set<PluginKind>,
                permissions: Set<PluginPermission> = [], policyVersion: String = "1",
                configuration: PluginConfigurationSchema = .init(), sourceConfiguration: PluginConfigurationSchema = .init(), onlineProviderID: String? = nil,
                onlineCapabilities: Set<PluginOnlineCapability> = [], dataProviderID: String? = nil, dspPlacements: PluginDSPPlacementOptions? = nil) {
        self.id = id; self.name = name; self.version = version; self.apiVersion = apiVersion
        self.kinds = kinds; self.permissions = permissions; self.policyVersion = policyVersion
        self.configuration = configuration; self.onlineProviderID = onlineProviderID
        self.sourceConfiguration = sourceConfiguration
        self.onlineCapabilities = onlineCapabilities
        self.dspPlacements = dspPlacements
        self.dataProviderID = dataProviderID
    }
}

public enum PluginError: Error, Equatable, Sendable {
    case unavailable, disabled, loadBlocked, permissionRequired, incompatible, invalidRegistration
    case invalidConfiguration, invalidResponse, unsupportedCapability, staleOperation, ambiguous
    case requestFailed(code: String)
}

public enum PluginLifecycleState: String, Codable, Sendable {
    case registered, disabled, loadBlocked, permissionRequired, loading, ready, running, unloaded, failed
    case compiledOut, incompatible, invalidRegistration
}
public struct PluginSnapshot: Sendable, Identifiable {
    public let descriptor: PluginDescriptor
    public let preference: PluginPreference
    public let state: PluginLifecycleState
    public let diagnostic: String?
    public var id: PluginID { descriptor.id }
    public init(descriptor: PluginDescriptor, preference: PluginPreference, state: PluginLifecycleState, diagnostic: String? = nil) {
        self.descriptor = descriptor; self.preference = preference; self.state = state
        self.diagnostic = diagnostic
    }
}
