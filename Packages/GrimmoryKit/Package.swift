// swift-tools-version: 6.2
import PackageDescription

// Grimmory 3.4.1 (BookLore successor): JWT with refresh, `/api/v1/app/...`, content via
// `/content` with Range — NOT `/download`, which accounts without `canDownload` may not use.
// The contract is the source of the `develop` branch, because the OpenAPI endpoint does not answer
// despite `API_DOCS_ENABLED`. Amazon's category noise ("Audiobook" on 188 e-books) is mapped away here,
// not on the server.
//
// macOS is included so that `swift test` answers in seconds on the desktop instead of
// in the simulator every time.
let package = Package(
    name: "GrimmoryKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GrimmoryKit", targets: ["GrimmoryKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
    ],
    targets: [
        .target(
            name: "GrimmoryKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit"]),
        .testTarget(
            name: "GrimmoryKitTests",
            dependencies: ["GrimmoryKit", .product(name: "SourcesKitMocks", package: "SourcesKit")],
            resources: [.copy("Fixtures")]),
    ]
)
