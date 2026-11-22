// swift-tools-version: 6.2
import PackageDescription

// Readium Swift Toolkit 3.11 (BSD-3) for EPUB (reflowable and fixed) and PDF. The
// UIKit navigator comes via a representable; reading themes Light, Sepia, Dark and the size control
// are independent of the app theme. The position locator becomes the `ReadingState`.
//
// **iOS only.** Readium does not declare macOS; hence this package is checked against the
// simulator and not with `swift test` on the Mac like the others.
//
let package = Package(
    name: "BookReader",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "BookReader", targets: ["BookReader"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../DesignSystem"),
        .package(path: "../PerformanceDiagnostics"),
        .package(url: "https://github.com/readium/swift-toolkit.git", exact: "3.11.0"),
        // Only for the test target: the parity check with the gold-standard books reads EPUBs via ZIP like
        // the reference (Readium's fork, already resolved anyway). Does not go into the app.
        .package(url: "https://github.com/readium/ZIPFoundation.git", from: "3.0.1"),
    ],
    targets: [
        .target(
            name: "BookReader",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit", "DesignSystem",
                "PerformanceDiagnostics",
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
            ]),
        .testTarget(
            name: "BookReaderTests",
            dependencies: [
                "BookReader", .product(name: "SourcesKitMocks", package: "SourcesKit"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]),
    ]
)
