import Foundation
import Testing

@testable import BookReader

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(TermCache.CodingKeys.allCases.map(\.rawValue)) == [
                "glossar", "karten", "regeln", "verzeichnis",
            ])
        #expect(Set(TermCache.Card.CodingKeys.allCases.map(\.rawValue)) == ["orte", "pfad"])
        #expect(
            Set(Glossary.CodingKeys.allCases.map(\.rawValue)) == [
                "allgemein", "eintraege", "kapitel", "ueberschrift",
            ])
        #expect(
            Set(Glossary.Item.CodingKeys.allCases.map(\.rawValue)) == [
                "abschnitt", "begriff", "erklaerung", "formen", "typ",
            ])
        #expect(Set(TermIndex.Mention.CodingKeys.allCases.map(\.rawValue)) == ["begriff", "motto", "wort"])
        #expect(
            Set(TermIndex.Chapter.CodingKeys.allCases.map(\.rawValue)) == ["href", "nennungen", "woerter"])
    }

    @Test func rawValues() {
        #expect(Set(AaSheet.Marking.allCases.map(\.rawValue)) == ["aus", "deutlich", "sparsam"])
        #expect(
            Set(Glossary.Variant.allCases.map(\.rawValue)) == [
                "begriff", "gruppe", "ort", "person", "sache", "sprache", "zeit",
            ])
        #expect(Set(InBookView.Part.allCases.map(\.rawValue)) == ["begriffe", "karte", "orte", "personen"])
        #expect(
            Set(ReadingStyle.ReadingTheme.allCases.map(\.rawValue)) == [
                "automatisch", "dunkel", "hell", "nacht", "sepia",
            ])
        #expect(
            Set(ReadingStyle.TypographyChoice.allCases.map(\.rawValue)) == [
                "avenir", "charter", "georgia", "helvetica", "iowan", "palatino", "verlag",
            ])
        #expect(Set(ReadingStyle.ColumnChoice.allCases.map(\.rawValue)) == ["automatisch", "eine", "zwei"])
    }
}
