import Foundation
import Testing

@testable import Library

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func rawValues() {
        #expect(
            Set(Facet.allCases.map(\.rawValue)) == ["autor", "format", "genre", "serie", "sprache", "verlag"])
        #expect(Set(ReadStatus.allCases.map(\.rawValue)) == ["angefangen", "gelesen", "ungelesen"])
        #expect(
            Set(Sorting.allCases.map(\.rawValue)) == [
                "autor", "bewertung", "reihe", "titel", "zuletztGelesen", "zuletztHinzugefuegt",
            ])
        #expect(
            Set(Filter.allCases.map(\.rawValue)) == [
                "angefangen", "behalten", "gelesen", "gemerkt", "ungelesen",
            ])
    }
}
