import Foundation
import MediaSourceAPI
import MusicDomain

/// A short-lived OAuth session. It is deliberately not Codable, printable or
/// persisted; a Keychain/OAuth adapter owns the actual refresh token.
public struct GoogleDriveOAuthSession: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    public var description: String { "GoogleDriveOAuthSession(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// OAuth browser presentation, callback handling and refresh-token storage
/// stay outside the Provider source. This protocol is the stable seam for the
/// App composition root and for deterministic tests.
public protocol GoogleDriveOAuthProviding: Sendable {
    func authorize() async throws -> GoogleDriveOAuthSession
    func refresh(_ session: GoogleDriveOAuthSession) async throws -> GoogleDriveOAuthSession
    func validSession() async throws -> GoogleDriveOAuthSession
}

/// Scoped OAuth is used by the production implementation so multiple Drive
/// source instances never share a Keychain record accidentally. The original
/// unscoped methods remain available for deterministic fixtures and backward
/// compatibility.
public protocol ScopedGoogleDriveOAuthProviding: GoogleDriveOAuthProviding {
    func authorize(
        for configuration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession
    func refresh(
        _ session: GoogleDriveOAuthSession,
        for configuration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession
    func validSession(
        for configuration: GoogleDriveSourceConfiguration
    ) async throws -> GoogleDriveOAuthSession
}

public struct UnavailableGoogleDriveOAuth: GoogleDriveOAuthProviding, Sendable {
    public init() {}

    public func authorize() async throws -> GoogleDriveOAuthSession {
        throw OnlineSourceAdapterError.authorizationRequired
    }

    public func refresh(
        _ session: GoogleDriveOAuthSession
    ) async throws -> GoogleDriveOAuthSession {
        throw OnlineSourceAdapterError.authorizationRequired
    }

    public func validSession() async throws -> GoogleDriveOAuthSession {
        throw OnlineSourceAdapterError.authorizationRequired
    }
}

public struct GoogleDriveSourceConfiguration: Equatable, Sendable {
    public let sourceID: MediaSourceID
    public let displayName: String
    public let credentialRecordID: String?

    public init(
        sourceID: MediaSourceID,
        displayName: String,
        credentialRecordID: String? = nil
    ) {
        self.sourceID = sourceID
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialRecordID = credentialRecordID
    }

    public var resolvedCredentialRecordID: String {
        credentialRecordID ?? sourceID.rawValue
    }
}

/// Google Drive Catalog, export/download and temporary credential-bearing
/// requests are injected so the Provider type can be tested independently of
/// OAuth UI and URLSession.
public protocol GoogleDriveTransport: Sendable {
    func browse(
        configuration: GoogleDriveSourceConfiguration,
        session: GoogleDriveOAuthSession,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage

    func download(
        configuration: GoogleDriveSourceConfiguration,
        session: GoogleDriveOAuthSession,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt

    func artwork(
        configuration: GoogleDriveSourceConfiguration,
        session: GoogleDriveOAuthSession,
        artworkID: ArtworkID
    ) async throws -> ArtworkResource?
}

public extension GoogleDriveTransport {
    func artwork(
        configuration _: GoogleDriveSourceConfiguration,
        session _: GoogleDriveOAuthSession,
        artworkID _: ArtworkID
    ) async throws -> ArtworkResource? {
        nil
    }
}

/// Google Drive is intentionally a DownloadSource in 1.2.0. It downloads
/// through a temporary staging URL and hands a receipt to the local importer;
/// it does not advertise online playback.
public final class GoogleDriveSource: DownloadSource, @unchecked Sendable {
    public let descriptor: MediaSourceDescriptor
    public let capabilities: MediaSourceCapabilities
    public let providerKind: OnlineProviderKind = .googleDrive
    public let onlineCapabilities: OnlineSourceCapabilities = [
        .browsing,
        .downloading,
    ]
    public let privacyPolicyVersion: String = "1.2.0"

    private let configuration: GoogleDriveSourceConfiguration
    private let oauth: any GoogleDriveOAuthProviding
    private let transport: any GoogleDriveTransport

    public init(
        configuration: GoogleDriveSourceConfiguration,
        oauth: any GoogleDriveOAuthProviding,
        transport: any GoogleDriveTransport = UnavailableGoogleDriveTransport()
    ) {
        self.configuration = configuration
        self.oauth = oauth
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
        let session = try await validSession()
        return try await transport.artwork(
            configuration: configuration,
            session: session,
            artworkID: artworkID
        )
    }

    public func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
        let session = try await validSession()
        return try await transport.browse(
            configuration: configuration,
            session: session,
            request: request
        )
    }

    public func download(
        _ itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        let session = try await validSession()
        return try await transport.download(
            configuration: configuration,
            session: session,
            itemID: itemID,
            options: options
        )
    }

    private func validSession() async throws -> GoogleDriveOAuthSession {
        if let scoped = oauth as? any ScopedGoogleDriveOAuthProviding {
            return try await scoped.validSession(for: configuration)
        }
        return try await oauth.validSession()
    }
}

public struct UnavailableGoogleDriveTransport: GoogleDriveTransport, Sendable {
    public init() {}

    public func browse(
        configuration _: GoogleDriveSourceConfiguration,
        session _: GoogleDriveOAuthSession,
        request _: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        throw OnlineSourceAdapterError.transportUnavailable
    }

    public func download(
        configuration _: GoogleDriveSourceConfiguration,
        session _: GoogleDriveOAuthSession,
        itemID _: SourceObjectID,
        options _: DownloadOptions
    ) async throws -> DownloadReceipt {
        throw OnlineSourceAdapterError.transportUnavailable
    }
}
