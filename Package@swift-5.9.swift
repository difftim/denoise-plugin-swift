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
        .package(url: "https://github.com/difftim/client-sdk-swift.git", from: "2.6.1-a2"),
    ],
    targets: [
        .binaryTarget(
            name: "RNNoise",
            
            // for local
            // path: "libs/RNNoise.xcframework"

            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.7/RNNoise.xcframework.zip",
            checksum: "6cc46b124fbc7a091e8ba8dcc02023d1a0742356ef68c3e197df71f08385a50b"
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
