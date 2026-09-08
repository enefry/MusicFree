import Foundation
import MediaSourceAPI
import MusicDomain
import OnlineSourceAdapter
import Testing

@Test("Google Drive HTTP transport maps Catalog folders and audio files")
func googleDriveHTTPTransportMapsCatalog() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "pageSize" })?.value == "2")
        return (
            Data(
                """
                {"nextPageToken":"next-page","files":[
                  {"id":"folder-1","name":"Albums","mimeType":"application/vnd.google-apps.folder","parents":["root"]},
                  {"id":"track-1","name":"Song.flac","mimeType":"audio/flac","size":"42","md5Checksum":"md5","parents":["root"]}
                ]}
                """.utf8
            ),
            try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
        )
    }

    let baseURL = try #require(URL(string: "https://drive.example.test/drive/v3"))
    let transport = GoogleDriveHTTPTransport(
        baseURL: baseURL,
        httpClient: client
    )
    let sourceID = MediaSourceID("drive.transport.fixture")
    let configuration = GoogleDriveSourceConfiguration(
        sourceID: sourceID,
        displayName: "Fixture Drive"
    )
    let page = try await transport.browse(
        configuration: configuration,
        session: GoogleDriveOAuthSession(accessToken: "fixture-token"),
        request: SourceBrowseRequest(pageSize: 2)
    )

    #expect(page.nextPageToken?.rawValue == "next-page")
    #expect(page.items.count == 2)
    #expect(page.items[0].kind == .folder)
    #expect(page.items[0].id.externalID == "folder-1")
    #expect(page.items[1].kind == .audioFile)
    #expect(page.items[1].isPlayable)
    #expect(page.items[1].byteSize == 42)
    #expect(page.items[1].contentRevision == "md5")
}

@Test("Google Drive HTTP transport stages a downloaded file without retaining the remote URL")
func googleDriveHTTPTransportStagesDownload() async throws {
    let client = StubOnlineHTTPClient()
    client.downloadHandler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-drive-fixture-\(UUID().uuidString).flac")
        try Data("fixture-audio".utf8).write(to: temporaryURL, options: .atomic)
        return (
            temporaryURL,
            try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/flac"]
            ))
        )
    }

    let transport = GoogleDriveHTTPTransport(httpClient: client)
    let sourceID = MediaSourceID("drive.download.fixture")
    let itemID = SourceObjectID(sourceID: sourceID, externalID: "file-1")
    let receipt = try await transport.download(
        configuration: GoogleDriveSourceConfiguration(
            sourceID: sourceID,
            displayName: "Fixture Drive"
        ),
        session: GoogleDriveOAuthSession(accessToken: "fixture-token"),
        itemID: itemID,
        options: DownloadOptions(preferredFileName: "Song.flac")
    )
    defer { try? FileManager.default.removeItem(at: receipt.fileURL) }

    #expect(receipt.sourceID == sourceID)
    #expect(receipt.itemID == itemID)
    #expect(receipt.fileURL.lastPathComponent == "Song.flac")
    #expect(receipt.fileURL.pathExtension == "flac")
    #expect(try Data(contentsOf: receipt.fileURL) == Data("fixture-audio".utf8))
    #expect(!receipt.description.contains("fixture-token"))
}

@Test("DS Audio HTTP transport logs in once and exposes browse, download and audition")
func dsAudioHTTPTransportPerformsSourceOperations() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            #expect(components.queryItems?.first(where: { $0.name == "account" })?.value == "fixture-account")
            #expect(components.queryItems?.first(where: { $0.name == "passwd" })?.value == "fixture-password")
            return (Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8), try #require(okResponse(for: request)))
        }
        #expect(components.queryItems?.first(where: { $0.name == "_sid" })?.value == "fixture-sid")
        if components.queryItems?.first(where: { $0.name == "method" })?.value == "list" {
            #expect(
                components.queryItems?.first(where: { $0.name == "additional" })?.value
                    == "song_tag,song_audio"
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"songs":[{"id":"song-1","filename":"Artist - Fixture Album.m4a","title":"Artist - Fixture Album.m4a","duration":123,"additional":{"song_tag":{"title":"Fixture Song","artist":"Fixture Artist","album":"Fixture Album"},"song_audio":{"container":"m4a"}}}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    client.downloadHandler = { request in
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-audio-fixture-\(UUID().uuidString).m4a")
        try Data("fixture-ds-audio".utf8).write(to: temporaryURL, options: .atomic)
        return (temporaryURL, try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mp4"]
        )))
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.transport.fixture")
    let endpoint = try #require(URL(string: "https://nas.example.test"))
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Fixture NAS",
        endpoint: endpoint,
        credentialRecordID: "fixture-record"
    )
    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )
    #expect(page.items.count == 1)
    #expect(page.items[0].title == "Fixture Song")
    #expect(page.items[0].artist == "Fixture Artist")
    #expect(page.items[0].album == "Fixture Album")

    let itemID = page.items[0].id
    let access = try await transport.playbackAccess(
        configuration: configuration,
        itemID: itemID,
        purpose: .audition
    )
    guard case .http(let request, _) = access else {
        Issue.record("DS Audio audition did not return HTTP access")
        return
    }
    #expect(request.url.absoluteString.contains("_sid=fixture-sid"))
    #expect(request.description == "RemotePlaybackRequest(redacted)")

    let receipt = try await transport.download(
        configuration: configuration,
        itemID: itemID,
        options: DownloadOptions(preferredFileName: "Fixture Song.m4a")
    )
    defer { try? FileManager.default.removeItem(at: receipt.fileURL) }
    #expect(receipt.fileURL.lastPathComponent == "Fixture Song.m4a")
    #expect(try Data(contentsOf: receipt.fileURL) == Data("fixture-ds-audio".utf8))
    #expect(client.requests.filter {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "api" && $0.value == "SYNO.API.Auth" }) == true
    }.count == 1)
}

@Test("DS Audio maps song metadata when additional is a JSON string")
func dsAudioMapsSongMetadataFromJSONStringAdditional() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"""
                {"success":true,"data":{"songs":[
                  {"id":"song-json-tag","filename":"Album Container.wav","title":"Album Container.wav",
                   "additional":"{\"song_tag\":{\"title\":\"真实曲名\",\"artist\":\"真实艺人\",\"album\":\"真实专辑\"},\"song_audio\":{\"container\":\"wav\"}}"}
                ]}}
                """#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.json-tag.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "JSON Tag NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )

    let item = try #require(page.items.first)
    #expect(item.title == "真实曲名")
    #expect(item.artist == "真实艺人")
    #expect(item.album == "真实专辑")
}

@Test("DS Audio downloads acknowledged commands through stream bytes and transcodes virtual IDs")
func dsAudioHTTPTransportDownloadsAcknowledgedCommandsFromStream() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        #expect(query["_sid"] == "fixture-sid")
        if query["api"] == "SYNO.API.Info" {
            return (
                Data(
                    """
                    {"success":true,"data":{
                      "SYNO.AudioStation.Download":{"path":"AudioStation/download.cgi","minVersion":1,"maxVersion":1},
                      "SYNO.AudioStation.Stream":{"path":"AudioStation/stream.cgi","minVersion":2,"maxVersion":2}
                    }}
                    """.utf8
                ),
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
            )
        }
        Issue.record("Unexpected DS Audio data request")
        return (
            Data(#"{"success":false,"error":{"code":404}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }
    client.downloadHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-audio-stream-\(UUID().uuidString)")
        if query["api"] == "SYNO.AudioStation.Download" {
            try Data(#"{"success":true}"#.utf8).write(to: temporaryURL, options: .atomic)
            return (
                temporaryURL,
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ))
            )
        }

        #expect(query["api"] == "SYNO.AudioStation.Stream")
        #expect(query["method"] == "transcode")
        #expect(query["format"] == "mp3")
        #expect(request.url?.path.hasSuffix("/webapi/AudioStation/stream.cgi/0.mp3") == true)
        try Data("fixture-transcoded-audio".utf8).write(to: temporaryURL, options: .atomic)
        return (
            temporaryURL,
            try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            ))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password",
        sessionID: "fixture-sid"
    )
    let sourceID = MediaSourceID("dsaudio.stream-fallback.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Stream Fallback NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let itemID = SourceObjectID(
        sourceID: sourceID,
        externalID: "music_v_virtual-song"
    )

    let receipt = try await transport.download(
        configuration: configuration,
        itemID: itemID,
        options: DownloadOptions(preferredFileName: "Live Song.flac")
    )
    defer { try? FileManager.default.removeItem(at: receipt.fileURL) }

    #expect(receipt.fileURL.lastPathComponent == "Live Song.mp3")
    #expect(receipt.fileURL.pathExtension == "mp3")
    #expect(try Data(contentsOf: receipt.fileURL) == Data("fixture-transcoded-audio".utf8))
    #expect(client.requests.compactMap {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "api" })?.value
    } == ["SYNO.API.Info", "SYNO.AudioStation.Download", "SYNO.API.Info", "SYNO.AudioStation.Stream"])

    let access = try await transport.playbackAccess(
        configuration: configuration,
        itemID: itemID,
        purpose: .audition
    )
    guard case .http(let request, let transcode) = access else {
        Issue.record("DS Audio virtual item did not return HTTP audition access")
        return
    }
    #expect(request.url.path.hasSuffix("/webapi/AudioStation/stream.cgi/0.mp3"))
    #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
        .queryItems?.contains(where: { $0.name == "method" && $0.value == "transcode" }) == true)
    #expect(transcode?.container == "mp3")
}

@Test("DS Audio download refreshes one expired persisted session and retries once")
func dsAudioHTTPTransportRecoversExpiredDownloadSession() async throws {
    let client = StubOnlineHTTPClient()
    var binaryDownloadAttempts = 0
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        switch query["api"] {
        case "SYNO.API.Info":
            return (
                Data(
                    #"{"success":true,"data":{"SYNO.AudioStation.Download":{"path":"AudioStation/download.cgi","minVersion":1,"maxVersion":1}}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        case "SYNO.API.Auth":
            return (
                Data(#"{"success":true,"data":{"sid":"fresh-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        default:
            Issue.record("Unexpected DS Audio data request: \(query["api"] ?? "unknown")")
            return (
                Data(#"{"success":true}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
    }
    client.downloadHandler = { request in
        let query = Dictionary(
            uniqueKeysWithValues: (
                try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
                    .queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["api"] == "SYNO.AudioStation.Download")
        binaryDownloadAttempts += 1
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-audio-session-recovery-\(UUID().uuidString)")
        let payload: Data
        let headers: [String: String]
        if binaryDownloadAttempts == 1 {
            payload = Data(#"{"success":false,"error":{"code":105}}"#.utf8)
            headers = ["Content-Type": "application/json"]
        } else {
            #expect(query["_sid"] == "fresh-sid")
            payload = Data("recovered-audio".utf8)
            headers = ["Content-Type": "audio/mpeg"]
        }
        try payload.write(to: temporaryURL, options: .atomic)
        return (
            temporaryURL,
            try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            ))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password",
        sessionID: "stale-sid"
    )
    let sourceID = MediaSourceID("dsaudio.session-recovery.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Session Recovery NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let receipt = try await transport.download(
        configuration: configuration,
        itemID: SourceObjectID(sourceID: sourceID, externalID: "song-recovery"),
        options: DownloadOptions(preferredFileName: "Recovered Song.mp3")
    )
    defer { try? FileManager.default.removeItem(at: receipt.fileURL) }

    #expect(binaryDownloadAttempts == 2)
    #expect(try Data(contentsOf: receipt.fileURL) == Data("recovered-audio".utf8))
    #expect(client.requests.contains {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "api" && $0.value == "SYNO.API.Auth" }) == true
    })
}

@Test("DS Audio HTTP transport completes a DSM two-factor authentication challenge")
func dsAudioHTTPTransportCompletesTwoFactorChallenge() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let queryItems = components.queryItems ?? []
        let api = queryItems.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            let oneTimeCode = queryItems.first(where: { $0.name == "otp_code" })?.value
            switch oneTimeCode {
            case nil:
                return (
                    Data(#"{"success":false,"error":{"code":403}}"#.utf8),
                    try #require(okResponse(for: request))
                )
            case "000000":
                return (
                    Data(#"{"success":false,"error":{"code":404}}"#.utf8),
                    try #require(okResponse(for: request))
                )
            case "123456":
                return (
                    Data(#"{"success":true,"data":{"sid":"two-factor-sid"}}"#.utf8),
                    try #require(okResponse(for: request))
                )
            default:
                Issue.record("Unexpected one-time code")
                return (
                    Data(#"{"success":false,"error":{"code":404}}"#.utf8),
                    try #require(okResponse(for: request))
                )
            }
        }
        #expect(queryItems.first(where: { $0.name == "_sid" })?.value == "two-factor-sid")
        return (
            Data(#"{"success":true,"data":{"songs":[]}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.two-factor.fixture"),
        displayName: "Two-Factor NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    await #expect(throws: OnlineSourceAuthenticationError.oneTimeCodeRequired) {
        try await transport.browse(
            configuration: configuration,
            request: SourceBrowseRequest()
        )
    }
    await #expect(throws: OnlineSourceAuthenticationError.invalidOneTimeCode) {
        try await transport.authenticate(
            configuration: configuration,
            oneTimeCode: "000000"
        )
    }

    try await transport.authenticate(
        configuration: configuration,
        oneTimeCode: "123456"
    )
    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )
    #expect(page.items.isEmpty)
}

@Test("DS Audio HTTP transport retries the compatible login endpoint after DSM error 102")
func dsAudioHTTPTransportRetriesCompatibleLoginEndpoint() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let path = try #require(request.url?.path)
        if path.hasSuffix("/webapi/auth.cgi") {
            return (
                Data(#"{"success":false,"error":{"code":102}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        #expect(path.hasSuffix("/webapi/entry.cgi"))
        return (
            Data(#"{"success":true,"data":{"sid":"compatible-entry-sid"}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client,
        api: DSAudioAPIConfiguration(authPath: "webapi/auth.cgi")
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.compatible-auth.fixture"),
        displayName: "Compatible Auth NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    try await transport.authenticate(
        configuration: configuration,
        oneTimeCode: "123456"
    )
    #expect(client.requests.map { $0.url?.path } == [
        "/webapi/auth.cgi",
        "/webapi/entry.cgi",
    ])
}

@Test("DS Audio browse discovers the NAS Song API after error 102")
func dsAudioBrowseDiscoversSongAPIAfterError102() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        if query["api"] == "SYNO.API.Info" {
            return (
                Data(
                    #"{"success":true,"data":{"SYNO.AudioStation.Song":{"path":"AudioStation/song.cgi","minVersion":1,"maxVersion":2}}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
        if request.url?.path == "/webapi/entry.cgi" {
            #expect(query["api"] == "SYNO.AudioStation.Folder")
            return (
                Data(#"{"success":false,"error":{"code":102}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        #expect(request.url?.path == "/webapi/AudioStation/song.cgi")
        #expect(query["api"] == "SYNO.AudioStation.Song")
        #expect(query["version"] == "2")
        return (
            Data(
                #"{"success":true,"data":{"songs":[{"id":"song-102","title":"Recovered Song","duration":60}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password",
        sessionID: "fixture-sid"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.discovery.fixture"),
        displayName: "Discovery NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )

    #expect(page.items.map(\.title) == ["Recovered Song"])
    #expect(client.requests.map { $0.url?.path } == [
        "/webapi/entry.cgi",
        "/webapi/entry.cgi",
        "/webapi/AudioStation/song.cgi",
    ])
}

@Test("DS Audio maps folder children and extensionless explicit files")
func dsAudioMapsFolderChildrenAndExtensionlessFiles() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"""
                {"success":true,"data":{"children":[
                    {"folder_id":"folder-1","name":"Albums","isdir":true},
                    {"file_id":"song-1","type":"file","name":"Extensionless Song","duration":123,"artist":"Fixture Artist"}
                ]}}
                """#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.children.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Children NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )

    #expect(page.items.map(\.displayName) == ["Albums", "Extensionless Song"])
    #expect(page.items[0].kind == .folder)
    #expect(!page.items[0].isDownloadable)
    #expect(page.items[1].kind == .audioFile)
    #expect(page.items[1].isPlayable)
    #expect(page.items[1].isDownloadable)
    #expect(page.items[1].artist == "Fixture Artist")
}

@Test("DS Audio merges folder and song collections without dropping either kind")
func dsAudioMergesFolderAndSongCollections() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = try #require(
            components.queryItems?.first(where: { $0.name == "api" })?.value
        )
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"folders":[{"id":"folder-1","name":"Albums","isdir":true},{"id":"folder-2","name":"Singles","isdir":true}],"songs":[{"id":"song-1","filename":"One.mp3","title":"One"},{"id":"folder-1","filename":"Duplicate Namespace Item.mp3"},{"id":"song-2","filename":"Two.mp3","title":"Two"}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.mixed-collections.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Mixed Collections NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )

    #expect(page.items.map(\.displayName) == [
        "Albums", "Singles", "One.mp3", "Two.mp3"
    ])
    #expect(page.items.map(\.kind) == [.folder, .folder, .audioFile, .audioFile])
    #expect(Set(page.items.map(\.id.externalID)).count == page.items.count)
}

@Test("DS Audio keeps album and artist roots navigable and scopes child requests")
func dsAudioKeepsAlbumAndArtistRootsNavigable() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        let api = try #require(query["api"])
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        switch api {
        case "SYNO.AudioStation.Album":
            return (
                Data(#"{"success":true,"data":{"albums":[{"id":"album-1","name":"Fixture Album","artist":"Fixture Artist"}]}}"#.utf8),
                try #require(okResponse(for: request))
            )
        case "SYNO.AudioStation.Artist":
            return (
                Data(#"{"success":true,"data":{"artists":[{"id":"artist-1","name":"Fixture Artist"}]}}"#.utf8),
                try #require(okResponse(for: request))
            )
        default:
            return (
                Data(#"{"success":true,"data":{"songs":[{"id":"song-1","title":"Fixture Song","type":"song"}]}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.dimension.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Dimension NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let albumPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .albums)
    )
    let album = try #require(albumPage.items.first)
    #expect(album.kind == .album)
    #expect(album.kind.isContainer)
    #expect(!album.isDownloadable)

    let albumSongs = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            parentID: album.id,
            mode: .albums
        )
    )
    #expect(albumSongs.items.first?.kind == .track)
    let albumComponents = try #require(
        URLComponents(url: client.requests.last!.url!, resolvingAgainstBaseURL: false)
    )
    let albumQuery = albumComponents.queryItems ?? []
    #expect(albumQuery.first(where: { $0.name == "album_id" })?.value == "album-1")

    let artistPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .artists)
    )
    let artist = try #require(artistPage.items.first)
    #expect(artist.kind == .artist)
    #expect(artist.kind.isContainer)

    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            parentID: SourceObjectID(sourceID: sourceID, externalID: "folder-1"),
            mode: .folders
        )
    )
    let folderComponents = try #require(
        URLComponents(url: client.requests.last!.url!, resolvingAgainstBaseURL: false)
    )
    let folderQuery = folderComponents.queryItems ?? []
    #expect(folderQuery.first(where: { $0.name == "folder_id" })?.value == "folder-1")
}

@Test("DS Audio maps dimension records that do not contain object ids")
func dsAudioMapsDimensionRecordsWithoutObjectIDs() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        let api = try #require(query["api"])
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        switch api {
        case "SYNO.AudioStation.Album":
            return (
                Data(
                    #"{"success":true,"data":{"albums":[{"album_artist":"崔健","artist":"","display_artist":"崔健","name":"-","year":1999},{"album_artist":"","artist":"","display_artist":"","name":"1999-我的快乐时代","year":0}],"offset":0,"total":14645}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        case "SYNO.AudioStation.Artist":
            return (
                Data(
                    #"{"success":true,"data":{"artists":[{"artist":"崔健","display_artist":"崔健","name":"崔健"}]}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        default:
            return (
                Data(
                    #"{"success":true,"data":{"songs":[{"id":"song-1","title":"Fixture Song","type":"song"}]}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.dimension-without-id.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Dimension Without IDs NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let albumPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .albums, pageSize: 2)
    )
    #expect(albumPage.items.map(\.displayName) == ["-", "1999-我的快乐时代"])
    #expect(albumPage.items.map(\.kind) == [.album, .album])
    #expect(albumPage.items[0].artist == "崔健")
    #expect(albumPage.items[0].album == "-")
    #expect(albumPage.items.allSatisfy { $0.id.externalID.hasPrefix("dsaudio.synthetic.album.") })
    #expect(albumPage.nextPageToken?.rawValue == "2")

    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            parentID: try #require(albumPage.items.first?.id),
            mode: .albums
        )
    )
    let albumComponents = try #require(
        URLComponents(url: client.requests.last!.url!, resolvingAgainstBaseURL: false)
    )
    let albumQuery = albumComponents.queryItems ?? []
    #expect(albumQuery.first(where: { $0.name == "album" })?.value == "-")
    #expect(albumQuery.first(where: { $0.name == "album_artist" })?.value == "崔健")
    #expect(albumQuery.first(where: { $0.name == "id" }) == nil)

    let artistPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .artists)
    )
    let artist = try #require(artistPage.items.first)
    #expect(artist.kind == .artist)
    #expect(artist.displayName == "崔健")
    #expect(artist.artist == "崔健")
    #expect(artist.id.externalID.hasPrefix("dsaudio.synthetic.artist."))

    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(parentID: artist.id, mode: .artists)
    )
    let artistComponents = try #require(
        URLComponents(url: client.requests.last!.url!, resolvingAgainstBaseURL: false)
    )
    let artistQuery = artistComponents.queryItems ?? []
    #expect(artistQuery.first(where: { $0.name == "artist" })?.value == "崔健")
    #expect(artistQuery.first(where: { $0.name == "id" }) == nil)
}

@Test("DS Audio continues total-backed pages when the response echoes offset")
func dsAudioContinuesTotalBackedPagesWhenResponseEchoesOffset() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        switch query["api"] {
        case "SYNO.API.Auth":
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        case "SYNO.API.Info":
            return (
                Data(#"{"success":true,"data":{"SYNO.AudioStation.Album":{"path":"webapi/entry.cgi","minVersion":3,"maxVersion":3}}}"#.utf8),
                try #require(okResponse(for: request))
            )
        default:
            let offset = query["offset"] ?? "0"
            let albums = offset == "0"
                ? #"[{"name":"Album 1","album_artist":"Artist 1"},{"name":"Album 2","album_artist":"Artist 2"}]"#
                : #"[{"name":"Album 3","album_artist":"Artist 3"},{"name":"Album 4","album_artist":"Artist 4"}]"#
            return (
                Data(
                    #"{"success":true,"data":{"albums":\#(albums),"offset":\#(offset),"total":5}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.echoed-offset.fixture"),
        displayName: "Echoed Offset NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let firstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .albums, pageSize: 2)
    )
    let secondPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            mode: .albums,
            pageSize: 2,
            pageToken: firstPage.nextPageToken
        )
    )

    #expect(firstPage.items.count == 2)
    #expect(firstPage.nextPageToken?.rawValue == "2")
    #expect(secondPage.items.map(\.displayName) == ["Album 3", "Album 4"])
    #expect(secondPage.nextPageToken?.rawValue == "4")
}

@Test("DS Audio rejects catalog responses that omit the success flag")
func dsAudioRejectsCatalogResponsesWithoutSuccessFlag() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = try #require(
            components.queryItems?.first(where: { $0.name == "api" })?.value
        )
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(#"{"data":{"songs":[{"id":"song-1","filename":"Should Not Load.mp3"}]}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.missing-success.fixture"),
        displayName: "Missing Success NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    await #expect(throws: OnlineSourceAdapterError.invalidResponse) {
        try await transport.browse(
            configuration: configuration,
            request: SourceBrowseRequest()
        )
    }
}

@Test("DS Audio maps list and non-audio MIME types without exposing them as media")
func dsAudioMapsListAndRejectsNonAudioMIMEFiles() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"""
                {"success":true,"data":{"list":[
                    {"id":"song-2","type":"audio_file","name":"List Song","mime":"audio/mpeg"},
                    {"id":"document-1","type":"file","name":"Notes.pdf","mime":"application/pdf"}
                ]}}
                """#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.list.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "List NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest()
    )

    #expect(page.items.count == 2)
    #expect(page.items[0].kind == .audioFile)
    #expect(page.items[0].isDownloadable)
    #expect(page.items[1].kind == .unknown)
    #expect(!page.items[1].isPlayable)
    #expect(!page.items[1].isDownloadable)
}

@Test("DS Audio device authorization persists trusted-device credentials after OTP")
func dsAudioDeviceAuthorizationPersistsTrustedDeviceCredentials() async throws {
    let store = FixtureCredentialStore()
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        #expect(query["enable_device_token"] == "yes")
        #expect(query["device_name"] == "MusicFree-fixture-device")
        #expect(query["enable_syno_token"] == "yes")
        if query["otp_code"] == nil {
            #expect(query["passwd"] == "fixture-password")
            return (
                Data(
                    #"{"success":false,"error":{"code":403,"errors":{"token":"fixture-challenge-token"}}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
        #expect(query["otp_code"] == "123456")
        #expect(query["passwd"] == "fixture-password")
        return (
            Data(
                #"{"success":true,"data":{"sid":"fixture-authorized-sid","did":"fixture-did","synotoken":"fixture-syno-token"}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }

    let authorizer = DSAudioDeviceAuthorizer(
        credentialStore: store,
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.authorizer.fixture")
    let endpoint = try #require(URL(string: "https://nas.example.test"))
    do {
        _ = try await authorizer.authorize(
            sourceID: sourceID,
            endpoint: endpoint,
            account: "fixture-account",
            password: "fixture-password",
            deviceName: "MusicFree-fixture-device"
        )
        Issue.record("Expected the DSM OTP challenge")
    } catch let challenge as DSAudioDeviceAuthorizationChallenge {
        #expect(challenge.challengeToken == "fixture-challenge-token")
        #expect(challenge.description == "DSAudioDeviceAuthorizationChallenge(redacted)")
    }

    let receipt = try await authorizer.authorize(
        sourceID: sourceID,
        endpoint: endpoint,
        account: "fixture-account",
        password: "fixture-password",
        deviceName: "MusicFree-fixture-device",
        oneTimeCode: "123456",
        challengeToken: "fixture-challenge-token"
    )
    #expect(receipt.deviceID == "fixture-did")
    let credential = try DSAudioCredential(
        secret: await store.secret(for: sourceID.rawValue)
    )
    #expect(credential.account == "fixture-account")
    #expect(credential.password == "fixture-password")
    #expect(credential.deviceName == "MusicFree-fixture-device")
    #expect(credential.deviceID == "fixture-did")
    #expect(credential.sessionID == "fixture-authorized-sid")
    #expect(credential.synoToken == "fixture-syno-token")
}

@Test("DS Audio device authorization accepts a code-only DSM OTP challenge")
func dsAudioDeviceAuthorizationAcceptsCodeOnlyOTPChallenge() async throws {
    let store = FixtureCredentialStore()
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        if query["otp_code"] == nil {
            return (
                Data(#"{"success":false,"error":{"code":403}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        #expect(query["otp_code"] == "123456")
        return (
            Data(#"{"success":true,"data":{"sid":"code-only-sid","did":"code-only-device"}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let authorizer = DSAudioDeviceAuthorizer(
        credentialStore: store,
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.code-only-otp.fixture")
    let endpoint = try #require(URL(string: "https://nas.example.test"))

    do {
        _ = try await authorizer.authorize(
            sourceID: sourceID,
            endpoint: endpoint,
            account: "fixture-account",
            password: "fixture-password",
            deviceName: "MusicFree-fixture-device"
        )
        Issue.record("Expected the DSM OTP challenge")
    } catch let challenge as DSAudioDeviceAuthorizationChallenge {
        #expect(challenge.challengeToken == nil)
    }

    let receipt = try await authorizer.authorize(
        sourceID: sourceID,
        endpoint: endpoint,
        account: "fixture-account",
        password: "fixture-password",
        deviceName: "MusicFree-fixture-device",
        oneTimeCode: "123456"
    )
    #expect(receipt.deviceID == "code-only-device")
}

@Test("DS Audio device authorization accepts DSM responses that only return a session id")
func dsAudioDeviceAuthorizationAcceptsSessionOnlyResponse() async throws {
    let store = FixtureCredentialStore()
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        #expect(
            components.queryItems?.first(where: { $0.name == "passwd" })?.value
                == "fixture-password"
        )
        return (
            Data(#"{"success":true,"data":{"sid":"session-only-sid"}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let authorizer = DSAudioDeviceAuthorizer(
        credentialStore: store,
        httpClient: client
    )
    let sourceID = MediaSourceID("dsaudio.session-only.fixture")
    let receipt = try await authorizer.authorize(
        sourceID: sourceID,
        endpoint: #require(URL(string: "https://nas.example.test")),
        account: "fixture-account",
        password: "fixture-password",
        deviceName: "MusicFree-fixture-device"
    )

    #expect(receipt.deviceID == nil)
    let credential = try DSAudioCredential(
        secret: await store.secret(for: sourceID.rawValue)
    )
    #expect(credential.sessionID == "session-only-sid")
    #expect(credential.deviceID == nil)
}

@Test("DS Audio device authorization maps a rejected OTP to invalidOneTimeCode")
func dsAudioDeviceAuthorizationMapsRejectedOTP() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let hasOTP = components.queryItems?.contains {
            $0.name == "otp_code" && $0.value == "000000"
        } == true
        #expect(hasOTP)
        return (
            Data(#"{"success":false,"error":{"code":403}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }
    let credentialStore = FixtureCredentialStore()
    let authorizer = DSAudioDeviceAuthorizer(
        credentialStore: credentialStore,
        httpClient: client
    )

    await #expect(throws: OnlineSourceAuthenticationError.invalidOneTimeCode) {
        try await authorizer.authorize(
            sourceID: MediaSourceID("dsaudio.rejected-otp.fixture"),
            endpoint: #require(URL(string: "https://nas.example.test")),
            account: "fixture-account",
            password: "fixture-password",
            deviceName: "MusicFree-fixture-device",
            oneTimeCode: "000000"
        )
    }
}

@Test("DS Audio catalog does not infer another page from a batch count")
func dsAudioCatalogDoesNotInferAnotherPageFromBatchCount() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"count":2,"songs":[{"id":"song-1","filename":"One.mp3"},{"id":"song-2","filename":"Two.mp3"}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.batch-count.fixture"),
        displayName: "Batch Count NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(pageSize: 2)
    )

    #expect(page.items.count == 2)
    #expect(page.nextPageToken == nil)
}

@Test("DS Audio catalog uses total instead of a stale next offset")
func dsAudioCatalogUsesTotalInsteadOfStaleNextOffset() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"total":3,"next_offset":999,"songs":[{"id":"song-1","filename":"One.mp3"},{"id":"song-2","filename":"Two.mp3"}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.total-authority.fixture"),
        displayName: "Total Authority NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(pageSize: 2)
    )

    #expect(page.nextPageToken?.rawValue == "2")
}

@Test("DS Audio catalog does not probe past a full terminal page with a stale total")
func dsAudioCatalogDoesNotProbePastFullTerminalPageWithStaleTotal() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"total":999,"songs":[{"id":"song-5","filename":"Five.mp3"},{"id":"song-6","filename":"Six.mp3"}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.stale-final-total.fixture"),
        displayName: "Stale Final Total NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            pageSize: 2,
            pageToken: MediaSourceCursor("4")
        )
    )

    #expect(page.items.count == 2)
    #expect(page.nextPageToken == nil)
}

@Test("DS Audio catalog treats a later short page as terminal despite a global total")
func dsAudioCatalogTreatsLaterShortPageAsTerminalDespiteGlobalTotal() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        let offset = components.queryItems?
            .first(where: { $0.name == "offset" })?.value
        if offset == "0" {
            return (
                Data(
                    #"{"success":true,"data":{"total":999,"songs":[{"id":"song-1","filename":"One.mp3"},{"id":"song-2","filename":"Two.mp3"}]}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"total":999,"songs":[{"id":"song-3","filename":"Three.mp3"}]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.short-final-global-total.fixture"),
        displayName: "Short Final NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let firstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(pageSize: 2)
    )
    let secondPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            pageSize: 2,
            pageToken: firstPage.nextPageToken
        )
    )

    #expect(firstPage.nextPageToken?.rawValue == "2")
    #expect(secondPage.items.count == 1)
    #expect(secondPage.nextPageToken == nil)
}

@Test("DS Audio catalog rejects invalid cursors and empty-page cursors")
func dsAudioCatalogRejectsInvalidCursors() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        return (
            Data(
                #"{"success":true,"data":{"next_offset":1,"songs":[]}}"#.utf8
            ),
            try #require(okResponse(for: request))
        )
    }
    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )
    let configuration = try DSAudioSourceConfiguration(
        sourceID: MediaSourceID("dsaudio.invalid-cursor.fixture"),
        displayName: "Invalid Cursor NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(pageSize: 2)
    )

    #expect(page.items.isEmpty)
    #expect(page.nextPageToken == nil)
}

@Test("DS Audio browse carries catalog dimensions, sorting and pagination")
func dsAudioBrowseCarriesDimensionsSortingAndPagination() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        switch query["api"] {
        case "SYNO.API.Auth":
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        case "SYNO.API.Info":
            return (
                Data(#"{"success":true,"data":{"SYNO.AudioStation.Folder":{"path":"webapi/entry.cgi","minVersion":2,"maxVersion":2},"SYNO.AudioStation.Album":{"path":"webapi/entry.cgi","minVersion":3,"maxVersion":3},"SYNO.AudioStation.Artist":{"path":"webapi/entry.cgi","minVersion":3,"maxVersion":3},"SYNO.AudioStation.Song":{"path":"webapi/entry.cgi","minVersion":3,"maxVersion":3}}}"#.utf8),
                try #require(okResponse(for: request))
            )
        default:
            #expect(query["_sid"] == "fixture-sid")
            #expect(query["limit"] == "2")
            let offset = query["offset"] ?? "0"
            let items: String
            switch query["api"] {
            case "SYNO.AudioStation.Folder":
                items = offset == "0"
                    ? #"""
                        [
                        {"id":"folder-1","name":"Folder 1","isdir":true},
                        {"id":"folder-2","name":"Folder 2","isdir":true}
                        ]
                    """#
                    : #"""
                        [
                        {"id":"folder-3","name":"Folder 3","isdir":true}
                        ]
                    """#
            case "SYNO.AudioStation.Album":
                items = offset == "0"
                    ? #"""
                        [
                        {"id":"album-1","name":"Album 1","artist":"Artist 1"},
                        {"id":"album-2","name":"Album 2","artist":"Artist 2"}
                        ]
                    """#
                    : #"""
                        [
                        {"id":"album-3","name":"Album 3","artist":"Artist 3"}
                        ]
                    """#
            case "SYNO.AudioStation.Artist":
                items = offset == "0"
                    ? #"""
                        [
                        {"id":"artist-1","name":"Artist 1"},
                        {"id":"artist-2","name":"Artist 2"}
                        ]
                    """#
                    : #"""
                        [
                        {"id":"artist-3","name":"Artist 3"}
                        ]
                    """#
            case "SYNO.AudioStation.Song":
                items = offset == "0"
                    ? #"""
                        [
                        {"id":"song-1","filename":"Song 1.mp3","duration":1,"artist":"Artist 1"},
                        {"id":"song-2","filename":"Song 2.mp3","duration":2,"artist":"Artist 2"}
                        ]
                    """#
                    : #"""
                        [
                        {"id":"song-3","filename":"Song 3.mp3","duration":3,"artist":"Artist 3"}
                        ]
                    """#
            default:
                Issue.record("Unexpected DS Audio catalog API: \(query["api"] ?? "unknown")")
                items = "[]"
            }
            return (
                Data(
                    #"{"success":true,"data":{"total":3,"items":\#(items)}}"#.utf8
                ),
                try #require(okResponse(for: request))
            )
        }
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password",
        sessionID: "fixture-sid"
    )
    let sourceID = MediaSourceID("dsaudio.dimensions-pagination.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Dimension Pagination NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )

    let folderFirstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .folders, pageSize: 2)
    )
    let folderSecondPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            mode: .folders,
            pageSize: 2,
            pageToken: folderFirstPage.nextPageToken
        )
    )
    #expect(folderFirstPage.items.map(\.id.externalID) == ["folder-1", "folder-2"])
    #expect(folderSecondPage.items.map(\.id.externalID) == ["folder-3"])
    #expect(folderFirstPage.nextPageToken?.rawValue == "2")
    #expect(folderSecondPage.nextPageToken == nil)

    let albumSort = SourceCatalogSort(key: .year, direction: .descending)
    let albumFirstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .albums, sort: albumSort, pageSize: 2)
    )
    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            mode: .albums,
            sort: albumSort,
            pageSize: 2,
            pageToken: albumFirstPage.nextPageToken
        )
    )

    let artistSort = SourceCatalogSort(key: .name, direction: .descending)
    let artistFirstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .artists, sort: artistSort, pageSize: 2)
    )
    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            mode: .artists,
            sort: artistSort,
            pageSize: 2,
            pageToken: artistFirstPage.nextPageToken
        )
    )

    let allMusicSort = SourceCatalogSort(key: .artist, direction: .ascending)
    let allMusicFirstPage = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(mode: .allMusic, sort: allMusicSort, pageSize: 2)
    )
    _ = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            mode: .allMusic,
            sort: allMusicSort,
            pageSize: 2,
            pageToken: allMusicFirstPage.nextPageToken
        )
    )

    func catalogQueries(for api: String) -> [[String: String]] {
        client.requests.compactMap { request in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            return query["api"] == api ? query : nil
        }
    }

    let folderQueries = catalogQueries(for: "SYNO.AudioStation.Folder")
    #expect(folderQueries.map { $0["offset"] } == ["0", "2"])
    #expect(folderQueries.allSatisfy {
        $0["sort_by"] == "name" && $0["sort_direction"] == "asc"
    })

    let albumQueries = catalogQueries(for: "SYNO.AudioStation.Album")
    #expect(albumQueries.map { $0["offset"] } == ["0", "2"])
    #expect(albumQueries.allSatisfy {
        $0["sort_by"] == "year" && $0["sort_direction"] == "desc"
    })

    let artistQueries = catalogQueries(for: "SYNO.AudioStation.Artist")
    #expect(artistQueries.map { $0["offset"] } == ["0", "2"])
    #expect(artistQueries.allSatisfy {
        $0["sort_by"] == "artist" && $0["sort_direction"] == "desc"
    })

    let songQueries = catalogQueries(for: "SYNO.AudioStation.Song")
    #expect(songQueries.map { $0["offset"] } == ["0", "2"])
    #expect(songQueries.allSatisfy {
        $0["sort_by"] == "artist" && $0["sort_direction"] == "asc"
    })
}

@Test("DS Audio catalog stops at a complete page when total equals consumed items")
func dsAudioCatalogStopsAtExactTotalBoundary() async throws {
    let client = StubOnlineHTTPClient()
    client.dataHandler = { request in
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let api = components.queryItems?.first(where: { $0.name == "api" })?.value
        if api == "SYNO.API.Auth" {
            return (
                Data(#"{"success":true,"data":{"sid":"fixture-sid"}}"#.utf8),
                try #require(okResponse(for: request))
            )
        }
        #expect(
            components.queryItems?.first(where: { $0.name == "offset" })?.value == "2"
        )
        return (
            Data(#"{"success":true,"data":{"total":4,"songs":[{"id":"song-3","filename":"Three.mp3"},{"id":"song-4","filename":"Four.mp3"}]}}"#.utf8),
            try #require(okResponse(for: request))
        )
    }

    let credential = try DSAudioCredential(
        account: "fixture-account",
        password: "fixture-password",
        sessionID: "fixture-sid"
    )
    let sourceID = MediaSourceID("dsaudio.exact-total.fixture")
    let configuration = try DSAudioSourceConfiguration(
        sourceID: sourceID,
        displayName: "Exact Total NAS",
        endpoint: #require(URL(string: "https://nas.example.test")),
        credentialRecordID: "fixture-record"
    )
    let transport = DSAudioHTTPTransport(
        credentialProvider: FixtureCredentialProvider(secret: credential.encodedSecret),
        httpClient: client
    )

    let page = try await transport.browse(
        configuration: configuration,
        request: SourceBrowseRequest(
            pageSize: 2,
            pageToken: MediaSourceCursor("2")
        )
    )

    #expect(page.items.count == 2)
    #expect(page.nextPageToken == nil)
}

private func okResponse(for request: URLRequest) -> HTTPURLResponse? {
    HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )
}

private struct FixtureCredentialProvider: OnlineCredentialProviding, Sendable {
    let secret: String

    func secret(for recordID: String) async throws -> String {
        secret
    }
}

private actor FixtureCredentialStore: OnlineCredentialStoring {
    private var values: [String: String] = [:]

    func secret(for recordID: String) async throws -> String {
        guard let value = values[recordID] else {
            throw OnlineSourceAdapterError.missingCredential
        }
        return value
    }

    func save(secret: String, for recordID: String) async throws {
        values[recordID] = secret
    }

    func remove(recordID: String) async throws {
        values.removeValue(forKey: recordID)
    }
}

private final class StubOnlineHTTPClient: OnlineHTTPClient, @unchecked Sendable {
    var requests: [URLRequest] = []
    var dataHandler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    var downloadHandler: ((URLRequest) throws -> (URL, HTTPURLResponse))?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let dataHandler else { throw OnlineSourceAdapterError.transportUnavailable }
        return try dataHandler(request)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        requests.append(request)
        guard let downloadHandler else { throw OnlineSourceAdapterError.transportUnavailable }
        return try downloadHandler(request)
    }
}
