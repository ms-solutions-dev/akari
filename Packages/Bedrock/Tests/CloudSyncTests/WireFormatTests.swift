import Foundation
import Testing

@testable import CloudSync

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(FieldValue.CodingKeys.allCases.map(\.rawValue)) == [
                "daten", "kommazahl", "text", "wahrheit", "zahl", "zeit",
            ])
        #expect(Set(RecordName.CodingKeys.allCases.map(\.rawValue)) == ["name", "typ"])
        #expect(
            Set(CloudRecord.CodingKeys.allCases.map(\.rawValue)) == [
                "ersteller", "felder", "geaendert", "name", "serverzeit", "siegel", "typ", "verschluesselt",
            ])
    }

    @Test func rawValues() {
        #expect(ZoneRemoval(rawValue: "vomNutzer") != nil)
        #expect(ZoneRemoval(rawValue: "vonFern") != nil)
    }
}
