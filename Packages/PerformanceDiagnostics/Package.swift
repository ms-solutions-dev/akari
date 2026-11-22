// swift-tools-version: 6.2
import PackageDescription

// The performance diagnostics: hangs, jank, sustained load, rebuilds and the
// MetricKit reports — as a file to share. Without dependencies, so that every reader
// and the shell can report their place without knowing each other.
//
// macOS is included so that `swift test` runs on the Mac; the frame beat and MetricKit
// exist only on iOS.
let package = Package(
    name: "PerformanceDiagnostics",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PerformanceDiagnostics", targets: ["PerformanceDiagnostics"])
    ],
    targets: [
        .target(name: "PerformanceDiagnostics"),
        .testTarget(name: "PerformanceDiagnosticsTests", dependencies: ["PerformanceDiagnostics"]),
    ]
)
