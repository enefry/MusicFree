import Foundation

/// One persisted gain value matched to a runtime EQ band frequency.
public struct EqualizerBandGain: Codable, Equatable, Hashable, Sendable {
  public let centerFrequencyHz: Double
  public let gainDecibels: Float

  public init(centerFrequencyHz: Double, gainDecibels: Float) {
    precondition(
      centerFrequencyHz.isFinite && centerFrequencyHz > 0,
      "EqualizerBandGain.centerFrequencyHz must be positive"
    )
    precondition(
      gainDecibels.isFinite,
      "EqualizerBandGain.gainDecibels must be finite"
    )
    self.centerFrequencyHz = centerFrequencyHz
    self.gainDecibels = gainDecibels
  }
}

/// User EQ intent. The runtime descriptor remains authoritative for supported
/// bands and gain limits.
public struct EqualizerConfiguration: Codable, Equatable, Hashable, Sendable {
  public let preampDecibels: Float
  public let bandGains: [EqualizerBandGain]

  public init(
    preampDecibels: Float = 0,
    bandGains: [EqualizerBandGain] = []
  ) {
    precondition(preampDecibels.isFinite, "EqualizerConfiguration.preamp must be finite")
    self.preampDecibels = preampDecibels
    self.bandGains = bandGains
  }

  /// Validates user intent against the active runtime EQ descriptor.
  public func validated(against descriptor: EqualizerDescriptor) throws -> Self {
    guard bandGains.count == descriptor.bands.count else {
      throw PlaybackError.invalidEffects
    }
    guard preampDecibels >= descriptor.minimumPreampDecibels,
      preampDecibels <= descriptor.maximumPreampDecibels
    else {
      throw PlaybackError.invalidEffects
    }

    for (gain, band) in zip(bandGains, descriptor.bands) {
      guard gain.centerFrequencyHz == band.centerFrequencyHz,
        gain.gainDecibels >= band.minimumGainDecibels,
        gain.gainDecibels <= band.maximumGainDecibels
      else {
        throw PlaybackError.invalidEffects
      }
    }
    return self
  }
}

/// Which ReplayGain metadata, if any, should affect playback.
public enum ReplayGainMode: String, Codable, CaseIterable, Hashable, Sendable {
  case disabled
  case track
  case album
}

public struct ReplayGainConfiguration: Codable, Equatable, Hashable, Sendable {
  public let mode: ReplayGainMode
  public let preampDecibels: Float
  public let preventClipping: Bool

  public init(
    mode: ReplayGainMode = .disabled,
    preampDecibels: Float = 0,
    preventClipping: Bool = true
  ) {
    precondition(preampDecibels.isFinite, "ReplayGainConfiguration.preamp must be finite")
    self.mode = mode
    self.preampDecibels = preampDecibels
    self.preventClipping = preventClipping
  }

  public static let disabled = Self()
}

public enum AudioTransitionMode: String, Codable, CaseIterable, Hashable, Sendable {
  case disabled
  case gapless
  case crossfade
}

/// Transition intent. A crossfade must carry a positive duration; the actual
/// capability is checked by the playback engine.
public struct AudioTransitionConfiguration: Codable, Equatable, Hashable, Sendable {
  public let mode: AudioTransitionMode
  public let crossfadeDuration: Duration?

  public init(
    mode: AudioTransitionMode = .disabled,
    crossfadeDuration: Duration? = nil
  ) {
    if mode == .crossfade {
      precondition(
        (crossfadeDuration ?? .zero) > .zero,
        "AudioTransitionConfiguration crossfade duration must be positive"
      )
    }
    self.mode = mode
    self.crossfadeDuration = mode == .crossfade ? crossfadeDuration : nil
  }

  public static let disabled = Self()
}

/// The complete user-selected effect intent applied to one engine session.
public struct AudioEffectConfiguration: Codable, Equatable, Hashable, Sendable {
  public let equalizer: EqualizerConfiguration?
  public let replayGain: ReplayGainConfiguration
  public let transition: AudioTransitionConfiguration
  public let rate: Float

  public init(
    equalizer: EqualizerConfiguration? = nil,
    replayGain: ReplayGainConfiguration = .disabled,
    transition: AudioTransitionConfiguration = .disabled,
    rate: Float = 1
  ) {
    precondition(rate.isFinite && rate > 0, "AudioEffectConfiguration.rate must be positive")
    self.equalizer = equalizer
    self.replayGain = replayGain
    self.transition = transition
    self.rate = rate
  }

  public static let neutral = Self()
}
