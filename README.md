# MusicFree

MusicFree is the project and bundle name for the iPhone/iPad local player shown
to users as `MyMusic`. It targets iOS/iPadOS 26+ and uses four local Swift
Packages so the domain/API layer, Apple infrastructure, the FFmpeg audio
adapter, and SwiftUI features remain independently testable.

The current release remains local-first. Files/Finder import, library browsing,
playlists, lyrics, metadata editing, background audio, Now Playing, queue
recovery, sleep timers and runtime EQ are implemented in the app. Optional
metadata/lyrics Providers are wired behind consent; the Metadata Server is
disabled in the current build configuration. Ampache, Subsonic, cloud sync,
podcasts, radio, CarPlay and Siri remain outside the implementation scope.

Current playback settings expose variable rate, sleep timers and a secondary
equalizer page. The equalizer uses a ten-band AVAudioUnitEQ and four presets,
while ReplayGain, gapless playback and crossfade remain hidden. Contract and
UI automation are separate from physical-device listening, route, format and
release validation.

## Generate the project

```sh
xcodegen generate --spec project.yml
xcodegen generate --spec project.debug.yml
```

## Validate the project

```sh
Scripts/check_architecture.sh
xcodebuild -list -project MusicFree.xcodeproj
xcodebuild -project MusicFree.xcodeproj -scheme MusicFreeCoreTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath "$PWD/.noindex/DerivedData" CODE_SIGNING_ALLOWED=NO test
xcodebuild -project MusicFree.xcodeproj -scheme MusicFreeInfrastructureTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath "$PWD/.noindex/DerivedData" CODE_SIGNING_ALLOWED=NO test
xcodebuild -project MusicFree.xcodeproj -scheme MusicFree \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.noindex/DerivedData" CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project MusicFree.xcodeproj -scheme MusicFree \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath "$PWD/.noindex/DerivedData" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Use a real available UDID in place of `<SIMULATOR_UDID>`. Device-name-only
destinations can resolve to an unavailable “latest” runtime. Do not run the
independent `xcodebuild` test commands in parallel because they share package
and Simulator services.

`MusicFreeFFmpegAdapter` depends on the repository-local
`Packages/FFmpegAudioKit`; that package pins the `0.0.4` FFmpeg binary release.
It handles local playback, media probe, metadata, and HTTP(S)
online audition. See its [README](Packages/MusicFreeFFmpegAdapter/README.md) for
the audio-stream TODO in the adapter README and remaining device, DS Audio, and format acceptance gates.

The current checkout status and release gates are summarized in
[`Docs/PROJECT_STATUS.md`](Docs/PROJECT_STATUS.md). The module interface baseline is defined in
[`Docs/Architecture/MODULE_INTERFACES.md`](Docs/Architecture/MODULE_INTERFACES.md),
and the documentation index is in [`Docs/README.md`](Docs/README.md). Manual
acceptance is defined in
[`Docs/Testing/MANUAL_TEST_CASES.md`](Docs/Testing/MANUAL_TEST_CASES.md).
