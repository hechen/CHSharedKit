// swift-tools-version: 6.1
import PackageDescription

// CHSharedKit 2.5.0 — on-device inference via Apple MLX.
//
// CHLocalLLM depends on Apple's reusable mlx-swift-lm libraries (which
// transitively pull mlx-swift) and Hugging Face's swift-transformers.
// Platform minimums match mlx-swift-lm's baseline. visionOS is included so
// VLM models can run on Apple Vision Pro.

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
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.3"
        ),
        // mlx-swift-lm 3.x decouples tokenization and downloads from the model
        // runtime. CHLocalLLM owns its Hugging Face integration directly, so
        // use the current transformer line rather than the legacy 1.0.x API.
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMinor(from: "1.3.0")
        ),
        // swift-transformers 1.3.3 still constructs Jinja objects with String
        // keys, while swift-jinja 2.4 requires ObjectKey. Keep this guard in
        // the shared package so every consumer resolves a buildable graph.
        .package(
            url: "https://github.com/huggingface/swift-jinja.git",
            exact: "2.3.5"
        ),
        // 2.7.0: MarkdownUI for chat-bubble rendering. MIT-licensed, ~one
        // additional dep (swift-cmark, transitively). Used by CHAIChatBubble.
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui",
            .upToNextMajor(from: "2.4.1")
        )
    ],
    targets: [
        .target(
            name: "CHSharedKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "CHLocalLLM",
            dependencies: [
                "CHSharedKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
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
