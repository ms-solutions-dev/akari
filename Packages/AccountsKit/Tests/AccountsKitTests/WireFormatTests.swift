import Foundation
import Testing

@testable import AccountsKit

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(Set(AccountEntry.CodingKeys.allCases.map(\.rawValue)) == ["erstellt", "geraet", "konto"])
        #expect(Set(AccountSlot.CodingKeys.allCases.map(\.rawValue)) == ["anbieter", "nummer"])
        #expect(
            Set(Profile.CodingKeys.allCases.map(\.rawValue)) == [
                "angelegt", "farbe", "geschuetzt", "geteiltVon", "hoechstalter", "id", "name", "wolke",
                "wolkenabgleich",
            ])
    }

}
