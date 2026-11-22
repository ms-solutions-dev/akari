import Library
import SourcesKit
import SourcesKitMocks
import SwiftUI
import Testing

@testable import Features

/// The gap line and its parts: the sentences appear without catalog as keys; testable are
/// the ranges, the parenthesis, the chip and the length in the status line.
@Suite("Series gaps in the UI")
@MainActor
struct SeriesGapScreenTests {

    @Test("Ranges merged: \"7-38\" with an en dash, \"3\" alone")
    func areas() {
        #expect(Formats.area(7...38) == "7–38")
        #expect(Formats.area(3...3) == "3")
    }

    @Test(
        "The number in parentheses only for a range; complete only with a length; gapless without a length shows nothing"
    )
    func line() throws {
        let area = try #require(SeriesGaps(numbers: [1, 2, 3, 4, 5, 6], total: 38))
        let line = try #require(Formats.gaps(area))
        #expect(line.hasSuffix("(32)"))
        #expect(Formats.gapList(area) == "7–38")
        let single = try #require(SeriesGaps(numbers: [1, 2, 4, 6], total: nil))
        let short = try #require(Formats.gaps(single))
        #expect(!short.hasSuffix(")"))
        let list = Formats.gapList(single)
        #expect(
            list.hasPrefix("3") && list.hasSuffix("5") && !list.contains("–"),
            "two singles, no range")
        let mixed = try #require(SeriesGaps(numbers: [1, 2, 4, 6, 10], total: nil))
        #expect(Formats.gapList(mixed).contains("7–9"))
        let one = try #require(SeriesGaps(numbers: [1, 3], total: nil))
        #expect(Formats.gaps(one)?.contains("series.gaps.one") == true)
        #expect(Formats.gaps(try #require(SeriesGaps(numbers: [1, 2], total: 2))) != nil)
        #expect(Formats.gaps(try #require(SeriesGaps(numbers: [1, 2], total: nil))) == nil)
    }

    @Test("The filter as a chip, gone again with the x")
    func chip() {
        var f = Filtering()
        f.gaps = true
        let chips = FilterChips.chips(f)
        #expect(chips.count == 1 && chips[0].kind == .gaps)
        #expect(FilterChips.without(chips[0], f).empty)
    }

    @Test(
        "Status line: the checked length beats the server's; Miakus does not say \"6 of 9 volumes\" beside \"1-5 missing\""
    )
    func statusLine() throws {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let identifier = SeriesID(source: source, id: "Miakus")
        let series = Series(identifier: identifier, kind: .book, name: "Miakus", volumeCount: 5, total: 9)
        let volumes = (6...10).map { n in
            Title(
                identifier: TitleID(source: source, id: "d\(n)"), kind: .book, name: "Miakus \(n)",
                series: SeriesReference(identifier: identifier, name: "Miakus", volume: Double(n)))
        }
        let shelf = Shelf(
            extracts: [
                LibraryExtract(source: source, seriesList: [series], title: volumes, state: MockShelf.state)
            ],
            now: MockShelf.state)
        let state = shelf.seriesState(identifier)
        #expect(
            SeriesHeader.statusLine(state, series: series).contains("series.ofTotal"),
            "without the check it believes the server")
        let gaps = try #require(shelf.gaps(identifier))
        #expect(gaps.total == nil)
        #expect(!SeriesHeader.statusLine(state, series: series, gaps: gaps).contains("series.ofTotal"))
        let plausible = try #require(SeriesGaps(numbers: [1, 2, 3], total: 9))
        #expect(SeriesHeader.statusLine(state, series: series, gaps: plausible).contains("series.ofTotal"))
    }
}
