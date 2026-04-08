// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CHSharedKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "CHSharedKit", targets: ["CHSharedKit"])
    ],
    targets: [
        .target(name: "CHSharedKit"),
        .testTarget(name: "CHSharedKitTests", dependencies: ["CHSharedKit"])
    ]
)
