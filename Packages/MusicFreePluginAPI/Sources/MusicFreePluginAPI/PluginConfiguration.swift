import Foundation

public indirect enum PluginJSONValue: Codable, Hashable, Sendable {
    case object([String: PluginJSONValue]), array([PluginJSONValue]), text(String), number(Double), flag(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .text(try value.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        case .null: try value.encodeNil()
        }
    }
}
public enum PluginConfigurationValue: Codable, Hashable, Sendable {
    case text(String), number(Double), flag(Bool), unknown(PluginJSONValue)
    public init(from decoder: Decoder) throws {
        let raw = try PluginJSONValue(from: decoder)
        if case .object(let object) = raw, object.count == 1,
           let key = object.keys.first, case .object(let payload) = object[key], payload.count == 1 {
            switch (key, payload["_0"]) {
            case ("text", .text(let value)): self = .text(value); return
            case ("number", .number(let value)): self = .number(value); return
            case ("flag", .flag(let value)): self = .flag(value); return
            default: break
            }
        }
        self = .unknown(raw)
    }
    public func encode(to encoder: Encoder) throws {
        let raw: PluginJSONValue
        switch self {
        case .text(let value): raw = .object(["text": .object(["_0": .text(value)])])
        case .number(let value): raw = .object(["number": .object(["_0": .number(value)])])
        case .flag(let value): raw = .object(["flag": .object(["_0": .flag(value)])])
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}
public enum PluginConfigurationFieldKind: String, Codable, Sendable { case text, number, flag, secret }
public struct PluginConfigurationField: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: PluginConfigurationFieldKind
    public let required: Bool
    public let minimumNumber: Double?
    public let maximumNumber: Double?
    public init(id: String, title: String, kind: PluginConfigurationFieldKind, required: Bool = false,
                minimumNumber: Double? = nil, maximumNumber: Double? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.required = required
        self.minimumNumber = minimumNumber; self.maximumNumber = maximumNumber
    }
}
public struct PluginConfigurationSchema: Codable, Hashable, Sendable {
    public let version: Int
    public let fields: [PluginConfigurationField]
    public init(version: Int = 1, fields: [PluginConfigurationField] = []) {
        self.version = version; self.fields = fields
    }
    public func validate(_ values: [String: PluginConfigurationValue], credentialRecordID: String?) throws {
        guard Set(fields.map(\.id)).count == fields.count, version > 0 else { throw PluginError.invalidConfiguration }
        for field in fields {
            guard field.minimumNumber?.isFinite ?? true, field.maximumNumber?.isFinite ?? true,
                  (field.minimumNumber ?? -Double.greatestFiniteMagnitude) <= (field.maximumNumber ?? Double.greatestFiniteMagnitude)
            else { throw PluginError.invalidConfiguration }
        }
        for (key, value) in values {
            guard let field = fields.first(where: { $0.id == key }) else { throw PluginError.invalidConfiguration }
            switch (field.kind, value) {
            case (.text, .text), (.flag, .flag): break
            case (.number, .number(let number)) where number.isFinite:
                guard field.minimumNumber.map({ number >= $0 }) ?? true,
                      field.maximumNumber.map({ number <= $0 }) ?? true else { throw PluginError.invalidConfiguration }
            default: throw PluginError.invalidConfiguration
            }
        }
        for field in fields where field.required {
            if field.kind == .secret {
                guard credentialRecordID?.isEmpty == false else { throw PluginError.invalidConfiguration }
            } else {
                guard let value = values[field.id] else { throw PluginError.invalidConfiguration }
                if case .text(let text) = value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PluginError.invalidConfiguration
                }
            }
        }
    }
}

/// Only schema-declared non-secret values and Keychain references are persisted.
public struct PluginPreference: Codable, Hashable, Sendable, Identifiable {
    public let pluginID: PluginID
    public var isVisible: Bool
    public var isEnabled: Bool
    public var isLoadAllowed: Bool
    public var configuration: [String: PluginConfigurationValue]
    public var schemaVersion: Int
    public var grantedPermissions: Set<PluginPermission>
    public var acceptedPolicyVersion: String?
    public var credentialRecordID: String?
    public var instances: [PluginInstanceConfiguration]
    public var dspPlacement: PluginDSPPlacement?
    /// Nil follows the descriptor default. Independent of processor parameters.
    public var dspPriority: Int?
    public var id: PluginID { pluginID }
    public init(pluginID: PluginID, isVisible: Bool = true, isEnabled: Bool = false,
                isLoadAllowed: Bool = false, configuration: [String: PluginConfigurationValue] = [:],
                schemaVersion: Int = 1, grantedPermissions: Set<PluginPermission> = [],
                acceptedPolicyVersion: String? = nil, credentialRecordID: String? = nil,
                instances: [PluginInstanceConfiguration] = [], dspPlacement: PluginDSPPlacement? = nil, dspPriority: Int? = nil) {
        self.pluginID = pluginID; self.isVisible = isVisible; self.isEnabled = isEnabled
        self.isLoadAllowed = isLoadAllowed; self.configuration = configuration; self.schemaVersion = schemaVersion
        self.grantedPermissions = grantedPermissions; self.acceptedPolicyVersion = acceptedPolicyVersion
        self.credentialRecordID = credentialRecordID
        self.instances = instances
        self.dspPlacement = dspPlacement
        self.dspPriority = dspPriority
    }
}

public struct PluginInstanceConfiguration: Codable, Hashable, Sendable {
    public let instanceID: String
    public let values: [String: PluginConfigurationValue]
    public let credentialRecordID: String?
    public let acceptedPolicyVersion: String?
    public let schemaVersion: Int
    public let dspPlacement: PluginDSPPlacement?
    public init(instanceID: String = "default", values: [String: PluginConfigurationValue] = [:],
                credentialRecordID: String? = nil, acceptedPolicyVersion: String? = nil, schemaVersion: Int = 1,
                dspPlacement: PluginDSPPlacement? = nil) {
        self.instanceID = instanceID; self.values = values; self.credentialRecordID = credentialRecordID
        self.acceptedPolicyVersion = acceptedPolicyVersion
        self.schemaVersion = schemaVersion
        self.dspPlacement = dspPlacement
    }
}
public protocol PluginCredentialAccess: Sendable {
    func read(recordID: String, pluginID: PluginID, instanceID: String) async throws -> Data?
}
