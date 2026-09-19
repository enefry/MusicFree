import Foundation
import MediaSourceAPI

/// Composition-root factory for the Provider adapters currently in 1.2.0.
///
/// Transport and OAuth implementations remain injectable so the app can use
/// inert defaults in builds that do not yet have a real DSM/Google session,
/// while tests can provide deterministic fixtures. Each configuration still
/// produces an independent adapter instance.
public struct DefaultOnlineSourceFactory: OnlineSourceFactory, Sendable {
    private let dsAudioTransport: any DSAudioTransport
    private let googleDriveOAuth: any GoogleDriveOAuthProviding
    private let googleDriveTransport: any GoogleDriveTransport

    public init(
        dsAudioTransport: (any DSAudioTransport)? = nil,
        dsAudioCredentialProvider: any OnlineCredentialProviding = KeychainOnlineCredentialStore(),
        googleDriveOAuth: (any GoogleDriveOAuthProviding)? = nil,
        googleDriveTransport: any GoogleDriveTransport = GoogleDriveHTTPTransport()
    ) {
        self.dsAudioTransport = dsAudioTransport
            ?? DSAudioHTTPTransport(credentialProvider: dsAudioCredentialProvider)
        if let googleDriveOAuth {
            self.googleDriveOAuth = googleDriveOAuth
        } else if let configuration = GoogleDriveOAuthConfiguration.fromMainBundle() {
            self.googleDriveOAuth = GoogleDriveOAuthClient(configuration: configuration)
        } else {
            self.googleDriveOAuth = UnavailableGoogleDriveOAuth()
        }
        self.googleDriveTransport = googleDriveTransport
    }

    public func makeSource(
        for configuration: OnlineSourceConfiguration
    ) throws -> (any OnlineSource)? {
        switch configuration.providerKind {
        case .dsAudio:
            guard let endpoint = configuration.endpoint else {
                throw OnlineSourceAdapterError.missingEndpoint
            }
            return DSAudioSource(
                configuration: try DSAudioSourceConfiguration(
                    sourceID: configuration.sourceID,
                    displayName: configuration.displayName,
                    endpoint: endpoint,
                    credentialRecordID: configuration.credentialRecordID
                        ?? configuration.sourceID.rawValue
                ),
                transport: dsAudioTransport
            )
        case .googleDrive:
            let sourceOAuth: any GoogleDriveOAuthProviding
            if let clientID = configuration.googleDriveClientID,
               let userConfiguration = GoogleDriveOAuthConfiguration.fromMainBundle(
                   clientIDOverride: clientID
               ) {
                sourceOAuth = GoogleDriveOAuthClient(configuration: userConfiguration)
            } else {
                sourceOAuth = googleDriveOAuth
            }
            return GoogleDriveSource(
                configuration: GoogleDriveSourceConfiguration(
                    sourceID: configuration.sourceID,
                    displayName: configuration.displayName,
                    rootObjectID: configuration.rootObjectID,
                    clientID: configuration.googleDriveClientID,
                    credentialRecordID: configuration.credentialRecordID
                        ?? configuration.sourceID.rawValue
                ),
                oauth: sourceOAuth,
                transport: googleDriveTransport
            )
        case .baiduPan, .gateway:
            return nil
        }
    }
}
