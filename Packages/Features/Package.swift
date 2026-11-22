// swift-tools-version: 6.2
import PackageDescription

// The app's screens, one folder per area: Start, Library, Search, Account, Series, Title,
// Saved, Storage. Everything visible lives here; everything testable without UI lives in
// the packages below.
//
// `BookReader` is deliberately NOT a dependency: Readium supports iOS only, and pulling it
// in would break `swift test` on the Mac. The shell knows the book reader only as a slot
// (`ReaderFactory` in the environment), and the app target plugs `BookReader` in.
// `ComicReader` supports macOS and is linked directly.
//
// macOS is included so `swift test` runs in seconds instead of needing a simulator.
let package = Package(
    name: "Features",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Features", targets: ["Features"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../NetworkLocation"),
        .package(path: "../SourcesKit"),
        .package(path: "../KomgaKit"),
        .package(path: "../GrimmoryKit"),
        .package(path: "../AudiobookshelfKit"),
        .package(path: "../AccountsKit"),
        .package(path: "../Library"),
        .package(path: "../OfflineStore"),
        .package(path: "../ReadingProgress"),
        .package(path: "../Metadata"),
        .package(path: "../ComicReader"),
        .package(path: "../AudioPlayer"),
        .package(path: "../Device"),
        .package(path: "../DesignSystem"),
        .package(path: "../WidgetBridge"),
        .package(path: "../PerformanceDiagnostics"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"),
                .product(name: "NetworkLocation", package: "NetworkLocation"), "SourcesKit", "KomgaKit",
                "GrimmoryKit",
                "AudiobookshelfKit", "AccountsKit", "Library", "OfflineStore", "ReadingProgress", "Metadata",
                "ComicReader",
                "AudioPlayer", "Device", "DesignSystem", "WidgetBridge", "PerformanceDiagnostics",
                .product(name: "CloudSync", package: "bedrock"),
                .product(name: "SourcesKitMocks", package: "SourcesKit"),
            ],
            // Bundled sample shelf: freely licensed books; the covers of the preview data
            // (public domain or CC BY, see `SampleCovers/LICENSES.md`).
            resources: [.copy("Beispiele"), .copy("SampleCovers"), .copy("MockContent")]),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
