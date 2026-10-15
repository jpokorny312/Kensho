// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Kensho",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "Kensho", targets: ["Kensho"]),
    ],
    targets: [
        // The core has no dependencies on purpose: the state machine is pure
        // Swift, so its tests run anywhere `swift test` does, no device needed.
        // The PrismCore / AVPlayer adapters arrive as separate targets.
        .target(name: "Kensho"),
        .testTarget(name: "KenshoTests", dependencies: ["Kensho"]),
    ]
)
