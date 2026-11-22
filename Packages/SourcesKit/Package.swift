// swift-tools-version: 6.2
import PackageDescription

// The slot: the `Source` protocol, `Capabilities`, `Title`, `ReadingState`,
// `ContentSource`. No network, no SwiftUI — what lives here must be testable without a server.
// Every source (Komga, Grimmory, Audiobookshelf, later the local one) fulfils this protocol,
// and everything above it (`Library`, `ReadingProgress`, the readers) knows only this protocol.
//
// `SourcesKitMocks` is a second product, not part of the test target: the mock sources
// are also needed by `Library` and `Features` in their tests, and a test target cannot
// supply another package. The app itself never links it.
//
// macOS is included so that `swift test` answers in seconds on the computer
// instead of going through the simulator every time.
let package = Package(
    name: "SourcesKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SourcesKit", targets: ["SourcesKit"]),
        .library(name: "SourcesKitMocks", targets: ["SourcesKitMocks"]),
    ],
    dependencies: [
        .package(path: "../Bedrock")
    ],
    targets: [
        .target(name: "SourcesKit", dependencies: [.product(name: "Bedrock", package: "bedrock")]),
        .target(name: "SourcesKitMocks", dependencies: ["SourcesKit"]),
        .testTarget(name: "SourcesKitTests", dependencies: ["SourcesKit", "SourcesKitMocks"]),
    ]
)
