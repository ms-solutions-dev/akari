import Foundation
import Testing

@testable import WidgetBridge

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(ReadingStatisticsSnapshot.CodingKeys.allCases.map(\.rawValue)) == [
                "beendetJahr", "beendetMonat", "geschrieben", "liegengeblieben", "mehrereProfile", "profil",
                "tage",
            ])
        #expect(
            Set(ReadingStatisticsSnapshot.Day.CodingKeys.allCases.map(\.rawValue)) == [
                "buch", "datum", "hoerbuch", "manga", "seiten",
            ])
        #expect(
            Set(ContinueListeningSnapshot.CodingKeys.allCases.map(\.rawValue)) == [
                "geschrieben", "hoerbuch", "mehrereProfile", "profil",
            ])
        #expect(
            Set(ContinueListeningSnapshot.Audiobook.CodingKeys.allCases.map(\.rawValue)) == [
                "cover", "dauer", "id", "kapitel", "laeuft", "link", "name", "tempo", "unterzeile", "zeit",
            ])
        #expect(
            Set(ContinueReadingSnapshot.CodingKeys.allCases.map(\.rawValue)) == [
                "eintraege", "geschrieben", "mehrereProfile", "profil",
            ])
        #expect(
            Set(ContinueReadingSnapshot.Item.CodingKeys.allCases.map(\.rawValue)) == [
                "anteil", "art", "cover", "id", "link", "name", "stand", "unterzeile",
            ])
    }

    @Test func rawValues() {
        #expect(ContinueReadingSnapshot.Kind(rawValue: "manga") != nil)
        #expect(ContinueReadingSnapshot.Kind(rawValue: "buch") != nil)
        #expect(ContinueReadingSnapshot.Kind(rawValue: "hoerbuch") != nil)
        #expect(ContinueReadingSnapshot.Kind(rawValue: "podcast") != nil)
    }
}
