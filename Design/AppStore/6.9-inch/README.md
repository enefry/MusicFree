# MyMusic: Local Player historical screenshot candidates

Target: iPhone 6.9-inch display, `1320 x 2868` pixels.
Storefront: English (U.S.) only.

These files are retained for history only. They are not the current App Store upload set. Use [`../README.md`](../README.md), `iPhone-6.5-inch/`, `iPad-12.9-inch/`, and `AppPreviews/` for the current simulator materials.

| File | Source | State | Decision |
| --- | --- | --- | --- |
| `01-library.png` | `Design/screenshot/library.png` | English, dark mode, library with mini-player | Keep after final build and demo-media rights review |
| `02-now-playing.png` | `Design/screenshot/nowplaying.png` | English, dark mode, Now Playing | Keep after final build and demo-media rights review |
| `03-settings.png` | `Design/screenshot/settings.png` | English, dark mode, settings | Keep after final build review |
| `04-playlist-detail.png` | Clean iPhone 17 Pro Max UI-test attachment | Dark theme, completed playlist with owned temporary fixture metadata | Keep as candidate; re-capture or re-verify with the final Release build |

## Do not submit

- `Design/screenshot/playlist.png`: it contains an active text field and the system keyboard.
- UI-test attachments under `/private/tmp/MusicFree*Attachments/`: several contain `BVT`, test playlist names, or test track names. The copied `04-playlist-detail.png` is the exception and was captured with a temporary self-generated fixture.
- Any screenshot captured from an old IPA or a build that has not been re-verified against the approved store name `MyMusic: Local Player`.

## Final capture requirements

- Use the final signed Release/Archive build, with no BVT launch arguments or test media.
- Use a self-owned or clearly licensed demo audio file, or capture empty states when the feature remains legible.
- Keep one language and one appearance theme across the set.
- Dismiss keyboards, sheets, menus, and editing controls before capture.
- Re-check the exported PNG dimensions and inspect the complete image before upload.
