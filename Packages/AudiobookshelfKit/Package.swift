// swift-tools-version: 6.2
import PackageDescription

// Audiobookshelf: token, `mediaProgress`, chapters. In stage 1 only connected as a
// library (counts, covers, reading progress) — the player comes in stage 2.
//
// macOS is included so `swift test` answers in seconds on the desktop
// instead of running in the simulator every time.
let package = Package(
    name: "AudiobookshelfKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AudiobookshelfKit", targets: ["AudiobookshelfKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "AudiobookshelfKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "AudiobookshelfKitTests",
            dependencies: [
                "AudiobookshelfKit", .product(name: "SourcesKitMocks", package: "SourcesKit"),
            ],
            resources: [.copy("Fixtures")]),
    ]
)
