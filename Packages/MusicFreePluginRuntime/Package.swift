// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MusicFreePluginRuntime", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MusicFreePluginRuntime", targets: ["MusicFreePluginRuntime"])],
    dependencies: [.package(path: "../MusicFreePluginAPI")],
    targets: [
        .target(name: "MusicFreePluginRuntime", dependencies: [
            .product(name: "MusicFreePluginAPI", package: "MusicFreePluginAPI"),
            .product(name: "MusicFreePluginDSPAPI", package: "MusicFreePluginAPI")
        ]),
        .testTarget(name: "MusicFreePluginRuntimeTests", dependencies: ["MusicFreePluginRuntime"])
    ], swiftLanguageModes: [.v6]
)
