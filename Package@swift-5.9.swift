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

            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.0/RNNoise.xcframework.zip",
            checksum: "561b87204ac6179ae0ffb64f6c34dd60086008006714ef0dba1ccf8a8135057b"
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
