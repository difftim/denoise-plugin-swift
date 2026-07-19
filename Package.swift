// swift-tools-version:5.7
// (Xcode14.0+)

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
            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.16/AudioPipeline.xcframework.zip",
            checksum: "9bfc616cf4d8ff1ec88c0aad8b3a1eda2b3f0c364eac7c472ab719c1ce62733c"
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
