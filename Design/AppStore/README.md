# App Store Asset Set

Product: `MyMusic: Local Player`  
Storefront: English (U.S.) only  
Capture source: iOS 26.5 Simulator, Debug build, no BVT launch arguments

These assets are release-preparation candidates. Re-check the final signed Release build and demo-media rights before uploading to App Store Connect.

## iPhone 6.5-inch

All files are `1284 x 2778` PNGs and fit the App Store Connect 6.5-inch iPhone slot.

| File | Feature |
| --- | --- |
| `iPhone-6.5-inch/01-library.png` | Library overview, recent albums, and mini-player |
| `iPhone-6.5-inch/02-songs.png` | Imported Songs list |
| `iPhone-6.5-inch/03-now-playing.png` | Now Playing with queue entries |
| `iPhone-6.5-inch/04-playlist-detail.png` | Focus playlist with three songs |
| `iPhone-6.5-inch/05-settings.png` | Appearance, icon, playback, and import settings |
| `iPhone-6.5-inch/06-equalizer.png` | Enabled custom equalizer |
| `iPhone-6.5-inch/07-sleep-timer.png` | Active one-time sleep timer |

## iPad 12.9-inch

All files are `2048 x 2732` PNGs from the iPad Pro 12.9-inch simulator.

| File | Feature |
| --- | --- |
| `iPad-12.9-inch/01-library.png` | Split-view library and imported songs |
| `iPad-12.9-inch/02-settings.png` | Settings and storage status |
| `iPad-12.9-inch/03-equalizer.png` | Full-width equalizer |
| `iPad-12.9-inch/04-sleep-timer.png` | Active sleep timer |
| `iPad-12.9-inch/05-playlist-detail.png` | Split-view Focus playlist |

## App Previews

The previews are silent H.264 MP4 files at `1284 x 2778`, normalized to 30 fps and shorter than 30 seconds.

| File | Flow |
| --- | --- |
| `AppPreviews/01-library-import.mp4` | Library, Songs, and local playback |
| `AppPreviews/02-now-playing-queue.mp4` | Now Playing and queue |
| `AppPreviews/03-settings-equalizer.mp4` | Settings and equalizer |

## Demo media

The screenshots use self-generated temporary audio metadata only:

- `Deep Focus` / `MyMusic Studio` / `Local Sessions`
- `Midnight Echo` / `MyMusic Studio` / `Local Sessions`
- `Morning Light` / `Northstar Audio` / `Acoustic Notes`
- `City Signals` / `Northstar Audio` / `Field Recordings`

No album artwork or copyrighted recording is embedded in the candidate assets.

## Apple Watch

No Apple Watch assets are included. The current Xcode project has only the iOS application, unit-test, and UI-test targets; it has no watchOS target or Watch app.

## Validation

From the outer `MusicPlayer` directory:

```sh
find MusicFree/Design/AppStore/iPhone-6.5-inch -name '*.png' -print0 | xargs -0 sips -g pixelWidth -g pixelHeight
find MusicFree/Design/AppStore/iPad-12.9-inch -name '*.png' -print0 | xargs -0 sips -g pixelWidth -g pixelHeight
for f in MusicFree/Design/AppStore/AppPreviews/*.mp4; do
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate,pix_fmt \
    -show_entries format=duration -of default=nw=1 "$f"
done
```

The old `6.9-inch` directory is retained as historical reference and is not part of this upload set.
