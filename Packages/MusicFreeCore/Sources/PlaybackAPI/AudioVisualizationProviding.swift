import Foundation

/// A named frequency band used by an analysis stream. It does not imply a PCM
/// tap or expose a decoder-specific audio buffer.
public struct AudioVisualizationBand: Codable, Equatable, Hashable, Sendable {
  public let centerFrequencyHz: Double
  public let name: String?

  public init(centerFrequencyHz: Double, name: String? = nil) {
    precondition(
      centerFrequencyHz.isFinite && centerFrequencyHz > 0,
      "AudioVisualizationBand.centerFrequencyHz must be positive"
    )
    self.centerFrequencyHz = centerFrequencyHz
    self.name = Self.normalized(name)
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

public struct AudioVisualizationDescriptor: Codable, Equatable, Hashable, Sendable {
  public let bands: [AudioVisualizationBand]

  public init(bands: [AudioVisualizationBand]) {
    let frequencies = bands.map(\.centerFrequencyHz)
    precondition(
      Set(frequencies).count == frequencies.count,
      "AudioVisualizationDescriptor bands must have unique center frequencies"
    )
    self.bands = bands
  }
}

/// One timestamped analysis frame. `magnitudes` is adapter-defined analysis
/// output and is intentionally not represented as raw PCM.
public struct AudioVisualizationFrame: Codable, Equatable, Hashable, Sendable {
  public let generation: PlaybackGeneration
  public let timestamp: Duration
  public let magnitudes: [Float]

  public init(
    generation: PlaybackGeneration,
    timestamp: Duration,
    magnitudes: [Float]
  ) {
    precondition(timestamp >= .zero, "AudioVisualizationFrame.timestamp cannot be negative")
    precondition(
      magnitudes.allSatisfy(\.isFinite),
      "AudioVisualizationFrame.magnitudes must be finite"
    )
    self.generation = generation
    self.timestamp = timestamp
    self.magnitudes = magnitudes
  }
}

/// Optional visualization output. Implementations should use a bounded
/// newest-frame buffer (normally one frame), drop stale generations, and
/// release their continuation through `onTermination`.
public protocol AudioVisualizationProviding: Sendable {
  func makeFrameStream(for generation: PlaybackGeneration)
    -> AsyncStream<AudioVisualizationFrame>
}
