import MediaSourceAPI
import MusicDomain

enum ProbedAudioStreamSelector {
  static func preferred(in probe: MediaProbeResult) -> AudioStreamSelection? {
    let tracks = probe.decodableAudioTracks
    // A decoder's track order is not a default-track signal. Only persist a
    // selection when the probe explicitly reports the default; otherwise VLC
    // must retain its own container-level choice.
    guard tracks.count > 1, let selected = tracks.first(where: \.isDefault) else {
      return nil
    }
    let normalizedStableID = selected.stableID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stableID: AudioStreamID?
    if let normalizedStableID,
       !normalizedStableID.isEmpty,
       tracks.compactMap({ $0.stableID?.trimmingCharacters(in: .whitespacesAndNewlines) })
         .filter({ $0 == normalizedStableID }).count == 1
    {
      stableID = AudioStreamID(normalizedStableID)
    } else {
      stableID = nil
    }
    return AudioStreamSelection(
      streamID: stableID,
      fallbackSignature: AudioStreamSignature(
        language: selected.language,
        title: selected.title,
        codec: selected.codec,
        channelCount: selected.channelCount.flatMap { $0 > 0 ? $0 : nil },
        indexHint: selected.index >= 0 ? selected.index : nil
      )
    )
  }
}
