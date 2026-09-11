import Foundation
import MediaSourceAPI
import MusicDomain

public enum OnlineSourceAdapterModule {}

public enum OnlineSourceAdapterError: Error, Equatable, Sendable, LocalizedError,
    CustomStringConvertible {
    case invalidProvider
    case missingEndpoint
    case missingCredential
    case authorizationRequired
    case invalidResponse
    case transportUnavailable
    case invalidCredential
    case permissionDenied
    case resourceNotFound
    case rateLimited
    case httpStatus(Int)
    /// A provider API returned an application-level error code. This is kept
    /// separate from `httpStatus` because DSM commonly returns HTTP 200 with
    /// a nested service error code.
    case serviceErrorCode(Int)
    case operationNotImplemented(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidProvider:
            return "在线源类型配置错误。"
        case .missingEndpoint:
            return "缺少在线源地址。"
        case .missingCredential:
            return "找不到在线源凭据。"
        case .authorizationRequired:
            return "在线源授权已过期。"
        case .invalidResponse:
            return "在线源返回的数据无法识别。"
        case .transportUnavailable:
            return "当前版本暂不支持此在线源。"
        case .invalidCredential:
            return "账号或密码不正确，或 DSM 拒绝了当前登录。"
        case .permissionDenied:
            return "在线源拒绝了访问。"
        case .resourceNotFound:
            return "找不到在线源资源。"
        case .rateLimited:
            return "在线源请求过于频繁。"
        case .httpStatus(let status):
            return "在线源返回网络错误（HTTP \(status)）。"
        case .serviceErrorCode(let code):
            return "在线源服务返回错误（代码 \(code)）。"
        case .operationNotImplemented(let operation):
            return "在线源暂不支持：\(operation)。"
        }
    }
}

extension OnlineSourceAdapterError: OnlineSourceAuthorizationRecoverableError {
    public var requiresUserAuthorization: Bool {
        switch self {
        case .authorizationRequired, .invalidCredential:
            true
        default:
            false
        }
    }
}

/// A credential reference contains no secret. Adapters resolve it through a
/// Keychain-backed provider only for the duration of one request.
public protocol OnlineCredentialProviding: Sendable {
    func secret(for recordID: String) async throws -> String
}

public struct DSAudioSourceConfiguration: Equatable, Sendable {
    public let sourceID: MediaSourceID
    public let displayName: String
    public let endpoint: URL
    public let credentialRecordID: String?

    public init(
        sourceID: MediaSourceID,
        displayName: String,
        endpoint: URL,
        credentialRecordID: String? = nil
    ) throws {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        components.host != nil
        else {
            throw OnlineSourceAdapterError.missingEndpoint
        }

        self.sourceID = sourceID
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
        self.credentialRecordID = credentialRecordID
    }
}

/// Network and DSM-specific parsing are injected behind this transport. This
/// keeps the source protocol testable without putting URLSession, cookies or
/// OAuth values into AppServices or persisted settings.
public protocol DSAudioTransport: Sendable {
    func authenticate(
        configuration: DSAudioSourceConfiguration,
        oneTimeCode: String
    ) async throws

    func browse(
        configuration: DSAudioSourceConfiguration,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage

    func search(
        configuration: DSAudioSourceConfiguration,
        request: SourceSearchRequest
    ) async throws -> SourceCatalogPage

    func download(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt

    func playbackAccess(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        purpose: PlaybackPurpose
    ) async throws -> PlaybackAccess

    func artwork(
        configuration: DSAudioSourceConfiguration,
        artworkID: ArtworkID
    ) async throws -> ArtworkResource?
}

public extension DSAudioTransport {
    func artwork(
        configuration _: DSAudioSourceConfiguration,
        artworkID _: ArtworkID
    ) async throws -> ArtworkResource? {
        nil
    }
}

/// DS Audio source boundary. The default transport is intentionally inert;
/// the production transport will own DSM API discovery, login/session renewal,
/// catalog mapping, staging downloads and temporary stream URL generation.
public final class DSAudioSource: SearchableDownloadSource, PlaybackSource,
    OneTimeCodeAuthenticatingOnlineSource, @unchecked Sendable {
    public let descriptor: MediaSourceDescriptor
    public let capabilities: MediaSourceCapabilities
    public let providerKind: OnlineProviderKind = .dsAudio
    public let onlineCapabilities: OnlineSourceCapabilities = [
        .browsing,
        .downloading,
        .searching,
        .onlinePlayback,
        .httpTranscoding,
        .artwork,
    ]
    public let privacyPolicyVersion: String = "1.2.0"

    private let configuration: DSAudioSourceConfiguration
    private let transport: any DSAudioTransport

    public init(
        configuration: DSAudioSourceConfiguration,
        transport: any DSAudioTransport = UnavailableDSAudioTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        descriptor = MediaSourceDescriptor(
            sourceID: configuration.sourceID,
            kind: .remote,
            displayName: configuration.displayName,
            isReadOnly: true
        )
        capabilities = [.artwork, .metadataReading]
    }

    public func resolve(_ assetID: MediaItemID) async throws -> PlaybackResource {
        throw OnlineSourceAdapterError.operationNotImplemented(
            "resolve imported media item \(assetID.sourceID)"
        )
    }

    public func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
        try await transport.artwork(configuration: configuration, artworkID: artworkID)
    }

    public func authenticate(oneTimeCode: String) async throws {
        try await transport.authenticate(
            configuration: configuration,
            oneTimeCode: oneTimeCode
        )
    }

    public func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
        try await transport.browse(configuration: configuration, request: request)
    }

    public func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage {
        try await transport.search(configuration: configuration, request: request)
    }

    public func download(
        _ itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        try await transport.download(
            configuration: configuration,
            itemID: itemID,
            options: options
        )
    }

    public func playbackAccess(
        for itemID: SourceObjectID,
        purpose: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        try await transport.playbackAccess(
            configuration: configuration,
            itemID: itemID,
            purpose: purpose
        )
    }
}

public struct UnavailableDSAudioTransport: DSAudioTransport, Sendable {
    public init() {}

    public func authenticate(
        configuration _: DSAudioSourceConfiguration,
        oneTimeCode _: String
    ) async throws {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func browse(
        configuration _: DSAudioSourceConfiguration,
        request _: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func search(
        configuration _: DSAudioSourceConfiguration,
        request _: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func download(
        configuration _: DSAudioSourceConfiguration,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func playbackAccess(
        configuration _: DSAudioSourceConfiguration,
        itemID _: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        throw OnlineSourceAdapterError.transportUnavailable
    }
}
