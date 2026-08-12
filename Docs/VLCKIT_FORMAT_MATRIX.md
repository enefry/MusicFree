# VLCKit format matrix

Last reviewed: 2026-08-10 (code alignment; no physical-device fixture run)

The app deliberately does not maintain a filename-extension allowlist. The
fixed VLC binary parses the resource, and `VLCMediaProbe` accepts it only when
the parsed media contains a decodable audio track. The table below is therefore
a validation backlog, not a promise that every VLC desktop module is present in
the iOS binary.

Validation environment for this review: Xcode iOS Simulator 26.3.1 and generic
iOS device compilation. No physical-device format run or two-hour playback run
is included here.

| Format / family | Probe/import code path | Device result | Release decision |
| --- | --- | --- | --- |
| MP3 | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| AAC / HE-AAC | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| ALAC | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| FLAC | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| Opus | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| Vorbis | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| WAV / PCM | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| AIFF | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| APE | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| WavPack | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| Musepack | Uses VLC parser and audio-track validation | Not tested with a real fixture | Keep unclaimed |
| Audio track in a compound container | `hasVideoTrack` is reported while audio tracks are selected | Not tested with a real fixture | Keep unclaimed |
| Corrupt or unsupported input | Probe maps parser/read failures to stable errors | Error mapping is contract-tested only | Keep unclaimed |

For each future matrix run, record the exact tag/revision/checksum, device model,
iOS build, fixture checksum, import result, probe result, first-play result,
seek/rate behavior, interruption behavior and teardown result. A failed or
unstable row must remain out of `PlaybackCapabilities` and the visible UI.
