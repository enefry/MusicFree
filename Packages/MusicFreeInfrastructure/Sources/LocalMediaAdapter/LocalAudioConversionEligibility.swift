import MediaSourceAPI

enum LocalAudioConversionEligibility {
  static func isSupported(
    _ track: ProbedAudioTrack,
    target: AudioConversionTarget
  ) -> Bool {
    guard track.isLossless,
          let channels = track.channelCount, (1...2).contains(channels),
          let sampleRate = track.sampleRate, sampleRate.isFinite, sampleRate > 0,
          track.codec?.lowercased().hasPrefix("dsd") != true
    else { return false }

    if case .alac = target {
      return track.bitDepth == 16 || track.bitDepth == 24
    }
    return true
  }

  static func isAlreadyTarget(
    _ track: ProbedAudioTrack,
    target: AudioConversionTarget
  ) -> Bool {
    guard case .alac = target else { return false }
    return track.codec?.caseInsensitiveCompare("alac") == .orderedSame
  }
}
