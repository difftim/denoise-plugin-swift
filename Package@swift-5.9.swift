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

            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.3/RNNoise.xcframework.zip",
            checksum: "7c9580e3235a0a494bf851477f0f5652fbf2380bcc320f4d20927712fc2d03a0"
        ),
        .target(
            name: "DenoisePluginFilter",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                "RNNoise",
            ],
            path: "Sources",
            exclude: ["build_rnnoise.sh", "release"]
        ),
    ]
)
