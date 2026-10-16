// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "Kensho", targets: ["Kensho"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    // The core has no dependencies on purpose: the state machine, routing
    // rules and logging are pure Swift, so their tests run anywhere
    // `swift test` does, no device needed.
    .target(name: "Kensho"),
    .testTarget(name: "KenshoTests", dependencies: ["Kensho"]),
]

// The PrismCore adapter links FFmpeg xcframeworks, which exist only for
// Apple platforms. The manifest runs on the host, so on Linux (where the
// core's tests are run during development) the adapter is simply absent.
#if !os(Linux)
products.append(.library(name: "KenshoPrismCore", targets: ["KenshoPrismCore"]))
dependencies += [
    // Must match the requirement the app itself uses for PrismCore, or
    // SwiftPM reports two different requirements for one package.
    .package(url: "https://github.com/jpokorny312/PrismCore", branch: "main"),
    // Same requirement PrismCore declares, for the same reason.
    .package(url: "https://github.com/mpvkit/MPVKit.git", .upToNextMinor(from: "1.0.0")),
]
targets.append(
    .target(
        name: "KenshoPrismCore",
        dependencies: [
            "Kensho",
            .product(name: "PrismCore", package: "PrismCore"),
            .product(name: "MPVKit", package: "MPVKit"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "Kensho",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
