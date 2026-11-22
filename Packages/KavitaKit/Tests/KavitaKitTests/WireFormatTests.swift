import Foundation
import Testing

@testable import KavitaKit

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(KavitaMapping.ChapterReference.CodingKeys.allCases.map(\.rawValue)) == [
                "epub", "libraryId", "seiten", "seriesId", "volumeId",
            ])
        #expect(
            Set(KavitaAccount.CodingKeys.allCases.map(\.rawValue)) == [
                "benutzername", "nutzerId", "rollen", "schluessel", "schluesselId", "server",
            ])
        #expect(Set(KavitaSource.SeriesMarker.CodingKeys.allCases.map(\.rawValue)) == ["bezuege", "marke"])
        #expect(Set(KavitaSource.MarkerNote.CodingKeys.allCases.map(\.rawValue)) == ["serien", "stand"])
    }

}
