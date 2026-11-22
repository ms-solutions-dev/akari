import Foundation
import Testing

@testable import NetworkLocation

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func rawValues() {
        #expect(
            Set(NetworkPath.Kind.allCases.map(\.rawValue)) == [
                "anderes", "kabel", "keines", "mobilfunk", "wlan",
            ])
        #expect(
            Set(LocationStatement.Place.allCases.map(\.rawValue)) == [
                "bibliothek", "live", "portale", "quellblatt", "suche",
            ])
        #expect(Set(LocationStatement.Source.allCases.map(\.rawValue)) == ["jellyfin", "portale", "xtream"])
        #expect(LocationStatement.Location(rawValue: "daheim") != nil)
        #expect(LocationStatement.Location(rawValue: "unterwegs") != nil)
        #expect(LocationStatement.Location(rawValue: "unbekannt") != nil)
    }
}
