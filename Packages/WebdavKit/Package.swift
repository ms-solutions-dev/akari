// swift-tools-version: 6.2
import PackageDescription

// A WebDAV folder as a source: Nextcloud, ownCloud, any server with PROPFIND. EPUB, PDF, CBZ
// and CBR files in it become titles — name, author and series from the path (Calibre scheme
// "Author/Title"), cover and OPF per range fetch from the file without fetching all of it
// (`Zip.Remote` from Device). No server reading state — it stays local (`StateStore` from
// SourcesKit). Test material under `Tests/WebdavKitTests/Fixtures`.
//
// macOS is included so that `swift test` answers in seconds on the desktop
let package = Package(
    name: "WebdavKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "WebdavKit", targets: ["WebdavKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../Device"),
    ],
    targets: [
        .target(
            name: "WebdavKit",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit", "Device"]),
        .testTarget(
            name: "WebdavKitTests",
            dependencies: [
                "WebdavKit", .product(name: "SourcesKitMocks", package: "SourcesKit"), "Device",
            ],
            resources: [.copy("Fixtures")]),
    ]
)
