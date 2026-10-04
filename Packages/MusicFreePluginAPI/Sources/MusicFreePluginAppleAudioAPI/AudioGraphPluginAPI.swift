import AVFAudio
import MusicFreePluginDSPAPI
import MusicFreePluginAPI

/// Node effects are configured on the main actor; AVAudioEngine owns rendering.
@MainActor public protocol PluginAppleAudioEffect: AnyObject {
    var node: AVAudioNode { get }
    var behavior: PluginDSPBehavior { get }
    func configure(format: AVAudioFormat) throws
    func reset(_ reason: PluginDSPResetReason)
    /// Return true only when parameters can be updated without replacing the node.
    func update(configuration: PluginInstanceConfiguration) throws -> Bool
    func setBypassed(_ bypassed: Bool)
}
public extension PluginAppleAudioEffect {
    func update(configuration: PluginInstanceConfiguration) throws -> Bool { false }
}
@MainActor public protocol AudioGraphDSPAdapter: AnyObject {
    func attach(_ effect: any PluginAppleAudioEffect, format: AVAudioFormat, graphGeneration: UInt64) throws
    func detach(graphGeneration: UInt64)
    func rebuild(format: AVAudioFormat, graphGeneration: UInt64) throws
}
public typealias AppleAudioDSPPluginFactory = @MainActor @Sendable (PluginInstanceConfiguration) throws -> any PluginAppleAudioEffect
