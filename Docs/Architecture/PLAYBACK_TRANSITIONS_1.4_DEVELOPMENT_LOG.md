# Playback transitions 1.4 development — B

2026-10-01. Session B, baseline `27bc43f`, shared checkout `feature/1.4.0_dev`. User authorized implementation; the older planning confirmation gate is superseded.

## Current implementation

- Independent fade-in/fade-out/crossfade preferences, each 0–3 s; new-install 80/120 ms, crossfade off. Missing legacy fade fields decode off; old >3 s crossfade clamps to 3 s.
- Optional transition ticket/commit port; queue/session/intent/revision guards. The next resource is ephemeral and history/Now Playing remain owned by Coordinator.
- Two bounded PCM rings inside each engine with a C11 atomic render envelope. Decode queues and control/polling never run on the render callback; user volume/mute remain on the master mixer.
- Unsegmented sources use actual decoded EOF with bounded lookahead, including local PCM and compressed sources; CUE retains its explicit range boundary. Local mono/stereo sources share a 48 kHz stereo bus, including different sample rates. Network, CUE overlap, incompatible channels and non-1 speed retain ordinary playback fallback. Source silence is preserved; no general encoder-padding removal is claimed.

## Early verification history

- Initial host build: blocked at A-owned evolving `OnlineSourceCoordinator.swift` / `CatalogBrowsingSource` (missing type during concurrent API migration). No unrelated repair performed. Log: `.noindex/logs/playback-transitions-build.log`.
- Simulator access requires escalation; sandbox `simctl` could not connect to CoreSimulator. Escalated inventory worked; no booted device initially.
- PCM numerical tests, lifecycle/settings tests, source graph build and Simulator output remain in progress. Physical listening and Archive have not been performed.

## DSP integration

The transition source bus feeds `timePitch -> equalizerUnit -> mainMixer`. A has connected a narrow post-EQ hook in `FFmpegPlaybackEngine`; B retains it. Neither transition graph nor the FFmpeg adapter depends on PluginRuntime.

B additionally exposes `FFmpegPCMProcessing` / `FFmpegPCMProcessorFactory` and `setPCMProcessorFactory(_:preservesTiming:)`. Each slot creates its own queue-confined processor, borrows its PCM buffer synchronously and resets on cancellation/rebuild. The legacy feeder uses the same hook. Install while the engine is stopped; processors with unverified delay/tail default to disabling gapless/crossfade. A can wrap `DSPProcessingChain` with this contract without changing B's ring/render code. Per-track plugin lifecycle wiring remains an explicit A handoff, not a claim of active production DSP.

## Actual output evidence

- 12 C render numerical cases passed with AddressSanitizer and UndefinedBehaviorSanitizer: 0/80/120/3000 ms in/out envelopes, irregular-block gapless/crossfade boundaries, cancellation/resume, and 10,001 correlated mix peak samples.
- Independent temporary `PlaybackTransitionsValidation` scheme bypassed A's in-flight UI/source tests. Two Swift Testing functions / three cases passed on MusicFree Regression iOS 26.5 Simulator: actual offline AVAudioEngine output for gapless and 100 ms crossfade, plus soft/hard lifecycle races.
- The first real output run exposed an inherited MainActor assertion in AVAudioSourceNode's SDK callback; fixed with a nonisolated factory. The offline test also needed `audioEngine.stop()` before switching initialized engine rendering mode. These failures were reproduced and corrected, not treated as environmental success.
- Further changes added synchronous MainActor handoff flushing before control invalidation, retirement at outgoing end-frame, actual rendered-duration history and a per-slot PCM hook. Their later completed regression is recorded below.

## Final implementation and current evidence

- Independent 0–3 s fade-in/fade-out/crossfade, separate gapless toggle, legacy fade-off migration and new-install 80/120 ms defaults are implemented. Settings sliders retain their drag locally and save on release, avoiding mid-gesture form disablement. Single-track fades apply to start/resume and soft pause/stop; manual replacement waits for the bounded outgoing stop before rebuilding. Interruptions, unavailable routes, session disposal and audition takeover bypass soft fading.
- Next preparation proceeds independently of history/queue persistence. A/B overlap retains at most two slots and two decoders: C waits for A retirement and queue-confined processor reset/release before opening. Continuous four-track gapless/crossfade tests verify creation/reset counts and at most two live processors.
- Handoff flushes synchronously before control invalidation; seek and route recovery capture the incoming decoder after flushing, so already-rendered B cannot become outgoing A again. Queue edits and library deletion suspend preparation across actor waits; deletion prunes the authoritative live queue when a handoff disk save is still pending. Position persistence cannot restore A after B commits. repeat-one/repeat-all/shuffle select the queue-authorized successor.
- Start/retirement history writes are serialized with bounded retries. Retirement records rendered duration; cancellation within overlap records `.interrupted`, while a complete outgoing boundary records `.ended`. Current/Now Playing and history commit once, despite duplicate or stale A callbacks.
- C envelope and mix clock are render-owned. Crossfade uses cosine/sine weights normalized by `max(1, cos + sin)` for correlated peak headroom; this intentionally attenuates the midpoint compared with a pure unnormalized equal-power mix. Master volume/mute remain separate. Starvation freezes source/envelope progress and cannot commit B before its first positive incoming envelope sample. A wall-clock soft-stop deadline only terminates stalled output; it does not drive gain.
- Actual AVAudioEngine source rendering may lead device/manual output due to prerender. The commit/retirement frame refers to the source render timeline; this is not a claim that physical speaker timing has been measured.

Executed on the current shared checkout, using `.noindex/DerivedData` and B's stable `.noindex/PlaybackTransitions/Core` scratch directory:

| Check | Actual result | Evidence |
| --- | --- | --- |
| Native C, AddressSanitizer + UndefinedBehaviorSanitizer | 14 numerical cases passed, including 0/80/120/3000 ms envelopes, irregular-block boundaries, starvation, positive handoff, repeated slot reuse and 10,001 correlated peak samples | `.noindex/logs/playback-transitions-numerical.log` |
| Core SwiftPM, `--no-parallel` | 286 test functions / 301 executed cases passed; includes 19 new transition cases | `.noindex/logs/playback-transitions-core-regression.log` |
| Final iOS 26.5 Simulator controls | 30 test functions / 53 executed cases passed, zero failed/skipped: 19 Coordinator/preferences, 16 transition graph/DSP/fallback/control, 18 existing remote/output lifecycle | `.noindex/logs/playback-transitions-final-controls.log`; `.noindex/artifacts/playback-transitions-final-controls-summary.json`; `Test-PlaybackTransitions-2026.10.01_09-22-57--0400.xcresult` under DerivedData |
| Final Coordinator repeat after deletion guard | 7 test functions / 19 executed cases passed on Simulator; complete Core 286/301 also passed after this guard | `.noindex/logs/playback-transitions-final-coordinator.log`; `Test-PlaybackTransitions-2026.10.01_09-32-37--0400.xcresult` under DerivedData |
| Final production host Debug, generic iOS Simulator | BUILD SUCCEEDED after the final graph and settings slider changes | `.noindex/logs/playback-transitions-host-debug-build.log` |
| Existing format/CUE/EQ/rate/volume regression | Final 22 test functions / 108 executed cases passed, zero failed/skipped | `.noindex/logs/playback-transitions-final-formats.log`; `.noindex/artifacts/playback-transitions-final-formats-summary.json` |
| Architecture / whitespace | `git diff --check` passed. Architecture script still fails only at HEAD-existing `App/RootViewController.swift:13/1728` SwiftUI embedding; confirmed with `git show HEAD` | `.noindex/logs/playback-transitions-architecture.log` |

The initial fully concurrent Core run exposed the obsolete new-default expectation for legacy settings and premature asynchronous assertions. The migration expectation now uses `.legacyDefaults`; the position/Now Playing test waits for the public publication result. Sequential complete regression passed. The first expanded Simulator run's only failure was an interruption test assuming no AVAudioEngine prerender; the corrected assertion checks actual source-frame duration and passed for pause/seek/route.

## Delivery limits and A handoff

- Gapless/crossfade supports local files at rate 1 with compatible channels and verified DSP timing. Mono/stereo sources convert to a common 48 kHz stereo bus; multichannel sources preserve their native layout and require compatible conversion. Compressed boundaries come from decoded EOF, not estimated duration. Remote, CUE overlap, incompatible channels, non-1 speed and unverified DSP latency/tail use ordinary playback fallback. Unsupported, empty or failed next preparation leaves the current resource playable. Source silence and decoder-delivered padding are not automatically trimmed.
- The FFmpeg adapter owns `FFmpegPCMProcessing` / factory, queue lifecycle, graph clocks and bounded rings; it has no PluginRuntime dependency. A owns `App/PluginFFmpegPCMAdapter.swift` and production plugin policy/chain installation. B preserves A's post-EQ graph hook. Zero-delay/tail per-track processors can opt into timing preservation; graph analysis and plugin reference features remain A's responsibility.
- Physical-device listening, Control Center/lock-screen timing, Bluetooth/AirPlay route acceptance, sustained device CPU/memory and Archive are unverified. Playback settings dragging was source/build validated; no B-specific UI interaction test was executed.
- No branch/worktree, staging, commit, push, reset or unrelated cleanup. Known B-created system-temp error result bundles were removed; stable evidence and shared DerivedData were retained.


## 2026-10-02: phone smooth-playback investigation

Confirmed source eligibility remains local WAV/AIFF/AIF/CAF, common format and 1x
for gapless/crossfade. Existing settings without fade fields retain zero fades;
new defaults are 80/120 ms. These constraints can explain subtle or absent
transitions, but the phone's media/settings/operation have not been observed.

Fixed the demonstrated seek regression: after a successful current-intent seek
and normalized snapshot update, `PlaybackCoordinator` schedules next preparation
again. A paused seek defers preparation until resume. Added two cases that verify
fresh successor tickets, stale commit rejection and Now Playing handoff. Before
fixing, playing seek failed to prepare a new successor. After fixing, all 5
Coordinator functions / 12 cases passed via macOS SwiftPM using the existing
`.noindex/PlaybackTransitions/Core` cache. Evidence is in
`.noindex/logs/playback-smooth-seek-before.log` and
`.noindex/logs/playback-smooth-seek-after.log`. Physical listening and this turn's
seek-only Simulator/Archive validation were not performed.

The subsequent phone crash log exposed a separate legacy-graph teardown defect.
It was reproduced on MusicFree Regression (iPhone 17 Pro, iOS 26.5 Simulator):
an 8 kHz mono file reached natural EOF, a second 8 kHz file remained valid, and
preparing 16 kHz then raised uncaught AVFAudio `-10868` while connecting
`timePitch -> equalizerUnit`. Natural EOF had paused the engine, making
`audioEngine.isRunning == false`; the conditional teardown therefore skipped
`stop()` and retained prepared resources for the old format. `teardown()` now
always calls `audioEngine.stop()` after `playerNode.stop()`, matching the API's
resource-release contract before the next decoder format is connected.

The new real-output regression runs six formats (8 kHz mono twice, 16 kHz mono,
44.1 kHz stereo, 96 kHz stereo and 48 kHz mono) forward and reversed, with and
without the post-EQ node. Before the fix, the first case reproduced `-10868` at
the 8-to-16 kHz change. After the fix, all 4 cases / 24 track plays passed. A
broader Simulator run then passed 25 test definitions / 43 executed cases, zero
failed/skipped: the full transition suite, remote engine lifecycle, packaged
format reuse and audio configuration-change recovery. Evidence:
`.noindex/logs/phone-audio-format-live-repro.log`,
`.noindex/logs/phone-audio-format-live-after-stop.log`,
`.noindex/logs/phone-audio-format-regression.log` and
`.noindex/artifacts/phone-audio-format-regression.xcresult`.

The supplied MP3 probe/duration warnings and SessionCore main-thread warning are
not the reproduced fatal path. Physical-device installation progressed after
the low-sample-rate fix below; listening, Control Center/route behavior and
Archive remain open.

The attached 7.11-second physical-phone recording then confirmed that smooth
transition itself was still absent for the app's BVT fixtures. Video frames show
`BVT Extremely Long Track...` reaching its end before `BVT Tone` starts, and
audio analysis finds complete silence from 4.094717 s to 4.483560 s: a
388.844 ms gap. Both fixtures are generated as local 8 kHz mono WAV files.
`startFeeder` required at least 32768 Hz before constructing the transition
graph, so these otherwise eligible files always used the legacy feeder; the
Coordinator's next preparation could not arm gapless/crossfade because no graph
existed.

Removed that artificial sample-rate floor while retaining rate-1, channel-count,
format and reliable-frame guards. Added a real Simulator main-mixer test matching
the recording: two 8 kHz WAV tracks with a 100 ms crossfade, requiring one
logical handoff and less than 10 ms of internal output silence. The focused
real-time test passed. The expanded Simulator regression passed 26 test
definitions / 44 executed cases, zero failed/skipped, and the production
composition capability test passed separately. Evidence:
`.noindex/artifacts/phone-smooth-recording/contact-sheet.png`,
`.noindex/artifacts/phone-smooth-recording/waveform.png`,
`.noindex/logs/phone-smooth-low-rate-realtime.log`,
`.noindex/logs/phone-smooth-low-rate-regression.log`,
`.noindex/artifacts/phone-smooth-low-rate-regression.xcresult` and
`.noindex/logs/phone-smooth-production-capabilities.log`. A signed Debug build
succeeded, was installed over `win.tools4me.music.debug` on the connected IPM16,
and launched with `--bvt-seed-audio`; log:
`.noindex/logs/phone-smooth-device-build.log`. Physical speaker listening at the
handoff still requires user confirmation.

## Latest phone recording: mixed compressed formats before the fix

Reviewed `ScreenRecording_10-03-2026 00-09-29_1.MP4` (44.79 s). This recording
contains WMA Pro → Musepack and BVT Tone → WMA Pro, not the previous pair of
8 kHz BVT WAV tracks. The original files were read from the connected debug
app's `Documents/ExternalFixtures`, without modifying the device:

- `wmapro.wma`: WMA Pro, 16 kHz mono, 189.705 s container duration.
- `mpc7.mpc`: Musepack 7, 44.1 kHz stereo, title
  `Dick Dale & His Del-Tones / Misirlou`, 150.178 s.

The first handoff has a 3.564 s interval below −45 dB in the recording. The
original WMA tail already contains approximately 2.210 s below that threshold,
and the Musepack intro contains approximately 1.096 s. These source intervals
must not be reported as engine loading delay. Correlation with the original
Musepack intro places its source start at recording time 2.966 s (r = 0.9987).
Gapless playback alone does not remove silence contained in the source.

At BVT Tone → WMA Pro, the recording shows the single-track fade envelope, but
no overlapping handoff. Recording time 39.157–39.814 s is below −45 dB (657 ms);
within it, 39.240–39.450 s is all-zero PCM after decoding the recording (210 ms).
Neither measurement alone is a pure engine-delay measurement: fades and source
silence also contribute. The original WMA intro matches the recording at
source-zero time 39.439 s (r = 0.9991). The intermediate seek, pause, replay and
end-of-queue intervals were excluded from handoff assessment.

At this investigation stage, source confirmed both compressed formats were rejected by `reliableFrames`
and next preparation still requires identical decoder formats. Therefore the
low-sample-rate fix did not deliver smooth switching for these mixed-format
examples. Single-track fade evidence is not crossfade acceptance. The earlier
0.0417 ms Simulator result used synthetic WAV tones and is not a before/after
measurement of this phone recording. General compressed/mixed-format transitions
remain unresolved; this review made no playback source change or new device
installation.

Reproducible recording analysis, original fixture copies and frame sheets are
under `.noindex/artifacts/phone-smooth-recording-latest/`.

## Simulator acceptance of the phone-recording pairs before the fix

At the user's request, ran the original WMA Pro and Musepack files plus an
equivalent BVT tone in the MusicFree App test host on iPhone 17 Pro / iOS 26.5.
Both recorded pairs failed in gapless, 1 s crossfade and 3 s crossfade modes:
six actual failures, each with `unsupported_capability` from next preparation
and zero handoff commits. Current playback reached EOF and subsequent ordinary
playback produced mixer audio in all six cases. The failure assertions remain
in `FFmpegDevicePlaybackTests.phoneRecordingSmoothHandoff` as opt-in acceptance
tests; production playback code was not changed.

The low-rate WAV real-output control passed, as did all four format-rebuild
cases (24 track plays), with no recurrence of the `-10868` crash. The xcresult
confirms 11 executed cases: 5 passed, 6 failed, zero skipped/expected failures.
Overall `TEST FAILED` is the correct outcome. Evidence and reproduction commands:
[Simulator report](../Testing/1.4_PLAYBACK_TRANSITIONS_SIMULATOR_2026-10-02.md).

## 2026-10-02: mixed compressed formats fixed and verified on Simulator

The original six phone-sample failures now pass: BVT WAV → WMA Pro and WMA Pro →
Musepack, each with gapless, 1 s and 3 s settings. Each produces one matching
handoff ticket, incoming mixer audio and no ordinary fallback. Each also passes
incoming 1.5x → seek and 1x → seek controls. Output graph reconfiguration stops
the engine and reconnects the complete chain so native-format legacy playback
after a converted transition does not retain prepared formats.

`TransitionPCMReader` keeps each decoder and per-track DSP on its serial queue,
then converts mono/stereo PCM to planar 48 kHz stereo. Both slots have bounded
3-second lookahead plus two blocks (about 2.45 MiB for the two stereo PCM rings,
excluding decoders/converters). Unknown compressed lengths are decoded through
EOF; C receives the actual published output-frame count and applies short-track
overlap bounds even if EOF arrives after arming. Empty next sources fail instead
of leaving preparation waiting indefinitely. Multichannel layouts are retained.

The original phone tests seek to the final 4 seconds, so the existing half-slot
duration cap reduces a requested 3 seconds to about 2 seconds. A separate 7-second
ALAC test confirms the full 144000-frame / 3-second overlap at 48 kHz with length
learned from EOF. Mixed-rate/channel four-track tests verify continuous output,
slot retirement and at most two live processors. No source-silence trimming was
introduced; the original WMA tail and Musepack intro silence remain in the audio.

Final `MusicFree` Debug run on MusicFree Regression / iPhone 17 Pro / iOS 26.5:

| Scope | Test functions / executed cases | Result |
| --- | --- | --- |
| Original phone-sample App host acceptance | 1 / 6 | Passed |
| Complete FFmpeg adapter suite, including format/CUE/remote/output and transitions | 72 / 190 | Passed |
| Coordinator and transition preferences | 8 / 21 | Passed |
| Total | 81 / 217 | Zero failures, skips or expected failures |
| C numerical ASan + UBSan | 19 cases | Passed, including 3 late-EOF cases and 10001 correlated peak samples |

Evidence: `.noindex/logs/phone-smooth-mixed-format-final.log`,
`.noindex/artifacts/phone-smooth-mixed-format-final.xcresult`, exported summary
and case tree under `.noindex/artifacts/phone-smooth-mixed-format-fix/`, and
`.noindex/logs/phone-smooth-mixed-format-numerical.log`. `git diff --check` passed.
The report above retains the original six failures and explains intermediate
test-fixture failures. Final acceptance uses real AVAudioEngine output in the
App host, with Coordinator tested separately; library-UI end-to-end playback,
new physical-device installation/listening, routes and Archive were not performed
in this fix turn.

## 2026-10-03: full playback-path review

The user's selected scope covers the complete smooth-playback path, settings,
and DSP integration. Fixed serial decoder ownership after handoff/rate/seek,
restoration of the transition bus and preferences at 1×, unnecessary successor
invalidation, route-rebuild notifications, boundary seek identity, render-claim
cancellation, output-start error propagation, soft-fade scheduling allowance,
and retirement/history accounting. The combined App-host regression also
verified the parallel review's post-EQ tap-before-detach fix and deferred DSP
revocation during playback.

Final iOS 26.5 Simulator results: 378 functions / 520 executed cases for playback,
Core and App-host integration; 196 / 219 for settings/UI feature models. All
**574 functions / 739 cases passed**, with zero failures or skips. The original
six WMA/Musepack phone-sample scenarios each committed once with positive incoming
output and no ordinary fallback. The C suite passed 21 numerical cases under
ASan/UBSan and ThreadSanitizer, including 5,000 cancellation interleavings.

The architecture script still reports the HEAD-existing RootViewController
SwiftUI boundary and the independent plugin HostBridge test import allowlist;
these are not playback regression failures. Physical listening/routes, UI
interaction and Archive remain separate acceptance work. Full findings, exact
evidence and shared-source attribution:
[Full review](PLAYBACK_TRANSITIONS_1.4_FULL_REVIEW_2026-10-03.md).
