import Foundation
import MediaSourceAPI
import MusicDomain
import OnlineSourceAdapter
import Testing

@Test("DS Audio exposes download, search and audition protocol capabilities")
func dsAudioAdapterExposesExpectedCapabilities() async throws {
    let source = DSAudioSource(
        configuration: try DSAudioSourceConfiguration(
            sourceID: MediaSourceID("dsaudio.adapter.fixture"),
            displayName: "DS Audio Fixture",
            endpoint: #require(URL(string: "https://nas.example.test"))
        )
    )
    let playbackSource: any PlaybackSource = source
    let searchableSource: any SearchableDownloadSource = source

    #expect(source.providerKind == OnlineProviderKind.dsAudio)
    #expect(source.onlineCapabilities.contains(OnlineSourceCapabilities.browsing))
    #expect(source.onlineCapabilities.contains(OnlineSourceCapabilities.downloading))
    #expect(source.onlineCapabilities.contains(OnlineSourceCapabilities.onlinePlayback))
    #expect(playbackSource.onlineCapabilities == source.onlineCapabilities)
    #expect(searchableSource.onlineCapabilities.contains(OnlineSourceCapabilities.searching))

    await #expect(throws: OnlineSourceAdapterError.transportUnavailable) {
        try await source.browse(SourceBrowseRequest())
    }
    await #expect(throws: OnlineSourceAdapterError.transportUnavailable) {
        try await source.authenticate(oneTimeCode: "123456")
    }
}

@Test("Google Drive exposes OAuth and download-only Provider boundary")
func googleDriveAdapterExposesExpectedCapabilities() async throws {
    let source = GoogleDriveSource(
        configuration: GoogleDriveSourceConfiguration(
            sourceID: MediaSourceID("drive.adapter.fixture"),
            displayName: "Drive Fixture",
            credentialRecordID: "keychain.fixture"
        ),
        oauth: FixtureGoogleDriveOAuth()
    )
    let downloadSource: any DownloadSource = source

    #expect(source.providerKind == OnlineProviderKind.googleDrive)
    #expect(source.onlineCapabilities.contains(OnlineSourceCapabilities.browsing))
    #expect(source.onlineCapabilities.contains(OnlineSourceCapabilities.downloading))
    #expect(!source.onlineCapabilities.contains(OnlineSourceCapabilities.onlinePlayback))
    #expect(downloadSource.descriptor.displayName == "Drive Fixture")

    await #expect(throws: OnlineSourceAdapterError.transportUnavailable) {
        try await source.browse(SourceBrowseRequest())
    }
}

@Test("Default online source factory supports multiple DS Audio and Google Drive instances")
func defaultOnlineSourceFactoryCreatesIndependentInstances() throws {
    let factory = DefaultOnlineSourceFactory()
    let firstConfiguration = try OnlineSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.factory.home"),
        providerKind: .dsAudio,
        displayName: "Home NAS",
        endpoint: URL(string: "https://home.example.test")
    )
    let secondConfiguration = try OnlineSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.factory.office"),
        providerKind: .dsAudio,
        displayName: "Office NAS",
        endpoint: URL(string: "https://office.example.test")
    )
    let driveConfiguration = try OnlineSourceConfiguration(
        sourceID: MediaSourceID("drive.factory.personal"),
        providerKind: .googleDrive,
        displayName: "Personal Drive"
    )

    let firstOptional = try factory.makeSource(for: firstConfiguration)
    let secondOptional = try factory.makeSource(for: secondConfiguration)
    let driveOptional = try factory.makeSource(for: driveConfiguration)
    let first = try #require(firstOptional)
    let second = try #require(secondOptional)
    let drive = try #require(driveOptional)

    #expect(first.descriptor.sourceID == firstConfiguration.sourceID)
    #expect(second.descriptor.sourceID == secondConfiguration.sourceID)
    #expect(first.descriptor.sourceID != second.descriptor.sourceID)
    #expect(first.providerKind == .dsAudio)
    #expect(second.providerKind == .dsAudio)
    #expect(drive.providerKind == .googleDrive)
    #expect(drive.onlineCapabilities.contains(.downloading))
    #expect(!drive.onlineCapabilities.contains(.onlinePlayback))
}

@Test("OAuth session and temporary access values stay redacted")
func oauthSessionDoesNotLeakSecrets() {
    let session = GoogleDriveOAuthSession(accessToken: "fixture-secret")

    #expect(session.description == "GoogleDriveOAuthSession(redacted)")
    #expect(!String(reflecting: session).contains("fixture-secret"))
    #expect(!(GoogleDriveOAuthSession.self is any Encodable.Type))
}

@Test("Google Drive OAuth configuration retains both client identifiers")
func googleDriveOAuthConfigurationRetainsClientIdentifiers() throws {
    let configuration = try GoogleDriveOAuthConfiguration(
        clientID: "123456789012-test.apps.googleusercontent.com",
        reversedClientID: " com.googleusercontent.apps.123456789012-test ",
        redirectURL: #require(
            URL(string: "com.googleusercontent.apps.123456789012-test:/oauth2redirect/google")
        )
    )

    #expect(
        configuration.clientID
            == "123456789012-test.apps.googleusercontent.com"
    )
    #expect(
        configuration.reversedClientID
            == "com.googleusercontent.apps.123456789012-test"
    )
}

private struct FixtureGoogleDriveOAuth: GoogleDriveOAuthProviding {
    func authorize() async throws -> GoogleDriveOAuthSession {
        GoogleDriveOAuthSession(accessToken: "fixture-secret")
    }

    func refresh(
        _ session: GoogleDriveOAuthSession
    ) async throws -> GoogleDriveOAuthSession {
        session
    }

    func validSession() async throws -> GoogleDriveOAuthSession {
        try await authorize()
    }
}
