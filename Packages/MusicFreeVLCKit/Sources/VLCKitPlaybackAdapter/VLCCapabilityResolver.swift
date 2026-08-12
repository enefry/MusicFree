import Foundation
import PlaybackAPI

internal struct VLCRuntimeCapabilitySnapshot: Sendable {
  let seeking: Bool
  let variableRate: Bool
  let equalizerDescriptor: EqualizerDescriptor?

  init(
    seeking: Bool,
    variableRate: Bool,
    equalizerDescriptor: EqualizerDescriptor? = nil
  ) {
    self.seeking = seeking
    self.variableRate = variableRate
    self.equalizerDescriptor = equalizerDescriptor
  }
}

internal enum VLCCapabilityResolver {
  static func resolve(
    policy: VLCKitCapabilityPolicy,
    runtime: VLCRuntimeCapabilitySnapshot
  ) -> PlaybackCapabilities {
    var capabilities: PlaybackCapabilities = []
    if policy.enabledCapabilities.contains(.seeking), runtime.seeking {
      capabilities.insert(.seeking)
    }
    if policy.enabledCapabilities.contains(.variableRate), runtime.variableRate {
      capabilities.insert(.variableRate)
    }
    if policy.enabledCapabilities.contains(.equalizer),
       runtime.equalizerDescriptor != nil
    {
      capabilities.insert(.equalizer)
    }
    return capabilities
  }
}
