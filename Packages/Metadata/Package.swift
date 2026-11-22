// swift-tools-version: 6.2
import PackageDescription

// What the server does not deliver: the author lookup (picture, life dates and a
// paragraph from Wikipedia/Wikidata), only if the user switches it on. Nothing else:
// komf, Grimmory's sync and Audible fill in on the server whatever the app shows.
//
// macOS is included so `swift test` answers in seconds on the Mac instead of going
// through the simulator every time.
let package = Package(
    name: "Metadata",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Metadata", targets: ["Metadata"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "Metadata",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "MetadataTests",
            dependencies: [
                "Metadata", .product(name: "SourcesKitMocks", package: "SourcesKit"),
            ],
            resources: [.copy("Fixtures")]),
    ]
)
