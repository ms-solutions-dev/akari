import Foundation
import KomgaKit
import SourcesKit
import Testing

@testable import AccountsKit

/// Accounts and profiles are stored in the Keychain and in UserDefaults as JSON. The expected strings
/// were produced by the code as it was before the English rename.
@Suite struct PersistedFormatTests {
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000_000)

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func komgaAccount() throws {
        let account = Account.komga(
            KomgaAccount(
                server: URL(string: "https://comics.example")!, userId: "u1", email: "a@b.example",
                apiKey: "k", keyId: "kid", roles: ["PAGE_STREAMING"]))
        #expect(try json(account) == Golden.komga)
        #expect(try JSONDecoder().decode(Account.self, from: Data(Golden.komga.utf8)) == account)
    }

    @Test func profiles() throws {
        let profiles = Profile(
            id: 2, name: "Sam", color: "tinte", maxAge: 12, protected: true, created: stamp,
            cloud: nil, sharedBy: "alex@example.com", cloudSync: false)
        #expect(try json(profiles) == Golden.profiles)
        #expect(try JSONDecoder().decode(Profile.self, from: Data(Golden.profiles.utf8)) == profiles)
    }

    @Test func accountSlot() throws {
        #expect(try json(AccountSlot(.komga, number: 1)) == Golden.slot)
    }
}

private enum Golden {
    static let komga =
        #"{"komga":{"_0":{"email":"a@b.example","nutzerId":"u1","rollen":["PAGE_STREAMING"],"schluessel":"k","schluesselId":"kid","server":"https:\/\/comics.example"}}}"#
    static let profiles =
        #"{"angelegt":7000000,"farbe":"tinte","geschuetzt":true,"geteiltVon":"alex@example.com","hoechstalter":12,"id":2,"name":"Sam","wolkenabgleich":false}"#
    static let slot = #"{"anbieter":"komga","nummer":1}"#
}
