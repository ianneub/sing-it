// swift-tools-version: 5.10
import PackageDescription

// The app's logic, free of UIKit/AVFoundation so it builds and tests on Linux too:
//   swift test --package-path ios/Packages/SingItCore
let package = Package(
    name: "SingItCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SingItCore", targets: ["SingItCore"])],
    targets: [
        .target(name: "SingItCore"),
        // Replays a recording through the analysis for tuning (see its usage text).
        .executableTarget(name: "singit-replay", dependencies: ["SingItCore"]),
        // Fixtures/ holds a made-up test hymn, read from disk by the tests.
        .testTarget(name: "SingItCoreTests", dependencies: ["SingItCore"], exclude: ["Fixtures"]),
    ]
)
