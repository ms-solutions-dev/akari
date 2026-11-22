import Foundation
import Testing

@testable import WebdavKit

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(Backfill.Finding.CodingKeys.allCases.map(\.rawValue)) == [
                "autoren", "band", "cover", "etag", "groesse", "keineBereiche", "name", "reihe", "seiten",
                "sprache", "stand", "vergeblich", "verlag", "zusammenfassung",
            ])
        #expect(
            Set(WebdavAccount.CodingKeys.allCases.map(\.rawValue)) == [
                "benutzername", "ordner", "passwort", "titel",
            ])
    }

}
