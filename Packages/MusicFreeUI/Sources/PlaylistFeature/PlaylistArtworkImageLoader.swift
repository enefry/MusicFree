import AppServices
import DesignSystem
import Foundation
import Kingfisher
import MediaSourceAPI
import MusicDomain
import UIKit

/// Kingfisher-backed artwork pipeline for PlaylistFeature surfaces.
/// Playlist artwork is persisted in the local library, so only the decoded
/// presentation image is retained in memory; source bytes remain service-owned.
@MainActor
final class PlaylistArtworkImagePipeline {
    static let shared = PlaylistArtworkImagePipeline()

    private let cache: ImageCache
    private let manager: KingfisherManager
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private var failedUntilByKey: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 30

    init(cacheName: String = "com.musicfree.playlist.artwork") {
        cache = ImageCache(name: cacheName)
        cache.memoryStorage.config.countLimit = 128
        cache.memoryStorage.config.totalCostLimit = 32 * 1_024 * 1_024
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
        let requestKey = "\(cacheKey)|\(dimension)"
        if let failedUntil = failedUntilByKey[requestKey] {
            guard failedUntil <= Date() else { return nil }
            failedUntilByKey[requestKey] = nil
        }
        if let task = inFlightRequests[requestKey] {
            return await task.value
        }

        let manager = manager
        let requestOptions = options(maximumPixelDimension: dimension)
        let task = Task { @MainActor in
            try? await manager.retrieveImage(
                with: .provider(PlaylistArtworkDataProvider(
                    cacheKey: cacheKey,
                    artworkID: artworkID,
                    sourceID: sourceID,
                    serving: serving
                )),
                options: requestOptions
            ).image
        }
        inFlightRequests[requestKey] = task
        let image = await task.value
        inFlightRequests[requestKey] = nil
        if image == nil {
            failedUntilByKey[requestKey] = Date().addingTimeInterval(failureRetryInterval)
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

private struct PlaylistArtworkDataProvider: ImageDataProvider {
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
                throw PlaylistArtworkImageLoaderError.missingResource
            }

            let maximumSize = 20 * 1_024 * 1_024
            var data = Data()
            switch resource {
            case let .localFile(url):
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > maximumSize {
                    throw PlaylistArtworkImageLoaderError.resourceTooLarge
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    try Task.checkCancellation()
                    let count = min(64 * 1_024, maximumSize - data.count + 1)
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                    guard chunk.count <= maximumSize - data.count else {
                        throw PlaylistArtworkImageLoaderError.resourceTooLarge
                    }
                    data.append(chunk)
                }
            case let .dataStream(stream):
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard chunk.count <= maximumSize - data.count else {
                        throw PlaylistArtworkImageLoaderError.resourceTooLarge
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

private enum PlaylistArtworkImageLoaderError: Error {
    case resourceTooLarge
    case missingResource
}

@MainActor
final class PlaylistArtworkBinding {
    private struct Request: Equatable {
        let artworkID: ArtworkID
        let sourceID: MediaSourceID
        let maximumPixelDimension: Int
    }

    private weak var view: MusicFreeUIKitArtworkView?
    private let pipeline: PlaylistArtworkImagePipeline
    private var request: Request?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        view: MusicFreeUIKitArtworkView,
        pipeline: PlaylistArtworkImagePipeline = .shared
    ) {
        self.view = view
        self.pipeline = pipeline
    }

    deinit { task?.cancel() }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        view?.image = nil
        view?.isLoading = false
    }

    func configure(
        artworkID: ArtworkID?,
        sourceID: MediaSourceID = .local,
        maximumPixelDimension: Int,
        serving: (any ArtworkServing)?
    ) {
        guard let view else { return }
        guard let artworkID, let serving else {
            reset()
            return
        }

        let next = Request(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: max(1, maximumPixelDimension)
        )
        if request == next, view.image != nil || task != nil { return }

        let sameArtwork = request?.artworkID == artworkID && request?.sourceID == sourceID
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        task = nil
        request = next
        if let image = pipeline.cachedImage(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: next.maximumPixelDimension
        ) {
            view.image = image
            view.isLoading = false
            return
        }
        if !sameArtwork { view.image = nil }
        view.isLoading = view.image == nil

        let pipeline = pipeline
        task = Task { @MainActor [weak self] in
            let image = await pipeline.image(
                artworkID: artworkID,
                sourceID: sourceID,
                maximumPixelDimension: next.maximumPixelDimension,
                serving: serving
            )
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.view?.image = image
            self.view?.isLoading = false
            self.task = nil
        }
    }
}
