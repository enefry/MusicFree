import FFmpegAudioKit
import Foundation
import MediaSourceAPI

/// 基于 FFmpegAudioKit 的元数据读取：读标签与内嵌封面，映射为 MusicFreeCore 的
/// `RawMediaMetadata`。只支持本地文件；远程资源留待后续版本。
///
/// 标签清洗（`MetadataTextRepair`）已内建在 `RawMediaMetadata` 的构造里，本层
/// 只做字段搬运与类型转换。
public final class FFmpegMetadataReader: Sendable, MetadataReading {
    public init() {}

    public func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
        try Task.checkCancellation()
        guard case let .localFile(url) = resource else {
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
            artworks: meta.artworks.map { art in
                RawArtwork(data: art.data, mimeType: art.mimeType)
            }
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
