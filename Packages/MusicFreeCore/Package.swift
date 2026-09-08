// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicFreeCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "MusicDomain", targets: ["MusicDomain"]),
        .library(name: "MediaSourceAPI", targets: ["MediaSourceAPI"]),
        .library(name: "LibraryAPI", targets: ["LibraryAPI"]),
        .library(name: "PlaybackAPI", targets: ["PlaybackAPI"]),
        .library(name: "SystemIntegrationAPI", targets: ["SystemIntegrationAPI"]),
        .library(name: "SettingsAPI", targets: ["SettingsAPI"]),
        .library(name: "AppServices", targets: ["AppServices"]),
        .library(name: "MusicTestSupport", targets: ["MusicTestSupport"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git",
            exact: "3.9.1"
        )
    ],
    targets: [
        .target(
            name: "MusicDomain",
            dependencies: [
                .product(
                    name: "CocoaLumberjackSwift",
                    package: "CocoaLumberjack"
                )
            ]
        ),
        .target(
            name: "MediaSourceAPI",
            dependencies: ["MusicDomain"]
        ),
        .target(
            name: "LibraryAPI",
            dependencies: ["MusicDomain"]
        ),
        .target(
            name: "PlaybackAPI",
            dependencies: ["MusicDomain", "MediaSourceAPI"]
        ),
        .target(
            name: "SystemIntegrationAPI",
            dependencies: ["MusicDomain", "PlaybackAPI"]
        ),
        .target(
            name: "SettingsAPI",
            dependencies: ["MusicDomain", "MediaSourceAPI", "PlaybackAPI"]
        ),
        .target(
            name: "AppServices",
            dependencies: [
                "MusicDomain",
                "MediaSourceAPI",
                "LibraryAPI",
                "PlaybackAPI",
                "SystemIntegrationAPI",
                "SettingsAPI"
            ]
        ),
        .target(
            name: "MusicTestSupport",
            dependencies: [
                "MusicDomain",
                "MediaSourceAPI",
                "LibraryAPI",
                "PlaybackAPI",
                "SystemIntegrationAPI",
                "SettingsAPI"
            ]
        ),
        .testTarget(
            name: "MusicFreeCoreTests",
            dependencies: [
                "AppServices",
                "MusicTestSupport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
