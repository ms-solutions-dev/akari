// swift-tools-version: 6.2
import PackageDescription

// The accounts (three servers, plus OPDS, WebDAV and Kavita): sign in, keep in the
// keychain, know their state, build the sources from them. The one package that knows
// the kits by name — so `Library` and the screens do not have to. Plus the setup code
// (QR) and the translation of server refusals into the four speaking sign-in errors.
//
// macOS is included so that `swift test` answers in seconds on the machine instead of
// in the simulator every time.
let package = Package(
    name: "AccountsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AccountsKit", targets: ["AccountsKit"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../KomgaKit"),
        .package(path: "../GrimmoryKit"),
        .package(path: "../AudiobookshelfKit"),
        .package(path: "../KavitaKit"),
        .package(path: "../OpdsKit"),
        .package(path: "../WebdavKit"),
    ],
    targets: [
        .target(
            name: "AccountsKit",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit", "KomgaKit", "GrimmoryKit",
                "AudiobookshelfKit", "KavitaKit", "OpdsKit", "WebdavKit",
                .product(name: "CloudSync", package: "bedrock"),
            ]),
        .testTarget(
            name: "AccountsKitTests",
            dependencies: [
                "AccountsKit", .product(name: "SourcesKitMocks", package: "SourcesKit"), "KomgaKit",
                "GrimmoryKit",
                "AudiobookshelfKit",
            ],
            resources: [.copy("Fixtures")]),
    ]
)
