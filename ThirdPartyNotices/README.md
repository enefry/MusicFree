# Third-party notices

> 本目录记录 App 内展示的第三方依赖、版本和完整许可文本。

MyMusic: Local Player links the exact `MusicFreeVLCKit` release
`4.0.0-audio.20260814.3`. Its packaged SBOM contains 14 components and its
`LICENSES/third-party-licenses` directory contains 14 corresponding license
files. All 14 records and texts are mirrored here so Settings > About and
licenses can render them without reading files from the framework at runtime.

The app consumes the modified open-source distribution through SwiftPM's
`VLCKit` product. The product is a prebuilt dynamic framework/XCFramework
linked by `MusicFreeVLCKitAdapter`, rather than a source copy embedded in this
app repository. The source repository is
[`enefry/MusicFreeVLCKit`](https://github.com/enefry/MusicFreeVLCKit).

See [`VLCKit.md`](VLCKit.md) for the component inventory, source revisions,
binary checksum, release material link, and local license file list. The
read-only [`manifest.json`](manifest.json) is bundled as the UI data source.

A release must still pass a separate LGPL distribution review, including
relinking, source/build materials and App Store terms, before publication.
