# VLCKit capability matrix

Last reviewed: 2026-08-11 (runtime EQ code alignment; physical-device rows remain unverified)

This matrix records what the current source and test evidence justify for the
fixed `VLCKit-SPM` release `4.0.0-alpha.20260805.1123` (revision
`818aca0e9cd605c69a3a5670c2ae662b1ca0783e`, checksum
`a8bd5703c324ed8e7c39241c6d091c56e99f13cf585b42fbeb0d4c6523f9386f`).

Status meanings:

- **implemented, runtime unverified**: the adapter and app wiring exist, but
  this review has no physical-device playback observation.
- **contract verified**: deterministic adapter/core tests passed, without
  proving hardware or long-running media behavior.
- **off**: deliberately absent from `PlaybackCapabilities` and hidden from UI.
- **future**: an API boundary exists but no first-release implementation is
  exposed.

Validation environment for this review: Xcode iOS Simulator 26.5 and the
generic iOS device compile path. A simulator result is not a real-device
playback result.

Latest EQ-related contract evidence is covered by the Core, VLCKit and UI test
targets. Generated result bundles are intentionally not tracked.

| Capability | Current app policy | Evidence | Status |
| --- | --- | --- | --- |
| Prepare/play/pause/stop | Adapter is constructed in `AppContainer` | `VLCPlaybackEngine` source and package compile; no physical-device session | implemented, runtime unverified |
| State/time/error event mapping | Always available to the adapter | `MusicFreeVLCKitAdapterTests` state, terminal and error mapping tests | contract verified |
| Generation and item isolation | Always enforced | `VLCKitPlaybackAdapterInitialTests.generationFiltering` | contract verified |
| Seek | Enabled in `AppContainer` policy | Policy resolver tests and app capability assertion; no hardware seek session | implemented, runtime unverified |
| Variable rate | Enabled in `AppContainer` policy | Policy resolver tests and app capability assertion; no hardware rate session | implemented, runtime unverified |
| Volume and mute | Adapter API available | Source-level bounds and mapping; no route/device observation | implemented, runtime unverified |
| Media probe and audio-track validation | Used by local import/source | `VLCMediaProbe` implementation; no checked-in real media fixture in this review | implemented, runtime unverified |
| Metadata and embedded artwork | Used by local import/source | `VLCMetadataReader` implementation; no physical-device fixture run | implemented, runtime unverified |
| Runtime EQ | Enabled in `AppContainer` policy | Runtime `VLCAudioEqualizer` descriptor and native presets, band/preamp mapping, clear-on-disable, Core/UI/VLCKit/App tests; no physical-device listening session | implemented, runtime unverified |
| ReplayGain | Not enabled | `VLCPlaybackEngine.apply` rejects it | off |
| Gapless | Not enabled | `VLCPlaybackEngine.apply` rejects it | off |
| Crossfade | Not enabled | `VLCPlaybackEngine.apply` rejects it | off |
| Visualization | No provider is exposed | No public VLC analysis-frame evidence | off |
| Queue, shuffle, repeat and recovery | Owned by `AppServices`, not VLC | Core/Fake coordinator tests; no physical playback progression | implemented in orchestration, runtime unverified |
| Audio session and Now Playing | Apple adapter is wired | Infrastructure contract tests and app capability snapshot | implemented, runtime unverified |
| Remote commands and route/interruption events | Apple adapter is wired | Infrastructure mapping/lifecycle tests | implemented, runtime unverified |
| Background and lock-screen playback | Declared/configured, not advertised as proven | Info.plist and adapter code only | runtime unverified |
| Remote HTTP media source | Protocol-neutral resource and safe header mapping only | `VLCMediaFactory` header rejection/redaction tests; no production remote source | future |
| Ampache/Subsonic | Intentionally absent | First-release scope excludes service integrations | out of scope |

The UI must continue to derive advanced controls from this matrix. No row marked
off or runtime unverified may be presented as physically verified. ReplayGain,
gapless, crossfade and visualization remain hidden until VLCKit support is
implemented and validated. Runtime EQ is exposed as implemented but still needs
a physical-device listening session.
