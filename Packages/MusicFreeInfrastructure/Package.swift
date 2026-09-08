// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeInfrastructure",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "LocalMediaAdapter", targets: ["LocalMediaAdapter"]),
        .library(name: "LibraryPersistenceAdapter", targets: ["LibraryPersistenceAdapter"]),
        .library(name: "AppleSystemAdapter", targets: ["AppleSystemAdapter"]),
        .library(name: "PreferencesPersistenceAdapter", targets: ["PreferencesPersistenceAdapter"]),
        .library(name: "OnlineSourceAdapter", targets: ["OnlineSourceAdapter"])
    ],
    dependencies: [
        .package(path: "../MusicFreeCore")
    ],
    targets: [
        .target(
            name: "LocalMediaAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "SettingsAPI", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "LibraryPersistenceAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "AppleSystemAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "SystemIntegrationAPI", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "PreferencesPersistenceAdapter",
            dependencies: [
                .product(name: "SettingsAPI", package: "MusicFreeCore"),
                .product(name: "AppServices", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "OnlineSourceAdapter",
            dependencies: [
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore")
            ]
        ),
        .testTarget(
            name: "MusicFreeInfrastructureTests",
            dependencies: [
                "LocalMediaAdapter",
                "LibraryPersistenceAdapter",
                "AppleSystemAdapter",
                "PreferencesPersistenceAdapter",
                "OnlineSourceAdapter",
                .product(name: "MusicTestSupport", package: "MusicFreeCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
