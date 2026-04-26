// swift-tools-version: 6.0
import PackageDescription

// CHSharedKit 2.5.0 — on-device inference via Apple MLX.
//
// CHLocalLLM depends on Apple's mlx-swift-examples (which transitively pulls
// mlx-swift) and Hugging Face's swift-transformers. Platform minimums match
// mlx-swift-examples' baseline (macOS 14, iOS 16). visionOS is added so VLM
// models can run on Apple Vision Pro.

let package = Package(
    name: "CHSharedKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "CHSharedKit", targets: ["CHSharedKit"]),
        .library(name: "CHLocalLLM", targets: ["CHLocalLLM"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-examples",
            exact: "2.29.1"
        ),
        // mlx-swift-examples@2.29.1 pins swift-transformers transitively to
        // upToNextMinor(from: "1.0.0"); we declare the same range here so the
        // CHLocalLLM target can `import Hub` and `import Tokenizers` directly
        // without relying on the transitive product surface.
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMinor(from: "1.0.0")
        )
    ],
    targets: [
        .target(name: "CHSharedKit"),
        .target(
            name: "CHLocalLLM",
            dependencies: [
                "CHSharedKit",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXVLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .testTarget(name: "CHSharedKitTests", dependencies: ["CHSharedKit", "CHLocalLLM"]),
        // Manual smoke test for verifying real on-device inference.
        // Run with: `swift run mlx-smoke "your prompt"` — downloads
        // Qwen2.5-3B-Instruct-4bit on first run (~1.7 GB) and prints
        // streamed tokens. Apple Silicon required.
        .executableTarget(
            name: "mlx-smoke",
            dependencies: ["CHLocalLLM"],
            path: "Tools/SmokeTest"
        )
    ]
)
