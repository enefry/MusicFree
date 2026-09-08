import Foundation
import MediaSourceAPI
import MusicDomain

public struct DSAudioDeviceAuthorizationChallenge: Error, Equatable, Sendable,
    LocalizedError, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let challengeToken: String?

    public init(challengeToken: String?) {
        let normalized = challengeToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.challengeToken = normalized?.isEmpty == false ? normalized : nil
    }

    public var errorDescription: String? {
        "The Synology account requires a one-time verification code."
    }

    public var description: String { "DSAudioDeviceAuthorizationChallenge(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct DSAudioDeviceAuthorizationReceipt: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let deviceName: String
    /// DSM 6/7 does not consistently return a trusted-device identifier.
    /// The session id is sufficient for the first authenticated operation;
    /// keep the device id optional and let the transport reuse it when DSM
    /// provides one.
    public let deviceID: String?

    public init(deviceName: String, deviceID: String? = nil) {
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    public var description: String { "DSAudioDeviceAuthorizationReceipt(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// Performs the interactive DSM login used while adding a source. The caller
/// keeps the password and OTP only for the active sheet; the resulting trusted
/// device, session and account credential are written to the source-scoped
/// Keychain record.
public actor DSAudioDeviceAuthorizer {
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-source-dsaudio-auth"
    )

    private let credentialStore: any OnlineCredentialStoring
    private let httpClient: any OnlineHTTPClient
    private let api: DSAudioAPIConfiguration

    public init(
        credentialStore: any OnlineCredentialStoring = KeychainOnlineCredentialStore(),
        httpClient: any OnlineHTTPClient = URLSessionOnlineHTTPClient(),
        api: DSAudioAPIConfiguration = DSAudioAPIConfiguration()
    ) {
        self.credentialStore = credentialStore
        self.httpClient = httpClient
        self.api = api
    }

    public func authorize(
        sourceID: MediaSourceID,
        endpoint: URL,
        account: String,
        password: String,
        deviceName: String,
        oneTimeCode: String? = nil,
        challengeToken: String? = nil
    ) async throws -> DSAudioDeviceAuthorizationReceipt {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty,
              !password.isEmpty,
              !normalizedDeviceName.isEmpty
        else {
            throw OnlineSourceAdapterError.invalidCredential
        }

        var queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "6"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: normalizedAccount),
            // DSM expects the account password and the one-time code as two
            // independent values. The challenge token is only a short-lived
            // server hint and must never replace the user's password.
            URLQueryItem(name: "passwd", value: password),
            URLQueryItem(name: "session", value: "AudioStation"),
            URLQueryItem(name: "format", value: "sid"),
            URLQueryItem(name: "enable_device_token", value: "yes"),
            URLQueryItem(name: "device_name", value: normalizedDeviceName),
            URLQueryItem(name: "enable_syno_token", value: "yes"),
        ]
        if let code = Self.normalized(oneTimeCode) {
            queryItems.append(URLQueryItem(name: "otp_code", value: code))
        }

        var lastFailure: [String: Any]?
        for path in Self.authenticationPaths(preferredPath: api.authPath) {
            Self.logger.info(
                "login request source=\(sourceID.rawValue) endpoint=\(Self.endpointDescription(endpoint)) path=\(path) hasOTP=\(Self.hasValue(oneTimeCode)) hasChallengeToken=\(Self.hasValue(challengeToken))"
            )
            let root = try await performLoginRequest(
                sourceID: sourceID,
                endpoint: endpoint,
                path: path,
                queryItems: queryItems
            )
            guard (root["success"] as? Bool) == true else {
                lastFailure = root
                let code = Self.dsmErrorCode(root: root)
                if code == 102 { continue }
                if Self.normalized(oneTimeCode) != nil,
                   code == 403 || code == 404 || code == 406 {
                    throw OnlineSourceAuthenticationError.invalidOneTimeCode
                }
                if Self.isVerificationChallenge(
                    root: root,
                    hasOneTimeCode: Self.normalized(oneTimeCode) != nil
                ) {
                    throw DSAudioDeviceAuthorizationChallenge(
                        challengeToken: Self.challengeToken(root: root)
                    )
                }
                if code == 404, Self.normalized(oneTimeCode) != nil {
                    throw OnlineSourceAuthenticationError.invalidOneTimeCode
                }
                throw Self.mapDSMError(root: root)
            }

            guard let data = root["data"] as? [String: Any],
                  let sid = Self.string(data["sid"]),
                  !sid.isEmpty
            else {
                Self.logger.error(
                    "login success missing sid source=\(sourceID.rawValue) path=\(path)"
                )
                throw OnlineSourceAdapterError.invalidResponse
            }
            let deviceID = Self.normalized(Self.string(data["did"]) ?? Self.string(data["device_id"]))
            Self.logger.info(
                "login authorized source=\(sourceID.rawValue) path=\(path) hasDeviceID=\(deviceID != nil) hasSynoToken=\(Self.hasValue(Self.string(data["synotoken"])))"
            )
            let credential = try DSAudioCredential(
                account: normalizedAccount,
                password: password,
                deviceName: normalizedDeviceName,
                deviceID: deviceID,
                sessionID: sid,
                synoToken: Self.string(data["synotoken"])
            )
            try await credentialStore.save(
                secret: credential.encodedSecret,
                for: sourceID.rawValue
            )
            return DSAudioDeviceAuthorizationReceipt(
                deviceName: normalizedDeviceName,
                deviceID: deviceID
            )
        }

        throw lastFailure.map(Self.mapDSMError(root:))
            ?? OnlineSourceAdapterError.invalidResponse
    }

    private func performLoginRequest(
        sourceID: MediaSourceID,
        endpoint: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        var components = URLComponents(
            url: endpoint.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            Self.logger.error(
                "login network failure source=\(sourceID.rawValue) endpoint=\(Self.endpointDescription(endpoint)) path=\(path) error=\(Self.redactedNetworkError(error))"
            )
            throw error
        }
        do {
            try validateOnlineHTTPStatus(response)
        } catch {
            Self.logger.error(
                "login response source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode) errorType=\(String(describing: type(of: error)))"
            )
            throw error
        }
        guard let root = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any]
        else {
            Self.logger.error(
                "login response invalid JSON source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode)"
            )
            throw OnlineSourceAdapterError.invalidResponse
        }
        Self.logger.info(
            "login response source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode) success=\((root["success"] as? Bool) == true) dsmCode=\(Self.dsmErrorCode(root: root).map(String.init) ?? "none") keys=\(root.keys.sorted().joined(separator: ","))"
        )
        return root
    }

    private static func authenticationPaths(preferredPath: String) -> [String] {
        var paths = [preferredPath]
        for compatiblePath in ["webapi/entry.cgi", "webapi/auth.cgi"]
        where !paths.contains(compatiblePath) {
            paths.append(compatiblePath)
        }
        return paths
    }

    private static func challengeToken(root: [String: Any]) -> String? {
        let error = root["error"] as? [String: Any]
        let errors = error?["errors"] as? [String: Any]
        return string(errors?["token"]) ?? string(error?["token"])
    }

    private static func dsmErrorCode(root: [String: Any]) -> Int? {
        int((root["error"] as? [String: Any])?["code"])
            ?? int(root["code"])
    }

    private static func isVerificationChallenge(
        root: [String: Any],
        hasOneTimeCode: Bool
    ) -> Bool {
        // Synology's API.Auth returns 403/406 for an OTP challenge. Some DSM
        // versions include a token while others return only the error code.
        // Once an OTP was already submitted, the same codes represent a
        // rejected attempt instead of a new challenge.
        if !hasOneTimeCode,
           let code = dsmErrorCode(root: root),
           code == 403 || code == 406 {
            return true
        }
        let challengeKeys = [
            "token", "otp", "otp_code", "verification", "verification_code",
            "two_factor", "twoFactor", "device_token"
        ]
        return challengeKeys.contains { key in
            containsKey(root["error"], key: key) || root[key] != nil
        }
    }

    private static func containsKey(_ value: Any?, key: String) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey($0, key: key) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey($0, key: key) }
        }
        return false
    }

    private static func mapDSMError(root: [String: Any]) -> OnlineSourceAdapterError {
        switch dsmErrorCode(root: root) {
        case 105, 106:
            return .authorizationRequired
        case 400, 401, 402, 403:
            return .invalidCredential
        case 406:
            return .permissionDenied
        case 404:
            return .resourceNotFound
        case 429:
            return .rateLimited
        case let code?:
            return .serviceErrorCode(code)
        case nil:
            return .invalidResponse
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func hasValue(_ value: String?) -> Bool {
        normalized(value) != nil
    }

    private static func endpointDescription(_ endpoint: URL) -> String {
        guard let host = endpoint.host else { return "invalid-host" }
        if let port = endpoint.port {
            return "\(host):\(port)"
        }
        return host
    }

    private static func redactedNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: type(of: error))
    }
}
