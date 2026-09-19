import Foundation
import Security

/// A credential reference is the only value Provider configuration may retain.
/// Secret bytes live in the Keychain and are read for one request/session only.
public protocol OnlineCredentialStoring: OnlineCredentialProviding {
    func save(secret: String, for recordID: String) async throws
    func remove(recordID: String) async throws
}

public struct UnavailableOnlineCredentialStore: OnlineCredentialStoring, Sendable {
    public init() {}

    public func secret(for recordID: String) async throws -> String {
        throw OnlineSourceAdapterError.missingCredential
    }

    public func save(secret: String, for recordID: String) async throws {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func remove(recordID: String) async throws {
        throw OnlineSourceAdapterError.transportUnavailable
    }
}

public final class KeychainOnlineCredentialStore: OnlineCredentialStoring, @unchecked Sendable {
    public let service: String

    public init(service: String = "win.tools4me.music.online") {
        self.service = service
    }

    public func secret(for recordID: String) async throws -> String {
        let data = try read(recordID: recordID)
        guard let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        return secret
    }

    public func save(secret: String, for recordID: String) async throws {
        guard !recordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secret.isEmpty,
              let data = secret.data(using: .utf8)
        else {
            throw OnlineSourceAdapterError.invalidCredential
        }

        var query = baseQuery(recordID: recordID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw OnlineSourceAdapterError.httpStatus(Int(updateStatus))
            }
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OnlineSourceAdapterError.httpStatus(Int(addStatus))
            }
        default:
            throw OnlineSourceAdapterError.httpStatus(Int(status))
        }
    }

    public func remove(recordID: String) async throws {
        let status = SecItemDelete(baseQuery(recordID: recordID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OnlineSourceAdapterError.httpStatus(Int(status))
        }
    }

    private func read(recordID: String) throws -> Data {
        var query = baseQuery(recordID: recordID)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? OnlineSourceAdapterError.missingCredential
                : OnlineSourceAdapterError.httpStatus(Int(status))
        }
        guard let data = result as? Data else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        return data
    }

    private func baseQuery(recordID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: recordID,
        ]
    }
}
