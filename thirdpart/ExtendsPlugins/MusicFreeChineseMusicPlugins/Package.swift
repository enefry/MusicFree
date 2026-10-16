// swift-tools-version: 6.2
import PackageDescription

let plugins = ["NetEaseLyricsPlugin", "NetEaseMetadataPlugin", "QQMusicLyricsPlugin", "QQMusicMetadataPlugin"]
let package = Package(
    name: "MusicFreeChineseMusicPlugins",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: plugins.map { .library(name: $0, targets: [$0]) }
        + [.library(name: "ChineseMusicCatalogSupport", targets: ["ChineseMusicCatalogSupport"])],
    dependencies: [
        .package(path: "../../../Packages/MusicFreePluginAPI"),
        .package(path: "../../../Packages/MusicFreeBuiltinDataPlugins")
    ],
    targets: [
        .target(name: "ChineseMusicCatalogSupport", dependencies: [
            .product(name: "DataPluginSupport", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI")
        ])
    ] + plugins.map { .target(name: $0, dependencies: [
        "ChineseMusicCatalogSupport",
        .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI")
    ]) } + [
        .testTarget(name: "ChineseMusicPluginTests", dependencies:
            plugins.map { .byName(name: $0) } + ["ChineseMusicCatalogSupport", .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI")])
    ],
    swiftLanguageModes: [.v6]
)
