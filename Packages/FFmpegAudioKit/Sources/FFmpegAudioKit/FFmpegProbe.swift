import CFFmpegAudio
import Foundation

/// 单条音频流的技术信息（格式中立，不含任何 MusicFree 业务类型）。
public struct FFAudioTrackInfo: Equatable, Sendable {
    public let index: Int
    public let codec: String?
    public let sampleRate: Double?
    public let channelCount: Int?
    public let bitDepth: Int?
    public let bitRate: Int?
    public let isDefault: Bool
    public let isDecodable: Bool
}

/// 探测结果（格式中立）。
public struct FFProbeResult: Equatable, Sendable {
    public let tracks: [FFAudioTrackInfo]
    public let container: String?
    public let duration: Duration?
    public let hasVideo: Bool
}

/// 只读探测：打开容器读流信息，不初始化解码器、不解码。
///
/// 与解码器一样约定单线程使用；probe 调用是一次性的，返回值可自由传递。
public enum FFmpegProbe {
    public enum ProbeError: Error {
        case open(Int32)
    }

    /// 探测本地文件。
    public static func probe(localFileURL url: URL) throws -> FFProbeResult {
        var status: Int32 = 0
        guard let handle = url.path.withCString({ ffaudio_probe_open($0, &status) }) else {
            throw ProbeError.open(status)
        }
        defer { ffaudio_probe_close(handle) }

        let count = Int(ffaudio_probe_track_count(handle))
        var tracks: [FFAudioTrackInfo] = []
        tracks.reserveCapacity(count)
        for i in 0 ..< count {
            var raw = FFAudioTrack()
            guard ffaudio_probe_track(handle, Int32(i), &raw) == FFAUDIO_OK.rawValue else {
                continue
            }
            tracks.append(FFAudioTrackInfo(
                index: Int(raw.index),
                codec: raw.codec_name.map { String(cString: $0) },
                sampleRate: raw.sample_rate > 0 ? Double(raw.sample_rate) : nil,
                channelCount: raw.channels > 0 ? Int(raw.channels) : nil,
                bitDepth: raw.bits_per_sample > 0 ? Int(raw.bits_per_sample) : nil,
                bitRate: raw.bit_rate > 0 ? Int(raw.bit_rate) : nil,
                isDefault: raw.is_default != 0,
                isDecodable: raw.is_decodable != 0
            ))
        }

        let durationMs = ffaudio_probe_duration_ms(handle)
        let container = ffaudio_probe_container(handle).map { String(cString: $0) }
        return FFProbeResult(
            tracks: tracks,
            container: container,
            duration: durationMs >= 0 ? .milliseconds(durationMs) : nil,
            hasVideo: ffaudio_probe_has_video(handle) != 0
        )
    }
}
