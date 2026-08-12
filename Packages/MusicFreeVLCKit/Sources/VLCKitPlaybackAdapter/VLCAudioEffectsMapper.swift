import Foundation
import PlaybackAPI

#if canImport(VLCKit)
import VLCKit
#endif

internal enum VLCAudioEffectsMapper {
  static let minimumGainDecibels: Float = -20
  static let maximumGainDecibels: Float = 20

  static func descriptor(frequencies: [Float]) -> EqualizerDescriptor? {
    let validFrequencies = frequencies.filter { $0.isFinite && $0 > 0 }
    guard !validFrequencies.isEmpty,
          Set(validFrequencies).count == validFrequencies.count
    else {
      return nil
    }
    return EqualizerDescriptor(
      bands: validFrequencies.map {
        EqualizerBandDescriptor(
          centerFrequencyHz: Double($0),
          minimumGainDecibels: minimumGainDecibels,
          maximumGainDecibels: maximumGainDecibels
        )
      },
      minimumPreampDecibels: minimumGainDecibels,
      maximumPreampDecibels: maximumGainDecibels
    )
  }

#if canImport(VLCKit)
  static func descriptor(from equalizer: VLCAudioEqualizer) -> EqualizerDescriptor? {
    guard let layout = descriptor(frequencies: equalizer.bands.map(\.frequency)) else {
      return nil
    }
    let presets: [EqualizerPresetDescriptor] = VLCAudioEqualizer.presets.compactMap {
      preset -> EqualizerPresetDescriptor? in
      let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }

      let presetEqualizer = VLCAudioEqualizer(preset: preset)
      let configuration = EqualizerConfiguration(
        preampDecibels: presetEqualizer.preAmplification,
        bandGains: presetEqualizer.bands.map {
          EqualizerBandGain(
            centerFrequencyHz: Double($0.frequency),
            gainDecibels: $0.amplification
          )
        }
      )
      guard (try? configuration.validated(against: layout)) != nil else {
        return nil
      }
      return EqualizerPresetDescriptor(
        id: UInt32(preset.index),
        name: name,
        configuration: configuration
      )
    }
    return EqualizerDescriptor(
      bands: layout.bands,
      minimumPreampDecibels: layout.minimumPreampDecibels,
      maximumPreampDecibels: layout.maximumPreampDecibels,
      presets: presets
    )
  }

  static func apply(
    _ configuration: EqualizerConfiguration,
    to equalizer: VLCAudioEqualizer,
    descriptor: EqualizerDescriptor
  ) throws {
    let validated = try configuration.validated(against: descriptor)
    equalizer.preAmplification = validated.preampDecibels
    for (gain, band) in zip(validated.bandGains, equalizer.bands) {
      band.amplification = gain.gainDecibels
    }
  }
#endif
}
