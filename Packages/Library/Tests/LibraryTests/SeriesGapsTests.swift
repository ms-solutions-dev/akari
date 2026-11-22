import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The gap computation against the cases from the Grimmory recording:
/// Gleiskriand (2 and 6), Krezegraurn (1–4 and 17), Deswutgou (fractions), Miakus (Goodreads
/// length below the largest number).
@Suite("Series gaps")
struct SeriesGapsTests {

    @Test("Gleiskriand with 2 and 6: 1, 3, 4, 5 missing — as ranges 1 and 3–5")
    func gaps() throws {
        let l = try #require(SeriesGaps(numbers: [6, 2], total: nil))
        #expect(l.missing == [1, 3, 4, 5])
        #expect(l.areas == [1...1, 3...5])
        #expect(l.highest == 6 && l.total == nil && l.count == 4 && !l.complete)
    }

    @Test("Fractions do not count: 1, 1.5, 2, 2.2, 2.5 is gapless, volume 0 too")
    func fractions() throws {
        let l = try #require(SeriesGaps(numbers: [0, 1, 1.5, 2, 2.2, 2.5], total: nil))
        #expect(l.complete && l.highest == 2)
        let onlyFraction = SeriesGaps(numbers: [0.5, 2.5], total: 3)
        #expect(onlyFraction == nil, "without a whole number no statement")
    }

    @Test("Without numbers no statement — not even with a length from the server")
    func withoutNumbers() {
        #expect(SeriesGaps(numbers: [], total: 6) == nil)
    }

    @Test("The length from the server extends the series: 1–3 of 6 → 4–6 missing")
    func total() throws {
        let l = try #require(SeriesGaps(numbers: [1, 2, 3], total: 6))
        #expect(l.missing == [4, 5, 6] && l.areas == [4...6] && l.total == 6)
    }

    @Test("Miakus: length 9 at volume 10 is noise — discarded, the gaps end at 10")
    func totalSmallerThanHighest() throws {
        let l = try #require(SeriesGaps(numbers: [6, 7, 8, 9, 10], total: 9))
        #expect(l.total == nil)
        #expect(l.missing == [1, 2, 3, 4, 5])
    }

    @Test("Complete: 1–6 of 6 — and 1–6 without length likewise, just without a statement about the length")
    func complete() throws {
        let with = try #require(SeriesGaps(numbers: [1, 2, 3, 4, 5, 6], total: 6))
        #expect(with.complete && with.total == 6 && with.areas.isEmpty)
        let without = try #require(SeriesGaps(numbers: [3, 1, 2], total: nil))
        #expect(without.complete && without.total == nil)
    }

    @Test(
        "Im Regal: Pepper&Carrot 36–38 hat 35 Lücken, Sherlock Holmes 1–2 keine, ohne Serie nil; der Filter hält nur Reihen mit Lücke"
    )
    func imRegal() async throws {
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() { extracts.append(try await q.library()) }
        let r = Shelf(extracts: extracts, now: MockShelf.state)
        let pepper = try #require(r.allSeries.first { $0.name == "Pepper&Carrot" })
        let holmes = try #require(r.allSeries.first { $0.name == "Sherlock Holmes" })
        #expect(r.gaps(pepper.identifier)?.count == 35)
        #expect(r.gaps(holmes.identifier)?.complete == true)
        #expect(r.gaps(SeriesID(source: holmes.identifier.source, id: "gibt-es-nicht")) == nil)
        var f = Filtering()
        f.gaps = true
        #expect(f.count == 1 && !f.empty)
        let entries = r.parts(sorting: .title, filtering: f).flatMap(\.entries)
        #expect(
            entries.map(\.name) == ["Pepper&Carrot"],
            "Sherlock Holmes ist vollständig, Einzeltitel sind keine Reihe")
    }
}
