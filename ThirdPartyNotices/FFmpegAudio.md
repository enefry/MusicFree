# FFmpegAudioKit and FFmpeg audio notice

MusicFree links the dynamic `FFmpegAudio.framework`, built from FFmpeg `8.1.2`
with LGPL components. The C/Swift wrapper source and reproducible build script
are in `Packages/FFmpegAudioKit`. Default builds resolve the DSD-capable
`0.0.4` binary even when a locally built framework is present. Local binaries
require an explicit `FFMPEG_AUDIO_USE_LOCAL_BINARY=1` override. The published
binary's SwiftPM SHA-256 checksum is
`1c65e5ec6be5329fc632847f914e602aa33cc1fd53908f0a498150a26fb2c9f8`.

- FFmpeg source: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
- Wrapper source and reproducible build script: `Packages/FFmpegAudioKit` (in this repository)
- Published binary used by clean checkouts: https://github.com/enefry/FFmpegAudioKit/releases/tag/0.0.4
- Complete LGPL 2.1 text: [COPYING.LGPLv2.1](FFmpegAudio/COPYING.LGPLv2.1)

The App Store release still requires a separate distribution and relinking
review. `manifest.json` is the in-app license list.
