// swift-tools-version: 6.2

import PackageDescription

// MusicFreeFFmpegAdapter
//
// 薄适配层：把本仓库 Packages/FFmpegAudioKit（audio-only ffmpeg 封装）映射到
// MusicFreeCore 的三个端口：
//   - FFmpegPlaybackEngine : PlaybackEngine / PlaybackAudioControlling
//     （ffmpeg 解码 → AVAudioEngine 输出，播放逻辑留在本层，不进 SDK）
//   - FFmpegMediaProbe     : MediaProbing
//   - FFmpegMetadataReader : MetadataReading
//
// ffmpeg 二进制与 C/Swift 解码桥由本仓库 FFmpegAudioKit 提供（FFmpeg 二进制来自 0.0.4 Release），
// 与 VLC 仓库彻底解耦。
let package = Package(
    name: "MusicFreeFFmpegAdapter",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "FFmpegPlaybackAdapter", targets: ["FFmpegPlaybackAdapter"])
    ],
    dependencies: [
        .package(path: "../FFmpegAudioKit"),
        .package(path: "../MusicFreeCore"),
        .package(path: "../MusicFreeInfrastructure")
    ],
    targets: [
        .target(
            name: "FFmpegPlaybackAdapter",
            dependencies: [
                .product(name: "FFmpegAudioKit", package: "FFmpegAudioKit"),
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "MusicFreeFFmpegAdapterTests",
            dependencies: [
                "FFmpegPlaybackAdapter",
                .product(name: "FFmpegAudioKit", package: "FFmpegAudioKit"),
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "MusicTestSupport", package: "MusicFreeCore"),
                .product(name: "LocalMediaAdapter", package: "MusicFreeInfrastructure")
            ],
            resources: [
                .copy("Fixtures/cue-seek-chirp.m4a"),
                .copy("Fixtures/cue-seek-chirp.mp3"),
                .copy("Fixtures/cue-seek-chirp.flac"),
                .copy("Fixtures/cue-seek-chirp.ogg"),
                .copy("Fixtures/dsd-quarter-second.dsf"),
                .copy("Fixtures/ac3.ac3"),
                .copy("Fixtures/alac.m4a"),
                .copy("Fixtures/current.m4a"),
                .copy("Fixtures/reencoded.m4a"),
                .copy("Fixtures/eac3.eac3"),
                .copy("Fixtures/opus.opus"),
                .copy("Fixtures/tta.tta"),
                .copy("Fixtures/vorbis.ogg"),
                .copy("Fixtures/wavpack.wv"),
                .copy("Fixtures/wmav2.wma"),
                .copy("Fixtures/pcm24.wav"),
                .copy("Fixtures/aiff.aiff"),
                .copy("Fixtures/caf.caf"),
                .copy("Fixtures/w64.w64"),
                .copy("Fixtures/au.au"),
                .copy("Fixtures/matroska.mka"),
                .copy("Fixtures/dts.dts"),
                .copy("Fixtures/wmav1.wma"),
                .copy("Fixtures/pcm32.wav"),
                .copy("Fixtures/pcmfloat.wav"),
                .copy("Fixtures/pcmu8.wav"),
                .copy("Fixtures/aiff24.aiff"),
                .copy("Fixtures/tagged-metadata.flac"),
                .copy("Fixtures/artwork-red.mp4"),
                .copy("Fixtures/artwork-blue.mp4")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
