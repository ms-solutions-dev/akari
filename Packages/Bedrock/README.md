# Bedrock

The ground under the app: everything a program needs that talks to a self-hosted server, and nothing that knows whether a book is open on top of it.

| File | Purpose |
|---|---|
| `CertificateTrust`, `CertificateQuestion` | Self-signed certificates: remember the fingerprint, ask when it changes |
| `SecureStore`, `KeyValueStore` | The keychain with four verbs, testable as a protocol |
| `Diagnostics`, `TraceRecorder`, `DiagnosticsID`, `DebugMode` | Network and flow trace, ring buffer, rolling files, a profile of the device |
| `CrashGuard`, `MemoryWatch` | Crash watch, memory level |
| `DeviceIdentity`, `DeviceName`, `ProgramID` | Who this device is, who this program is |
| `AccentPalette`, `Theme` | Accent colour from images, colour schemes with a contrast check |
| `ErrorImage` | One error, one sentence for the user, as a localisation key |
| `TransportSecurityRule` | The App Transport Security rules the way the system evaluates them |
| `Licenses` | Reads the licenses of third-party packages from the bundle |
| `BackgroundTime`, `LaunchQuiet` | Background time for work that must finish, and a quiet first second after launch |

**The test for every new file:** would a weather app for a home server need it too? If "book", "comic" or "audio" is in the name or in the first comment, it belongs in the app, not here.

## The second product: `CloudSync`

The CloudKit carrier for everything that belongs to a profile: **one zone per profile** in the private database, and through sharing in the shared database of another account.

| File | Purpose |
|---|---|
| `CloudService` | The protocol: account, zones, records, pushes, sharing, without a single `CKRecord` |
| `CloudKitService` | The implementation on CloudKit |
| `CloudMock` | The same seam without a network and without an account; all tests run against it |
| `ProfileZone` | A mirror with a queue: the app reads and writes at once, the trip to the server catches up; conflicts go through a merge rule per type |
| `CloudHub` | The one place that knows the container: account state, subscriptions, zone choice, sharing |
| `CloudRecord`, `LegacyData` | The record without CloudKit types; the takeover from the store that came before |

**A product of its own and not part of `Bedrock`**, because it links `CloudKit`: whoever needs only the ground should not have to compile the framework.

```swift
dependencies: [.package(path: "../Bedrock")]
.product(name: "CloudSync", package: "bedrock")
```

**`CloudKitService` has no default for the container** and none for the subscription prefix. That is deliberate: a default would mean that a program which forgets to set it writes silently into the container of another one. Every program names both itself.

## Tests

```sh
swift test --package-path Packages/Bedrock
```
