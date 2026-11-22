import Foundation
import Testing

@testable import SourcesKit

@Suite("Model")
struct ModelTests {
    let komga = SourceID(provider: .komga, server: "comics.example")

    @Test("Two servers of the same provider are two sources")
    func identifiers() {
        let second = SourceID(provider: .komga, server: "comics2.example")
        #expect(komga != second)
        #expect(TitleID(source: komga, id: "7") != TitleID(source: second, id: "7"))
        #expect("\(TitleID(source: komga, id: "7"))" == "komga@comics.example/7")
    }

    @Test("All capabilities are eight, and they survive JSON")
    func capabilities() throws {
        #expect(Capabilities.all.rawValue == 0b1111_1111)
        let robin: Capabilities = [.seriesList, .rating, .savedList]
        #expect(!robin.contains(.keep))
        let data = try JSONEncoder().encode(robin)
        #expect(try JSONDecoder().decode(Capabilities.self, from: data) == robin)
    }

    @Test("A rating stays between zero and five stars")
    func rating() {
        #expect(Rating(stars: 8.4, origin: "Komga").stars == 5)
        #expect(Rating(stars: -1, origin: "Komga").stars == 0)
        #expect(Rating(stars: 4.2, voices: 41_200, origin: "Goodreads").voices == 41_200)
    }

    @Test("An extract with series, title and reading state survives JSON")
    func extractCodable() throws {
        let bookSeries = SeriesID(source: komga, id: "s1")
        let volume = Title(
            identifier: TitleID(source: komga, id: "b1"), kind: .manga, name: "Band 47",
            series: SeriesReference(identifier: bookSeries, name: "Reihe", volume: 47), genres: ["Fantasy"],
            scope: .pages(205), ageRating: 12, added: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let extract = LibraryExtract(
            source: komga,
            seriesList: [Series(identifier: bookSeries, kind: .manga, name: "Reihe", volumeCount: 48)],
            title: [volume],
            readingStates: [
                volume.identifier: ReadingState(
                    position: .page(63, from: 205), timestamp: Date(timeIntervalSince1970: 1_700_000_100))
            ],
            state: Date(timeIntervalSince1970: 1_700_000_200))
        let data = try JSONEncoder().encode(extract)
        let back = try JSONDecoder().decode(LibraryExtract.self, from: data)
        #expect(back == extract)
        #expect(back.readingStates[volume.identifier]?.fraction == 63.0 / 205.0)
    }

    @Test("The page stream names its pages, the others do not")
    func contentSource() {
        let strom = ContentSource.pageStream(count: 205) { URL(string: "https://comics.example/p/\($0)")! }
        #expect(strom.pageCount == 205)
        if case .pageStream(_, let page, _) = strom {
            #expect(page(7).absoluteString == "https://comics.example/p/7")
        }
        #expect(
            ContentSource.file(URL(string: "https://b.example/f")!, size: nil, rangeCapable: false)
                .pageCount == nil)
        #expect(ContentSource.audioStream { AudioManifest(tracks: [], chapter: []) }.pageCount == nil)
    }

    @Test("A release date from day, year or time — empty stays nil, never 1970")
    func releaseDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let tag = Title.releaseDate("2003-07-14")
        #expect(
            calendar.dateComponents([.year, .month, .day], from: tag!)
                == DateComponents(year: 2003, month: 7, day: 14))
        let year = Title.releaseDate("2009")
        #expect(
            calendar.dateComponents([.year, .month, .day], from: year!)
                == DateComponents(year: 2009, month: 1, day: 1))
        let time = Title.releaseDate("2019-06-03T00:00:00Z")
        #expect(calendar.component(.year, from: time!) == 2019)
        #expect(Title.releaseDate(nil) == nil)
        #expect(Title.releaseDate("") == nil)
        #expect(Title.releaseDate("unbekannt") == nil)
    }
}

@Suite("Blurb, language, year")
struct DataHardeningTests {

    @Test("A blurb is not a number and not an abbreviation")
    func blurb() {
        #expect(Title.blurb("1905") == nil)
        #expect(Title.blurb("upped by @x") == nil)
        #expect(Title.blurb("   ") == nil)
        #expect(Title.blurb(nil) == nil)
        #expect(Title.blurb("Eine Welt unter der Erde, in der niemand hinaus darf.") != nil)
    }

    @Test("Language codes: deu → de, unknown → nil, en-US stays")
    func language() {
        #expect(Title.languageCode("deu") == "de")
        #expect(Title.languageCode("de") == "de")
        #expect(Title.languageCode("en-us") == "en-US")
        #expect(Title.languageCode("unknown") == nil)
        #expect(Title.languageCode("") == nil)
        #expect(Title.languageCode("eng") == "en")
    }

    @Test("Year 0100 is not a release date")
    func year() {
        #expect(Title.releaseDate("0100-01-01") == nil)
        #expect(Title.releaseDate("1455") != nil)
    }
}
