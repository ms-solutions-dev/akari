// swift-tools-version: 6.2
import PackageDescription

// The own image viewer for the Komga page stream: preload +-3 pages,
// right-to-left as default, double spread on iPad in landscape with landscape-image detection, always black,
// HUD gone after 3 s. No Readium - its CBZ navigator is deprecated and reads files,
// not streams.
//
// macOS is included so `swift test` answers in seconds on the Mac
// instead of using the simulator every time.
let package = Package(
    name: "ComicReader",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ComicReader", targets: ["ComicReader"])
    ],
    dependencies: [
        .package(path: "../PerformanceDiagnostics"),
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "ComicReader",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit", "DesignSystem",
                "PerformanceDiagnostics",
            ]),
        .testTarget(
            name: "ComicReaderTests",
            dependencies: ["ComicReader", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
