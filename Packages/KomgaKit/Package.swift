// swift-tools-version: 6.2
import PackageDescription

// Komga 1.26: REST v1/v2, the page stream (original size only, ~700 kB per page),
// `read-progress`, API key instead of a password. Test material is real responses from a
// Komga instance under `KomgaKitTests/Fixtures`.
//
// macOS is included so `swift test` answers in seconds on the desktop instead of
// running in the simulator every time.
let package = Package(
    name: "KomgaKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KomgaKit", targets: ["KomgaKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "KomgaKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "KomgaKitTests",
            dependencies: ["KomgaKit", .product(name: "SourcesKitMocks", package: "SourcesKit")],
            resources: [.copy("Fixtures")]),
    ]
)
