import Foundation
import SourcesKit
import Testing

@testable import AccountsKit

/// Storage keys (UserDefaults, Keychain, App Group) keep their original, mostly German, spelling: installed apps
/// find their data under exactly these strings. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func profileKeys() {
        #expect(ProfileRegistry.listKey == "profile.liste")
        #expect(ProfileRegistry.activeKey == "profile.aktiv")
        #expect(Profile.prefix(3) == "profil.3.")
        #expect(ProfileStore.suite(2) == "dev.ms-solutions.akari.profil.2")
    }

    @Test func accountKeys() {
        #expect(AccountSlot(.komga).lookupKey == "konto.komga")
        #expect(AccountSlot(.opds, number: 2).lookupKey == "konto.opds.2")
    }

    @Test func setupCodeFields() {
        #expect(SetupCode.certificateKey == "zertifikat")
        #expect(SetupCode.personKey == "person")
        #expect(SetupCode.sharingKey == "freigabe")
        #expect(SetupCode.colorKey == "farbe")
    }
}
