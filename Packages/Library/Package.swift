// swift-tools-version: 6.2
import PackageDescription

// The sum of the sources: kinds, genres, counters, "continue reading" from the youngest
// reading state of all sources, the "up next" rule (next volume of a started series).
// Offline from the cache. Knows no source by name — only the protocol.
//
// macOS is included so that `swift test` answers in seconds on the Mac
// instead of in the simulator every time.
let package = Package(
    name: "Library",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Library", targets: ["Library"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../ReadingProgress"),
    ],
    targets: [
        .target(
            name: "Library",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit", "ReadingProgress",
                .product(name: "CloudSync", package: "bedrock"),
            ]),
        .testTarget(
            name: "LibraryTests",
            dependencies: ["Library", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
