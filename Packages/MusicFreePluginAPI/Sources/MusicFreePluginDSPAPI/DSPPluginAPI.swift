import Foundation
import MusicFreePluginAPI

public struct PluginPCMFormat: Hashable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let maximumFrames: Int
    public init(sampleRate: Double, channelCount: Int, maximumFrames: Int) throws {
        guard sampleRate.isFinite, sampleRate > 0, (1...32).contains(channelCount),
              maximumFrames > 0, maximumFrames <= 1_048_576 else { throw PluginError.invalidConfiguration }
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.maximumFrames = maximumFrames
    }
}
public enum PluginDSPScope: String, Sendable { case perTrack, postMix }
public enum PluginDSPResetReason: Sendable { case seek, stop, routeChange, mediaReset, reconfigure }
public struct PluginDSPBehavior: Sendable {
    public let scope: PluginDSPScope
    public let latencyFrames: Int
    public let tailFrames: Int
    public init(scope: PluginDSPScope = .perTrack, latencyFrames: Int = 0, tailFrames: Int = 0) {
        self.scope = scope; self.latencyFrames = max(0, latencyFrames); self.tailFrames = max(0, tailFrames)
    }
}
/// Borrowed planar Float32 memory. Only valid for the synchronous process call;
/// neither the table nor any channel pointer may be retained by a processor.
public struct PluginPCMBufferView {
    public let channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>
    public let frameCount: Int
    public let format: PluginPCMFormat
    public init(channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int, format: PluginPCMFormat) throws {
        guard channels.count == format.channelCount, (0...format.maximumFrames).contains(frameCount) else { throw PluginError.invalidConfiguration }
        self.channels = channels; self.frameCount = frameCount; self.format = format
    }
}
/// Configuration/reset happen on the same serial owner as processing. No await,
/// preference lookup, network, log, allocation or blocking inside process.
public protocol PluginDSPProcessor: Sendable {
    var behavior: PluginDSPBehavior { get }
    mutating func prepare(format: PluginPCMFormat) throws
    mutating func process(_ buffer: PluginPCMBufferView) throws
    mutating func reset(_ reason: PluginDSPResetReason)
}
public typealias DSPPluginFactory = @Sendable (PluginInstanceConfiguration) throws -> any PluginDSPProcessor
