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
        .package(url: "https://github.com/difftim/client-sdk-swift.git", from: "2.10.2-a9"),
    ],
    targets: [
        .binaryTarget(
            name: "AudioPipeline",
            // path: "libs_audio_pipeline/AudioPipeline.xcframework"

            // for remote release:
            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.10/AudioPipeline.xcframework.zip",
            checksum: "ea0a449e6c2f3a6692ae35ba9e1a2c667957bc9b06a48255ef814e6d7e1f3b54"
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
