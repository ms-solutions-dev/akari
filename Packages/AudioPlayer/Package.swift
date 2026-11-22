// swift-tools-version: 6.2
import PackageDescription

// The audiobook player: AVQueuePlayer over the tracks from Audiobookshelf, a
// loopback bridge because AVPlayer does not trust the home certificate, lock screen,
// headphone buttons, smart rewind, sleep timer, mini player. No CarPlay (entitlement).
//
// macOS is included so `swift test` answers in seconds on the Mac -
// the bridge and the rules are testable there; the audio session only exists on iOS.
let package = Package(
    name: "AudioPlayer",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AudioPlayer", targets: ["AudioPlayer"])
    ],
    dependencies: [
        .package(path: "../Bedrock"),
        .package(path: "../SourcesKit"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "AudioPlayer",
            dependencies: [.product(name: "Bedrock", package: "bedrock"), "SourcesKit", "DesignSystem"]),
        .testTarget(
            name: "AudioPlayerTests",
            dependencies: ["AudioPlayer", .product(name: "SourcesKitMocks", package: "SourcesKit")]),
    ]
)
