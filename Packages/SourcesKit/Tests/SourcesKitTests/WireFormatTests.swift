import Foundation
import Testing

@testable import SourcesKit

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(Set(Chapter.CodingKeys.allCases.map(\.rawValue)) == ["beginn", "ende", "name"])
        #expect(Set(PageSize.CodingKeys.allCases.map(\.rawValue)) == ["breite", "hoehe"])
        #expect(
            Set(AudioTrack.CodingKeys.allCases.map(\.rawValue)) == [
                "adresse", "beginn", "dauer", "endung", "groesse",
            ])
        #expect(Set(AudioManifest.CodingKeys.allCases.map(\.rawValue)) == ["dauer", "kapitel", "spuren"])
        #expect(
            Set(ReadingState.CodingKeys.allCases.map(\.rawValue)) == [
                "abgeschlossen", "geraet", "position", "zeitstempel",
            ])
        #expect(
            Set(ReadingState.Position.CodingKeys.allCases.map(\.rawValue)) == [
                "anteil", "position", "seite", "sekunde",
            ])
        #expect(Set(SourceID.CodingKeys.allCases.map(\.rawValue)) == ["anbieter", "server"])
        #expect(Set(TitleID.CodingKeys.allCases.map(\.rawValue)) == ["id", "quelle"])
        #expect(Set(SeriesID.CodingKeys.allCases.map(\.rawValue)) == ["id", "quelle"])
        #expect(Set(SaveTarget.CodingKeys.allCases.map(\.rawValue)) == ["serie", "titel"])
        #expect(Set(CollectionID.CodingKeys.allCases.map(\.rawValue)) == ["id", "quelle"])
        #expect(
            Set(TitleCollection.CodingKeys.allCases.map(\.rawValue)) == [
                "bearbeitbar", "eintraege", "geordnet", "gestalt", "kennung", "name", "privat", "symbol",
            ])
        #expect(Set(Scope.CodingKeys.allCases.map(\.rawValue)) == ["dauer", "seiten", "unbekannt"])
        #expect(Set(Rating.CodingKeys.allCases.map(\.rawValue)) == ["herkunft", "sterne", "stimmen"])
        #expect(Set(SeriesReference.CodingKeys.allCases.map(\.rawValue)) == ["band", "kennung", "name"])
        #expect(
            Set(Title.CodingKeys.allCases.map(\.rawValue)) == [
                "altersfreigabe", "art", "autoren", "bewertung", "cover", "erschienen", "format", "genres",
                "groesse", "hinzugefuegt", "kapitel", "kennung", "leserichtung", "name", "serie", "sprache",
                "sprecher", "umfang", "untertitel", "verlag", "zusammenfassung",
            ])
        #expect(
            Set(Series.CodingKeys.allCases.map(\.rawValue)) == [
                "altersfreigabe", "anzahlBaende", "art", "autoren", "bewertung", "cover", "genres", "gesamt",
                "hinzugefuegt", "kennung", "leserichtung", "name", "sprache", "status", "zeichner",
                "zusammenfassung",
            ])
        #expect(
            Set(AuthorReference.CodingKeys.allCases.map(\.rawValue)) == [
                "anzahl", "bild", "kennung", "name", "quelle",
            ])
    }

    @Test func rawValues() {
        #expect(
            Set(Provider.allCases.map(\.rawValue)) == [
                "audiobookshelf", "geraet", "grimmory", "kavita", "komga", "opds", "webdav",
            ])
        #expect(TitleCollection.CollectionKind(rawValue: "regal") != nil)
        #expect(TitleCollection.CollectionKind(rawValue: "sammlung") != nil)
        #expect(TitleCollection.CollectionKind(rawValue: "leseliste") != nil)
        #expect(Set(Kind.allCases.map(\.rawValue)) == ["buch", "hoerbuch", "manga", "podcast"])
        #expect(ReadingDirection(rawValue: "linksNachRechts") != nil)
        #expect(ReadingDirection(rawValue: "rechtsNachLinks") != nil)
        #expect(ReadingDirection(rawValue: "vertikal") != nil)
        #expect(SeriesStatus(rawValue: "laufend") != nil)
        #expect(SeriesStatus(rawValue: "abgeschlossen") != nil)
        #expect(SeriesStatus(rawValue: "abgebrochen") != nil)
        #expect(SeriesStatus(rawValue: "pausiert") != nil)
    }
}
