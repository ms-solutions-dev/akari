import Foundation
import Testing

@testable import Features

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func rawValues() {
        #expect(
            Set(ViewMode.allCases.map(\.rawValue)) == ["autoren", "regal", "reihen", "sammlungen", "titel"])
        #expect(
            Set(DisruptionProbe.allCases.map(\.rawValue)) == [
                "401", "502", "abs-aus", "alle-aus", "download", "grimmory-aus", "hoerbuch", "komga-aus",
                "konflikt", "langsam", "langsam-start", "seiten", "warteschlange", "zertifikat",
            ])
        #expect(Set(StartRow.allCases.map(\.rawValue)) == ["aus", "liegengeblieben", "neu", "sammlungen"])
    }
}
