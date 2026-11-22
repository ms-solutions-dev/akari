// swift-tools-version: 6.2
import PackageDescription

// The design language "calm, librarian": serifs for titles, grotesque for text,
// hairlines, fixed digit width, paper. Four color themes (ink, terracotta, indigo, plum)
// as `ColorTheme` with light/dark pairs. The rules (Dynamic Type, tap targets)
// are standard; the building blocks are new.
//
// macOS is included so `swift test` answers in seconds on the Mac
// instead of using the simulator every time.
let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        .package(path: "../Bedrock")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: [
                .product(name: "Bedrock", package: "bedrock"),
                .product(name: "CloudSync", package: "bedrock"),
            ],
            resources: [.copy("Schriften"), .copy("Marke"), .copy("Wurm")]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
