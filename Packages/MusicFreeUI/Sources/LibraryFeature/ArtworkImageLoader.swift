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
    private static let defaultMaximumPixelDimension = 2_048

    static func image(
        from resource: ArtworkResource?,
        maximumPixelDimension: Int = defaultMaximumPixelDimension
    ) async throws -> UIImage? {
        let maximumPixelDimension = max(1, maximumPixelDimension)
        let decodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let resource else { return UIImage?(nil) }

            let image: UIImage?
            switch resource {
            case .localFile(let url):
                try validateLocalFileSize(url)
                image = downsampledImage(
                    from: url,
                    maximumPixelDimension: maximumPixelDimension
                )
            case .dataStream(let stream):
                let data = try await data(from: stream)
                try Task.checkCancellation()
                image = downsampledImage(
                    from: data,
                    maximumPixelDimension: maximumPixelDimension
                )
            }
            try Task.checkCancellation()
            return image
        }

        return try await withTaskCancellationHandler {
            try await decodingTask.value
        } onCancel: {
            decodingTask.cancel()
        }
    }

    private static func data(
        from stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        var data = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            try appendBounded(chunk, to: &data)
        }
        return data
    }

    private static func validateLocalFileSize(_ url: URL) throws {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let fileSize, fileSize > maximumResourceSize {
            throw ArtworkImageLoaderError.resourceTooLarge
        }
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

    private static func downsampledImage(
        from url: URL,
        maximumPixelDimension: Int
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            sourceOptions
        ) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

/// Kingfisher owns decoded-image caching and downsampling. The source service
/// remains responsible for resolving local files and streams. Local originals
/// already live in managed storage, so we only cache the processed image in RAM.
@MainActor
final class LibraryArtworkImagePipeline {
    static let shared = LibraryArtworkImagePipeline()

    private let cache: ImageCache
    private let manager: KingfisherManager
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private var failedUntilByKey: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 30

    init(cacheName: String = "com.musicfree.library.artwork") {
        cache = ImageCache(name: cacheName)
        cache.memoryStorage.config.countLimit = 512
        cache.memoryStorage.config.totalCostLimit = 64 * 1_024 * 1_024
        manager = KingfisherManager(downloader: .default, cache: cache)
    }

    // This synchronous lookup lets reused/new cells show a cached cover in the
    // same render pass, without scheduling a Task or showing a loading spinner.
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
        if let image = cachedImage(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: maximumPixelDimension
        ) {
            return image
        }
        let cacheKey = Self.cacheKey(artworkID: artworkID, sourceID: sourceID)
        let key = "\(cacheKey)|\(max(1, maximumPixelDimension))"
        if let failedUntil = failedUntilByKey[key] {
            guard failedUntil <= Date() else { return nil }
            failedUntilByKey[key] = nil
        }
        if let task = inFlightRequests[key] {
            return await task.value
        }

        // Providers are not network downloads; retain coalescing here so cells
        // requesting the same local cover share a single read and decode.
        let options = options(maximumPixelDimension: maximumPixelDimension)
        let manager = manager
        let task = Task { @MainActor in
            try? await manager.retrieveImage(
                with: .provider(LibraryArtworkDataProvider(
                    cacheKey: cacheKey,
                    artworkID: artworkID,
                    sourceID: sourceID,
                    serving: serving
                )),
                options: options
            ).image
        }
        inFlightRequests[key] = task
        let image = await task.value
        inFlightRequests[key] = nil
        if image == nil {
            failedUntilByKey[key] = Date().addingTimeInterval(failureRetryInterval)
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
        // Length-prefix the source to avoid ambiguous separator-containing IDs.
        "\(sourceID.rawValue.utf8.count):\(sourceID.rawValue)\(artworkID.rawValue)"
    }
}

/// Keeps the service boundary and the existing 20 MiB input bound when handing
/// image data to Kingfisher. Blocking local reads run off the main actor.
struct LibraryArtworkDataProvider: ImageDataProvider {
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
