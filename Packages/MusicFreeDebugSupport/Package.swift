// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeDebugSupport",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "MusicFreeDebugSupport", targets: ["MusicFreeDebugSupport"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/kean/Pulse.git",
            exact: "5.2.3"
        ),
        .package(
            url: "https://github.com/LookInsideApp/LookInside-Release.git",
            from: "0.2.9"
        )
    ],
    targets: [
        .target(
            name: "MusicFreeDebugSupport",
            dependencies: [
                .product(name: "Pulse", package: "Pulse"),
                .product(name: "PulseProxy", package: "Pulse"),
                .product(name: "PulseUI", package: "Pulse"),
                .product(name: "LookInsideServer", package: "LookInside-Release")
            ],
            path: "Sources/MusicFreeDebugSupport"
        )
    ],
    swiftLanguageModes: [.v6]
)
