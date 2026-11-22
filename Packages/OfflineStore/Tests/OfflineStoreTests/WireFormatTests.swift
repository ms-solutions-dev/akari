import Foundation
import Testing

@testable import OfflineStore

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(KeptItem.CodingKeys.allCases.map(\.rawValue)) == [
                "art", "coverDatei", "dateien", "groesse", "kennung", "name", "seit", "stand", "titel",
            ])
        #expect(
            Set(KeptItem.Status.CodingKeys.allCases.map(\.rawValue)) == ["fertig", "gestoert", "laufend"])
    }

}
