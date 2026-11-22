import Foundation
import SourcesKit
import Testing

@testable import Library

@Suite("Shelf with 35,000 titles")
struct RegalGrossTests {

    /// Measured (Mac, release): build 23 ms, start rows each under 5 ms, genres 28 ms,
    /// authors 158 ms. Hence the shelf still holds all titles (no "core"): what is expensive —
    /// genres and authors — the catalog computes off the main thread.
    @Test("Build and the start rows stay under a screen waiting time")
    func gross() throws {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let genres = ["Krimi", "Roman", "Thriller", "Fantasy", "Historischer Roman", "Science-Fiction"]
        let title = (0..<35_000).map { (i: Int) -> Title in
            let bookSeries: SeriesReference? =
                i % 4 == 0
                ? SeriesReference(
                    identifier: SeriesID(source: source, id: "s\(i / 12)"), name: "Reihe \(i / 12)",
                    volume: Double(i % 12)) : nil
            return Title(
                identifier: TitleID(source: source, id: "\(i)"), kind: .book, name: "Buch \(i)",
                authors: ["Autor \(i % 3_000)"], series: bookSeries, genres: [genres[i % genres.count]],
                added: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
        }
        let extract = LibraryExtract(source: source, title: title, state: Date())
        let clock = ContinuousClock()
        var shelf: Shelf!
        let build = clock.measure {
            shelf = Shelf(extracts: [extract], bookSeriesList: Shelf.bookSeriesDefault, now: Date())
        }
        let proceed = clock.measure { _ = shelf.continueReading }
        let new = clock.measure { _ = shelf.newOnShelf }
        let all = clock.measure { _ = shelf.allTitles.count }
        let entries = clock.measure { _ = shelf.entries(.book).count }
        let genreTime = clock.measure { _ = shelf.genres(.book) }
        let authors = clock.measure { _ = shelf.authors(.book) }
        print(
            "Shelf 35k: build \(build), continue reading \(proceed), new \(new), allTitles \(all), entries \(entries), genres \(genreTime), authors \(authors)"
        )
        // Generous so that a debug run passes too; regressions by
        // orders of magnitude should be caught.
        #expect(build < .seconds(2))
        #expect(proceed + new + all + entries < .seconds(1))
    }
}
