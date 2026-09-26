import CFFmpegAudio
import Foundation

/// 解码器的自定义字节输入（例如网络流）。
///
/// 所有方法都在调用 `FFmpegAudioDecoder` 的线程上同步执行，允许阻塞等待数据；
/// 实现方负责在取消时尽快让阻塞中的 `read` 返回（抛错即可）。
public protocol FFmpegByteSource: AnyObject, Sendable {
    /// 读取最多 `buffer.count` 字节，返回实际读到的字节数；0 表示输入结束。
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    /// 是否支持随机访问。打开解码器时读取一次；为 false 时不会调用 `seek`。
    var isSeekable: Bool { get }
    /// 总字节数；未知为 nil。
    var byteCount: Int64? { get }
    /// 定位到绝对字节偏移，随后 `read` 从该处继续。
    func seek(toOffset offset: Int64) throws
}

/// C 回调的 opaque 载体：持有字节源并跟踪当前位置（C 层 SEEK_CUR 需要）。
/// 只在解码线程访问。
final class ByteSourceBox {
    let source: FFmpegByteSource
    var position: Int64 = 0
    /// 最近一次读/seek 抛出的错误，供上层还原具体原因（如 HTTP 状态码）。
    var lastError: Error?

    init(source: FFmpegByteSource) {
        self.source = source
    }

    func callbacks() -> FFAudioIOCallbacks {
        FFAudioIOCallbacks(
            opaque: Unmanaged.passUnretained(self).toOpaque(),
            read: byteSourceRead,
            seek: source.isSeekable ? byteSourceSeek : nil
        )
    }
}

private func byteSourceRead(
    _ opaque: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ size: Int32
) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return -1 }
    let box = Unmanaged<ByteSourceBox>.fromOpaque(opaque).takeUnretainedValue()
    do {
        let count = try box.source.read(
            into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size))
        )
        box.position += Int64(count)
        return Int32(count)
    } catch {
        box.lastError = error
        return -1
    }
}

private func byteSourceSeek(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: Int64,
    _ whence: Int32
) -> Int64 {
    guard let opaque else { return -1 }
    let box = Unmanaged<ByteSourceBox>.fromOpaque(opaque).takeUnretainedValue()
    if whence == FFAUDIO_SEEK_SIZE {
        return box.source.byteCount ?? -1
    }
    let target: Int64
    switch whence {
    case SEEK_SET:
        target = offset
    case SEEK_CUR:
        target = box.position + offset
    case SEEK_END:
        guard let size = box.source.byteCount else { return -1 }
        target = size + offset
    default:
        return -1
    }
    guard target >= 0 else { return -1 }
    do {
        try box.source.seek(toOffset: target)
        box.position = target
        return target
    } catch {
        box.lastError = error
        return -1
    }
}
