import Foundation
import Testing

@testable import Metadata

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(Set(AuthorLookup.Item.CodingKeys.allCases.map(\.rawValue)) == ["geholt", "profil"])
        #expect(
            Set(AuthorProfile.CodingKeys.allCases.map(\.rawValue)) == [
                "artikel", "bild", "geboren", "geholt", "gestorben", "kurz", "name", "sprache", "text",
            ])
        #expect(Set(LifeDate.CodingKeys.allCases.map(\.rawValue)) == ["jahr", "monat", "tag"])
    }

}
