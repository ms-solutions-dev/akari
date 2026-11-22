import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

@Suite("Catalog index")
struct CatalogIndexTests {

    private func filled() async throws -> (CatalogIndex, [LibraryExtract]) {
        let index = try CatalogIndex(file: nil)
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() {
            let a = try await q.library()
            extracts.append(a)
            try index.replace(a)
        }
        return (index, extracts)
    }

    @Test("Many titles with one bulk query — also beyond the chunk size, unknown ones are missing")
    func bulkQuery() async throws {
        let (index, extracts) = try await filled()
        let known = extracts.flatMap(\.title).map(\.identifier)
        let source = try #require(known.first?.source)
        // More than one chunk: known identifiers, padded with unknown ones.
        let unknown = (0..<CatalogIndex.bulkSize).map {
            TitleID(source: source, id: "fehlt-\($0)")
        }
        let found = try index.title(known + unknown)
        #expect(found.count == Set(known).count)
        for k in known { #expect(found[k] == (try index.title(k)), "\(k)") }
        #expect(found[unknown[0]] == nil)
        #expect(try index.title([]).isEmpty)
    }

    @Test("The kinds of many titles without reading them — the same as in the title")
    func kinds() async throws {
        let (index, extracts) = try await filled()
        let title = extracts.flatMap(\.title)
        let kinds = try index.kinds(title.map(\.identifier))
        #expect(kinds.count == Set(title.map(\.identifier)).count)
        for t in title { #expect(kinds[t.identifier.description] == t.kind, "\(t.name)") }
        #expect(try index.kinds([]).isEmpty)
    }

    @Test("Replace and count per kind — the same numbers as the shelf")
    func counting() async throws {
        let (index, extracts) = try await filled()
        let shelf = Shelf(extracts: extracts, bookSeriesList: [], now: MockShelf.state)
        for kind in [Kind.manga, .book, .audiobook] {
            let expected = shelf.allTitles.filter { $0.kind == kind }.count
            #expect(try index.count(CatalogQuery(kind: kind)) == expected, "\(kind)")
        }
        #expect(try index.count(CatalogQuery()) == shelf.allTitles.count)
    }

    @Test("Replacing a source leaves the others; signing out removes it entirely")
    func replace() async throws {
        let (index, extracts) = try await filled()
        let previously = try index.count(CatalogQuery())
        try index.replace(extracts[0])
        #expect(try index.count(CatalogQuery()) == previously, "kein Doppel")
        try index.remove(source: extracts[0].source)
        #expect(try index.count(CatalogQuery()) == previously - extracts[0].title.count)
        #expect(try index.identifiers(source: extracts[0].source).isEmpty)
    }

    @Test("Read status from the states: read, started, unread add up to everything")
    func phase() async throws {
        let (index, extracts) = try await filled()
        let shelf = Shelf(extracts: extracts, bookSeriesList: [], now: MockShelf.state)
        var sum = 0
        for z in ReadStatus.allCases {
            var a = CatalogQuery()
            a.phase = z
            let n = try index.count(a)
            let expected = shelf.allTitles.filter { ReadStatus(shelf.readingState($0.identifier)) == z }.count
            #expect(n == expected, "\(z)")
            sum += n
        }
        #expect(sum == shelf.allTitles.count)
    }

    @Test("Bundled entries as on the shelf: series as one entry, single titles on their own")
    func bundled() async throws {
        let (index, extracts) = try await filled()
        for bookSeriesList in [Set<Kind>(), Shelf.bookSeriesDefault] {
            let shelf = Shelf(extracts: extracts, bookSeriesList: bookSeriesList, now: MockShelf.state)
            for kind in [nil, Kind.manga, .book, .audiobook] {
                let expected = Set(shelf.entries(kind).map(\.id))
                let a = CatalogQuery(kind: kind, sorting: .title)
                let ist = try index.entries(a, bundled: bookSeriesList, atMost: 1000).map(\.id)
                #expect(Set(ist) == expected, "\(String(describing: kind)) \(bookSeriesList)")
                #expect(try index.entryCount(a, bundled: bookSeriesList) == expected.count)
            }
        }
    }

    @Test("Title sorting orders numbers naturally: volume 2 before volume 10")
    func natural() throws {
        let index = try CatalogIndex(file: nil)
        let source = SourceID(provider: .komga, server: "x")
        let title = ["Pepper&Carrot 10", "Pepper&Carrot 2", "Älteste Tage", "pepper&carrot 1"].enumerated()
            .map {
                i, n in
                Title(identifier: TitleID(source: source, id: "\(i)"), kind: .manga, name: n)
            }
        try index.replace(LibraryExtract(source: source, title: title, state: Date()))
        let names = try index.title(CatalogQuery(sorting: .title)).map(\.name)
        #expect(names == ["Älteste Tage", "pepper&carrot 1", "Pepper&Carrot 2", "Pepper&Carrot 10"])
    }

    @Test("Facets count under the other filters, not under their own")
    func facets() async throws {
        let (index, _) = try await filled()
        var a = CatalogQuery(kind: .manga)
        let genres = try index.facet(.genre, a)
        #expect(!genres.isEmpty)
        let first = try #require(genres.first)
        a.genres = [first.value]
        #expect(try index.count(a) == first.count)
        // The field's own counter continues over all values — otherwise one would see only "Krimi".
        #expect(try index.facet(.genre, a) == genres)
    }

    @Test("Search by word start, without accents and capitalization")
    func search() async throws {
        let (index, _) = try await filled()
        #expect(try index.search("pepper").contains { $0.name.hasPrefix("Pepper&Carrot") })
        #expect(
            try index.search("REVOY").contains { $0.name.hasPrefix("Pepper&Carrot") },
            "Autor, Kleinschreibung")
        #expect(try index.search("").isEmpty)
    }

    @Test("Pages do not overlap and together make up everything")
    func pages() async throws {
        let (index, _) = try await filled()
        let all = try index.title(CatalogQuery(sorting: .recentlyAdded), atMost: 1000).map(
            \.identifier)
        var collected: [TitleID] = []
        var from = 0
        while true {
            let page = try index.title(
                CatalogQuery(sorting: .recentlyAdded), from: from, atMost: 2)
            if page.isEmpty { break }
            collected += page.map(\.identifier)
            from += page.count
        }
        #expect(collected == all)
        #expect(Set(collected).count == collected.count)
    }

    @Test("35,000 titles: load, count, one page, facets — fast enough for the device")
    func gross() throws {
        let index = try CatalogIndex(file: nil)
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let genres = ["Krimi", "Roman", "Thriller", "Fantasy", "Historischer Roman", "Science-Fiction"]
        let title = (0..<35_000).map { i in
            Title(
                identifier: TitleID(source: source, id: "\(i)"), kind: .book, name: "Buch \(i)",
                authors: ["Autor \(i % 3_000)"], genres: [genres[i % genres.count]],
                language: i % 5 == 0 ? "en" : "de",
                added: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
        }
        let clock = ContinuousClock()
        let scan = try clock.measure {
            try index.replace(LibraryExtract(source: source, title: title, state: Date()))
        }
        var a = CatalogQuery(kind: .book, sorting: .title)
        a.genres = ["Krimi"]
        var n = 0
        let counting = try clock.measure { n = try index.count(a) }
        var page: [Title] = []
        let paging = try clock.measure { page = try index.title(a, from: 3_000, atMost: 60) }
        let countingFacet = try clock.measure { _ = try index.facet(.genre, a) }
        #expect(n == 35_000 / genres.count + (35_000 % genres.count > 0 ? 1 : 0))
        #expect(page.count == 60)
        print(
            "Catalog index 35k: load \(scan), count \(counting), page \(paging), facet \(countingFacet)"
        )
        #expect(paging < .milliseconds(100))
        #expect(counting < .milliseconds(200))
    }
}
