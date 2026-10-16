# Third-party notices

This directory contains the license texts shipped with MusicFree and the
`manifest.json` shown in Settings > About. The app currently links Kingfisher,
CocoaLumberjack, and the FFmpeg audio framework distributed by FFmpegAudioKit.
See [FFmpegAudio.md](FFmpegAudio.md) for the FFmpeg version, source, binary,
checksum, and complete LGPL license text.

The equalizer also includes numerical preset curve data from VideoLAN, adapted
to the current band's frequencies and gain limits. See `VLCEqualizerPresets.txt`
for attribution and license. This data does not add a VLCKit binary dependency.

The NetEase and QQ Music lyrics/metadata plugins adapt query protocols from
`jitwxs/163MusicLyrics`. See `163MusicLyrics-Apache-2.0.txt` for attribution and
the Apache-2.0 license text. These plugins do not include audio downloading.

An App Store release needs a separate distribution review, including LGPL
source and relinking obligations.
