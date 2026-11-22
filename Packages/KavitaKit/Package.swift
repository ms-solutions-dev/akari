// swift-tools-version: 6.2
import PackageDescription

// Kavita 0.9.1: REST under `/api`, auth key as the `x-api-key` header instead of a password or
// JWT, pages individually via `/api/Reader/image`, EPUB as a file via `/api/Download/chapter`,
// reading state per chapter via `/api/Reader/progress`. Before this, Kavita only ran via
// OPDS (`OpdsKit`), without reading state in return. Test material is real responses from
// a Kavita instance under `KavitaKitTests/Fixtures`.
//
// macOS is included so `swift test` answers in seconds on the desktop
// instead of running in the simulator every time.
let package = Package(
    name: "KavitaKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KavitaKit", targets: ["KavitaKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "KavitaKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "KavitaKitTests",
            dependencies: ["KavitaKit", .product(name: "SourcesKitMocks", package: "SourcesKit")],
            resources: [.copy("Fixtures")]),
    ]
)
