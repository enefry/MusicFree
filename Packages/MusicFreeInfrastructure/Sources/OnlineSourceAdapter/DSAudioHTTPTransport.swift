import Foundation
import MediaSourceAPI
import MusicDomain

public struct DSAudioCredential: Codable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let account: String
    public let password: String
    public let deviceName: String?
    public let deviceID: String?
    public let sessionID: String?
    public let synoToken: String?

    public init(
        account: String,
        password: String,
        deviceName: String? = nil,
        deviceID: String? = nil,
        sessionID: String? = nil,
        synoToken: String? = nil
    ) throws {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty, !password.isEmpty else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        self.account = normalizedAccount
        self.password = password
        self.deviceName = Self.normalized(deviceName)
        self.deviceID = Self.normalized(deviceID)
        self.sessionID = Self.normalized(sessionID)
        self.synoToken = Self.normalized(synoToken)
    }

    public init(secret: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        if let value = try? JSONDecoder().decode(Self.self, from: data) {
            self = value
            return
        }
        let parts = secret.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw OnlineSourceAdapterError.invalidCredential
        }
        try self.init(account: parts[0], password: parts[1])
    }

    public var encodedSecret: String {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public var description: String { "DSAudioCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }

    private static func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else { return nil }
        return normalized
    }
}

/// The DSM API names and versions are isolated here because Audio Station API
/// versions differ between DSM generations. The transport keeps the default
/// endpoint configurable without weakening the DownloadSource/PlaybackSource
/// contracts.
public struct DSAudioAPIConfiguration: Sendable, Equatable {
    public let authPath: String
    public let entryPath: String
    public let browseAPI: String
    public let browseVersion: Int
    public let songAPI: String
    public let songVersion: Int
    public let albumAPI: String
    public let albumVersion: Int
    public let artistAPI: String
    public let artistVersion: Int
    public let searchAPI: String
    public let searchVersion: Int
    public let downloadAPI: String
    public let downloadVersion: Int
    public let streamAPI: String
    public let streamVersion: Int

    public init(
        authPath: String = "webapi/entry.cgi",
        entryPath: String = "webapi/entry.cgi",
        browseAPI: String = "SYNO.AudioStation.Folder",
        browseVersion: Int = 2,
        songAPI: String = "SYNO.AudioStation.Song",
        songVersion: Int = 3,
        albumAPI: String = "SYNO.AudioStation.Album",
        albumVersion: Int = 3,
        artistAPI: String = "SYNO.AudioStation.Artist",
        artistVersion: Int = 3,
        searchAPI: String = "SYNO.AudioStation.Search",
        searchVersion: Int = 3,
        downloadAPI: String = "SYNO.AudioStation.Download",
        downloadVersion: Int = 1,
        streamAPI: String = "SYNO.AudioStation.Stream",
        streamVersion: Int = 2
    ) {
        self.authPath = authPath
        self.entryPath = entryPath
        self.browseAPI = browseAPI
        self.browseVersion = browseVersion
        self.songAPI = songAPI
        self.songVersion = songVersion
        self.albumAPI = albumAPI
        self.albumVersion = albumVersion
        self.artistAPI = artistAPI
        self.artistVersion = artistVersion
        self.searchAPI = searchAPI
        self.searchVersion = searchVersion
        self.downloadAPI = downloadAPI
        self.downloadVersion = downloadVersion
        self.streamAPI = streamAPI
        self.streamVersion = streamVersion
    }
}

/// DSM/Audio Station HTTP transport. Runtime sessions are keyed by source
/// instance; the Keychain credential may also restore the last authorized SID
/// and trusted-device identity after the app is relaunched.
public actor DSAudioHTTPTransport: DSAudioTransport {
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-source-dsaudio"
    )

    private struct Session: Sendable {
        let sid: String
        let synoToken: String?
        let expiresAt: Date
    }

    private struct ResolvedAPI: Sendable {
        let name: String
        let path: String
        let version: Int
    }

    private let credentialProvider: any OnlineCredentialProviding
    private let httpClient: any OnlineHTTPClient
    private let api: DSAudioAPIConfiguration
    private var sessions: [MediaSourceID: Session] = [:]
    private var resolvedAPIs: [MediaSourceID: [String: ResolvedAPI]] = [:]
    private var rejectedPersistedSessions = Set<MediaSourceID>()

    public init(
        credentialProvider: any OnlineCredentialProviding,
        httpClient: any OnlineHTTPClient = URLSessionOnlineHTTPClient(),
        api: DSAudioAPIConfiguration = DSAudioAPIConfiguration()
    ) {
        self.credentialProvider = credentialProvider
        self.httpClient = httpClient
        self.api = api
    }

    public func authenticate(
        configuration: DSAudioSourceConfiguration,
        oneTimeCode: String
    ) async throws {
        let normalizedCode = oneTimeCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            throw OnlineSourceAuthenticationError.invalidOneTimeCode
        }
        sessions.removeValue(forKey: configuration.sourceID)
        let session = try await login(
            for: configuration,
            oneTimeCode: normalizedCode
        )
        sessions[configuration.sourceID] = session
    }

    public func browse(
        configuration: DSAudioSourceConfiguration,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        var parameters = [
            "limit": String(request.pageSize),
            "offset": String(Self.offset(from: request.pageToken)),
            "library": "all",
            // Folder/Song list responses omit tag data on several DSM builds
            // unless it is requested explicitly. Keep this at the transport
            // boundary so downloaded transcoded audio can still retain the
            // source title, artist, and album when the stream itself has no
            // embedded tags.
            "additional": "song_tag,song_audio",
        ]
        let apiName: String
        let apiVersion: Int
        let compatibleAPINames: [String]
        switch request.mode {
        case .folders:
            apiName = api.browseAPI
            apiVersion = api.browseVersion
            compatibleAPINames = [
                "SYNO.AudioStation.Song",
                "SYNO.AudioStation.Audio",
                "SYNO.AudioStation.Folder",
            ]
        case .albums:
            // The album endpoint returns album containers at the root. Once an
            // album is opened, use the Song endpoint with the album filters so
            // DSM responses without an album object id remain navigable.
            apiName = request.parentID == nil ? api.albumAPI : "SYNO.AudioStation.Song"
            apiVersion = request.parentID == nil ? api.albumVersion : 3
            compatibleAPINames = request.parentID == nil
                ? ["SYNO.AudioStation.Album", "SYNO.AudioStation.Song"]
                : ["SYNO.AudioStation.Song", "SYNO.AudioStation.Audio"]
        case .artists:
            // Artist roots are containers too. Child requests are narrowed to
            // the artist's songs rather than falling back to folder browsing.
            apiName = request.parentID == nil ? api.artistAPI : "SYNO.AudioStation.Song"
            apiVersion = request.parentID == nil ? api.artistVersion : 3
            compatibleAPINames = request.parentID == nil
                ? ["SYNO.AudioStation.Artist", "SYNO.AudioStation.Song"]
                : ["SYNO.AudioStation.Song", "SYNO.AudioStation.Audio"]
        case .allMusic:
            // The Song endpoint is the unfiltered Audio Station catalog. It
            // exposes the same audio metadata needed by audition, download,
            // and import, while keeping all-music browsing separate from the
            // folder tree.
            apiName = api.songAPI
            apiVersion = api.songVersion
            compatibleAPINames = [
                "SYNO.AudioStation.Song",
                "SYNO.AudioStation.Audio",
                api.browseAPI,
            ]
        }
        parameters.merge(
            Self.sortParameters(mode: request.mode, sort: request.sort)
        ) { _, newValue in newValue }
        if let parentID = request.parentID?.externalID {
            parameters.merge(
                Self.parentParameters(mode: request.mode, externalID: parentID)
            ) { _, newValue in newValue }
        }
        let root = try await performJSON(
            configuration: configuration,
            apiName: apiName,
            version: apiVersion,
            method: "list",
            compatibleAPINames: compatibleAPINames,
            parameters: parameters
        )
        let page = Self.catalogPage(
            root: root,
            sourceID: configuration.sourceID,
            parentID: request.parentID,
            mode: request.mode,
            pageSize: request.pageSize,
            offset: Self.offset(from: request.pageToken)
        )
        Self.logger.info(
            "browse parsed source=\(configuration.sourceID.rawValue) parent=\(request.parentID?.externalID ?? "root") items=\(page.items.count) kinds=\(Self.catalogKinds(page.items)) next=\(page.nextPageToken?.rawValue ?? "none")"
        )
        return page
    }

    public func search(
        configuration: DSAudioSourceConfiguration,
        request: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        let offset = Self.offset(from: request.pageToken)
        var parameters = [
            // Search API calls this field `keyword`; older builds accepted
            // `query`, so retain both while resolving the compatible API.
            "keyword": request.query,
            "query": request.query,
            "limit": String(request.pageSize),
            "offset": String(offset),
            "additional": "song_tag,song_audio",
        ]
        parameters.merge(
            Self.sortParameters(mode: request.mode, sort: request.sort)
        ) { _, newValue in newValue }
        if let parentID = request.parentID?.externalID {
            parameters.merge(
                Self.parentParameters(mode: request.mode, externalID: parentID)
            ) { _, newValue in newValue }
        }
        let root = try await performJSON(
            configuration: configuration,
            apiName: api.searchAPI,
            version: api.searchVersion,
            method: "list",
            compatibleAPINames: ["SYNO.AudioStation.Search"],
            parameters: parameters
        )
        return Self.catalogPage(
            root: root,
            sourceID: configuration.sourceID,
            parentID: request.parentID,
            mode: request.mode,
            pageSize: request.pageSize,
            offset: offset
        )
    }

    public func download(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        var didRecoverSession = false
        while true {
            do {
                return try await downloadOnce(
                    configuration: configuration,
                    itemID: itemID,
                    options: options
                )
            } catch let error as OnlineSourceAdapterError
                where error == .authorizationRequired && !didRecoverSession {
                didRecoverSession = true
                invalidateSession(for: configuration)
                Self.logger.info(
                    "download session recovery source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) retry=1"
                )
            }
        }
    }

    private func downloadOnce(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        guard itemID.sourceID == configuration.sourceID else {
            throw OnlineSourceAdapterError.resourceNotFound
        }
        let session = try await validSession(for: configuration)
        let resolved = await resolvedAPI(
            configuration: configuration,
            session: session,
            apiName: api.downloadAPI,
            version: api.downloadVersion,
            compatibleAPINames: ["SYNO.AudioStation.Download"]
        )
        let url = try makeURL(
            endpoint: configuration.endpoint,
            path: resolved.path,
            queryItems: [
                URLQueryItem(name: "api", value: resolved.name),
                URLQueryItem(name: "version", value: String(resolved.version)),
                URLQueryItem(name: "method", value: "download"),
                URLQueryItem(name: "id", value: itemID.externalID),
                URLQueryItem(name: "_sid", value: session.sid),
            ] + Self.synoTokenQueryItems(session.synoToken)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.logger.info(
            "download request source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) api=\(resolved.name) path=\(resolved.path)"
        )
        let (temporaryURL, response) = try await httpClient.download(for: request)
        do {
            let byteCount = Self.fileByteCount(at: temporaryURL)
            let mimeType = response.mimeType ?? "unknown"
            let responseKind = Self.downloadResponseKind(
                response: response,
                temporaryURL: temporaryURL
            )
            Self.logger.info(
                "download response source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) status=\(response.statusCode) mime=\(mimeType) bytes=\(byteCount) kind=\(responseKind) contentLength=\(response.value(forHTTPHeaderField: "Content-Length") ?? "unknown") hasDisposition=\(response.value(forHTTPHeaderField: "Content-Disposition") != nil)"
            )
            try validateOnlineHTTPStatus(response)
            if responseKind == "json" {
                let data = try Data(contentsOf: temporaryURL)
                try? FileManager.default.removeItem(at: temporaryURL)
                guard let root = Self.jsonRoot(data: data) else {
                    throw OnlineSourceAdapterError.invalidResponse
                }
                guard (root["success"] as? Bool) == true else {
                    let code = Self.dsmErrorCode(root: root)
                    Self.logger.error(
                        "download DSM response source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) status=\(response.statusCode) mime=\(mimeType) bytes=\(byteCount) contentLength=\(response.value(forHTTPHeaderField: "Content-Length") ?? "unknown") hasDisposition=\(response.value(forHTTPHeaderField: "Content-Disposition") != nil) code=\(code.map(String.init) ?? "unknown") shape=\(Self.redactedJSONSummary(data: data))"
                    )
                    throw Self.mapDSMError(root: root)
                }

                // Some DSM/Audio Station builds acknowledge Download.cgi with
                // {success:true} but do not return the audio bytes. Fetch the
                // same object through the stream/transcode endpoint so the
                // existing local-media importer receives a real file.
                Self.logger.info(
                    "download command acknowledged source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) fallback=stream"
                )
                return try await downloadFromStream(
                    configuration: configuration,
                    itemID: itemID,
                    options: options,
                    session: session
                )
            }
            let staged = try stageOnlineDownload(
                temporaryURL: temporaryURL,
                preferredFileName: options.preferredFileName,
                fallbackExtension: "audio"
            )
            Self.logger.info(
                "download staged source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) bytes=\(staged.byteCount.map(String.init) ?? "unknown")"
            )
            return DownloadReceipt(
                sourceID: configuration.sourceID,
                itemID: itemID,
                fileURL: staged.url,
                byteCount: staged.byteCount
            )
        } catch {
            Self.logger.error(
                "download failed source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) error=\(Self.redactedErrorCode(error))"
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func invalidateSession(for configuration: DSAudioSourceConfiguration) {
        sessions.removeValue(forKey: configuration.sourceID)
        rejectedPersistedSessions.insert(configuration.sourceID)
    }

    private func downloadFromStream(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        options: DownloadOptions,
        session: Session
    ) async throws -> DownloadReceipt {
        let (request, isTranscoded) = try await makeStreamRequest(
            configuration: configuration,
            itemID: itemID,
            session: session
        )
        Self.logger.info(
            "stream download request source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) transcoded=\(isTranscoded)"
        )
        let (temporaryURL, response) = try await httpClient.download(for: request)
        do {
            let byteCount = Self.fileByteCount(at: temporaryURL)
            let responseKind = Self.downloadResponseKind(
                response: response,
                temporaryURL: temporaryURL
            )
            Self.logger.info(
                "stream download response source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) status=\(response.statusCode) mime=\(response.mimeType ?? "unknown") bytes=\(byteCount) kind=\(responseKind)"
            )
            try validateOnlineHTTPStatus(response)
            if responseKind == "json" {
                let data = try Data(contentsOf: temporaryURL)
                let root = Self.jsonRoot(data: data)
                let code = root.map(Self.dsmErrorCode(root:)) ?? Self.dsmErrorCode(data: data)
                Self.logger.error(
                    "stream download DSM response source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) code=\(code.map(String.init) ?? "unknown") shape=\(Self.redactedJSONSummary(data: data))"
                )
                throw root.map(Self.mapDSMError(root:)) ?? .invalidResponse
            }
            let preferredFileName = isTranscoded
                ? Self.fileName(options.preferredFileName, replacingExtensionWith: "mp3")
                : options.preferredFileName
            let staged = try stageOnlineDownload(
                temporaryURL: temporaryURL,
                preferredFileName: preferredFileName,
                fallbackExtension: isTranscoded ? "mp3" : "audio"
            )
            Self.logger.info(
                "stream download staged source=\(configuration.sourceID.rawValue) item=\(itemID.externalID) bytes=\(staged.byteCount.map(String.init) ?? "unknown")"
            )
            return DownloadReceipt(
                sourceID: configuration.sourceID,
                itemID: itemID,
                fileURL: staged.url,
                byteCount: staged.byteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func playbackAccess(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        purpose _: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        guard itemID.sourceID == configuration.sourceID else {
            throw OnlineSourceAdapterError.resourceNotFound
        }
        let session = try await validSession(for: configuration)
        let (request, isTranscoded) = try await makeStreamRequest(
            configuration: configuration,
            itemID: itemID,
            session: session
        )
        return .http(
            request: RemotePlaybackRequest(
                url: request.url!,
                headers: ["Accept": "audio/*"],
                expiresAt: Date().addingTimeInterval(300)
            ),
            transcode: isTranscoded
                ? TranscodeDescriptor(container: "mp3")
                : nil
        )
    }

    private func makeStreamRequest(
        configuration: DSAudioSourceConfiguration,
        itemID: SourceObjectID,
        session: Session
    ) async throws -> (request: URLRequest, isTranscoded: Bool) {
        let resolved = await resolvedAPI(
            configuration: configuration,
            session: session,
            apiName: api.streamAPI,
            version: api.streamVersion,
            compatibleAPINames: ["SYNO.AudioStation.Stream"]
        )
        let isTranscoded = Self.requiresTranscode(itemID: itemID)
        let path = isTranscoded ? "\(resolved.path)/0.mp3" : resolved.path
        let method = isTranscoded ? "transcode" : "stream"
        var queryItems = [
            URLQueryItem(name: "api", value: resolved.name),
            URLQueryItem(name: "version", value: String(resolved.version)),
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "id", value: itemID.externalID),
            URLQueryItem(name: "_sid", value: session.sid),
        ] + Self.synoTokenQueryItems(session.synoToken)
        if isTranscoded {
            queryItems.append(URLQueryItem(name: "format", value: "mp3"))
        }
        var request = URLRequest(
            url: try makeURL(
                endpoint: configuration.endpoint,
                path: path,
                queryItems: queryItems
            )
        )
        request.httpMethod = "GET"
        return (request, isTranscoded)
    }

    public func artwork(
        configuration _: DSAudioSourceConfiguration,
        artworkID _: ArtworkID
    ) async throws -> ArtworkResource? {
        nil
    }

    private func performJSON(
        configuration: DSAudioSourceConfiguration,
        apiName: String,
        version: Int,
        method: String,
        compatibleAPINames: [String],
        parameters: [String: String]
    ) async throws -> [String: Any] {
        var resolved = resolvedAPIs[configuration.sourceID]?[apiName]
            ?? ResolvedAPI(
                name: apiName,
                path: api.entryPath,
                version: version
            )
        var attemptedDiscovery = false
        for attempt in 0 ..< 2 {
            let session = try await validSession(for: configuration)
            let queryItems = [
                URLQueryItem(name: "api", value: resolved.name),
                URLQueryItem(name: "version", value: String(resolved.version)),
                URLQueryItem(name: "method", value: method),
                URLQueryItem(name: "_sid", value: session.sid),
            ] + Self.synoTokenQueryItems(session.synoToken)
                + parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            let url = try makeURL(
                endpoint: configuration.endpoint,
                path: resolved.path,
                queryItems: queryItems
            )
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await httpClient.data(for: request)
            } catch {
                Self.logger.error(
                    "json network failure source=\(configuration.sourceID.rawValue) api=\(resolved.name) method=\(method) path=\(resolved.path) error=\(Self.redactedErrorCode(error))"
                )
                throw error
            }
            Self.logger.info(
                "json response source=\(configuration.sourceID.rawValue) api=\(resolved.name) method=\(method) path=\(resolved.path) status=\(response.statusCode) bytes=\(data.count) shape=\(Self.redactedJSONSummary(data: data))"
            )
            try validateOnlineHTTPStatus(response)
            guard let root = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any]
            else {
                throw OnlineSourceAdapterError.invalidResponse
            }
            guard root["success"] != nil else {
                Self.logger.error(
                    "json response missing success source=\(configuration.sourceID.rawValue) api=\(resolved.name) method=\(method) path=\(resolved.path) shape=\(Self.redactedJSONSummary(data: data))"
                )
                throw OnlineSourceAdapterError.invalidResponse
            }
            guard Self.bool(root["success"]) else {
                let code = Self.dsmErrorCode(root: root)
                if code == 102 || code == 104, !attemptedDiscovery {
                    attemptedDiscovery = true
                    if let discovered = try await discoverAPI(
                        endpoint: configuration.endpoint,
                        session: session,
                        preferredNames: [apiName] + compatibleAPINames,
                        preferredVersion: version
                    ) {
                        resolved = discovered
                        resolvedAPIs[configuration.sourceID, default: [:]][apiName] = discovered
                        continue
                    }
                }
                let error = Self.mapDSMError(root: root)
                if error == .authorizationRequired, attempt == 0 {
                    sessions.removeValue(forKey: configuration.sourceID)
                    rejectedPersistedSessions.insert(configuration.sourceID)
                    continue
                }
                throw error
            }
            resolvedAPIs[configuration.sourceID, default: [:]][apiName] = resolved
            return root
        }
        throw OnlineSourceAdapterError.authorizationRequired
    }

    /// Resolves binary Audio Station endpoints before a download or temporary
    /// stream URL is handed to the caller. DSM commonly exposes these APIs at
    /// `AudioStation/*.cgi`, while some installations accept the generic
    /// `entry.cgi` route. Discovery is best-effort; the configured fallback is
    /// retained for older or restricted DSM builds.
    private func resolvedAPI(
        configuration: DSAudioSourceConfiguration,
        session: Session,
        apiName: String,
        version: Int,
        compatibleAPINames: [String]
    ) async -> ResolvedAPI {
        if let cached = resolvedAPIs[configuration.sourceID]?[apiName] {
            return cached
        }

        let fallback = ResolvedAPI(
            name: apiName,
            path: api.entryPath,
            version: version
        )
        guard let discovered = try? await discoverAPI(
            endpoint: configuration.endpoint,
            session: session,
            preferredNames: [apiName] + compatibleAPINames,
            preferredVersion: version
        ) else {
            resolvedAPIs[configuration.sourceID, default: [:]][apiName] = fallback
            return fallback
        }
        resolvedAPIs[configuration.sourceID, default: [:]][apiName] = discovered
        return discovered
    }

    private func discoverAPI(
        endpoint: URL,
        session: Session,
        preferredNames: [String],
        preferredVersion: Int
    ) async throws -> ResolvedAPI? {
        let url = try makeURL(
            endpoint: endpoint,
            path: "webapi/entry.cgi",
            queryItems: [
                URLQueryItem(name: "api", value: "SYNO.API.Info"),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "query"),
                URLQueryItem(name: "query", value: "all"),
                URLQueryItem(name: "_sid", value: session.sid),
            ] + Self.synoTokenQueryItems(session.synoToken)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await httpClient.data(for: request)
        try validateOnlineHTTPStatus(response)
        guard let root = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any],
            (root["success"] as? Bool) == true,
            let available = root["data"] as? [String: Any]
        else {
            return nil
        }

        for name in Self.unique(preferredNames) {
            guard let descriptor = available[name] as? [String: Any],
                  let path = Self.string(descriptor["path"]),
                  let minimumVersion = Self.int(descriptor["minVersion"]),
                  let maximumVersion = Self.int(descriptor["maxVersion"])
            else { continue }
            return ResolvedAPI(
                name: name,
                path: Self.webAPIPath(path),
                version: min(max(preferredVersion, minimumVersion), maximumVersion)
            )
        }
        return nil
    }

    private func validSession(
        for configuration: DSAudioSourceConfiguration
    ) async throws -> Session {
        if let session = sessions[configuration.sourceID],
           session.expiresAt > Date().addingTimeInterval(30) {
            Self.logger.debug(
                "session cache hit source=\(configuration.sourceID.rawValue) hasSynoToken=\(session.synoToken != nil)"
            )
            return session
        }
        if sessions[configuration.sourceID] != nil {
            Self.logger.info(
                "session cache expired source=\(configuration.sourceID.rawValue)"
            )
        }
        guard let credentialRecordID = configuration.credentialRecordID,
              !credentialRecordID.isEmpty
        else {
            Self.logger.error(
                "session unavailable source=\(configuration.sourceID.rawValue) reason=missing_credential_record"
            )
            throw OnlineSourceAdapterError.missingCredential
        }
        let secret: String
        do {
            secret = try await credentialProvider.secret(for: credentialRecordID)
        } catch {
            Self.logger.error(
                "credential load failed source=\(configuration.sourceID.rawValue) error=\(Self.redactedErrorCode(error))"
            )
            throw error
        }
        let credential: DSAudioCredential
        do {
            credential = try DSAudioCredential(secret: secret)
        } catch {
            Self.logger.error(
                "credential decode failed source=\(configuration.sourceID.rawValue) error=\(Self.redactedErrorCode(error))"
            )
            throw error
        }
        if !rejectedPersistedSessions.contains(configuration.sourceID),
           let sid = credential.sessionID {
            Self.logger.info(
                "restoring persisted session source=\(configuration.sourceID.rawValue) hasDeviceID=\(credential.deviceID != nil) hasSynoToken=\(credential.synoToken != nil)"
            )
            let session = Session(
                sid: sid,
                synoToken: credential.synoToken,
                expiresAt: Date().addingTimeInterval(900)
            )
            sessions[configuration.sourceID] = session
            return session
        }
        let sessionRecoveryReason = rejectedPersistedSessions.contains(configuration.sourceID)
            ? "persisted_session_rejected"
            : "no_persisted_session"
        Self.logger.info(
            "starting session login source=\(configuration.sourceID.rawValue) reason=\(sessionRecoveryReason)"
        )
        let session = try await login(
            for: configuration,
            credential: credential,
            oneTimeCode: nil
        )
        sessions[configuration.sourceID] = session
        return session
    }

    private func login(
        for configuration: DSAudioSourceConfiguration,
        oneTimeCode: String?
    ) async throws -> Session {
        guard let credentialRecordID = configuration.credentialRecordID,
              !credentialRecordID.isEmpty
        else {
            throw OnlineSourceAdapterError.missingCredential
        }
        let secret: String
        do {
            secret = try await credentialProvider.secret(for: credentialRecordID)
        } catch {
            Self.logger.error(
                "relogin credential load failed source=\(configuration.sourceID.rawValue) error=\(Self.redactedErrorCode(error))"
            )
            throw error
        }
        let credential: DSAudioCredential
        do {
            credential = try DSAudioCredential(secret: secret)
        } catch {
            Self.logger.error(
                "relogin credential decode failed source=\(configuration.sourceID.rawValue) error=\(Self.redactedErrorCode(error))"
            )
            throw error
        }
        return try await login(
            for: configuration,
            credential: credential,
            oneTimeCode: oneTimeCode
        )
    }

    private func login(
        for configuration: DSAudioSourceConfiguration,
        credential: DSAudioCredential,
        oneTimeCode: String?
    ) async throws -> Session {
        var queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "6"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: credential.account),
            URLQueryItem(name: "passwd", value: credential.password),
            URLQueryItem(name: "session", value: "AudioStation"),
            URLQueryItem(name: "format", value: "sid"),
            URLQueryItem(name: "enable_device_token", value: "yes"),
            URLQueryItem(name: "enable_syno_token", value: "yes"),
        ]
        if let deviceName = credential.deviceName {
            queryItems.append(URLQueryItem(name: "device_name", value: deviceName))
        }
        if let deviceID = credential.deviceID {
            queryItems.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        if let oneTimeCode {
            queryItems.append(URLQueryItem(name: "otp_code", value: oneTimeCode))
        }
        var lastFailure: [String: Any]?
        for path in Self.authenticationPaths(preferredPath: api.authPath) {
            Self.logger.info(
                "session login request source=\(configuration.sourceID.rawValue) endpoint=\(Self.endpointDescription(configuration.endpoint)) path=\(path) hasOTP=\(oneTimeCode != nil) hasDeviceID=\(credential.deviceID != nil)"
            )
            let root = try await performLoginRequest(
                sourceID: configuration.sourceID,
                endpoint: configuration.endpoint,
                path: path,
                queryItems: queryItems
            )
            guard (root["success"] as? Bool) == true else {
                lastFailure = root
                let code = Self.dsmErrorCode(root: root)
                Self.logger.error(
                    "session login rejected source=\(configuration.sourceID.rawValue) path=\(path) dsmCode=\(code.map(String.init) ?? "unknown") error=\(Self.redactedErrorCode(Self.mapDSMAuthError(root: root)))"
                )
                if code == 102 {
                    continue
                }
                throw Self.mapDSMAuthError(root: root)
            }
            guard let payload = root["data"] as? [String: Any],
                  let sid = Self.string(payload["sid"]),
                  !sid.isEmpty
            else {
                Self.logger.error(
                    "session login success missing sid source=\(configuration.sourceID.rawValue) path=\(path)"
                )
                throw OnlineSourceAdapterError.invalidResponse
            }
            let synoToken = Self.string(payload["synotoken"])
            let deviceID = Self.string(payload["device_id"])
                ?? Self.string(payload["did"])
                ?? credential.deviceID
            if let store = credentialProvider as? any OnlineCredentialStoring {
                let updated = try DSAudioCredential(
                    account: credential.account,
                    password: credential.password,
                    deviceName: credential.deviceName,
                    deviceID: deviceID,
                    sessionID: sid,
                    synoToken: synoToken
                )
                try await store.save(
                    secret: updated.encodedSecret,
                    for: configuration.credentialRecordID ?? configuration.sourceID.rawValue
                )
            }
            rejectedPersistedSessions.remove(configuration.sourceID)
            Self.logger.info(
                "session login authorized source=\(configuration.sourceID.rawValue) path=\(path) hasDeviceID=\(deviceID != nil) hasSynoToken=\(synoToken != nil)"
            )
            return Session(
                sid: sid,
                synoToken: synoToken,
                expiresAt: Date().addingTimeInterval(900)
            )
        }
        throw lastFailure.map(Self.mapDSMAuthError(root:))
            ?? OnlineSourceAdapterError.invalidResponse
    }

    private func performLoginRequest(
        sourceID: MediaSourceID,
        endpoint: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> [String: Any] {
        let url = try makeURL(
            endpoint: endpoint,
            path: path,
            queryItems: queryItems
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            Self.logger.error(
                "session login network failure source=\(sourceID.rawValue) endpoint=\(Self.endpointDescription(endpoint)) path=\(path) error=\(Self.redactedNetworkError(error))"
            )
            throw error
        }
        do {
            try validateOnlineHTTPStatus(response)
        } catch {
            Self.logger.error(
                "session login HTTP failure source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode) error=\(Self.redactedErrorCode(error))"
            )
            throw error
        }
        guard let root = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any]
        else {
            Self.logger.error(
                "session login invalid JSON source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode) bytes=\(data.count)"
            )
            throw OnlineSourceAdapterError.invalidResponse
        }
        Self.logger.info(
            "session login response source=\(sourceID.rawValue) path=\(path) httpStatus=\(response.statusCode) success=\((root["success"] as? Bool) == true) dsmCode=\(Self.dsmErrorCode(root: root).map(String.init) ?? "none") shape=\(Self.redactedJSONSummary(data: data))"
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

    private static func webAPIPath(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.hasPrefix("webapi/") ? normalized : "webapi/\(normalized)"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func synoTokenQueryItems(_ token: String?) -> [URLQueryItem] {
        token.map { [URLQueryItem(name: "SynoToken", value: $0)] } ?? []
    }

    private func makeURL(
        endpoint: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents(
            url: endpoint.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return url
    }

    private static func catalogPage(
        root: [String: Any],
        sourceID: MediaSourceID,
        parentID: SourceObjectID?,
        mode: SourceCatalogBrowseMode,
        pageSize: Int,
        offset: Int
    ) -> SourceCatalogPage {
        let items = uniqueCatalogItems(
            rawItems(from: root).compactMap {
                catalogItem(
                    from: $0,
                    sourceID: sourceID,
                    parentID: parentID,
                    mode: mode
                )
            }
        )
        let data = root["data"] as? [String: Any]
        let nextOffset = explicitNextOffset(data: data, root: root)
        let responseOffset = int(data?["offset"]) ?? int(root["offset"])
        let total = int(data?["total"])
            ?? int(root["total"])
        let hasMore = bool(data?["has_more"])
            || bool(data?["hasMore"])
            || bool(root["has_more"])
            || bool(root["hasMore"])
        let hasBatchCount = int(data?["count"]) != nil
            || int(data?["item_count"]) != nil
            || int(data?["itemCount"]) != nil
            || int(root["count"]) != nil
            || int(root["item_count"]) != nil
            || int(root["itemCount"]) != nil
        let nextPageOffset: Int?
        if let candidate = nextOffset,
           !items.isEmpty,
           candidate > offset,
           candidate >= offset + items.count,
           total.map({ candidate < $0 }) ?? true {
            // An explicit cursor is the strongest signal. When a DSM build
            // also returns `total`, reject impossible cursors such as 999 for
            // a three-item directory rather than probing an invalid offset.
            nextPageOffset = candidate
        } else if hasMore, !items.isEmpty {
            let candidate = offset + items.count
            nextPageOffset = total.map { candidate < $0 } ?? true
                ? candidate
                : nil
        } else if let total,
                  !items.isEmpty,
                  items.count >= pageSize,
                  offset + items.count < total,
                  (offset == 0 || responseOffset == offset) {
            // Some older DSM builds expose only `total` on the first page.
            // Keep that compatibility path. Builds that also echo the
            // response offset can safely continue later full pages; a later
            // full page without that signal may have a stale library-wide
            // total for a smaller directory, so it is treated as terminal.
            nextPageOffset = offset + items.count
        } else if items.count >= pageSize,
                  total == nil,
                  !hasBatchCount {
            // A few Audio Station versions omit both `total` and `has_more`
            // but still honor the requested page size. Keep those catalogs
            // pageable; the first short page will terminate the sequence.
            nextPageOffset = offset + items.count
        } else {
            // A page that includes a total/count but no positive continuation
            // signal is terminal. DSM installations have been observed to
            // return a library-wide/global total for a directory request, so
            // inferring another cursor from a full later page can manufacture
            // a request past the directory end and show a false failure.
            nextPageOffset = nil
        }
        return SourceCatalogPage(
            items: items,
            nextPageToken: nextPageOffset.map { MediaSourceCursor(String($0)) }
        )
    }

    private static func explicitNextOffset(
        data: [String: Any]?,
        root: [String: Any]
    ) -> Int? {
        int(data?["next_offset"])
            ?? int(data?["nextOffset"])
            ?? int(root["next_offset"])
            ?? int(root["nextOffset"])
    }

    private static func catalogKinds(_ items: [SourceCatalogItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.kind.rawValue, default: 0] += 1
        }
        return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }

    private static func rawItems(from root: [String: Any]) -> [[String: Any]] {
        if let dataItems = root["data"] as? [[String: Any]] {
            return dataItems
        }
        let data = root["data"] as? [String: Any]
        // DSM generations and Audio Station endpoints do not agree on the
        // collection key. Folder endpoints commonly return `folders` or
        // `children`, while Song/Audio endpoints may return `list` or
        // `entries`. Keep this normalization at the transport boundary so
        // the source/UI contract never needs DSM-specific response shapes.
        let collectionKeys = [
            // Prefer an already-normalized combined collection, then keep
            // folders/containers before songs/files to match the directory
            // mental model used by DSM and the app's folder navigation.
            "items", "children", "folders", "albums", "artists", "songs", "tracks",
            "files", "list", "entries", "records", "audio", "audios",
        ]
        var result: [[String: Any]] = []
        var seenIDs = Set<String>()
        for key in collectionKeys {
            let collections = [data?[key], root[key]]
            for collection in collections {
                guard let values = collection as? [[String: Any]] else { continue }
                for value in values {
                    guard let identity = rawItemIdentity(value) else {
                        result.append(value)
                        continue
                    }
                    guard seenIDs.insert(identity).inserted else { continue }
                    result.append(value)
                }
            }
        }
        return result
    }

    private static func uniqueCatalogItems(
        _ items: [SourceCatalogItem]
    ) -> [SourceCatalogItem] {
        var seen = Set<SourceObjectID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func rawItemIdentity(_ raw: [String: Any]) -> String? {
        for key in [
            "id", "song_id", "track_id", "file_id", "folder_id", "album_id", "artist_id", "uuid",
        ] {
            guard let value = string(raw[key]), !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private struct DimensionSelection {
        let name: String
        let artist: String?
        let year: Int?
    }

    private static func parentParameters(
        mode: SourceCatalogBrowseMode,
        externalID: String
    ) -> [String: String] {
        var parameters: [String: String] = [:]
        let selection = dimensionSelection(mode: mode, externalID: externalID)

        // Folder and older dimension responses expose an opaque object id.
        // Synthetic dimension ids carry the human-readable filter instead and
        // must never be sent back to DSM as an object id.
        if selection == nil {
            parameters["id"] = externalID
            parameters["parent"] = externalID
        }

        switch mode {
        case .folders:
            parameters["folder_id"] = externalID
        case .albums:
            if let selection {
                // AudioStation.Album returns name/artist metadata but no id on
                // some DSM 7 installations. Song.list accepts the album
                // metadata as its filter in that response shape.
                parameters["album"] = selection.name
                if let artist = selection.artist {
                    parameters["album_artist"] = artist
                }
                if let year = selection.year {
                    parameters["year"] = String(year)
                }
            } else {
                parameters["album_id"] = externalID
            }
        case .artists:
            if let selection {
                parameters["artist"] = selection.name
            } else {
                parameters["artist_id"] = externalID
            }
        case .allMusic:
            parameters["folder_id"] = externalID
        }
        return parameters
    }

    private static func sortParameters(
        mode: SourceCatalogBrowseMode,
        sort: SourceCatalogSort
    ) -> [String: String] {
        let sortBy: String
        switch sort.key {
        case .name:
            switch mode {
            case .folders: sortBy = "name"
            case .albums: sortBy = "album"
            case .artists: sortBy = "artist"
            case .allMusic: sortBy = "title"
            }
        case .artist:
            sortBy = "artist"
        case .album:
            sortBy = "album"
        case .year:
            sortBy = "year"
        }
        return [
            "sort_by": sortBy,
            "sort_direction": sort.direction == .ascending ? "asc" : "desc",
        ]
    }

    private static func syntheticDimensionID(
        mode: SourceCatalogBrowseMode,
        name: String,
        artist: String?,
        year: Int?
    ) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        let encodedName = encodeSyntheticPart(normalizedName)
        switch mode {
        case .albums:
            let encodedArtist = encodeSyntheticPart(artist ?? "")
            let yearValue = year.map(String.init) ?? ""
            return "dsaudio.synthetic.album.\(encodedName).\(encodedArtist).\(yearValue)"
        case .artists:
            return "dsaudio.synthetic.artist.\(encodedName)"
        case .folders, .allMusic:
            return nil
        }
    }

    private static func dimensionSelection(
        mode: SourceCatalogBrowseMode,
        externalID: String
    ) -> DimensionSelection? {
        let parts = externalID
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 4,
              parts[0] == "dsaudio",
              parts[1] == "synthetic"
        else { return nil }

        switch (mode, parts[2]) {
        case (.albums, "album") where parts.count == 6:
            guard let name = decodeSyntheticPart(parts[3]) else { return nil }
            let artist = decodeSyntheticPart(parts[4]).flatMap { value in
                value.isEmpty ? nil : value
            }
            let year = Int(parts[5])
            return DimensionSelection(name: name, artist: artist, year: year)
        case (.artists, "artist") where parts.count == 4:
            guard let name = decodeSyntheticPart(parts[3]) else { return nil }
            return DimensionSelection(name: name, artist: nil, year: nil)
        default:
            return nil
        }
    }

    private static func encodeSyntheticPart(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeSyntheticPart(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func catalogItem(
        from raw: [String: Any],
        sourceID: MediaSourceID,
        parentID: SourceObjectID?,
        mode: SourceCatalogBrowseMode
    ) -> SourceCatalogItem? {
        let dimensionName: String?
        switch mode {
        case .albums:
            dimensionName = firstNonEmpty([
                string(raw["name"]),
                string(raw["album"]),
                string(raw["title"]),
            ])
        case .artists:
            dimensionName = firstNonEmpty([
                string(raw["name"]),
                string(raw["artist"]),
                string(raw["display_artist"]),
                string(raw["title"]),
            ])
        case .folders, .allMusic:
            dimensionName = nil
        }
        let dimensionArtist = firstNonEmpty([
            string(raw["album_artist"]),
            string(raw["display_artist"]),
            string(raw["artist"]),
        ])
        let dimensionYear = int(raw["year"]).flatMap { $0 > 0 ? $0 : nil }
        let explicitExternalID = string(raw["id"])
            ?? string(raw["song_id"])
            ?? string(raw["track_id"])
            ?? string(raw["file_id"])
            ?? string(raw["folder_id"])
            ?? string(raw["album_id"])
            ?? string(raw["artist_id"])
            ?? string(raw["uuid"])
        let externalID = explicitExternalID
            ?? (parentID == nil
                ? syntheticDimensionID(
                    mode: mode,
                    name: dimensionName ?? "",
                    artist: dimensionArtist,
                    year: dimensionYear
                )
                : nil)
        guard let externalID, !externalID.isEmpty else { return nil }
        let type = (string(raw["type"]) ?? string(raw["kind"]) ?? "")
            .lowercased()
        let additional = dictionary(raw["additional"])
        let songTag = dictionary(additional?["song_tag"])
            ?? dictionary(additional?["songTag"])
            ?? dictionary(raw["song_tag"])
            ?? dictionary(raw["songTag"])
        let metadata = dictionary(additional?["metadata"])
            ?? dictionary(raw["metadata"])
            ?? dictionary(raw["tags"])
        let songAudio = dictionary(additional?["song_audio"])
            ?? dictionary(additional?["songAudio"])

        let isFolder = bool(raw["is_folder"])
            || bool(raw["isFolder"])
            || bool(raw["is_dir"])
            || bool(raw["isDir"])
            || bool(raw["isdir"])
            || bool(raw["is_directory"])
            || bool(raw["isDirectory"])
            || bool(raw["folder"])
            || type == "directory"
            || type == "dir"
            || type.contains("folder")
        let isAlbumType = type.contains("album")
        let isArtistType = type.contains("artist")
        let rawMimeType = string(raw["mime_type"])
            ?? string(raw["mimeType"])
            ?? string(raw["content_type"])
            ?? string(raw["contentType"])
            ?? string(raw["mime"])
        let audioContainer = string(songAudio?["container"])
            ?? string(songAudio?["format"])
            ?? string(raw["container"])
            ?? string(raw["format"])
            ?? string(raw["file_type"])
            ?? string(raw["fileType"])
        let suffix = firstNonEmpty([
            string(raw["suffix"]),
            string(raw["extension"]),
            string(raw["file_extension"]),
            string(raw["fileExtension"]),
            string(raw["ext"]),
            string(raw["path"]).map { URL(fileURLWithPath: $0).pathExtension },
            string(raw["filename"]).map { URL(fileURLWithPath: $0).pathExtension },
            string(raw["file_name"]).map { URL(fileURLWithPath: $0).pathExtension },
            string(raw["name"]).map { URL(fileURLWithPath: $0).pathExtension },
        ])
        let hasAudioMetadata = songAudio != nil
            || raw["duration"] != nil
            || raw["song_id"] != nil
            || raw["track_id"] != nil
            || raw["artist"] != nil
            || raw["album"] != nil
            || raw["bitrate"] != nil
        let isTrackType = type.contains("song")
            || type.contains("track")
            || type == "music"
        let isAudioType = isTrackType || type.contains("audio")
        let isExplicitFile = bool(raw["is_file"])
            || bool(raw["isFile"])
            || type == "file"
            || type == "audiofile"
            || type == "audio_file"
        let isExplicitlyNonAudio = rawMimeType.map {
            !$0.lowercased().hasPrefix("audio/")
        } ?? false
        // Album and artist APIs commonly return only `id`/`name` (and
        // optional artist metadata), without a `type` field. At the root of a
        // dimension-specific request those records are containers even when
        // their shape overlaps a song's metadata.
        let hasStrongAudioIdentity = songAudio != nil
            || raw["duration"] != nil
            || raw["song_id"] != nil
            || raw["track_id"] != nil
            || raw["bitrate"] != nil
            || raw["is_playable"] != nil
            || raw["isPlayable"] != nil
            || type.contains("song")
            || type.contains("track")
            || type == "music"
            || type.contains("audio")
            || rawMimeType?.lowercased().hasPrefix("audio/") == true
            || audioContainer != nil
            || SourceCatalogItem.isAudioFileExtension(suffix)
            || isExplicitFile
        let isDimensionContainer = parentID == nil
            && (mode == .albums || mode == .artists)
            && !isFolder
            && !hasStrongAudioIdentity
            && !isExplicitlyNonAudio
        let isAlbum = isAlbumType
            || (mode == .albums && isDimensionContainer)
        let isArtist = isArtistType
            || (mode == .artists && isDimensionContainer)
        let isPlayable = !isFolder
            && !isAlbum
            && !isArtist
            && !isExplicitlyNonAudio
            && (bool(raw["is_playable"])
                || bool(raw["isPlayable"])
                || isAudioType
                || hasAudioMetadata
                || rawMimeType?.lowercased().hasPrefix("audio/") == true
                || audioContainer != nil
                || SourceCatalogItem.isAudioFileExtension(suffix)
                // Audio Station's folder listing can mark an audio object only
                // as a generic `file`; its filename may be extensionless. Treat
                // that explicit file marker as audio unless DSM supplied a
                // contradictory non-audio MIME type.
                || isExplicitFile)
        let kind: SourceCatalogItemKind = isFolder
            ? .folder
            : (isArtist
                ? .artist
                : (isAlbum
                    ? .album
                    : (isPlayable
                        ? (isTrackType ? .track : .audioFile)
                        : .unknown)))

        let pathName = lastPathComponent(string(raw["path"]))
        let displayName: String
        if isFolder || isAlbum || isArtist {
            displayName = dimensionName
                ?? firstNonEmpty([
                    string(raw["title"]),
                    string(raw["name"]),
                    pathName,
                ])
                ?? externalID
        } else {
            displayName = firstNonEmpty([
                string(raw["song_title"]),
                string(raw["title"]),
                string(raw["name"]),
                string(raw["filename"]),
                string(raw["file_name"]),
                pathName,
                
            ]) ?? externalID
        }
        // On some DSM versions `title` is the source filename while the
        // embedded track title is returned in song_tag. Prefer the metadata
        // value so compilation folders do not render the same filename for
        // every song.
        let titleCandidate = firstNonEmpty([
            string(songTag?["title"]),
            string(songTag?["name"]),
            string(songTag?["song_title"]),
            string(songTag?["track_title"]),
            string(songTag?["trackTitle"]),
            string(songTag?["song_name"]),
            string(metadata?["title"]),
            string(metadata?["name"]),
            string(metadata?["song_title"]),
            string(metadata?["track_title"]),
            string(additional?["song_title"]),
            string(additional?["track_title"]),
            string(raw["song_title"]),
            string(raw["song_name"]),
            string(raw["track_title"]),
            string(raw["trackTitle"]),
            string(raw["display_title"]),
            string(raw["title"]),
            string(raw["name"]),
        ])
        let title = titleCandidate.flatMap {
            Self.isMeaningfulTrackTitle($0, comparedToFileName: displayName)
                ? $0
                : nil
        }
        let artist = firstNonEmpty([
            string(raw["artist"]),
            nestedString(raw["artist"], key: "name"),
            string(raw["album_artist"]),
            string(raw["display_artist"]),
            string(songTag?["artist"]),
            nestedString(songTag?["artist"], key: "name"),
            isArtist ? dimensionName : nil,
        ])
        let album = firstNonEmpty([
            string(raw["album"]),
            nestedString(raw["album"], key: "name"),
            string(songTag?["album"]),
            nestedString(songTag?["album"], key: "name"),
            isAlbum ? dimensionName : nil,
        ])
        let mimeType = rawMimeType?.contains("/") == true
            ? rawMimeType
            : audioContainer.map { "audio/\($0.lowercased())" }
        return SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: externalID),
            kind: kind,
            displayName: displayName,
            parentID: parentID,
            title: title,
            artist: artist,
            album: album,
            duration: (double(raw["duration"]) ?? double(songAudio?["duration"]))
                .map(Duration.seconds),
            byteSize: int64(raw["size"])
                ?? int64(raw["file_size"])
                ?? int64(songAudio?["filesize"])
                ?? int64(songAudio?["file_size"]),
            contentRevision: string(raw["version"]) ?? string(raw["mtime"]),
            mimeType: mimeType,
            isPlayable: isPlayable
        )
    }

    private static func mapDSMError(root: [String: Any]) -> OnlineSourceAdapterError {
        let code = int((root["error"] as? [String: Any])?["code"])
            ?? int(root["code"])
        switch code {
        case 105, 106:
            return .authorizationRequired
        case 400, 401, 402:
            return .permissionDenied
        case 404:
            return .resourceNotFound
        case 429:
            return .rateLimited
        default:
            return code.map(OnlineSourceAdapterError.serviceErrorCode)
                ?? .invalidResponse
        }
    }

    private static func mapDSMAuthError(root: [String: Any]) -> any Error {
        let code = dsmErrorCode(root: root)
        switch code {
        case 403, 406:
            return OnlineSourceAuthenticationError.oneTimeCodeRequired
        case 404:
            return OnlineSourceAuthenticationError.invalidOneTimeCode
        default:
            return mapDSMError(root: root)
        }
    }

    private static func dsmErrorCode(root: [String: Any]) -> Int? {
        dsmErrorCode(in: root)
    }

    private static func dsmErrorCode(in value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            if let code = int(dictionary["code"]) {
                return code
            }
            for key in ["error", "errors", "data", "result"] {
                if let nested = dictionary[key],
                   let code = dsmErrorCode(in: nested) {
                    return code
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let code = dsmErrorCode(in: nested) {
                    return code
                }
            }
        }
        return nil
    }

    private static func mapDSMError(data: Data) -> OnlineSourceAdapterError {
        guard let root = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any]
        else {
            return .invalidResponse
        }
        return mapDSMError(root: root)
    }

    private static func dsmErrorCode(data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any]
        else {
            return nil
        }
        return dsmErrorCode(root: root)
    }

    private static func redactedJSONSummary(data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return "parse=failed"
        }
        guard let root = object as? [String: Any] else {
            return "root=\(jsonValueShape(object))"
        }
        let keys = root.keys.sorted().joined(separator: ",")
        let success: String
        if let value = root["success"] as? Bool {
            success = value ? "true" : "false"
        } else {
            success = "missing"
        }
        return "keys=\(keys) success=\(success) data=\(jsonValueShape(root["data"])) error=\(jsonValueShape(root["error"]))"
    }

    private static func jsonValueShape(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return "missing"
        case let dictionary as [String: Any]:
            return "object(\(dictionary.keys.sorted().joined(separator: ",")))"
        case let array as [Any]:
            return "array(\(array.count))"
        case is String:
            return "string"
        case is NSNumber:
            return "number"
        default:
            return "value"
        }
    }

    private static func fileByteCount(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
            .map(\.int64Value) ?? -1
    }

    private static func requiresTranscode(itemID: SourceObjectID) -> Bool {
        let externalID = itemID.externalID.lowercased()
        return externalID.hasPrefix("music_v_") || externalID.contains("_v_")
    }

    private static func fileName(
        _ value: String?,
        replacingExtensionWith newExtension: String
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let url = URL(fileURLWithPath: value)
        if url.pathExtension.isEmpty {
            return "\(value).\(newExtension)"
        }
        return url.deletingPathExtension()
            .appendingPathExtension(newExtension)
            .lastPathComponent
    }

    private static func jsonRoot(data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any]
    }

    private static func downloadResponseKind(
        response: HTTPURLResponse,
        temporaryURL: URL
    ) -> String {
        if response.mimeType?.lowercased().contains("json") == true {
            return "json"
        }
        guard let handle = try? FileHandle(forReadingFrom: temporaryURL) else {
            return "binary"
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 512) else {
            return "binary"
        }
        let bytes = prefix.drop(while: { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        })
        return bytes.first == 0x7B || bytes.first == 0x5B ? "json" : "binary"
    }

    private static func redactedErrorCode(_ error: Error) -> String {
        switch error {
        case let error as OnlineSourceAdapterError:
            switch error {
            case let .httpStatus(status): return "http_\(status)"
            case let .serviceErrorCode(code): return "service_\(code)"
            case .invalidProvider: return "invalid_provider"
            case .missingEndpoint: return "missing_endpoint"
            case .missingCredential: return "missing_credential"
            case .authorizationRequired: return "authorization_required"
            case .invalidResponse: return "invalid_response"
            case .transportUnavailable: return "transport_unavailable"
            case .invalidCredential: return "invalid_credential"
            case .permissionDenied: return "permission_denied"
            case .resourceNotFound: return "resource_not_found"
            case .rateLimited: return "rate_limited"
            case .operationNotImplemented: return "operation_not_implemented"
            }
        case is CancellationError:
            return "cancelled"
        default:
            return String(describing: type(of: error))
        }
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

    private static func offset(from cursor: MediaSourceCursor?) -> Int {
        cursor.flatMap { Int($0.rawValue) } ?? 0
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    private static func isMeaningfulTrackTitle(
        _ candidate: String,
        comparedToFileName fileName: String
    ) -> Bool {
        let titleName = URL(fileURLWithPath: candidate).lastPathComponent
        let titleStem = URL(fileURLWithPath: titleName)
            .deletingPathExtension()
            .lastPathComponent
        let displayName = URL(fileURLWithPath: fileName).lastPathComponent
        let displayStem = URL(fileURLWithPath: displayName)
            .deletingPathExtension()
            .lastPathComponent
        let normalizedTitle = titleStem
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDisplayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDisplayStem = displayStem
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTitle.isEmpty,
              normalizedTitle != "—",
              normalizedTitle != "-",
              // A bare number is a track ordinal, never a song title.
              !normalizedTitle.allSatisfy({ $0.isNumber }),
              normalizedTitle != normalizedDisplayName,
              normalizedTitle != normalizedDisplayStem
        else { return false }
        return true
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = (value as? String)?.lowercased() {
            return ["1", "true", "yes", "y"].contains(value)
        }
        return false
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func nestedString(_ value: Any?, key: String) -> String? {
        string(dictionary(value)?[key])
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any]
        }
        if let string = value as? String,
           let data = string.data(using: .utf8) {
            return try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any]
        }
        if let data = value as? Data {
            return try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any]
        }
        return nil
    }

    private static func lastPathComponent(_ value: String?) -> String? {
        guard let value,
              let component = value.split(whereSeparator: { $0 == "/" || $0 == "\\" })
              .last
        else { return nil }
        let normalized = String(component)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
