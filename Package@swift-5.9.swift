// swift-tools-version:5.9
// (Xcode15.0+)

import PackageDescription

let package = Package(
    name: "AudioPipelineProcessor",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "AudioPipelineProcessor",
            targets: ["AudioPipelineProcessor"]
        ),
        .library(
            name: "DenoisePluginFilter",
            targets: ["AudioPipelineProcessor"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/difftim/client-sdk-swift.git", from: "2.12.1"),
    ],
    targets: [
        .binaryTarget(
            name: "AudioPipeline",
            // path: "libs_audio_pipeline/AudioPipeline.xcframework"

            // for remote release:
            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.15/AudioPipeline.xcframework.zip",
            checksum: "3f5cd7fc0bfd5e6e4cd7c3d3fd582dc650130ec8c1cca1b8b47ffaea53ff258d"
        ),
        .target(
            name: "AudioPipelineProcessor",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                "AudioPipeline",
            ],
            path: "Sources/AudioPipelineProcessor"
        ),
    ]
)
