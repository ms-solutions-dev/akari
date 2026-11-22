// swift-tools-version: 6.0
import PackageDescription

// Where the phone currently is: Wi-Fi, cellular, tunnel, nothing at all.
//
// The tvOS app does not have this package, and that is no oversight: an Apple TV sits on
// a cable. The phone changes networks in the middle of a film, and five different things
// hang off that: the location line ("what this source can do on the go"), the offline
// store rule "Wi-Fi only", the suggested resolution, the playback target (on the go
// "Apple TV" silently falls back to the phone) and the `cellular` state.
//
// Without this package the app does not know whether it is on Wi-Fi, and a measured
// bandwidth tied to a clock rather than to the path is wrong for a device that leaves
// the house.
let package = Package(
    name: "NetworkLocation",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NetworkLocation", targets: ["NetworkLocation"])],
    // **Depends on nothing:** a dependency on `Core` used to stand here without any file
    // using it (no `import` in the whole target). Removed, so the reading app can include
    // the package by path without pulling in video code.
    targets: [
        .target(name: "NetworkLocation"),
        .testTarget(name: "NetworkLocationTests", dependencies: ["NetworkLocation"]),
    ]
)
