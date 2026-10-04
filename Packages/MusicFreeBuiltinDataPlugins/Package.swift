// swift-tools-version: 6.2
import PackageDescription
let plugins = ["LRCLIBLyricsPlugin", "MetadataServerLyricsPlugin", "MusicKitMetadataPlugin", "MusicBrainzMetadataPlugin", "MetadataServerMetadataPlugin", "DiscogsMetadataPlugin"]
let package = Package(
    name: "MusicFreeBuiltinDataPlugins", platforms: [.iOS(.v17), .macOS(.v13)],
    products: plugins.map { .library(name: $0, targets: [$0]) },
    dependencies: [.package(path: "../MusicFreePluginAPI")],
    targets: [
        .target(name: "DataPluginSupport", dependencies: [.product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI")])
    ] + plugins.map { .target(name: $0, dependencies: ["DataPluginSupport", .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI")]) }
      + [.testTarget(name: "BuiltinDataPluginTests", dependencies: plugins.map { .byName(name: $0) } + ["DataPluginSupport"])],
    swiftLanguageModes: [.v6]
)
