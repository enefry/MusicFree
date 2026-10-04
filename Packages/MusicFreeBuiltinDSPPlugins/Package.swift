// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MusicFreeBuiltinDSPPlugins", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "EqualizerDSPPlugin", targets: ["EqualizerDSPPlugin"])],
    dependencies: [.package(path: "../MusicFreePluginAPI")],
    targets: [
        .target(name: "EqualizerDSPPlugin", dependencies: [
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginAppleAudioAPI", package: "MusicFreePluginAPI")]),
        .testTarget(name: "EqualizerDSPPluginTests", dependencies: ["EqualizerDSPPlugin"])
    ], swiftLanguageModes: [.v6]
)
