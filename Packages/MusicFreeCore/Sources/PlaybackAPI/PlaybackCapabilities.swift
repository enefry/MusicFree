import Foundation

/// Capabilities explicitly verified by the active playback adapter.
public struct PlaybackCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let seeking = Self(rawValue: 1 << 0)
  public static let variableRate = Self(rawValue: 1 << 1)
  public static let equalizer = Self(rawValue: 1 << 2)
  public static let replayGain = Self(rawValue: 1 << 3)
  public static let gapless = Self(rawValue: 1 << 4)
  public static let crossfade = Self(rawValue: 1 << 5)
  public static let visualization = Self(rawValue: 1 << 6)

  public static let all: Self = [
    .seeking,
    .variableRate,
    .equalizer,
    .replayGain,
    .gapless,
    .crossfade,
    .visualization,
  ]

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(UInt64.self))
  }
}

/// A runtime EQ band. Adapters may expose any number of bands and do not have
/// to emulate a fixed ten-band layout.
public struct EqualizerBandDescriptor: Codable, Equatable, Hashable, Sendable {
  public let centerFrequencyHz: Double
  public let minimumGainDecibels: Float
  public let maximumGainDecibels: Float
  public let name: String?

  public init(
    centerFrequencyHz: Double,
    minimumGainDecibels: Float,
    maximumGainDecibels: Float,
    name: String? = nil
  ) {
    precondition(
      centerFrequencyHz.isFinite && centerFrequencyHz > 0,
      "EqualizerBandDescriptor.centerFrequencyHz must be positive"
    )
    precondition(
      minimumGainDecibels.isFinite && maximumGainDecibels.isFinite
        && minimumGainDecibels <= maximumGainDecibels,
      "EqualizerBandDescriptor gain range is invalid"
    )

    self.centerFrequencyHz = centerFrequencyHz
    self.minimumGainDecibels = minimumGainDecibels
    self.maximumGainDecibels = maximumGainDecibels
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

/// A runtime-provided EQ preset. Persist the concrete configuration rather
/// than this adapter-owned identifier so framework upgrades cannot invalidate
/// saved user intent.
public struct EqualizerPresetDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: UInt32
  public let name: String
  public let configuration: EqualizerConfiguration

  public init(
    id: UInt32,
    name: String,
    configuration: EqualizerConfiguration
  ) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(!normalizedName.isEmpty, "EqualizerPresetDescriptor.name must not be empty")
    self.id = id
    self.name = normalizedName
    self.configuration = configuration
  }
}

/// Runtime-provided EQ layout, gain bounds, and optional presets.
public struct EqualizerDescriptor: Codable, Equatable, Hashable, Sendable {
  public let bands: [EqualizerBandDescriptor]
  public let minimumPreampDecibels: Float
  public let maximumPreampDecibels: Float
  public let presets: [EqualizerPresetDescriptor]

  public init(
    bands: [EqualizerBandDescriptor],
    minimumPreampDecibels: Float = -12,
    maximumPreampDecibels: Float = 12,
    presets: [EqualizerPresetDescriptor] = []
  ) {
    precondition(
      minimumPreampDecibels.isFinite && maximumPreampDecibels.isFinite
        && minimumPreampDecibels <= maximumPreampDecibels,
      "EqualizerDescriptor preamp range is invalid"
    )
    let frequencies = bands.map(\.centerFrequencyHz)
    precondition(
      Set(frequencies).count == frequencies.count,
      "EqualizerDescriptor bands must have unique center frequencies"
    )
    precondition(
      Set(presets.map(\.id)).count == presets.count,
      "EqualizerDescriptor presets must have unique identifiers"
    )

    self.bands = bands
    self.minimumPreampDecibels = minimumPreampDecibels
    self.maximumPreampDecibels = maximumPreampDecibels
    self.presets = presets
  }

  public var bandCount: Int {
    bands.count
  }

  private enum CodingKeys: String, CodingKey {
    case bands
    case minimumPreampDecibels
    case maximumPreampDecibels
    case presets
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      bands: try container.decode([EqualizerBandDescriptor].self, forKey: .bands),
      minimumPreampDecibels: try container.decode(Float.self, forKey: .minimumPreampDecibels),
      maximumPreampDecibels: try container.decode(Float.self, forKey: .maximumPreampDecibels),
      presets: try container.decodeIfPresent(
        [EqualizerPresetDescriptor].self,
        forKey: .presets
      ) ?? []
    )
  }
}
