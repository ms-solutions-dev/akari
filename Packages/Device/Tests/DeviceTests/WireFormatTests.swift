import Foundation
import Testing

@testable import Device

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(PackageMetadata.CodingKeys.allCases.map(\.rawValue)) == [
                "art", "autoren", "cover", "datei", "erstellt", "genres", "herkunft", "name", "reihe",
                "seiten", "sprache", "untertitel", "verlag", "version", "zusammenfassung",
            ])
        #expect(Set(PackageMetadata.BookSeries.CodingKeys.allCases.map(\.rawValue)) == ["band", "name"])
        #expect(
            Set(PackageMetadata.Origin.CodingKeys.allCases.map(\.rawValue)) == ["anbieter", "id", "server"])
        #expect(
            Set(Zip.Item.CodingKeys.allCases.map(\.rawValue)) == [
                "gepackt", "groesse", "kopfLaenge", "methode", "name", "versatz",
            ])
        #expect(Set(Zip.Remote.CodingKeys.allCases.map(\.rawValue)) == ["eintraege", "groesse"])
    }

}
