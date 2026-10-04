# Playback transitions 1.4: full-path review and repairs

2026-10-03, `feature/1.4.0_dev`, shared working checkout.

## Scope

The user selected the complete smooth-playback path: persisted settings and
effective configuration, Coordinator queue/session identity, engine lifecycle,
decoder ownership, conversion, the C render bus, history/Now Playing, and the
PCM/post-EQ DSP integration boundary. The independent plugin system is outside
this review. Existing unrelated changes remain in place; nothing was staged or
committed.

Another active review session edited the same checkout during this work. The
results below validate the combined source. The local before/after diff includes
those concurrent edits and must not be treated as exclusive authorship by this
session.

## Confirmed findings and fixes

| Priority | Trigger and prior behavior | Resulting behavior and evidence |
| --- | --- | --- |
| P1 | A hands off to B on the second decoder queue, then B changes rate and seeks. The legacy feeder returned to the first queue while B's previous processor could still be resetting. | The replacement feeder retains `currentDecodeQueue`. A regression blocks the old reset and proves no replacement processor is created until that serial owner releases it. |
| P1 | Preparing/seeking at a non-1 rate selected the legacy feeder. Restoring 1× left the engine unable to prepare a successor. | Restoring 1× rebuilds the transition bus at the current position for seekable, supported resources. The regression requires an actual incoming handoff. |
| P1 | Applying an effects configuration at 1.5× to restore 1× clipped transition preferences against the temporarily reduced runtime capabilities. Gapless and fades stayed disabled. | Transition configuration is clipped against configured engine support; the engine retains responsibility for current resource/rate fallback. A failing-before Coordinator regression now retains gapless and both fade durations and prepares the successor. |
| P1 | Redundant resume or unchanged effects/rate unnecessarily invalidated a prepared successor. Route rebuilding discarded a ticket without informing the Coordinator. | Redundant commands retain preparation. Explicit engine invalidation clears the matching ticket; output rebuilding retries preparation, speculative decode failure falls back at EOF, and obsolete invalidations are ignored. |
| P1 | A seek arrived after render had begun B but before MainActor published B. Capturing A before flushing the handoff discarded the seek. | The Coordinator flushes the handoff before capturing item/generation. The boundary regression seeks B and publishes B's requested position. |
| P1 | Cancellation could land between render claiming next and publishing the handoff. | The C claim remains distinguishable until publication. Cancellation quiesces rendering only for that in-flight claim, then delivers its commit before invalidating the ticket. Ordinary cancellation leaves the running envelope intact. The native suite exercises 5,000 concurrent cancellation interleavings. |
| P1 | Starting a rebuilt transition output failed, but the failure was ignored and control could publish playing. | Output start failures publish a playback error; play/seek/rate restoration propagate failure instead of overwriting it as playing. This path was reviewed in source; no synthetic AVAudioEngine start-failure injection is claimed. |
| P2 | A wall-clock fade deadline could stop the engine before delayed output callbacks rendered the full fade. | The fallback deadline includes 250 ms scheduling allowance; normal completion remains driven by the render envelope. A manual-render regression delays output by 180 ms before rendering a 120 ms fade. |
| P2 | Shutdown removed the retirement callback before hard stop, losing the outgoing overlap's completion/played-duration history. Legacy output before returning to the graph was also omitted from later retirement duration. | Retirement stays subscribed through teardown and its history writes are awaited. Legacy rendered time is accumulated without counting seek offsets. Regressions check exactly-once interrupted history and the duration retained across rate restoration. |
| P1, integration | Revoking the post-EQ effect detached the node before removing its analysis tap, raising `AVAudioNode removeTapOnBus: (NULL != engine)` in the App host. | The concurrent plugin review supplied tap removal before detach and deferred graph mutation while running. This review reproduced the crash and added a passing real-engine case for revoke while playing → pause → automatic detach → resume. |

The concurrent playback changes were also checked in the combined regression:
queue edits invalidate by successor identity; queue persistence preserves a
rendered handoff across repository awaits; unsupported authoritative commits stop
instead of leaving hidden playback; render cancellation carries a generation;
late next preparation preserves an already-fading outgoing gain; capabilities
reflect current restrictions; allocation/format failures are recoverable.

## Validation

All Xcode work reused `.noindex/DerivedData` and the existing shared host lock.
Device: **MusicFree Regression**, iPhone 17 Pro, iOS 26.5 Simulator,
`C3DA6A33-6237-4B7E-ADFE-7E429DC54B69`; Xcode 26.6.

| Check | Result | Evidence |
| --- | --- | --- |
| Initial defect reproduction | Four selected regressions failed before repair: rate restoration, serial decoder ownership, redundant resume, shutdown retirement | `.noindex/logs/playback-full-review-before.log` |
| Effects/rate preference reproduction | One regression failed with three assertions before repair | `.noindex/logs/playback-full-review-effects-before.log` |
| Focused transition repair | Adapter and Coordinator focused tests passed before expanding coverage | `.noindex/artifacts/playback-full-review-focused.xcresult` |
| First complete run | App host crashed while revoking DSP; remaining playback suites completed. Xcode stalled collecting crash diagnostics and was terminated. This run is not a successful acceptance result. | `.noindex/logs/playback-full-review-final.log`, `.noindex/logs/playback-full-review-xcode-sample.txt` |
| Final complete Simulator regression | **378 test functions / 520 executed cases passed**, zero failed/skipped/expected failures | `.noindex/artifacts/playback-full-review-verified.xcresult`, `playback-full-review-verified-summary.json` and `playback-full-review-verified-tests.json` in the same directory |
| Settings and UI feature model regression | **196 test functions / 219 executed cases passed**, zero failed/skipped/expected failures. Includes independent fade/crossfade persistence and unsupported-capability preference retention. | `.noindex/artifacts/playback-full-review-settings.xcresult`, `playback-full-review-settings-summary.json` and `playback-full-review-settings-tests.json` in the same directory |
| Native render, ASan + UBSan | **21 numerical cases passed**, including 5,000 cancellation interleavings, late-arm tail continuity and 10,001 correlated mix peaks | `.noindex/logs/playback-full-review-numerical.log` |
| Native render, ThreadSanitizer | **21 numerical cases passed**, no sanitizer diagnostics | `.noindex/logs/playback-full-review-thread-sanitizer.log` |
| Whitespace | `git diff --check` passed | Final working source |
| Repository architecture check | Not clean: pre-existing RootViewController SwiftUI hosting boundary and the parallel plugin HostBridge test AVFAudio allowlist. No claim of a repository-wide clean gate. | `.noindex/logs/playback-full-review-architecture.log` |

The complete Simulator selection includes all FFmpeg adapter tests, all Core
tests, transition Coordinator/preferences, the six original phone-sample cases,
and App-host DSP integration. Counts are extracted from xcresult; an XCTest
wrapper reporting zero cases is not used as evidence for Swift Testing cases.

The first final run breaks down as follows: transition Coordinator/preferences
16 functions / 31 cases, App host 6 / 11 (six phone scenarios plus five DSP
tests), Core 279 / 282, and FFmpeg adapter 77 / 196. Together with the UI feature
run, the two successful runs cover **574 functions / 739 executed cases**.
The original six phone cases each logged `commits=1`, `fallback=false` and
positive incoming mixer energy.

The settings test still expected an obsolete 4-second crossfade input. Its
valid preference-retention case now uses the agreed 3-second maximum; the Core
boundary tests separately continue to reject inputs above 3 seconds. A new
settings regression independently changes and disables fade-in/crossfade while
retaining fade-out and gapless preferences. The UI feature run also validates
the concurrent SettingsViewModel change made after the playback build; playback
source hashes were unchanged between that build and final verification.

The RootViewController architecture violations were verified in `HEAD` at lines
13 and 1728. The additional AVFAudio match is in
`MusicFreePluginHostBridge/Tests/MusicFreePluginHostBridgeTests/HostBridgeTests.swift`;
it belongs to the independent plugin review. The script's plugin dependency
checks passed once run with normal SwiftPM cache access.

Original sample pairs are BVT 8 kHz WAV → WMA Pro and WMA Pro → Musepack, with
gapless, 1 s and 3 s settings. Acceptance requires one ticketed handoff, incoming
mixer energy and no ordinary fallback, plus rate/seek controls after handoff.
The last-four-seconds seek bounds a requested 3 s overlap to about 2 s; the
separate 7 s ALAC fixture verifies a full 3 s overlap.

## Curve/EOF investigation and limits

An exact realtime tap-frame-count experiment failed for both graph and legacy
paths because tap delivery buffers the final partial block and time pitch alters
buffering. That experiment does **not** establish audible EOF truncation. The
replacement regression checks elapsed realtime playback against source duration
and requires actual nonzero output; both paths passed. No production EOF-delay
patch was introduced on the basis of tap counts.

Sources now decode through actual EOF rather than file-extension or duration
metadata cutoffs. Mono/stereo sources use the shared 48 kHz stereo bus; compatible
multichannel sources preserve their layout. Remote/CUE overlap, non-1 rate and
unverified DSP delay/tail retain ordinary fallback. File-intrinsic silence and
decoder-delivered padding are preserved. The WMA/Musepack silence previously
measured in the phone recording remains source content, not an engine gap.

This review does not establish physical speaker/headphone listening, Bluetooth
or AirPlay behavior, lock-screen/Control Center acceptance, sustained device
performance, UI interaction coverage, or a signed Archive. The user's earlier
“looks working” observation is retained separately from these automated results.

## Local review artifacts

- `.noindex/artifacts/playback-full-review/before/`: source snapshots before this review's repairs.
- `.noindex/artifacts/playback-full-review/review-fixes.diff`: combined changes relative to those snapshots, including concurrent work.
- `.noindex/artifacts/playback-full-review/verified-source-sha256.json`: reviewed playback/DSP source hashes at the final build start.
- `.noindex/artifacts/playback-full-review/validated-source-sha256.json`: the same playback source plus the subsequently tested UI source/test revision.
- `.noindex/artifacts/playback-full-review-verified.xcresult`: final Simulator result bundle.

Earlier mixed-format reproduction and original phone-recording measurements are
in [the Simulator report](../Testing/1.4_PLAYBACK_TRANSITIONS_SIMULATOR_2026-10-02.md).
