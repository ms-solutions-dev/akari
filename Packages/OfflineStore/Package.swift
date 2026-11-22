// swift-tools-version: 6.2
import PackageDescription

// Not the stock package from CineLounge for the phone — there, queues are the main
// business. Here two concepts: the **cache** (invisible, ceiling, evicts by "last
// opened") and **keeping** (pinned, with badge, does not count against the ceiling).
// The word "download" does not appear. `NetworkLocation` says whether we are at home.
//
// macOS is included so that `swift test` answers in seconds on the machine instead of
// in the simulator every time.
let package = Package(
    name: "OfflineStore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OfflineStore", targets: ["OfflineStore"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../NetworkLocation"),
    ],
    targets: [
        .target(
            name: "OfflineStore",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"), "SourcesKit",
                .product(name: "NetworkLocation", package: "NetworkLocation"),
            ]),
        .testTarget(
            name: "OfflineStoreTests",
            dependencies: ["OfflineStore", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
