// swift-tools-version: 6.2
import PackageDescription

// OPDS as a fifth source: 1.2 (Atom) and 2.0 (JSON) through one model. Catalog, covers, file,
// individual pages via OPDS-PSE (Atom: Komga, Kavita) or the Divina manifest (JSON: Komga v2),
// search via OpenSearch or the URI template. Reading state on the server only through the
// progression API (Komga v2, comics) — otherwise local. Test material is real feeds from a
// Komga server (v1.2 and v2) and a Grimmory server under `Tests/OpdsKitTests/Fixtures`.
//
// macOS is included so that `swift test` answers in seconds on the desktop
let package = Package(
    name: "OpdsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OpdsKit", targets: ["OpdsKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "OpdsKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "OpdsKitTests",
            dependencies: ["OpdsKit", .product(name: "SourcesKitMocks", package: "SourcesKit")],
            resources: [.copy("Fixtures")]),
    ]
)
