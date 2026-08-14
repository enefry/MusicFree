// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "LibraryFeature", targets: ["LibraryFeature"]),
        .library(name: "PlayerFeature", targets: ["PlayerFeature"]),
        .library(name: "PlaylistFeature", targets: ["PlaylistFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"])
    ],
    dependencies: [
        .package(path: "../MusicFreeCore")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "LibraryFeature",
            dependencies: [
                "DesignSystem",
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "AppServices", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "PlayerFeature",
            dependencies: [
                "DesignSystem",
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "AppServices", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "PlaylistFeature",
            dependencies: [
                "DesignSystem",
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "AppServices", package: "MusicFreeCore")
            ]
        ),
        .target(
            name: "SettingsFeature",
            dependencies: [
                "DesignSystem",
                .product(name: "SettingsAPI", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "SystemIntegrationAPI", package: "MusicFreeCore"),
                .product(name: "AppServices", package: "MusicFreeCore")
            ]
        ),
        .testTarget(
            name: "MusicFreeUITests",
            dependencies: [
                "DesignSystem",
                "LibraryFeature",
                "PlayerFeature",
                "PlaylistFeature",
                "SettingsFeature",
                .product(name: "AppServices", package: "MusicFreeCore"),
                .product(name: "LibraryAPI", package: "MusicFreeCore"),
                .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
                .product(name: "MusicDomain", package: "MusicFreeCore"),
                .product(name: "PlaybackAPI", package: "MusicFreeCore"),
                .product(name: "SettingsAPI", package: "MusicFreeCore"),
                .product(name: "SystemIntegrationAPI", package: "MusicFreeCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
