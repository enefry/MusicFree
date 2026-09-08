import CryptoKit
import Foundation
import Security

#if canImport(AuthenticationServices) && canImport(UIKit)
    import AuthenticationServices
    import UIKit
#endif

public struct GoogleDriveOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let reversedClientID: String?
    public let redirectURL: URL
    public let scope: String
    public let authorizationURL: URL
    public let tokenURL: URL

    public init(
        clientID: String,
        reversedClientID: String? = nil,
        redirectURL: URL,
        scope: String = "https://www.googleapis.com/auth/drive.readonly",
        authorizationURL: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
    ) throws {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty,
              redirectURL.scheme != nil
        else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        self.clientID = normalizedClientID
        if let reversedClientID {
            let normalizedReversedClientID = reversedClientID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.reversedClientID = normalizedReversedClientID.isEmpty
                ? nil
                : normalizedReversedClientID
        } else {
            self.reversedClientID = nil
        }
        self.redirectURL = redirectURL
        self.scope = scope
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
    }

    public static func fromMainBundle(
        bundle: Bundle = .main
    ) -> Self? {
        let enabledValue = bundle.object(
            forInfoDictionaryKey: "GoogleDriveOAuthEnabled"
        )
        let isEnabled: Bool
        switch enabledValue {
        case let value as Bool:
            isEnabled = value
        case let value as String:
            isEnabled = ["1", "YES", "TRUE"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            )
        default:
            isEnabled = false
        }
        guard isEnabled else { return nil }

        guard let clientID = nonEmptyString(
            bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthClientID") as? String
        ),
            let redirectValue = nonEmptyString(
                bundle.object(
                    forInfoDictionaryKey: "GoogleDriveOAuthRedirectURL"
                ) as? String
            ),
            let redirectURL = URL(string: redirectValue)
        else {
            return nil
        }
        return try? Self(
            clientID: clientID,
            reversedClientID: nonEmptyString(
                bundle.object(
                    forInfoDictionaryKey: "GoogleDriveOAuthReversedClientID"
                ) as? String
            ),
            redirectURL: redirectURL
        )
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public protocol GoogleDriveTokenStoring: Sendable {
    func load(recordID: String) async throws -> GoogleDriveStoredToken
    func save(_ token: GoogleDriveStoredToken, recordID: String) async throws
    func remove(recordID: String) async throws
}

public struct GoogleDriveStoredToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct UnavailableGoogleDriveTokenStore: GoogleDriveTokenStoring, Sendable {
    public init() {}

    public func load(recordID: String) async throws -> GoogleDriveStoredToken {
        throw OnlineSourceAdapterError.authorizationRequired
    }

    public func save(
        _ token: GoogleDriveStoredToken,
        recordID: String
    ) async throws {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func remove(recordID: String) async throws {
        throw OnlineSourceAdapterError.transportUnavailable
    }
}

public final class KeychainGoogleDriveTokenStore: GoogleDriveTokenStoring, @unchecked Sendable {
    public let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "win.tools4me.music.google-drive") {
        self.service = service
    }

    public func load(recordID: String) async throws -> GoogleDriveStoredToken {
        var query = baseQuery(recordID: recordID)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? OnlineSourceAdapterError.authorizationRequired
                : OnlineSourceAdapterError.httpStatus(Int(status))
        }
        guard let data = result as? Data else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        return try decoder.decode(GoogleDriveStoredToken.self, from: data)
    }

    public func save(
        _ token: GoogleDriveStoredToken,
        recordID: String
    ) async throws {
        let data = try encoder.encode(token)
        var query = baseQuery(recordID: recordID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
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

    private func baseQuery(recordID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: recordID,
        ]
    }
}

/// PKCE-based Google OAuth implementation. Refresh tokens are stored only in
/// Keychain and are scoped by the configured online-source record ID.
public final class GoogleDriveOAuthClient: ScopedGoogleDriveOAuthProviding, @unchecked Sendable {
    public let configuration: GoogleDriveOAuthConfiguration
    private let tokenStore: any GoogleDriveTokenStoring
    private let session: URLSession
    private let defaultRecordID: String

    public init(
        configuration: GoogleDriveOAuthConfiguration,
        tokenStore: any GoogleDriveTokenStoring = KeychainGoogleDriveTokenStore(),
        session: URLSession = .shared,
        defaultRecordID: String = "default"
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.session = session
        self.defaultRecordID = defaultRecordID
    }

    public func authorize() async throws -> GoogleDriveOAuthSession {
        try await authorize(recordID: defaultRecordID)
    }

    public func refresh(
        _ session: GoogleDriveOAuthSession
    ) async throws -> GoogleDriveOAuthSession {
        try await refresh(session, recordID: defaultRecordID)
    }

    public func validSession() async throws -> GoogleDriveOAuthSession {
        try await validSession(recordID: defaultRecordID)
    }

    public func authorize(
        for sourceConfiguration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession {
        try await authorize(recordID: sourceConfiguration.resolvedCredentialRecordID)
    }

    public func refresh(
        _ session: GoogleDriveOAuthSession,
        for sourceConfiguration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession {
        try await refresh(
            session,
            recordID: sourceConfiguration.resolvedCredentialRecordID
        )
    }

    public func validSession(
        for sourceConfiguration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession {
        try await validSession(recordID: sourceConfiguration.resolvedCredentialRecordID)
    }

    private func authorize(recordID: String) async throws -> GoogleDriveOAuthSession {
        let verifier = Self.randomString(byteCount: 32)
        let state = Self.randomString(byteCount: 16)
        let challenge = Self.base64URLEncoded(
            Data(SHA256.hash(data: Data(verifier.utf8)))
        )
        let authorizationURL = try makeAuthorizationURL(
            state: state,
            codeChallenge: challenge
        )
        let callbackURL = try await authenticate(url: authorizationURL)
        guard let callbackComponents = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ),
            callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        if let error = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw OnlineSourceAdapterError.operationNotImplemented(
                "Google OAuth \(error)"
            )
        }
        guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OnlineSourceAdapterError.authorizationRequired
        }
        let token = try await exchange(
            code: code,
            verifier: verifier,
            existingRefreshToken: nil
        )
        try await tokenStore.save(token, recordID: recordID)
        return token.session
    }

    private func validSession(recordID: String) async throws -> GoogleDriveOAuthSession {
        do {
            let stored = try await tokenStore.load(recordID: recordID)
            if !stored.isExpiredSoon {
                return stored.session
            }
            if stored.refreshToken != nil {
                return try await refresh(stored.session, recordID: recordID)
            }
        } catch let error as OnlineSourceAdapterError {
            guard error == .authorizationRequired else { throw error }
        }
        return try await authorize(recordID: recordID)
    }

    private func refresh(
        _ session: GoogleDriveOAuthSession,
        recordID: String
    ) async throws -> GoogleDriveOAuthSession {
        let stored = try await tokenStore.load(recordID: recordID)
        guard let refreshToken = stored.refreshToken else {
            return try await authorize(recordID: recordID)
        }
        let refreshed = try await exchange(
            refreshToken: refreshToken,
            existingRefreshToken: refreshToken
        )
        try await tokenStore.save(refreshed, recordID: recordID)
        return refreshed.session
    }

    private func exchange(
        code: String? = nil,
        verifier: String? = nil,
        refreshToken: String? = nil,
        existingRefreshToken: String?
    ) async throws -> GoogleDriveStoredToken {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var fields = [
            "client_id": configuration.clientID,
        ]
        if let code {
            fields["code"] = code
            fields["code_verifier"] = verifier
            fields["redirect_uri"] = configuration.redirectURL.absoluteString
            fields["grant_type"] = "authorization_code"
        } else if let refreshToken {
            fields["refresh_token"] = refreshToken
            fields["grant_type"] = "refresh_token"
        } else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        request.httpBody = Self.formEncoded(fields)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw mapOAuthError(data: data, statusCode: response.statusCode)
        }
        let payload = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        guard !payload.accessToken.isEmpty else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return GoogleDriveStoredToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? existingRefreshToken,
            expiresAt: payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private func makeAuthorizationURL(
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents(
            url: configuration.authorizationURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components?.url else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return url
    }

    private func authenticate(url: URL) async throws -> URL {
        #if canImport(AuthenticationServices) && canImport(UIKit)
            guard let callbackScheme = configuration.redirectURL.scheme else {
                throw OnlineSourceAdapterError.invalidCredential
            }
            let authenticator = await MainActor.run {
                GoogleDriveWebAuthenticator()
            }
            return try await authenticator.authenticate(url: url, callbackScheme: callbackScheme)
        #else
            throw OnlineSourceAdapterError.transportUnavailable
        #endif
    }

    private func mapOAuthError(data: Data, statusCode: Int) -> OnlineSourceAdapterError {
        if let payload = try? JSONDecoder().decode(
            GoogleOAuthErrorResponse.self,
            from: data
        ),
            payload.error == "invalid_grant" {
            return .authorizationRequired
        }
        return statusCode == 401 ? .authorizationRequired : .httpStatus(statusCode)
    }

    private static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncoded(Data(bytes))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ fields: [String: String?]) -> Data {
        let value = fields
            .compactMap { key, value in
                guard let value else { return nil }
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "+&=")
                return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(value.utf8)
    }
}

private extension GoogleDriveStoredToken {
    var isExpiredSoon: Bool {
        guard let expiresAt else { return true }
        return Date().addingTimeInterval(60) >= expiresAt
    }

    var session: GoogleDriveOAuthSession {
        GoogleDriveOAuthSession(accessToken: accessToken, expiresAt: expiresAt)
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String?
}

#if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    private final class GoogleDriveWebAuthenticator: NSObject,
        ASWebAuthenticationPresentationContextProviding {
        private var session: ASWebAuthenticationSession?

        func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callbackURL, error in
                    self?.session = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: OnlineSourceAdapterError.invalidResponse)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    self.session = nil
                    continuation.resume(
                        throwing: OnlineSourceAdapterError.transportUnavailable
                    )
                    return
                }
            }
        }

        func presentationAnchor(
            for session: ASWebAuthenticationSession
        ) -> ASPresentationAnchor {
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })
            if let windowScene {
                return ASPresentationAnchor(windowScene: windowScene)
            }
            return ASPresentationAnchor()
        }
    }
#endif
