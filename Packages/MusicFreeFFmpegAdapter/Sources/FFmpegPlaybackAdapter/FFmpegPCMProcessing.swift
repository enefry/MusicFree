import AVFoundation

/// Optional queue-confined DSP. A fresh processor belongs to exactly one
/// decoder slot. Buffers/pointers are borrowed for this synchronous call only.
/// The host supplies a factory without making this adapter depend on plugins.
public protocol FFmpegPCMProcessing: AnyObject {
    func process(_ buffer: AVAudioPCMBuffer) throws
    func reset()
}

public typealias FFmpegPCMProcessorFactory = @Sendable (AVAudioFormat) throws -> any FFmpegPCMProcessing
