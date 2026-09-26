import CFFmpegAudio
import Foundation

/// 内嵌封面（格式中立）。
public struct FFArtwork: Equatable, Sendable {
    public let data: Data
    public let mimeType: String?
}

/// 元数据读取结果（格式中立，不含 MusicFree 业务类型）。
public struct FFMetadata: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let composer: String?
    public let genre: String?
    public let comment: String?
    public let lyrics: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let duration: Duration?
    public let artworks: [FFArtwork]
}

/// 只读元数据：读取标签与内嵌封面，不解码音频。
public enum FFmpegMetadataReader {
    public enum MetadataError: Error {
        case open(Int32)
    }

    /// 读取本地文件的标签与封面。
    public static func read(localFileURL url: URL) throws -> FFMetadata {
        var status: Int32 = 0
        guard let handle = url.path.withCString({ ffaudio_metadata_open($0, &status) }) else {
            throw MetadataError.open(status)
        }
        defer { ffaudio_metadata_close(handle) }

        func value(_ keys: String...) -> String? {
            for key in keys {
                if let raw = key.withCString({ ffaudio_metadata_value(handle, $0) }) {
                    let s = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { return s }
                }
            }
            return nil
        }

        // "3/12" 之类取前导整数。
        func leadingInt(_ raw: String?) -> Int? {
            guard let raw else { return nil }
            let digits = raw.prefix { $0.isNumber }
            return Int(digits)
        }

        let durationMs = ffaudio_metadata_duration_ms(handle)

        var artworks: [FFArtwork] = []
        let artCount = Int(ffaudio_metadata_artwork_count(handle))
        for i in 0 ..< artCount {
            var bytes: UnsafePointer<UInt8>?
            var len: Int32 = 0
            var mime: UnsafePointer<CChar>?
            guard ffaudio_metadata_artwork(handle, Int32(i), &bytes, &len, &mime) == FFAUDIO_OK.rawValue,
                  let bytes, len > 0
            else { continue }
            artworks.append(FFArtwork(
                data: Data(bytes: bytes, count: Int(len)),
                mimeType: mime.map { String(cString: $0) }
            ))
        }

        return FFMetadata(
            title: value("title"),
            artist: value("artist"),
            album: value("album"),
            albumArtist: value("album_artist", "albumartist"),
            composer: value("composer"),
            genre: value("genre"),
            comment: value("comment"),
            lyrics: value("lyrics", "unsyncedlyrics", "USLT"),
            trackNumber: leadingInt(value("track")),
            discNumber: leadingInt(value("disc")),
            year: leadingInt(value("date", "year")),
            duration: durationMs >= 0 ? .milliseconds(durationMs) : nil,
            artworks: artworks
        )
    }
}
