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
            url: "https://github.com/difftim/denoise-plugin-swift/releases/download/1.0.13/AudioPipeline.xcframework.zip",
            checksum: "e371d287e1143bb75afade408a1358bdf35f13c875f7223ddd800208d1e28c09"
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
