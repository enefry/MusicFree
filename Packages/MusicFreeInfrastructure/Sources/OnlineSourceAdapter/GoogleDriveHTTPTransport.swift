import Foundation
import MediaSourceAPI
import MusicDomain

/// Read-only Google Drive v3 transport for the 1.2.0 DownloadSource boundary.
/// It lists folders/files and stages binary audio downloads; it never stores a
/// remote URL or OAuth token in a catalog value.
public final class GoogleDriveHTTPTransport: GoogleDriveTransport, @unchecked Sendable {
    public let baseURL: URL
    private let httpClient: any OnlineHTTPClient

    public init(
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
        httpClient: any OnlineHTTPClient = URLSessionOnlineHTTPClient()
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
    }

    public func browse(
        configuration: GoogleDriveSourceConfiguration,
        session: GoogleDriveOAuthSession,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        let parentID = request.parentID?.externalID ?? "root"
        let escapedParentID = parentID.replacingOccurrences(of: "'", with: "\\'")
        let query = "'\(escapedParentID)' in parents and trashed = false"
        let url = try makeURL(
            path: "files",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(
                    name: "pageSize",
                    value: String(request.pageSize)
                ),
                URLQueryItem(
                    name: "pageToken",
                    value: request.pageToken?.rawValue
                ),
                URLQueryItem(
                    name: "orderBy",
                    value: request.sort.direction == .ascending
                        ? "folder,name_natural"
                        : "folder,name_natural desc"
                ),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum,parents)"
                ),
            ]
        )
        let response = try await get(url: url, session: session)
        let page = try JSONDecoder().decode(DriveFilesPage.self, from: response)
        return SourceCatalogPage(
            items: page.files.map {
                $0.catalogItem(sourceID: configuration.sourceID)
            },
            nextPageToken: page.nextPageToken.map { MediaSourceCursor($0) }
        )
    }

    public func download(
        configuration: GoogleDriveSourceConfiguration,
        session: GoogleDriveOAuthSession,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        guard itemID.sourceID == configuration.sourceID else {
            throw OnlineSourceAdapterError.resourceNotFound
        }
        let url = try makeURL(
            path: "files/\( Self.pathComponent(itemID.externalID) )",
            queryItems: [URLQueryItem(name: "alt", value: "media")]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await httpClient.download(for: request)
        do {
            try validateOnlineHTTPStatus(response)
            if let mimeType = response.mimeType?.lowercased(),
               mimeType.contains("json") || mimeType.hasPrefix("text/") {
                let data = try Data(contentsOf: temporaryURL)
                try? FileManager.default.removeItem(at: temporaryURL)
                throw mapDriveError(data: data)
            }
            let staged = try stageOnlineDownload(
                temporaryURL: temporaryURL,
                preferredFileName: options.preferredFileName,
                fallbackExtension: "audio"
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

    public func artwork(
        configuration _: GoogleDriveSourceConfiguration,
        session _: GoogleDriveOAuthSession,
        artworkID _: ArtworkID
    ) async throws -> ArtworkResource? {
        nil
    }

    private func get(url: URL, session: GoogleDriveOAuthSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        try validateOnlineHTTPStatus(response)
        if let error = try? JSONDecoder().decode(DriveErrorEnvelope.self, from: data),
           error.error != nil {
            throw mapDriveError(data: data)
        }
        return data
    }

    private func makeURL(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.filter { $0.value != nil }
        guard let url = components?.url else {
            throw OnlineSourceAdapterError.invalidResponse
        }
        return url
    }

    private func mapDriveError(data: Data) -> OnlineSourceAdapterError {
        guard let envelope = try? JSONDecoder().decode(
            DriveErrorEnvelope.self,
            from: data
        ),
        let status = envelope.error?.code
        else {
            return .invalidResponse
        }
        switch status {
        case 401:
            return .authorizationRequired
        case 403:
            return .permissionDenied
        case 404:
            return .resourceNotFound
        case 429:
            return .rateLimited
        default:
            return .httpStatus(status)
        }
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private struct DriveFilesPage: Decodable {
    let nextPageToken: String?
    let files: [DriveFile]
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let md5Checksum: String?
    let parents: [String]?

    func catalogItem(sourceID: MediaSourceID) -> SourceCatalogItem {
        let isFolder = mimeType == "application/vnd.google-apps.folder"
        let isAudio = !isFolder && (
            mimeType.lowercased().hasPrefix("audio/")
                || ["mp3", "m4a", "m4b", "flac", "wav", "aac", "ogg", "opus", "alac"]
                    .contains(URL(fileURLWithPath: name).pathExtension.lowercased())
        )
        return SourceCatalogItem(
            id: SourceObjectID(sourceID: sourceID, externalID: id),
            kind: isFolder ? .folder : (isAudio ? .audioFile : .unknown),
            displayName: name,
            parentID: parents?.first.map {
                SourceObjectID(sourceID: sourceID, externalID: $0)
            },
            byteSize: size.flatMap(Int64.init),
            contentRevision: md5Checksum ?? modifiedTime,
            mimeType: mimeType,
            isPlayable: isAudio
        )
    }
}

private struct DriveErrorEnvelope: Decodable {
    let error: DriveError?
}

private struct DriveError: Decodable {
    let code: Int
}
