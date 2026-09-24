// swift-tools-version: 6.2

import PackageDescription

// MusicFreeFFmpegAdapter
//
// 薄适配层：把独立仓库 FFmpegAudioKit（audio-only ffmpeg 封装）映射到
// MusicFreeCore 的三个端口：
//   - FFmpegPlaybackEngine : PlaybackEngine / PlaybackAudioControlling
//     （ffmpeg 解码 → AVAudioEngine 输出，播放逻辑留在本层，不进 SDK）
//   - FFmpegMediaProbe     : MediaProbing
//   - FFmpegMetadataReader : MetadataReading
//
// ffmpeg 二进制与 C/Swift 解码桥全部下沉到 ../../thirdpart/FFmpegAudioKit，
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
        .package(path: "../../thirdpart/FFmpegAudioKit"),
        .package(path: "../MusicFreeCore")
    ],
    targets: [
        .target(
            name: "FFmpegPlaybackAdapter",
            dependencies: [
                .product(name: "FFmpegAudioKit", package: "FFmpegAudioKit"),
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore")
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
                .product(name: "MusicTestSupport", package: "MusicFreeCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
