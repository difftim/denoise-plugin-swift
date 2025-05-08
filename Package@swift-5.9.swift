// swift-tools-version:5.9
// (Xcode15.0+)

import PackageDescription

let package = Package(
    name: "DenoisePluginFilter",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "DenoisePluginFilter",
            targets: ["DenoisePluginFilter"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/difftim/client-sdk-swift.git", from: "2.0.19-a2"),
    ],
    targets: [
        .binaryTarget(
            name: "RNNoise",
            
            // for local
            // path: "libs/RNNoise.xcframework"

            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.2/RNNoise.xcframework.zip",
            checksum: "e79c4cfb5e32c1c1b658b3212d97b705a1d8d2a14818f2943ce6c5ac22fe3b8e"
        ),
        .target(
            name: "DenoisePluginFilter",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                "RNNoise",
            ],
            path: "Sources"
        ),
    ]
)
