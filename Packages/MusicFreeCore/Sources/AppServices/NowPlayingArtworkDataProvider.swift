import Foundation
import MediaSourceAPI
import MusicDomain
import SystemIntegrationAPI

internal actor SourceNowPlayingArtworkProvider: NowPlayingArtworkProviding {
    static let maximumByteCount = 20 * 1024 * 1024

    private let sourceResolver: any MediaSourceResolving
    private let sourceID: MediaSourceID
    private let artworkID: ArtworkID
    private var cachedData: Data?

    init(
        sourceResolver: any MediaSourceResolving,
        sourceID: MediaSourceID,
        artworkID: ArtworkID
    ) {
        self.sourceResolver = sourceResolver
        self.sourceID = sourceID
        self.artworkID = artworkID
    }

    func artworkData() async throws -> Data? {
        if let cachedData { return cachedData }
        try Task.checkCancellation()
        let source = try await sourceResolver.source(for: sourceID)
        guard let resource = try await source.artwork(for: artworkID) else { return nil }

        let data = try await Self.read(resource, maximumByteCount: Self.maximumByteCount)
        try Task.checkCancellation()
        cachedData = data
        return data
    }

    private nonisolated static func read(
        _ resource: ArtworkResource,
        maximumByteCount: Int
    ) async throws -> Data {
        switch resource {
        case .localFile(let url):
            let readTask = Task.detached(priority: .utility) {
                try readLocalFile(url, maximumByteCount: maximumByteCount)
            }
            return try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: {
                readTask.cancel()
            }
        case .dataStream(let stream):
            var data = Data()
            for try await chunk in stream {
                try Task.checkCancellation()
                guard chunk.count <= maximumByteCount - data.count else {
                    throw NowPlayingArtworkError.resourceTooLarge
                }
                data.append(chunk)
            }
            return data
        }
    }

    private nonisolated static func readLocalFile(
        _ url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                return data
            }
            guard chunk.count <= maximumByteCount - data.count else {
                throw NowPlayingArtworkError.resourceTooLarge
            }
            data.append(chunk)
        }
    }
}

private enum NowPlayingArtworkError: Error {
    case resourceTooLarge
}
