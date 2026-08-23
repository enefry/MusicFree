# MyMusic: Local Player App Store Submission Draft

> Status: historical preparation draft based on the 2026-08-15 checkout and simulator assets. Refresh the version, build, privacy URL, screenshots and release gates before using it for a current submission. The metadata below is for the English (U.S.) storefront only; it does not mean an App Store Connect record, final upload, or Apple review has been completed.

## 0. Open release gates

- [ ] Store name alignment: the approved App Store name is `MyMusic: Local Player`. The current binary display name remains `MyMusic`; decide whether that shorter home-screen name is intentional before the final Archive.
- [ ] Privacy policy URL: publish [`PRIVACY_POLICY.md`](../PRIVACY_POLICY.md) in the public GitHub repository and verify that the exact HTTPS URL below is reachable without authentication.
- [ ] Support and review contact: use the public GitHub Issues URL below for user support, and fill in the App Review contact person's name, phone, and email in App Store Connect.
- [ ] App Privacy confirmation: the current `App/PrivacyInfo.xcprivacy` declares no collected data and no tracking. Re-check the final binary, the dynamic VLCKit framework, and any release services before submitting the questionnaire.
- [ ] Third-party license review: complete the VLCKit/LGPL source, relinking, binary-distribution, and App Store review before publication.
- [ ] Final Release build: the current configuration is `0.1.8 (2026081404)`, but the final tracking/release build has not been packaged yet. Do not upload an older IPA from `dist/`.
- [ ] Device acceptance: real-device playback, background audio, Lock Screen controls, audio routes, interruptions, format coverage, and long-running playback are still being tested.
- [ ] Screenshot sign-off: the simulator candidates in [`Design/AppStore/`](../../Design/AppStore/) are English and correctly sized; re-verify the final set with the final Release build and owned/licensed demo media.

## 1. App Store Connect basic metadata

| Field | Value | Notes |
| --- | --- | --- |
| App Name | `MyMusic: Local Player` | English (U.S.) storefront; 30 characters or fewer |
| Subtitle | `Import and play your music` | English (U.S.) storefront; 30 characters or fewer |
| Bundle ID | `win.tools4me.music` | Configured in the project |
| Primary Category | `Music` | `public.app-category.music` |
| Secondary Category | Leave blank unless selected by the publisher | Optional |
| App version | `0.1.8` | Current `APP_VERSION`; final release may change |
| Build | `2026081404` | Current `BUILD_VERSION`; final release may change |
| Minimum OS | iOS/iPadOS 26+ | Confirm against the final Archive |
| Supported devices | iPhone and iPad | The project declares both device families; no Apple Watch target is present |
| Price / availability | To be completed | Not defined by the source project |
| In-App Purchases | None planned | Re-check App Store Connect and the final project |
| SKU | To be completed | Keep stable once chosen |

## 2. English (U.S.) listing

### Name

`MyMusic: Local Player`

### Subtitle

`Import and play your music`

### Promotional Text

`A focused local music player for the audio files you already own.`

### Description

```text
MyMusic: Local Player is a focused player for the audio files you already own.

Bring your local library into one place. Import audio files from Files or Finder file sharing, then browse them by artists, albums, songs, genres, folders, favorites, and playback history.

Make listening your own:

- Create and manage playlists
- Build a queue with play next, add to queue, shuffle, and repeat
- Continue listening with background audio and Lock Screen controls
- Seek through tracks and adjust playback speed
- Tune playback with an equalizer
- Choose light, dark, or system appearance
- Switch between available app icon styles

MyMusic: Local Player is designed for a personal, local library. It does not provide a streaming catalog, cloud sync, podcasts, radio, or an account-based service. Your imported library and listening organization stay on your device.
```

### Keywords

`local,music,player,audio,library,offline,playlist,equalizer,background`

### What's New

```text
Initial release of MyMusic: Local Player: import a local audio library, organize playlists, and listen with a focused player for iPhone and iPad.
```

## 3. Localization scope

Only the English (U.S.) storefront is prepared for this release. Leave Chinese and all other language metadata fields blank in App Store Connect.

## 4. App Review information

### Review notes

```text
MyMusic: Local Player plays audio files imported from the user's device. No account or login is required.

To test the main flow:
1. Launch the app and open Library.
2. Tap the add button and choose an audio file from Files, or place an audio file in the app's Documents folder through Finder file sharing.
3. Open Songs and tap the imported track to play it.
4. Use the mini-player to open Now Playing. Test play/pause, seeking, queue, favorite, and playback controls.
5. Open Playlists to create a playlist and add the imported track.
6. Open Settings to test playback speed, equalizer, appearance, and app icon selection.

The app is local-only and does not require a server account. Please use a sample audio file supplied by App Review; the app does not ship a streaming catalog or copyrighted demo music.
```

### Contact fields

| Field | Value |
| --- | --- |
| First name / Last name | Fill in the publisher contact |
| Phone | Fill in the publisher contact |
| Email | Fill in the publisher contact |
| Review attachment | Final Release build and demo-media rights note, if needed |

## 5. URLs, privacy, and rights

| Field | Value | Notes |
| --- | --- | --- |
| Support URL | `https://github.com/enefry/MusicFree/issues` | Use GitHub Issues as the public support channel |
| Marketing URL | `https://github.com/enefry/MusicFree` | Optional; keep the public repository presentable |
| Privacy Policy URL | `https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY.md` | Publish the file at this path before submission |
| Copyright | `(c) 2026 enefry` | Confirm the legal rights holder and year |

### App Privacy answers to prepare

- Data collection: `No Data Collected`, based on the current Privacy Manifest; re-check the final binary and bundled dependencies before submission.
- Tracking: `No`.
- Encryption: the project sets `ITSAppUsesNonExemptEncryption = false`; answer export-compliance questions against the final build.
- Third-party code: the app links the modified open-source `MusicFreeVLCKit` dynamic framework; dependency and license materials are in [`ThirdPartyNotices/`](../../ThirdPartyNotices/).
- Content rights: confirm rights to the app icon, screenshot media metadata, demo audio, and copy before upload.

## 6. Screenshot and preview checklist

The final simulator candidate set is in [`Design/AppStore/README.md`](../../Design/AppStore/README.md). It is English-only and uses temporary self-generated demo audio metadata. The screenshots were captured from the Debug simulator build without BVT launch arguments; re-verify the final set with the signed Release build before upload.

### iPhone 6.5-inch

Target: `1284 x 2778` pixels. Submit up to 10 screenshots from [`Design/AppStore/iPhone-6.5-inch/`](../../Design/AppStore/iPhone-6.5-inch/).

| File | Focus |
| --- | --- |
| `01-library.png` | Library categories, recent albums, and mini-player |
| `02-songs.png` | Imported local songs with artists and quick actions |
| `03-now-playing.png` | Now Playing, playback controls, and upcoming queue |
| `04-playlist-detail.png` | Focus playlist with three imported songs |
| `05-settings.png` | Appearance, app icons, playback speed, and import settings |
| `06-equalizer.png` | Enabled equalizer with custom profile and bands |
| `07-sleep-timer.png` | Active one-time sleep timer |

### iPad 12.9-inch

Target: `2048 x 2732` pixels. Candidate screenshots are in [`Design/AppStore/iPad-12.9-inch/`](../../Design/AppStore/iPad-12.9-inch/).

| File | Focus |
| --- | --- |
| `01-library.png` | iPad split-view library and imported songs |
| `02-settings.png` | Settings, storage status, and appearance |
| `03-equalizer.png` | Full-width equalizer settings |
| `04-sleep-timer.png` | Active sleep timer in the iPad settings column |
| `05-playlist-detail.png` | Focus playlist and three-song detail view |

### App Previews

The three H.264 previews are in [`Design/AppStore/AppPreviews/`](../../Design/AppStore/AppPreviews/). Each is `1284 x 2778`, 30 fps, silent, and shorter than 30 seconds.

| File | Flow |
| --- | --- |
| `01-library-import.mp4` | Library to Songs to a local track |
| `02-now-playing-queue.mp4` | Now Playing and queue controls |
| `03-settings-equalizer.mp4` | Settings to the enabled equalizer |

### Apple Watch

Do not create or submit Apple Watch screenshots or previews for this build. `project.yml` declares only the iOS application and test targets; there is no watchOS target, Watch app, or watchOS runtime in the current setup.

### Screenshot submission rules

- Submit only images captured from the final Release build through the real app flow. Do not use images containing `BVT`, test playlist names, or test fixture names.
- Dismiss keyboards, sheets, menus, and editing controls; keep a stable completed state that demonstrates the feature.
- Use one language, theme, and final build across the set; do not mix storefront locales.
- Confirm rights to any song title, artist, album art, or source text shown in the images. Re-capture with owned or clearly licensed demo audio when needed.
- Use App Store Connect's preview to check status bar treatment, device corners, text truncation, and bottom-tab overlap before upload.
- Keep the old [`Design/AppStore/6.9-inch/`](../../Design/AppStore/6.9-inch/) directory as historical reference only; it is not the current upload set.

## 7. Pre-submission checklist

- [ ] App name, Bundle ID, version, build, and final Archive agree.
- [ ] The final build is a signed Release/Archive, not the older IPA and not a BVT-injected build.
- [ ] iPhone real-device playback, background/Lock Screen behavior, routes, interruptions, and formats pass.
- [ ] iPad layout, rotation, navigation, and file import pass on a real device.
- [ ] Privacy policy URL, GitHub Issues support URL, review contact, and copyright are confirmed.
- [ ] Age-rating questionnaire is complete based on the final product.
- [ ] App Privacy answers match the final Privacy Manifest and bundled component behavior.
- [ ] VLCKit/LGPL distribution review is complete, with source, relinking instructions, and license texts ready.
- [ ] iPhone 6.5-inch screenshots are final and uploaded to the matching App Store Connect slot.
- [ ] iPad screenshots are final and uploaded to the matching iPad slot if enabled for the version.
- [ ] App Previews are final, under 30 seconds, and uploaded only to the iPhone preview slots.
- [ ] No Apple Watch metadata or media is submitted unless a future watchOS target is added.
- [ ] TestFlight install, upgrade, clean install, and first-launch flows pass.
- [ ] Submit for review only after the above items are complete.

## 8. Sources

- [`README.md`](../../README.md): product positioning and excluded services.
- [`App/PrivacyInfo.xcprivacy`](../../App/PrivacyInfo.xcprivacy): current privacy manifest.
- [`basic_config.xcconfig`](../../basic_config.xcconfig): version, build, category, and display-name configuration.
- [`ThirdPartyNotices/README.md`](../../ThirdPartyNotices/README.md): third-party dependency and LGPL release gates.
- [`Docs/Testing/MANUAL_TEST_CASES.md`](../Testing/MANUAL_TEST_CASES.md): real-device, Release, and publication acceptance boundaries.
- [`Design/AppStore/README.md`](../../Design/AppStore/README.md): current simulator screenshot and App Preview inventory with validation commands.
