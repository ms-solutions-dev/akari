import Foundation
import Testing

@testable import PerformanceDiagnostics

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(Set(Event.CodingKeys.allCases.map(\.rawValue)) == ["art", "ort", "text", "zeit"])
    }

    @Test func rawValues() {
        #expect(
            Set(Event.Kind.allCases.map(\.rawValue)) == [
                "dauerlast", "haenger", "langeBilder", "last", "messung", "metrickit", "netz", "neuaufbau",
                "notiz", "ort", "ruckeln", "zug", "zustand",
            ])
    }
}
