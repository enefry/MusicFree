import AppServices
import Combine
import Foundation
import ImageIO
import MediaSourceAPI
import MusicDomain
import SwiftUI
import UIKit

@MainActor
final class ArtworkImageLoader: ObservableObject {
    @Published private(set) var image: Image?
    private var requestGeneration = 0
    private let imageDecoder: @Sendable (ArtworkResource?) async throws -> UIImage?

    init(
        imageDecoder: @escaping @Sendable (ArtworkResource?) async throws -> UIImage? = {
            try await ArtworkImageDecoding.image(from: $0)
        }
    ) {
        self.imageDecoder = imageDecoder
    }

    func load(
        artworkID: ArtworkID?,
        sourceID: MediaSourceID?,
        serving: (any ArtworkServing)?
    ) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        image = nil
        guard let artworkID, let sourceID, let serving else { return }

        do {
            let resource = try await serving.artwork(
                for: artworkID,
                sourceID: sourceID
            )
            try Task.checkCancellation()
            let decodedImage = try await imageDecoder(resource)
            try Task.checkCancellation()
            guard let uiImage = decodedImage, generation == requestGeneration else { return }
            image = Image(uiImage: uiImage)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            image = nil
        }
    }
}

/// Keeps blocking file I/O, stream accumulation, and image decoding off the
/// MainActor-owned observable state.
enum ArtworkImageDecoding {
    private static let maximumResourceSize = 20 * 1_024 * 1_024
    private static let readChunkSize = 64 * 1_024
    private static let maximumPixelDimension = 2_048

    static func image(from resource: ArtworkResource?) async throws -> UIImage? {
        let decodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let resource else { return UIImage?(nil) }

            let data = try await data(from: resource)
            try Task.checkCancellation()
            let image = downsampledImage(from: data)
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

    private static func downsampledImage(from data: Data) -> UIImage? {
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

enum ArtworkImageLoaderError: Error {
    case resourceTooLarge
}
