import Foundation
import Testing

@testable import ReadingProgress

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(ReadingSession.CodingKeys.allCases.map(\.rawValue)) == [
                "abgeschlossen", "anteil", "art", "beginn", "ende", "id", "kennung", "lesezeit", "name",
                "seiten",
            ])
        #expect(Set(Pending.CodingKeys.allCases.map(\.rawValue)) == ["kennung", "seit", "stand"])
    }

}
