// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MusicFreePluginAudio", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MusicFreePluginAudio", targets: ["MusicFreePluginAudio"])],
    dependencies: [.package(path: "../MusicFreePluginAPI")],
    targets: [
        .target(name: "PluginAnalysisRing"),
        .target(name: "MusicFreePluginAudio", dependencies: ["PluginAnalysisRing",
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginAppleAudioAPI", package: "MusicFreePluginAPI")]),
        .testTarget(name: "MusicFreePluginAudioTests", dependencies: ["MusicFreePluginAudio"])
    ], swiftLanguageModes: [.v6]
)
