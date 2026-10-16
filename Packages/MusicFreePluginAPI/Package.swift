// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MusicFreePluginAPI",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MusicFreePluginAPI", targets: ["MusicFreePluginAPI"]),
        .library(name: "MusicFreePluginDSPAPI", targets: ["MusicFreePluginDSPAPI"]),
        .library(name: "MusicFreePluginAppleAudioAPI", targets: ["MusicFreePluginAppleAudioAPI"]),
        .library(name: "MusicFreePluginSettingsUIKitAPI", targets: ["MusicFreePluginSettingsUIKitAPI"])
    ],
    targets: [
        .target(name: "MusicFreePluginAPI"),
        .target(name: "MusicFreePluginDSPAPI", dependencies: ["MusicFreePluginAPI"]),
        .target(name: "MusicFreePluginAppleAudioAPI", dependencies: ["MusicFreePluginDSPAPI"]),
        .target(name: "MusicFreePluginSettingsUIKitAPI", dependencies: ["MusicFreePluginAPI"])
    ],
    swiftLanguageModes: [.v6]
)
