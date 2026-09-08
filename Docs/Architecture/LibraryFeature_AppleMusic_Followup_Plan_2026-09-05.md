# LibraryFeature Follow-up Plan

## Scope

This follow-up is limited to the unfinished UIKit LibraryFeature work that was
compared with the Apple Music reference UI. The reference image and reference
directory are visual references only; they are not additional product
requirements.

## Completed baseline

- Album, artist, genre, folder, and song surfaces use native UIKit collection
  views with Apple Music-style menus and primary playback actions.
- Song sharing resolves and shares song files rather than sharing only text.
- Album and artist collection sharing resolves all songs in the collection.
- Album menus expose destructive deletion with confirmation.
- Artist detail groups duplicate album records by title, release year, and
  album type while retaining all underlying album IDs for playback and actions.
- Tracks without an album, including orphaned album references, are modeled as
  a separate `No Album` collection.

## Status at 2026-09-05

The implementation work is split into four states so that simulator-only
verification is not reported as completed product work:

- **Implemented in source:** collection menus, file-based sharing, album
  deletion, duplicate artist-album grouping, and the `No Album` collection.
- **Build verified:** the current `MusicFree` iOS Simulator test bundle builds
  successfully with the repository DerivedData path.
- **Runtime verification pending:** visual comparison of every Library surface
  against the Apple Music reference, especially the artist album grid and the
  album detail header/track list. The focused UI-test command was corrected to
  use the full XCTest identifier, but the previous invocation selected zero
  tests and is therefore not evidence of a pass.
- **Environment blocked:** a subsequent simulator probe failed with
  `CoreSimulatorService connection refused`. Direct SwiftPM tests are also
  blocked by the sandbox's user-level Swift/Clang cache permissions. The
  repository build, architecture check, and diff check remain valid.

## Replanned work and order

The unfinished work is split by the boundary that can fail, with the current
implementation and the remaining verification kept separate:

1. **Data and refresh boundary**
   - Keep BVT artist-album and no-album fixtures deterministic on every
     explicitly seeded launch.
   - Keep the no-album fixture without an `IPRD` chunk and classify both
     `track.albumID == nil` and orphaned album IDs as `No Album`.
   - Re-query the supplemental no-album collection after track, album, or
     deletion changes, including track-only imports.

2. **Artist -> artist albums**
   - Match the Apple Music reference with a stable two-column album grid.
   - Verify both item frames from the settled layout environment and keep a
     fixed card-height budget so a first-layout width cannot create a full-width
     card or a clipped second card. The source now uses a native compositional
     layout; this remains a runtime verification item until the simulator is
     healthy.
   - Keep a full-card accessibility activation target and preserve grouped album
     navigation so duplicate records open the union of their tracks.

3. **Collection actions and detail consistency**
   - Keep song sharing file-based and album/artist sharing collection-based.
   - Keep album deletion destructive and confirmed, then refresh albums,
     overview data, and the `No Album` count.
   - Complete the remaining Apple Music comparison for album detail headers,
     numbered track rows, menus, empty states, and list/grid transitions.

4. **Verification gates**
   - Build with the repository DerivedData path and run focused logic tests.
   - Once CoreSimulatorService is healthy, run the focused UI tests with the
     complete selectors below, then the full `MusicFreeFeatureLoadingUITests`
     suite:
     `MusicFreeUITests/MusicFreeFeatureLoadingUITests/testLibraryAlbumsExposeNoAlbumCollection`
     and
     `MusicFreeUITests/MusicFreeFeatureLoadingUITests/testArtistDetailUsesStableTwoColumnAlbumGrid`.
   - Finish with `git diff --check` and `Scripts/check_architecture.sh`.

## Acceptance criteria

- An artist with multiple album records sees a stable two-column album grid;
  cards align in each row, the second card is not clipped, and titles remain
  inside their cards.
- Selecting an artist album group presents the union of all grouped album
  tracks, without duplicate track IDs.
- Songs with no album metadata are reachable through Albums -> No Album and are
  not silently omitted from the Library.
- Songs whose album ID points to a deleted or missing album record are reachable
  through the same No Album collection.
- Optional `No Album` content does not change the meaning of generic layout
  tests when the fixture contains no such songs.
