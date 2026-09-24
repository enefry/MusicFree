import FFmpegAudioKit
import Foundation
import MediaSourceAPI

/// 基于 FFmpegAudioKit 的媒体探测：打开容器读流信息，映射为 MusicFreeCore 的
/// `MediaProbeResult`。只支持本地文件；远程资源留待后续版本（自定义 AVIO）。
///
/// ffmpeg 探测是同步、阻塞的，故放到工具队列执行，避免占用调用方执行器。
public final class FFmpegMediaProbe: Sendable, MediaProbing {
    public init() {}

    public func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
        try Task.checkCancellation()
        guard case let .localFile(url) = resource else {
            // 远程资源当前不支持探测。
            throw MediaSourceError.invalidResource
        }

        let result: FFProbeResult
        do {
            result = try await Self.runOffMain {
                try FFmpegProbe.probe(localFileURL: url)
            }
        } catch is CancellationError {
            throw MediaSourceError.cancelled
        } catch {
            throw MediaSourceError.probeFailed(.readFailed)
        }
        try Task.checkCancellation()

        let tracks = result.tracks.map { track in
            ProbedAudioTrack(
                index: track.index,
                stableID: "ffmpeg-stream:\(track.index)",
                codec: track.codec,
                sampleRate: track.sampleRate,
                channelCount: track.channelCount,
                bitDepth: track.bitDepth,
                bitRate: track.bitRate,
                language: nil,
                title: nil,
                isDefault: track.isDefault,
                isDecodable: track.isDecodable
            )
        }
        return try MediaProbeResult(
            audioTracks: tracks,
            container: result.container,
            duration: result.duration,
            hasVideoTrack: result.hasVideo
        ).validated()
    }

    /// 在工具队列执行阻塞的 ffmpeg 调用，桥回 async 世界。
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
