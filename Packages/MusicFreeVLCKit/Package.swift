// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeVLCKit",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "VLCKitPlaybackAdapter", targets: ["VLCKitPlaybackAdapter"])
    ],
    dependencies: [
        .package(path: "../MusicFreeCore"),
        .package(
            url: "https://github.com/MobileVLCKit-SPM/VLCKit-SPM.git",
            exact: "4.0.0-alpha.20260805.1123"
        )
    ],
    targets: [
        .target(
            name: "VLCKitPlaybackAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "VLCKit", package: "VLCKit-SPM")
            ]
        ),
        .testTarget(
            name: "MusicFreeVLCKitTests",
            dependencies: [
                "VLCKitPlaybackAdapter",
                .product(name: "MusicTestSupport", package: "MusicFreeCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
