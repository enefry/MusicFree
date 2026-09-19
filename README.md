# MusicFree

MusicFree is the project and bundle name for the iPhone/iPad local player shown
to users as `MyMusic`. It targets iOS/iPadOS 26+ and uses four local Swift
Packages so the domain/API layer, Apple infrastructure, the VLCKit 4.0 alpha
adapter, and SwiftUI features remain independently testable.

The current release remains local-first. Files/Finder import, library browsing,
playlists, lyrics, metadata editing, background audio, Now Playing, queue
recovery, sleep timers and runtime EQ are implemented in the app. Optional
metadata/lyrics Providers are wired behind consent; the Metadata Server is
disabled in the current build configuration. Ampache, Subsonic, cloud sync,
podcasts, radio, CarPlay and Siri remain outside the implementation scope.

Current playback settings expose variable rate, sleep timers and a secondary
equalizer page. The equalizer uses VLCKit's runtime bands and native presets,
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
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project MusicFree.xcodeproj -scheme MusicFreeInfrastructureTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project MusicFree.xcodeproj -scheme MusicFree \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project MusicFree.xcodeproj -scheme MusicFree \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Use a real available UDID in place of `<SIMULATOR_UDID>`. Device-name-only
destinations can resolve to an unavailable “latest” runtime. Do not run the
independent `xcodebuild` test commands in parallel because they share package
and Simulator services.

`MusicFreeVLCKitAdapter` links the exact VLCKit release recorded in
`Packages/MusicFreeVLCKitAdapter/Package.resolved`; Simulator tests cover adapter
contracts, while physical-device playback and format validation remain
separate release gates.

The current checkout status and release gates are summarized in
[`Docs/PROJECT_STATUS.md`](Docs/PROJECT_STATUS.md). The module interface baseline is defined in
[`Docs/Architecture/MODULE_INTERFACES.md`](Docs/Architecture/MODULE_INTERFACES.md),
and the documentation index is in [`Docs/README.md`](Docs/README.md). Manual
acceptance is defined in
[`Docs/Testing/MANUAL_TEST_CASES.md`](Docs/Testing/MANUAL_TEST_CASES.md).
