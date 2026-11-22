// swift-tools-version: 6.2
import PackageDescription

// What app and widget have to know in common — and nothing else: the shape of the
// "Continue reading" snapshot, the folder in the app group, the file names of the
// covers. Foundation only, no Bedrock, no SourcesKit: the widget extension
// pulls in this one package and stays small — every byte in the widget process counts
// against its memory cap, and every package behind it would be a second build.
//
// macOS is included so `swift test` answers in seconds on the desktop
// instead of running in the simulator every time.
let package = Package(
    name: "WidgetBridge",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "WidgetBridge", targets: ["WidgetBridge"])
    ],
    targets: [
        .target(name: "WidgetBridge"),
        .testTarget(name: "WidgetBridgeTests", dependencies: ["WidgetBridge"]),
    ]
)
