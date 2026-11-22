import Foundation
import Testing

@testable import Bedrock

/// The device identifier is the bracket around everything the server keeps about
/// this device: sign-in, sessions, running encodings. Two identifiers side by
/// side are therefore no cosmetic flaw: the server then clears encodings that
/// belong to "another device", and playback runs into a 404.
@Suite("Device identifier")
struct DeviceIdentityTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "device-identity-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("The first query creates an identifier and stores it")
    func firstAskPersists() {
        // Exactly this was missing at app launch: it rolled an identifier without
        // storing it; on the next run there was the next one, and the server listed the
        // television several times.
        let defaults = freshDefaults()

        let first = DeviceIdentity.id(in: defaults)

        #expect(!first.isEmpty)
        #expect(defaults.string(forKey: DeviceIdentity.storageKey) == first)
    }

    @Test("Every further query returns the same identifier")
    func laterAsksAgree() {
        // Sign-in and app launch both ask. If they got different ones, the playback
        // session would hang on a device the sign-in has never seen.
        let defaults = freshDefaults()

        let first = DeviceIdentity.id(in: defaults)
        let second = DeviceIdentity.id(in: defaults)

        #expect(first == second)
    }

    @Test("An already stored identifier is left untouched")
    func storedIdentitySurvives() {
        let defaults = freshDefaults()
        defaults.set("bestand", forKey: DeviceIdentity.storageKey)

        #expect(DeviceIdentity.id(in: defaults) == "bestand")
    }
}
