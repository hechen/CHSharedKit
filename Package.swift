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
    dependencies: [],
    targets: [
        .target(name: "CHSharedKit"),
        .target(
            name: "CHLocalLLM",
            dependencies: ["CHSharedKit"]
        ),
        .testTarget(name: "CHSharedKitTests", dependencies: ["CHSharedKit"])
    ]
)
