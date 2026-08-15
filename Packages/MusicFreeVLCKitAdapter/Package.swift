// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeVLCKitAdapter",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "VLCKitPlaybackAdapter", targets: ["VLCKitPlaybackAdapter"])
    ],
    dependencies: [
        .package(path: "../MusicFreeCore"),
        .package(
            url: "https://github.com/enefry/MusicFreeVLCKit.git",
            exact: "4.0.0-audio.20260814.3"
        )
    ],
    targets: [
        .target(
            name: "VLCKitPlaybackAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "VLCKit", package: "MusicFreeVLCKit")
            ]
        ),
        .testTarget(
            name: "MusicFreeVLCKitAdapterTests",
            dependencies: [
                "VLCKitPlaybackAdapter",
                .product(name: "MusicTestSupport", package: "MusicFreeCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
