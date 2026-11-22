import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The shelf against the three mocks — and against extracts that hit a
/// rule deliberately. The clock stands on `MockShelf.state`.
@Suite("Shelf")
struct RegalTests {

    private func shelf(_ sources: [MockSource] = MockShelf.base()) async throws -> Shelf {
        var extracts: [LibraryExtract] = []
        for q in sources { extracts.append(try await q.library()) }
        return Shelf(
            extracts: extracts,
            capabilities: Dictionary(sources.map { ($0.identifier, $0.capabilities) }) { a, _ in a },
            bookSeriesList: [], now: MockShelf.state)
    }

    @Test("Kinds in segment order — without Grimmory “Books” is missing, it is not empty")
    func kinds() async throws {
        #expect(try await shelf().kinds == [.manga, .book, .audiobook])
        #expect(
            try await shelf([MockShelf.komga(), MockShelf.audiobookshelf()]).kinds == [
                .manga, .audiobook,
            ])
        #expect(Shelf.empty.kinds.isEmpty)
    }

    @Test("Counters: 1 series · 3 volumes, 3 books, 3 audiobooks")
    func counter() async throws {
        let r = try await shelf()
        #expect(r.counter(.manga) == Shelf.Counter(seriesList: 1, title: 3))
        #expect(r.counter(.book) == Shelf.Counter(seriesList: 1, title: 3))
        #expect(r.counter(.audiobook) == Shelf.Counter(seriesList: 0, title: 3))
    }

    @Test("Podcasts: always a folder per podcast, even without series bundling; episodes as volumes")
    func podcasts() async throws {
        let r = try await shelf(MockShelf.all())
        #expect(r.kinds == [.manga, .book, .audiobook, .podcast])
        #expect(r.counter(.podcast) == Shelf.Counter(seriesList: 1, title: 4))
        let entries = r.entries(.podcast)
        #expect(entries.count == 1, "vier Folgen, ein Eintrag — die Reihen-Wahl gilt für Podcasts nicht")
        guard case .series(let series) = entries[0] else {
            Issue.record("Serie erwartet")
            return
        }
        #expect(series.name == "Moonlit Tales Podcast" && series.kind == .podcast)
        #expect(r.volumes(series.identifier).map { $0.series?.volume } == [1, 2, 3, 4])
        // The started episode stands under continue listening — youngest state first, before The Time Machine.
        #expect(
            r.continueReading.map(\.title.name).prefix(3).contains("After the Rain"))
        #expect(r.continueReadingVisible.contains { $0.title.kind == .podcast })
    }

    @Test("Entries: manga as series, books and audiobooks as titles")
    func entries() async throws {
        let r = try await shelf()
        #expect(r.entries(.manga).map(\.name) == ["Pepper&Carrot"])
        #expect(r.entries(.book).count == 3)
        #expect(r.entries().count == 7)
        #expect(r.entries().first?.kind == .manga, "die Reihenfolge der Leiste")
    }

    @Test("Continue reading: the youngest first, mixed across all three servers")
    func continueReading() async throws {
        let names = try await shelf().continueReading.map(\.title.name)
        #expect(
            names == [
                "The Memoirs of Sherlock Holmes", "Pepper&Carrot 37", "The Time Machine",
                "The Adventures of Sherlock Holmes",
            ])
    }

    @Test(
        "Liegengeblieben ist eine Blickfeld-Regel: was Start nicht zeigt, egal seit wann — nach Fortschritt")
    func stalled() async throws {
        let r = try await shelf()
        #expect(
            r.continueReadingVisible.map(\.title.name) == [
                "The Memoirs of Sherlock Holmes", "Pepper&Carrot 37", "The Adventures of Sherlock Holmes",
                "The Time Machine",
            ])
        #expect(r.stalled.isEmpty, "vier Angefangene passen alle ins Blickfeld")
        func identifier(_ name: String) throws -> TitleID {
            try #require(r.allTitles.first { $0.name == name }).identifier
        }
        // Two more books, long started: the fifth reader drops out of sight.
        let five = r.with(
            ReadingState(
                position: .fraction(0.12), timestamp: MockShelf.state.addingTimeInterval(-20 * 86_400)),
            for: try identifier("Frankenstein")
        )
        .with(
            ReadingState(
                position: .page(20, from: 201),
                timestamp: MockShelf.state.addingTimeInterval(-60 * 86_400)),
            for: try identifier("Pepper&Carrot 38"))
        #expect(five.continueReadingVisible.count == 5, "hero plus three readings, plus an audiobook")
        #expect(
            five.stalled.map(\.title.name) == ["Pepper&Carrot 38"],
            "das älteste fällt heraus, egal wie alt")
        // If the hero listens, Home shows three readings — two are stalled, the one read further first,
        // although it is the older one.
        let listens = five.with(
            ReadingState(position: .second(9_000, from: 41_500), timestamp: MockShelf.state),
            for: try identifier("Treasure Island"))
        #expect(
            listens.continueReadingVisible.map(\.title.name) == [
                "Treasure Island", "The Time Machine", "The Memoirs of Sherlock Holmes", "Pepper&Carrot 37",
                "Frankenstein",
            ])
        #expect(
            listens.stalled.map(\.title.name) == ["Pepper&Carrot 38", "The Adventures of Sherlock Holmes"])
        #expect(listens.stalled.allSatisfy { $0.state.started && !$0.state.completed })
    }

    @Test("Up next: only series with a finished volume and without an open one — volume 48 once 47 is done")
    func asNext() async throws {
        let r = try await shelf()
        #expect(r.asNext.isEmpty, "47 ist offen und steht unter Weiterlesen")
        let band47 = try #require(r.allTitles.first { $0.name == "Pepper&Carrot 37" })
        let to = r.with(
            ReadingState(
                position: .page(205, from: 205), timestamp: MockShelf.state, completed: true),
            for: band47.identifier)
        let next = to.asNext
        #expect(next.map(\.title.name) == ["Pepper&Carrot 38"])
        #expect(next.first?.new == true, "Band 48 kam vor zwei Tagen")
    }

    @Test("New on shelf: volume 48 bundled under the series, plus the two new titles without series")
    func newOnShelf() async throws {
        let new = try await shelf().newOnShelf
        #expect(new.map(\.name) == ["Pepper&Carrot", "The Jungle Book", "Frankenstein"])
        guard case .series(let series, let volumes) = new[0] else {
            Issue.record("Serie erwartet")
            return
        }
        #expect(series.name == "Pepper&Carrot")
        #expect(volumes.map(\.name) == ["Pepper&Carrot 38"])
    }

    @Test("A series in which nothing is started comes as a whole — not volume by volume")
    func newSeries() {
        let source = SourceID(provider: .komga, server: "comics.example")
        let bookSeries = SeriesID(source: source, id: "neu")
        let series = Series(
            identifier: bookSeries, kind: .manga, name: "Frisch", volumeCount: 12, added: MockShelf.state)
        let volumes = (1...12).map { n in
            Title(
                identifier: TitleID(source: source, id: "neu-\(n)"), kind: .manga, name: "Frisch \(n)",
                series: SeriesReference(identifier: bookSeries, name: "Frisch", volume: Double(n)),
                added: MockShelf.state.addingTimeInterval(-3_600))
        }
        let r = Shelf(
            extracts: [
                LibraryExtract(source: source, seriesList: [series], title: volumes, state: MockShelf.state)
            ],
            now: MockShelf.state)
        #expect(r.newOnShelf.count == 1)
        guard case .series(_, let newOnes) = r.newOnShelf[0] else {
            Issue.record("Serie erwartet")
            return
        }
        #expect(newOnes.count == 12)
        #expect(r.asNext.isEmpty)
        #expect(r.continueReading.isEmpty)
    }

    @Test("Genres: by frequency, no row under two genres")
    func genres() async throws {
        let r = try await shelf()
        #expect(r.genres(.book).map(\.name) == ["Detective Fiction", "Mystery", "Gothic Fiction", "Horror"])
        #expect(r.genres(.book).map(\.count) == [2, 2, 1, 1])
        #expect(r.genres(.audiobook).isEmpty, "one genre alone is no choice")
        #expect(r.genres(.manga).map(\.name) == ["Fantasy", "Humor"])
        #expect(r.genres().count == 7)
    }

    @Test("Without genre comes last — and is a key of its own")
    func withoutGenre() {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        func book(_ n: Int, _ genres: [String]) -> Title {
            Title(
                identifier: TitleID(source: source, id: "\(n)"), kind: .book, name: "Buch \(n)",
                genres: genres)
        }
        let r = Shelf(
            extracts: [
                LibraryExtract(
                    source: source,
                    title: [book(1, ["Krimi"]), book(2, []), book(3, []), book(4, ["Krimi"])],
                    state: MockShelf.state)
            ])
        #expect(r.genres(.book).map(\.lookupKey) == [.name("Krimi"), .without])
        #expect(r.parts(kind: .book, genre: .without, sorting: .title).flatMap(\.entries).count == 2)
    }

    @Test("Filtering: several criteria at once, series via their volumes, publisher page, filter values")
    func filtering() async throws {
        let r = try await shelf()
        var f = Filtering()
        #expect(f.empty)
        f.formats = ["EPUB"]
        #expect(
            r.parts(sorting: .title, filtering: f).flatMap(\.entries).allSatisfy { $0.kind == .book }
        )
        f.formats = ["CBZ"]
        let manga = r.parts(sorting: .title, filtering: f).flatMap(\.entries)
        #expect(manga.count == 1 && manga[0].kind == .manga, "die Serie passt über ihre Bände")
        f.phase = .read
        #expect(
            r.parts(sorting: .title, filtering: f).isEmpty, "die Serie ist angefangen, nicht gelesen")
        #expect(f.count == 2)
        var g = Filtering()
        g.publishers = ["Project Gutenberg"]
        g.languages = ["en"]
        #expect(
            r.parts(kind: .book, sorting: .title, filtering: g).flatMap(\.entries).count == 3,
            "two Holmes volumes and Frankenstein")
        #expect(
            r.parts(kind: .book, publisher: "project gutenberg", sorting: .title, filtering: Filtering())
                .flatMap(
                    \.entries
                ).count == 3)
        #expect(Filtering(.keep).downloaded && Filtering(.read).phase == .read)
        let values = r.filterValues(.book)
        #expect(values.formats.map(\.value) == ["EPUB"])
        #expect(values.publishers.first?.value == "Project Gutenberg" && values.publishers.first?.count == 3)
        #expect(values.languages.map(\.value) == ["en"])
        #expect(values.years == 1818...1894)
    }

    @Test("Authors: three spellings, one person; counter per kind; author page finds all")
    func authors() {
        let grimmory = SourceID(provider: .grimmory, server: "buecher.example")
        let abs = SourceID(provider: .audiobookshelf, server: "hoerbuch.example")
        func title(_ q: SourceID, _ n: Int, _ kind: Kind, _ authors: [String], days: Int) -> Title {
            Title(
                identifier: TitleID(source: q, id: "\(n)"), kind: kind, name: "T \(n)", authors: authors,
                added: MockShelf.state.addingTimeInterval(TimeInterval(-days * 86_400)))
        }
        let r = Shelf(
            extracts: [
                LibraryExtract(
                    source: grimmory,
                    title: [
                        title(grimmory, 1, .book, ["Halvorsen, J. K."], days: 3),
                        title(grimmory, 2, .book, ["J.K. Halvorsen", "Zacharias Zorn"], days: 2),
                        title(grimmory, 3, .book, ["Arne Ebeling"], days: 9),
                    ],
                    authors: [
                        AuthorReference(
                            source: grimmory, identifier: "7", name: "J K Halvorsen", image: nil, count: 2),
                        AuthorReference(
                            source: grimmory, identifier: "8", name: "Halvorsen, J. K.",
                            image: URL(string: "https://buecher.example/api/v1/media/author/8/thumbnail"),
                            count: 1),
                    ], state: MockShelf.state),
                LibraryExtract(
                    source: abs, title: [title(abs, 4, .audiobook, ["J. K. Halvorsen"], days: 1)],
                    state: MockShelf.state),
            ])
        let all = r.authors()
        #expect(all.map(\.name) == ["Arne Ebeling", "J. K. Halvorsen", "Zacharias Zorn"], "nach Nachname")
        let halvorsen = all[1]
        #expect(halvorsen.count == [.book: 2, .audiobook: 1])
        #expect(halvorsen.title == 3)
        #expect(halvorsen.cover?.source == abs, "the youngest cover")
        #expect(halvorsen.reference?.identifier == "8", "the server entry with image wins")
        #expect(r.authorReference("j.k. halvorsen")?.identifier == "8")
        #expect(all[0].reference == nil, "Ebeling hat keinen Server-Eintrag")
        #expect(r.authors(.audiobook).map(\.name) == ["J. K. Halvorsen"])
        let page = r.parts(author: "Halvorsen, J.K.", sorting: .title).flatMap(\.entries)
        #expect(page.count == 3, "die Autorenseite vergleicht normiert")
    }

    @Test("Sections: by title with letter headers, by author with names, by time without header")
    func parts() async throws {
        let r = try await shelf()
        let byTitle = r.parts(kind: .book, sorting: .title)
        #expect(byTitle.map(\.header) == [.text("F"), .text("T")])
        #expect(
            byTitle[1].entries.map(\.name) == [
                "The Adventures of Sherlock Holmes", "The Memoirs of Sherlock Holmes",
            ])
        #expect(
            r.parts(kind: .book, sorting: .author).map(\.header)
                == [.text("Arthur Conan Doyle"), .text("Mary Shelley")])
        let byTime = r.parts(kind: .audiobook, sorting: .recentlyAdded)
        #expect(byTime.count == 1 && byTime[0].header == nil)
        #expect(byTime[0].entries.first?.name == "The Jungle Book")
        let byRead = r.parts(sorting: .recentlyRead).flatMap(\.entries)
        #expect(byRead.first?.name == "The Memoirs of Sherlock Holmes")
        #expect(Shelf.initialLetter("Éclair") == "E")
        #expect(Shelf.initialLetter("1984") == "#")
        #expect(Shelf.initialLetter("„Übermorgen") == "U")
    }

    @Test("Filter: Unread · Started · Read · Keep — a series counts via its volumes")
    func filter() async throws {
        let r = try await shelf()
        #expect(
            r.parts(kind: .manga, sorting: .title, filter: .started).flatMap(\.entries).count == 1
        )
        #expect(r.parts(kind: .manga, sorting: .title, filter: .read).isEmpty)
        #expect(
            r.parts(kind: .audiobook, sorting: .title, filter: .unread).flatMap(\.entries).count
                == 2)
        #expect(r.parts(sorting: .title, filter: .keep).isEmpty)
        let limit = try #require(r.allTitles.first { $0.name == "Treasure Island" })
        let withKept = r.with(keep: [limit.identifier])
        #expect(
            withKept.parts(sorting: .title, filter: .keep).flatMap(\.entries).map(\.name)
                == ["Treasure Island"])
    }

    @Test("Default: manga recently read, everything else recently added")
    func preset() {
        #expect(Sorting.preset(for: .manga) == .recentlyRead)
        #expect(Sorting.preset(for: .book) == .recentlyAdded)
        #expect(Sorting.preset(for: nil) == .recentlyAdded)
    }

    @Test("Series state: 1 read · volume 47 · page 63 — and after the end of 47 volume 48")
    func seriesState() async throws {
        let r = try await shelf()
        let bookSeries = try #require(r.allSeries.first { $0.name == "Pepper&Carrot" })
        let state = r.seriesState(bookSeries.identifier)
        #expect(state.read == 1 && state.total == 3)
        #expect(state.current?.name == "Pepper&Carrot 37")
        #expect(state.state?.position == .page(63, from: 205))
        #expect(!state.completed)
        let band47 = try #require(state.current)
        let after = r.with(
            ReadingState(
                position: .page(205, from: 205), timestamp: MockShelf.state, completed: true),
            for: band47.identifier
        )
        .seriesState(bookSeries.identifier)
        #expect(after.read == 2 && after.current?.name == "Pepper&Carrot 38" && after.state == nil)
        let band48 = try #require(after.current)
        let done = r.with(
            ReadingState(
                position: .page(205, from: 205), timestamp: MockShelf.state, completed: true),
            for: band47.identifier
        )
        .with(
            ReadingState(
                position: .page(201, from: 201), timestamp: MockShelf.state, completed: true),
            for: band48.identifier
        )
        .seriesState(bookSeries.identifier)
        #expect(done.completed && done.current == nil && done.read == 3)
    }

    @Test("The state of an entry — unread, started, read")
    func readStatus() {
        #expect(ReadStatus(nil) == .unread)
        #expect(ReadStatus(ReadingState(position: .page(0, from: 10), timestamp: .now)) == .unread)
        #expect(ReadStatus(ReadingState(position: .page(3, from: 10), timestamp: .now)) == .started)
        #expect(
            ReadStatus(ReadingState(position: .page(3, from: 10), timestamp: .now, completed: true))
                == .read)
    }

    @Test("By series: one section per series in reading order, singles last by publication")
    func bySeries() async throws {
        let r = try await shelf()
        let parts = r.parts(kind: .book, sorting: .bookSeries)
        #expect(parts.map(\.header) == [.text("Sherlock Holmes"), .withoutBookSeries])
        #expect(
            parts[0].entries.map(\.name) == [
                "The Adventures of Sherlock Holmes", "The Memoirs of Sherlock Holmes",
            ])
        #expect(parts[1].entries.map(\.name) == ["Frankenstein"])
        // Without a volume number the publication date decides, then the name.
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let bookSeries = SeriesID(source: source, id: "r")
        func book(_ name: String, year: Int?) -> Title {
            Title(
                identifier: TitleID(source: source, id: name), kind: .book, name: name,
                series: SeriesReference(identifier: bookSeries, name: "Dationfur"),
                released: year.map { Title.releaseDate(String($0))! })
        }
        let unnumbered = Shelf(
            extracts: [
                LibraryExtract(
                    source: source,
                    title: [book("Zett", year: nil), book("Farben", year: 1983), book("Alles", year: 1986)],
                    state: MockShelf.state)
            ])
        #expect(
            unnumbered.parts(sorting: .bookSeries)[0].entries.map(\.name) == ["Farben", "Alles", "Zett"])
        #expect(Sorting.defaultInGenre(for: .book) == .bookSeries)
        #expect(Sorting.defaultInGenre(for: .manga) == .recentlyRead)
    }
}

/// The search over the three mocks — "Sonnen" does not exist there, so Sherlock Holmes,
/// Pepper&Carrot and The Time Machine.
@Suite("Search")
struct SearchTests {

    private func shelf() async throws -> Shelf {
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() { extracts.append(try await q.library()) }
        return Shelf(extracts: extracts, bookSeriesList: [], now: MockShelf.state)
    }

    @Test("“holmes” finds the two Sherlock Holmes books under books, nothing else; empty for whitespace")
    func books() async throws {
        let r = try await shelf()
        let result = r.search("holmes")
        #expect(result.clusters.map(\.kind) == [.book])
        #expect(result.clusters[0].hit.count == 2)
        if case .title(let first) = result.clusters[0].hit[0] {
            #expect(first.name.contains("Sherlock Holmes"))
        }
        #expect(result.authors.isEmpty)
        #expect(r.search("   ").empty)
        #expect(r.search("xyzzy").empty)
    }

    @Test("The series is the hit, not its volumes — and a volume that matches on its own stands below")
    func series() async throws {
        let r = try await shelf()
        let result = r.search("pepper&carrot")
        #expect(result.clusters.map(\.kind) == [.manga])
        guard case .series(let series, let volumes) = result.clusters[0].hit[0] else {
            Issue.record("kein Serientreffer")
            return
        }
        #expect(series.name == "Pepper&Carrot")
        #expect(volumes.isEmpty, "alle Bände tragen den Seriennamen — die Serie ist der Treffer")
        let volume = r.search("pepper&carrot 37")
        guard case .series(_, let matched) = volume.clusters[0].hit[0] else {
            Issue.record("kein Serientreffer")
            return
        }
        #expect(matched.map(\.name) == ["Pepper&Carrot 37"])
    }

    @Test("Author and accent: “wélls” matches the audiobook via the author and names it as a group")
    func author() async throws {
        let r = try await shelf()
        let result = r.search("wélls")
        #expect(result.clusters.map(\.kind) == [.audiobook])
        #expect(result.clusters[0].hit.count == 1)
        #expect(result.authors == [Shelf.SearchResult.Author(name: "H. G. Wells", count: 1)])
        #expect(r.search("wélls", kind: .book).empty)
        #expect(r.parts(author: "h. g. wells", sorting: .title).flatMap(\.entries).count == 1)
    }

    @Test("Rank: start before word start before middle before author")
    func rang() {
        let w = Shelf.searchWords("Hol")
        #expect(Shelf.rang(w, name: "Holmes", others: []) == 0)
        #expect(Shelf.rang(w, name: "Sherlock Holmes", others: []) == 1)
        #expect(Shelf.rang(w, name: "Whole", others: []) == 2)
        #expect(Shelf.rang(w, name: "Brise", others: ["Holger"]) == 3)
        #expect(Shelf.rang(w, name: "Brise", others: []) == nil)
        #expect(Shelf.searchWords("Ätna  vulkan") == ["atna", "vulkan"])
    }

    @Test("Saved: entries in order, filter in the library, series via a volume")
    func saved() async throws {
        let r0 = try await shelf()
        let memoirs = r0.allTitles.first { $0.name.hasPrefix("The Memoirs") }!
        let volume = r0.allTitles.first { $0.name == "Pepper&Carrot 37" }!
        let r = r0.with(saved: [.title(memoirs.identifier), .title(volume.identifier)])
        #expect(r.savedEntries.map(\.name) == ["The Memoirs of Sherlock Holmes", "Pepper&Carrot 37"])
        #expect(r.isSaved(.series(r.allSeries.first { $0.kind == .manga }!)))
        #expect(r.parts(sorting: .title, filter: .saved).flatMap(\.entries).count == 2)
        let without = r.with(saved: [.title(TitleID(source: memoirs.identifier.source, id: "weg"))])
        #expect(without.savedEntries.isEmpty)
    }
}

@Suite("Sorting by rating")
struct RatingTests {

    @Test("The best first, without stars last")
    func rating() async throws {
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() { extracts.append(try await q.library()) }
        let r = Shelf(extracts: extracts, bookSeriesList: [], now: MockShelf.state)
        let entries = r.parts(kind: .book, sorting: .rating).flatMap(\.entries)
        #expect(
            entries.map(\.name) == [
                "Frankenstein", "The Adventures of Sherlock Holmes", "The Memoirs of Sherlock Holmes",
            ])
        let all = r.parts(sorting: .rating).flatMap(\.entries)
        #expect(all.last?.rating == nil, "Hörbücher ohne Sterne stehen zuletzt")
    }
}

/// Series as a series in the grid — the collection view over the library's books.
@Suite("Series and collections")
struct SeriesBundlingTests {

    private func shelf(bookSeriesList: Set<Kind>) async throws -> Shelf {
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() {
            let a = try await q.library()
            let s = (try? await q.collections()) ?? []
            extracts.append(a.with(collections: s))
        }
        return Shelf(extracts: extracts, bookSeriesList: bookSeriesList, now: MockShelf.state)
    }

    @Test(
        "With series: Sherlock Holmes stands as one series, Frankenstein stays a title; without: three titles"
    )
    func bundling() async throws {
        let with = try await shelf(bookSeriesList: [.book])
        let entries = with.entries(.book)
        #expect(entries.count == 2)
        #expect(
            entries.contains { if case .series(let s) = $0 { s.name == "Sherlock Holmes" } else { false } })
        #expect(
            entries.contains { if case .title(let t) = $0 { t.name == "Frankenstein" } else { false } })
        #expect(try await shelf(bookSeriesList: []).entries(.book).count == 3)
        // Audiobooks without series in the mock shelf stay titles, also bundled.
        #expect(try await shelf(bookSeriesList: [.audiobook]).entries(.audiobook).count == 3)
        #expect(with.with(bookSeriesList: []).entries(.book).count == 3)
    }

    @Test(
        "Sammlungen: die Grimmory-Attrappe bringt „Summer Reading“ mit Frankenstein; eine geordnete Sammlung sortiert nicht um"
    )
    func collections() async throws {
        let r = try await shelf(bookSeriesList: [.book])
        #expect(r.collections.map(\.name) == ["Summer Reading"])
        let s = try #require(r.collections.first)
        #expect(r.entries(in: s).map(\.name) == ["Frankenstein"])
        #expect(r.cover(for: s).count == 1)
        let frankenstein = r.allTitles.first { $0.name == "Frankenstein" }!
        #expect(r.collections(with: .title(frankenstein)).count == 1)
        #expect(r.parts(collection: s.identifier, sorting: .title).flatMap(\.entries).count == 1)
        let holmes = r.allTitles.first { $0.name.hasPrefix("The Memoirs") }!
        let ordered = TitleCollection(
            identifier: CollectionID(source: s.identifier.source, id: "l"), name: "Leseliste",
            collectionKind: .readingList,
            entries: [.title(holmes.identifier), .title(frankenstein.identifier)], ordered: true,
            editable: true)
        let r2 = r.with(ordered)
        #expect(r2.collections.count == 2)
        #expect(
            r2.parts(collection: ordered.identifier, sorting: .title).flatMap(\.entries).map(\.name)
                == ["The Memoirs of Sherlock Holmes", "Frankenstein"], "Serverreihenfolge, nicht alphabetisch"
        )
        let r3 = r2.with(ordered.with(.title(holmes.identifier), into: false))
        #expect(r3.entries(in: r3.collection(ordered.identifier)!).count == 1)
    }
}

extension SeriesBundlingTests {

    @Test("A new reading state keeps collections, titles and volumes — and equals the freshly built shelf")
    func stateKeepsCollections() async throws {
        let r = try await shelf(bookSeriesList: [.book])
        let title = try #require(r.allTitles.first)
        let state = ReadingState(position: .page(3, from: 10), timestamp: MockShelf.state)
        let new = r.with(state, for: title.identifier)
        #expect(!r.collections.isEmpty)
        #expect(new.collections == r.collections)
        #expect(new.readingState(title.identifier) == state)
        #expect(new.title(title.identifier) == title)
        let fresh = Shelf(extracts: new.extracts, bookSeriesList: [.book], now: MockShelf.state)
        #expect(new == fresh, "the copied lookups are the ones a rebuild would have")
    }
}

@Suite("Shelf keeps its series choice")
struct SeriesChoiceKeptTests {
    @Test("with(state:), with(keep:), with(saved:) carry the series choice on")
    func stays() {
        let source = SourceID(provider: .komga, server: "x")
        let shelf = Shelf(extracts: [], bookSeriesList: [])
        let identifier = TitleID(source: source, id: "1")
        #expect(shelf.with(nil, for: identifier).bookSeriesList.isEmpty)
        #expect(shelf.with(keep: [identifier]).bookSeriesList.isEmpty)
        #expect(shelf.with(saved: []).bookSeriesList.isEmpty)
    }
}
