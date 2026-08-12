# MusicFree

MusicFree is an original iPhone/iPad local music player for iOS/iPadOS 26+. It
uses four local Swift Packages so the domain/API layer, Apple infrastructure,
the VLCKit 4.0 alpha adapter, and SwiftUI features remain independently
testable.

The first release is local-only. Ampache, Subsonic, Apple Music, cloud sync,
podcasts, radio, CarPlay and Siri are deliberately outside the implementation
scope; the source protocols keep only protocol-neutral extension points.

Current playback settings expose variable rate and a secondary equalizer page.
The equalizer uses VLCKit's runtime bands and native presets, while ReplayGain,
gapless playback and crossfade remain hidden. Simulator contracts are green;
physical-device listening and route validation remain release gates.

## Generate the project

```sh
xcodegen generate --spec project.yml
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

`MusicFreeVLCKit` is linked to the exact VLCKit 4.0 alpha recorded in
`Packages/MusicFreeVLCKit/Package.resolved`; Simulator tests cover adapter
contracts, while physical-device playback and format validation remain
separate release gates.

The module interface baseline is defined in
[`Docs/Architecture/MODULE_INTERFACES.md`](Docs/Architecture/MODULE_INTERFACES.md),
and manual acceptance is defined in
[`Docs/MANUAL_TEST_CASES.md`](Docs/MANUAL_TEST_CASES.md).
