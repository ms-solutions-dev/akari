// swift-tools-version: 6.2
import PackageDescription

// The fourth source: "On this device". EPUB, PDF and CBZ that arrive via AirDrop,
// Files or mail — and the package format `.akari` of its own (ZIP with
// file, `metadaten.json` and cover), which only this app understands. No network: the
// source reads and writes a folder under "Documents", the reading state lies next to it.
//
// macOS is included so that `swift test` answers in seconds on the Mac.
let package = Package(
    name: "Device",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Device", targets: ["Device"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "Device",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "DeviceTests",
            dependencies: ["Device", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
