import AppServices
import Foundation
import ImageIO
import Kingfisher
import MediaSourceAPI
import MusicDomain
import UIKit

/// Keeps blocking file I/O, stream accumulation, and image decoding off the
/// MainActor-owned observable state.
enum ArtworkImageDecoding {
    private static let maximumResourceSize = 20 * 1_024 * 1_024
    private static let readChunkSize = 64 * 1_024
    private static let defaultMaximumPixelDimension = 2_048

    static func image(
        from resource: ArtworkResource?,
        maximumPixelDimension: Int = defaultMaximumPixelDimension
    ) async throws -> UIImage? {
        let maximumPixelDimension = max(1, maximumPixelDimension)
        let decodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let resource else { return UIImage?(nil) }

            let data = try await data(from: resource)
            try Task.checkCancellation()
            let image = downsampledImage(
                from: data,
                maximumPixelDimension: maximumPixelDimension
            )
            try Task.checkCancellation()
            return image
        }

        return try await withTaskCancellationHandler {
            try await decodingTask.value
        } onCancel: {
            decodingTask.cancel()
        }
    }

    private static func data(from resource: ArtworkResource) async throws -> Data {
        switch resource {
        case .localFile(let url):
            return try data(fromLocalFile: url)
        case .dataStream(let stream):
            var data = Data()
            for try await chunk in stream {
                try Task.checkCancellation()
                try appendBounded(chunk, to: &data)
            }
            return data
        }
    }

    private static func data(fromLocalFile url: URL) throws -> Data {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let fileSize, fileSize > maximumResourceSize {
            throw ArtworkImageLoaderError.resourceTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maximumResourceSize - data.count
            let count = min(readChunkSize, remaining + 1)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            try appendBounded(chunk, to: &data)
        }
        return data
    }

    private static func appendBounded(_ chunk: Data, to data: inout Data) throws {
        guard chunk.count <= maximumResourceSize - data.count else {
            throw ArtworkImageLoaderError.resourceTooLarge
        }
        data.append(chunk)
    }

    private static func downsampledImage(
        from data: Data,
        maximumPixelDimension: Int
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

/// Kingfisher owns decoded-image caching and downsampling for every PlayerFeature
/// artwork surface. The source service still resolves local files and streams.
@MainActor
final class PlayerArtworkImagePipeline {
    static let shared = PlayerArtworkImagePipeline()

    private let cache: ImageCache
    private let manager: KingfisherManager
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private var failedUntilByKey: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 30

    init(cacheName: String = "com.musicfree.player.artwork") {
        cache = ImageCache(name: cacheName)
        cache.memoryStorage.config.countLimit = 256
        cache.memoryStorage.config.totalCostLimit = 64 * 1_024 * 1_024
        manager = KingfisherManager(downloader: .default, cache: cache)
    }

    func cachedImage(
        artworkID: ArtworkID,
        sourceID: MediaSourceID,
        maximumPixelDimension: Int
    ) -> UIImage? {
        cache.retrieveImageInMemoryCache(
            forKey: Self.cacheKey(artworkID: artworkID, sourceID: sourceID),
            options: options(maximumPixelDimension: maximumPixelDimension)
        )
    }

    func image(
        artworkID: ArtworkID,
        sourceID: MediaSourceID,
        maximumPixelDimension: Int,
        serving: any ArtworkServing
    ) async -> UIImage? {
        let dimension = max(1, maximumPixelDimension)
        if let image = cachedImage(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: dimension
        ) {
            return image
        }
        let cacheKey = Self.cacheKey(artworkID: artworkID, sourceID: sourceID)
        let key = "\(cacheKey)|\(dimension)"
        if let failedUntil = failedUntilByKey[key] {
            guard failedUntil <= Date() else { return nil }
            failedUntilByKey[key] = nil
        }
        if let task = inFlightRequests[key] {
            return await task.value
        }

        let manager = manager
        let requestOptions = options(maximumPixelDimension: dimension)
        let task = Task { @MainActor in
            try? await manager.retrieveImage(
                with: .provider(PlayerArtworkDataProvider(
                    cacheKey: cacheKey,
                    artworkID: artworkID,
                    sourceID: sourceID,
                    serving: serving
                )),
                options: requestOptions
            ).image
        }
        inFlightRequests[key] = task
        let image = await task.value
        inFlightRequests[key] = nil
        if image == nil {
            failedUntilByKey[key] = Date().addingTimeInterval(failureRetryInterval)
        } else {
            failedUntilByKey[key] = nil
        }
        return image
    }

    private func options(maximumPixelDimension: Int) -> KingfisherOptionsInfo {
        let dimension = CGFloat(max(1, maximumPixelDimension))
        return [
            .targetCache(cache),
            .cacheMemoryOnly,
            .memoryCacheExpiration(.seconds(300)),
            .scaleFactor(1),
            .processor(DownsamplingImageProcessor(size: CGSize(width: dimension, height: dimension))),
            .backgroundDecode,
        ]
    }

    private static func cacheKey(artworkID: ArtworkID, sourceID: MediaSourceID) -> String {
        "\(sourceID.rawValue.utf8.count):\(sourceID.rawValue)\(artworkID.rawValue)"
    }
}

/// Keeps the source boundary and the existing 20 MiB input bound while handing
/// bytes to Kingfisher. Reads and stream accumulation run off the main actor.
struct PlayerArtworkDataProvider: ImageDataProvider {
    let cacheKey: String
    let artworkID: ArtworkID
    let sourceID: MediaSourceID
    let serving: any ArtworkServing

    func data() async throws -> Data {
        let serving = serving
        let artworkID = artworkID
        let sourceID = sourceID
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let resource = try await serving.artwork(for: artworkID, sourceID: sourceID) else {
                throw ArtworkImageLoaderError.missingResource
            }
            let maximumSize = 20 * 1_024 * 1_024
            var data = Data()
            switch resource {
            case let .localFile(url):
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > maximumSize {
                    throw ArtworkImageLoaderError.resourceTooLarge
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    try Task.checkCancellation()
                    let count = min(64 * 1_024, maximumSize - data.count + 1)
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                    guard chunk.count <= maximumSize - data.count else {
                        throw ArtworkImageLoaderError.resourceTooLarge
                    }
                    data.append(chunk)
                }
            case let .dataStream(stream):
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard chunk.count <= maximumSize - data.count else {
                        throw ArtworkImageLoaderError.resourceTooLarge
                    }
                    data.append(chunk)
                }
            }
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum ArtworkImageLoaderError: Error {
    case resourceTooLarge
    case missingResource
}
