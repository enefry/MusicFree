import Foundation
import Security
import MusicFreePluginAPI

public struct KeychainPluginCredentialStore: PluginCredentialAccess {
    private let service = "win.tools4me.music.plugins.v1"
    public init() {}
    private func namespace(pluginID: PluginID, instanceID: String) -> String {
        "plugin:\(pluginID.rawValue.utf8.count):\(pluginID.rawValue):\(instanceID.utf8.count):\(instanceID):"
    }
    public func read(recordID: String, pluginID: PluginID, instanceID: String) async throws -> Data? {
        guard recordID.hasPrefix(namespace(pluginID: pluginID, instanceID: instanceID)) else { throw PluginError.permissionRequired }
        var query = query(recordID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PluginError.requestFailed(code: "credential_read") }
        return value as? Data
    }
    public func save(_ data: Data, pluginID: PluginID, instanceID: String) throws -> String {
        let recordID = namespace(pluginID: pluginID, instanceID: instanceID) + UUID().uuidString
        var query = query(recordID); query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw PluginError.requestFailed(code: "credential_save") }
        return recordID
    }
    public func delete(recordID: String, pluginID: PluginID, instanceID: String) throws {
        guard recordID.hasPrefix(namespace(pluginID: pluginID, instanceID: instanceID)) else { throw PluginError.permissionRequired }
        let status = SecItemDelete(query(recordID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PluginError.requestFailed(code: "credential_delete") }
    }
    private func query(_ recordID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: recordID]
    }
}
