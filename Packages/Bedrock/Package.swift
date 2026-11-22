// swift-tools-version: 6.0
import PackageDescription

// The foundation under all programs: certificates, keychain, diagnostics, crash
// guard, device identifier, color palette. None of it knows whether a film is
// playing above it or a book is open.
//
// **Why a package of its own:** the reading app needs exactly these files and
// nothing of the rest, which consists to 90 % of picture and sound and brings
// two C targets. Copying would have produced two diverged versions within a
// month; depending on the whole thing would mean compiling 30,000 lines of
// video code on every build.
//
// **The touchstone for every file here:** would a weather app need it too? If
// "picture", "sound" or "channel" appears in its name or its first comment, it
// does not belong here.
//
// No third-party dependencies, no network, no SwiftUI.
//
// **`CloudSync` is the second product:** the CloudKit carrier for everything
// profile-related: one zone per profile in the private database, shared into
// the shared database of another account. It meets the same touchstone: it knows
// no session, no bookmarks and no channel, only records with fields, zones,
// change tokens, queue and sharing.
//
// **A product of its own and not part of `Bedrock`**, because it links
// `CloudKit`: whoever needs only the foundation should not compile this
// framework along.
let package = Package(
    name: "Bedrock",
    // macOS for `swift test` on the computer; iOS for phone and reading app.
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Bedrock", targets: ["Bedrock"]),
        .library(name: "CloudSync", targets: ["CloudSync"]),
    ],
    targets: [
        .target(name: "Bedrock"),
        .testTarget(name: "BedrockTests", dependencies: ["Bedrock"]),
        .target(name: "CloudSync", dependencies: ["Bedrock"]),
        .testTarget(name: "CloudSyncTests", dependencies: ["CloudSync"]),
    ]
)
