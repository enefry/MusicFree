import AVFoundation
import CFFmpegAudio
import Foundation

/// ffmpeg C 解码桥的 Swift 薄封装。
///
/// 只做一件事：打开一个音频资源，按需把 PCM 解码进 `AVAudioPCMBuffer`
/// （非交错 / planar Float32，即 AVAudioEngine 的标准格式）。它不是并发安全
/// 的——约定由单一解码队列独占访问，因此标注 `@unchecked Sendable` 以便在该
/// 队列间传递。
public final class FFmpegAudioDecoder: @unchecked Sendable {
    /// 解码输出格式，非交错（planar）Float32。
    public let format: AVAudioFormat
    /// 采样率下的总时长；未知为 nil。
    public let duration: Duration?

    private let handle: OpaquePointer
    private let channels: Int
    // 自定义输入时持有；C 层通过 unretained 指针回调它，必须活得比 handle 久
    // （deinit 先 ffaudio_close，再释放存储属性）。
    private let ioBox: ByteSourceBox?

    public enum DecoderError: Error {
        case open(Int32)
        case unsupportedFormat
        /// 输入读取失败，且字节源没有给出更具体的错误。
        case io
    }

    /// 打开本地文件。
    public convenience init(localFileURL url: URL) throws {
        var status: Int32 = 0
        let handle = url.path.withCString { ffaudio_open_file($0, &status) }
        try self.init(handle: handle, status: status, ioBox: nil)
    }

    /// 以自定义字节输入打开（例如网络流）。会在当前线程同步读取容器头部，
    /// 可能阻塞；`probeSize` 限制探测读取的字节数以控制起播耗时。
    public convenience init(byteSource: FFmpegByteSource, probeSize: Int64? = nil) throws {
        let box = ByteSourceBox(source: byteSource)
        var status: Int32 = 0
        let handle = ffaudio_open_io(box.callbacks(), probeSize ?? 0, &status)
        try self.init(handle: handle, status: status, ioBox: box)
    }

    private init(handle: OpaquePointer?, status: Int32, ioBox: ByteSourceBox?) throws {
        guard let handle else {
            throw ioBox?.lastError ?? DecoderError.open(status)
        }
        let raw = ffaudio_format(handle)
        guard raw.sample_rate > 0, raw.channels > 0,
              let audioFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(raw.sample_rate),
                  channels: AVAudioChannelCount(raw.channels),
                  interleaved: false
              )
        else {
            ffaudio_close(handle)
            throw DecoderError.unsupportedFormat
        }

        self.handle = handle
        self.ioBox = ioBox
        self.format = audioFormat
        self.channels = Int(raw.channels)
        self.duration = raw.duration_ms >= 0 ? .milliseconds(raw.duration_ms) : nil
    }

    deinit {
        ffaudio_close(handle)
    }

    /// 把最多 `frameCapacity` 帧解码进新分配的 buffer。
    /// 返回 nil 表示到达文件尾，抛错表示解码或读取失败。
    ///
    /// C 层产出的是交错 Float32；这里读进交错暂存后散布到各声道平面，使输出
    /// buffer 为非交错（planar）——AVAudioUnit / AVAudioEngine 连接所要求的
    /// 标准格式（交错格式会触发 `setFormat` -10868 kAudioUnitErr_FormatNotSupported）。
    public func nextBuffer(frameCapacity: AVAudioFrameCount = 8192) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity),
              let channelData = buffer.floatChannelData
        else {
            throw DecoderError.unsupportedFormat
        }

        let channelCount = channels
        var interleaved = [Float](repeating: 0, count: Int(frameCapacity) * channelCount)
        let framesRead = interleaved.withUnsafeMutableBufferPointer { ptr in
            ffaudio_read_float(handle, ptr.baseAddress, Int32(frameCapacity))
        }
        if framesRead == FFAUDIO_ERR_IO.rawValue {
            throw takeIOError()
        }
        if framesRead < 0 {
            throw DecoderError.open(framesRead)
        }
        if framesRead == 0 {
            return nil // EOF
        }

        let frames = Int(framesRead)
        interleaved.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            if channelCount == 1 {
                channelData[0].update(from: base, count: frames)
            } else {
                for ch in 0 ..< channelCount {
                    let dst = channelData[ch]
                    for frame in 0 ..< frames {
                        dst[frame] = base[frame * channelCount + ch]
                    }
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// seek 到指定位置；随后 `nextBuffer` 从该位置继续。
    public func seek(to position: Duration) throws {
        let components = position.components
        guard position >= .zero,
              components.seconds <= Int64.max / 1_000_000 else {
            throw DecoderError.open(FFAUDIO_ERR_ARG.rawValue)
        }
        let (us, overflow) = (components.seconds * 1_000_000).addingReportingOverflow(
            components.attoseconds / 1_000_000_000_000
        )
        guard !overflow else { throw DecoderError.open(FFAUDIO_ERR_ARG.rawValue) }
        ioBox?.lastError = nil
        let status = ffaudio_seek_us(handle, us)
        if status != FFAUDIO_OK.rawValue {
            if let error = ioBox?.lastError {
                ioBox?.lastError = nil
                throw error
            }
            throw DecoderError.open(status)
        }
    }

    private func takeIOError() -> Error {
        defer { ioBox?.lastError = nil }
        return ioBox?.lastError ?? DecoderError.io
    }
}
