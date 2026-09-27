# MusicFreeFFmpegAdapter

The `FFmpegPlaybackAdapter` product implements the MusicFree playback, local media
probe, and metadata ports using the independent `FFmpegAudioKit` dependency.
Playback decodes PCM with FFmpeg and sends it through `AVAudioEngine`.

Playback supports local files and HTTP(S) audio, logical CUE ranges, seek on
seekable inputs, rate, volume, mute, and a ten-band `AVAudioUnitEQ`. A CUE
selection's `startAt`, seek, progress, duration, and natural end use the logical
range timeline. The selected PCM is cut at the range boundary before it reaches
the output node. Remote servers without Range support do not offer seek, so a
CUE range that begins after zero cannot play on such a stream.

## Outstanding

- **TODO(audio-stream):** There is currently no user entry point for selecting
  an audio track. `PlaybackSelection.audioStream` is not forwarded to
  `FFmpegAudioDecoder`; its C layer uses `av_find_best_stream`, so a multi-track
  file plays the default track. Before adding a selector, account for the
  persisted `vlc-media-id:N` versus `ffmpeg-stream:N` identifier change.
- App-host automation has played the packaged format samples on a physical
  device, and live DS Audio audition and seek have passed on a simulator.
  Audible headphone output, physical route changes, interruptions, background
  playback, and the remaining advertised formats still need acceptance checks
  before declaring behavioral replacement complete.
