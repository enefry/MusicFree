import AVFoundation
import FFmpegAudioKit
import Foundation
import ImageIO
import MediaSourceAPI
import UniformTypeIdentifiers

/// 基于 FFmpegAudioKit 的元数据读取：读标签与内嵌封面，映射为 MusicFreeCore 的
/// `RawMediaMetadata`。只支持本地文件；远程资源留待后续版本。
///
/// 标签清洗（`MetadataTextRepair`）已内建在 `RawMediaMetadata` 的构造里，本层
/// 只做字段搬运与类型转换。
public final class FFmpegMetadataReader: Sendable, MetadataReading {
    public init() {}

    public func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
        try Task.checkCancellation()
        guard let url = resource.localFileURL else {
            throw MediaSourceError.invalidResource
        }

        let meta: FFMetadata
        do {
            meta = try await Self.runOffMain {
                // 显式限定到 kit 的读取器，避免与本类型同名冲突。
                try FFmpegAudioKit.FFmpegMetadataReader.read(localFileURL: url)
            }
        } catch is CancellationError {
            throw MediaSourceError.cancelled
        } catch {
            throw MediaSourceError.probeFailed(.readFailed)
        }
        try Task.checkCancellation()

        let artworks = meta.artworks.map { art in
            RawArtwork(data: art.data, mimeType: art.mimeType)
        }
        let videoArtwork = artworks.isEmpty ? await Self.videoFrameArtwork(at: url) : nil
        try Task.checkCancellation()
        return RawMediaMetadata(
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            albumArtist: meta.albumArtist,
            composer: meta.composer,
            genre: meta.genre,
            comment: meta.comment,
            lyrics: meta.lyrics,
            trackNumber: meta.trackNumber,
            discNumber: meta.discNumber,
            year: meta.year,
            duration: meta.duration,
            artworks: videoArtwork.map { [$0] } ?? artworks
        )
    }

    private static func videoFrameArtwork(at url: URL) async -> RawArtwork? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        guard let image = try? await generator.image(at: .zero).image,
              !Task.isCancelled else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return RawArtwork(
            data: data as Data, mimeType: "image/jpeg",
            pixelWidth: image.width, pixelHeight: image.height
        )
    }

    private static func runOffMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
