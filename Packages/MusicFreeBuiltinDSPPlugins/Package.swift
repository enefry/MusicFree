// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MusicFreeBuiltinDSPPlugins", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "EqualizerDSPPlugin", targets: ["EqualizerDSPPlugin"]),
               .library(name: "StereoBalanceDSPPlugin", targets: ["StereoBalanceDSPPlugin"]),
               .library(name: "DeclickDSPPlugin", targets: ["DeclickDSPPlugin"])],
    dependencies: [.package(path: "../MusicFreePluginAPI")],
    targets: [
        .target(name: "EqualizerDSPPlugin", dependencies: [
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginAppleAudioAPI", package: "MusicFreePluginAPI")]),
        .target(name: "StereoBalanceDSPPlugin", dependencies: [
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI")]),
        .target(name: "DeclickDSPPlugin", dependencies: [
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI")]),
        .testTarget(name: "DeclickDSPPluginTests", dependencies: ["DeclickDSPPlugin"]),
        .testTarget(name: "EqualizerDSPPluginTests", dependencies: ["EqualizerDSPPlugin"]),
        .testTarget(name: "StereoBalanceDSPPluginTests", dependencies: ["StereoBalanceDSPPlugin"])
    ], swiftLanguageModes: [.v6]
)
