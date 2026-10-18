// swift-tools-version: 6.0
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

// The adapters need Apple frameworks (AVFoundation) and, for PrismCore, the
// FFmpeg xcframeworks, which exist only for Apple platforms. The manifest runs
// on the host, so on Linux (where the core's tests can run) they are simply absent.
#if !os(Linux)
products += [
    .library(name: "KenshoAVFoundation", targets: ["KenshoAVFoundation"]),
    .library(name: "KenshoPrismCore", targets: ["KenshoPrismCore"]),
]
dependencies += [
    // The SAME revision the app's Xcode project pins PrismCore to (SwiftPM
    // refuses two different requirements for one package). Bump both together;
    // Scripts/check_prismcore_pin.py checks that they agree.
    .package(url: "https://github.com/jpokorny312/PrismCore", revision: "5f3d331004fdff8e4e11e3b9fb599ab33fd13d94"),
    // Same requirement PrismCore declares, for the same reason.
    .package(url: "https://github.com/mpvkit/MPVKit.git", .upToNextMinor(from: "1.0.0")),
]
targets += [
    // What the players do with AVFoundation, without PrismCore: the diagnostics
    // of a served playlist and of an AVPlayerItem.
    .target(name: "KenshoAVFoundation", dependencies: ["Kensho"]),
    .testTarget(name: "KenshoAVFoundationTests", dependencies: ["KenshoAVFoundation", "Kensho"]),
    .target(
        name: "KenshoPrismCore",
        dependencies: [
            "Kensho",
            "KenshoAVFoundation",
            .product(name: "PrismCore", package: "PrismCore"),
            .product(name: "MPVKit", package: "MPVKit"),
        ]
    ),
]
#endif

let package = Package(
    name: "Kensho",
    platforms: [
        .iOS(.v16),
        // PrismCore asks for tvOS 17 (and the app's Apple TV target is built for it): a package that declares less than the package it uses is refused.
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets,
    // Swift 5 mode for every target, as PrismCore itself and the app are built: the C interop of the adapter is not ready for the strict checking of 6.
    swiftLanguageModes: [.v5]
)
