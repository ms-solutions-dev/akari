// swift-tools-version: 6.2
import PackageDescription

// The server is the truth. The conflict rule "further wins, ask on a step back", the
// supplying of states after an interruption, and the shared model (fraction + timestamp as
// a wrapper around page, CFI or second).
//
// macOS is included so `swift test` answers in seconds on the Mac instead of going
// through the simulator every time.
let package = Package(
    name: "ReadingProgress",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ReadingProgress", targets: ["ReadingProgress"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "ReadingProgress",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit",
                .product(name: "CloudSync", package: "bedrock"),
            ]),
        .testTarget(name: "ReadingProgressTests", dependencies: ["ReadingProgress"]),
    ]
)
