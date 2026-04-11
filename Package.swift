// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CHSharedKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "CHSharedKit", targets: ["CHSharedKit"]),
        .library(name: "CHLocalLLM", targets: ["CHLocalLLM"])
    ],
    dependencies: [
        .package(url: "https://github.com/eastriverlee/LLM.swift", from: "1.0.0")
    ],
    targets: [
        .target(name: "CHSharedKit"),
        .target(
            name: "CHLocalLLM",
            dependencies: [
                "CHSharedKit",
                .product(name: "LLM", package: "LLM.swift")
            ],
            // LLM.swift targets Swift 5 concurrency model; relax in this target only
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "CHSharedKitTests", dependencies: ["CHSharedKit"])
    ]
)
