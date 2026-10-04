// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MusicFreePluginHostBridge", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MusicFreePluginHostBridge", targets: ["MusicFreePluginHostBridge"])],
    dependencies: [.package(path: "../MusicFreeCore"), .package(path: "../MusicFreePluginRuntime"),
        .package(path: "../MusicFreePluginAPI"), .package(path: "../MusicFreePluginAudio"), .package(path: "../MusicFreeBuiltinDataPlugins")],
    targets: [
        .target(name: "MusicFreePluginHostBridge", dependencies: [
            .product(name: "AppServices", package: "MusicFreeCore"),
            .product(name: "MusicDomain", package: "MusicFreeCore"),
            .product(name: "LibraryAPI", package: "MusicFreeCore"),
            .product(name: "MediaSourceAPI", package: "MusicFreeCore"),
            .product(name: "PlaybackAPI", package: "MusicFreeCore"),
            .product(name: "SettingsAPI", package: "MusicFreeCore"),
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginAppleAudioAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginRuntime", package: "MusicFreePluginRuntime"),
            .product(name: "MusicFreePluginAudio", package: "MusicFreePluginAudio"),
            .product(name: "LRCLIBLyricsPlugin", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "MetadataServerLyricsPlugin", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "MusicKitMetadataPlugin", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "MusicBrainzMetadataPlugin", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "MetadataServerMetadataPlugin", package: "MusicFreeBuiltinDataPlugins"),
            .product(name: "DiscogsMetadataPlugin", package: "MusicFreeBuiltinDataPlugins")]),
        .testTarget(name: "MusicFreePluginHostBridgeTests", dependencies: ["MusicFreePluginHostBridge"])
    ], swiftLanguageModes: [.v6]
)
