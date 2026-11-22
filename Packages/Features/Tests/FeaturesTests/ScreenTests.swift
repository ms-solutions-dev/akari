import AccountsKit
import Bedrock
import Library
import Metadata
import OfflineStore
import SourcesKit
import SourcesKitMocks
import SwiftUI
import Testing

@testable import Features

/// What can be checked on the screens without a catalog: the phrases themselves come from
/// `Localizable.xcstrings` and appear in the test run only as keys.
@Suite("Start, library, detail")
@MainActor
struct ScreenTests {

    @Test("Stars: full from 0.75, half from 0.25, otherwise empty")
    func stars() {
        #expect(
            (0..<5).map { Stars.symbol(4.2, $0) } == [
                "star.fill", "star.fill", "star.fill", "star.fill", "star",
            ])
        #expect(Stars.symbol(3.5, 3) == "star.leadinghalf.filled")
        #expect(Stars.symbol(3.8, 3) == "star.fill")
        #expect(Stars.symbol(3.1, 3) == "star")
    }

    @Test("The details in the title detail: only what the server said")
    func details() {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let empty = Title(identifier: TitleID(source: source, id: "1"), kind: .book, name: "Ohne alles")
        #expect(TitleDetailView.details(empty).isEmpty)
        let full = Title(
            identifier: TitleID(source: source, id: "2"), kind: .audiobook, name: "Alles",
            scope: .duration(33_120),
            language: "de", ageRating: 12, publisher: "Fleidro", narrator: ["S. Stimme"], size: 1_200_000,
            format: "MP3")
        let share = TitleDetailView.details(full)
        #expect(share.count == 6, "duration, format, size, narrator, language, age; the publisher is a link")
        #expect(share[1] == "MP3")
        #expect(!share.contains("Fleidro"))
    }

    @Test(
        "Keeping an audiobook: the sheet's phrase names title, tracks and total; the storage row the tracks")
    func audiobookKeep() {
        let source = SourceID(provider: .audiobookshelf, server: "hoerbuch.example")
        let title = Title(
            identifier: TitleID(source: source, id: "li_1"), kind: .audiobook, name: "The Time Machine",
            scope: .duration(38_000), size: 640_000_000)
        let volume = AudioManifest(
            tracks: (0..<3).map {
                AudioTrack(
                    address: URL(string: "https://hoerbuch.example/api/items/li_1/file/\($0)")!,
                    startTime: Double($0) * 10,
                    duration: 10, size: 1_000_000, fileExtension: "mp3")
            }, chapter: [])
        let phrase = KeepButton.audiobookPhrase(title, volume: volume, onTheGo: false)
        #expect(phrase.hasPrefix("The Time Machine · "))
        #expect(phrase.contains("3"))
        #expect(phrase.contains(Formats.bytes(3_000_000)))
        #expect(!phrase.contains(Formats.bytes(640_000_000)), "the data package counts, not the list")
        // Without a data package only the list; on the road the notice goes into a second row.
        let without = KeepButton.audiobookPhrase(title, volume: nil, onTheGo: true)
        #expect(without.hasPrefix("The Time Machine · " + Formats.bytes(640_000_000) + "\n"))
        let entry = KeptItem(
            identifier: title.identifier, name: title.name, kind: .audiobook, since: Date(), size: 3_000_000,
            state: .done, files: ["spur-0001.mp3", "spur-0002.mp3", "spur-0003.mp3"])
        #expect(StorageView.secondaryLine(entry).hasSuffix(" · " + Formats.bytes(3_000_000)))
        #expect(
            StorageView.secondaryLine(entry.with(state: .done, files: ["a"])) != Formats.bytes(3_000_000))
        let book = KeptItem(
            identifier: title.identifier, name: "Buch", kind: .book, since: Date(), size: 800_000,
            state: .done,
            files: ["inhalt.epub"])
        #expect(StorageView.secondaryLine(book) == Formats.bytes(800_000))
    }

    @Test("The format from extension and content type")
    func format() {
        #expect(Title.format(".epub") == "EPUB")
        #expect(Title.format("pdf") == "PDF")
        #expect(Title.format("application/zip") == "CBZ")
        #expect(Title.format("application/x-rar-compressed; version=4") == "CBR")
        #expect(Title.format("application/epub+zip") == "EPUB")
        #expect(Title.format("audio/mpeg") == "MP3")
        #expect(Title.format("audio/mp4") == "M4B")
        #expect(Title.format("application/x-mobipocket-ebook") == nil)
        #expect(Title.format("") == nil)
        #expect(Title.format(nil) == nil)
    }

    @Test("Author header: life dates with star and cross, counter per kind, sections by last name")
    func authorHeader() {
        let living = AuthorProfile(
            name: "X", born: LifeDate(year: 1958, month: 3, day: 14), language: "de")
        #expect(AuthorHeader.lifeDates(living)?.hasPrefix("* ") == true)
        #expect(AuthorHeader.lifeDates(living)?.contains("†") == false)
        let tot = AuthorProfile(
            name: "Y", born: LifeDate(year: 1920), died: LifeDate(year: 1995, month: 3),
            language: "en")
        #expect(AuthorHeader.lifeDates(tot)?.contains(" · † ") == true)
        #expect(AuthorHeader.lifeDates(AuthorProfile(name: "Z", language: "de")) == nil)
        #expect(
            AuthorHeader.counterText([.audiobook: 2, .book: 3]).hasPrefix("counter.books"),
            "books before audiobooks; in the test run only the key")
        let authors = [
            Shelf.Author(lookupKey: "a", name: "Annika Elsner", count: [.book: 1], cover: nil),
            Shelf.Author(lookupKey: "b", name: "J. K. Ravensdale", count: [.book: 1], cover: nil),
            Shelf.Author(lookupKey: "c", name: "Éric Émile", count: [.book: 1], cover: nil),
            Shelf.Author(lookupKey: "d", name: "3Nord", count: [.book: 1], cover: nil),
        ]
        let parts = AuthorList<EmptyView>.parts(authors)
        #expect(parts.map(\.header) == ["E", "R", "#"])
        #expect(parts[0].authors.map(\.name) == ["Annika Elsner", "Éric Émile"])
    }

    @Test("Placeholder per kind")
    func placeholder() {
        #expect(Cover.glyph(.manga) == "book.pages")
        #expect(Cover.glyph(.book) == "book.closed")
        #expect(Cover.glyph(.audiobook) == "headphones")
    }

    @Test("The shell takes a library with mocks, and Start is full after refreshing")
    func shellWithLibrary() async {
        let state = ProfileState()
        defer { state.tidyUp() }
        let sources = MockShelf.base()
        let context = state.context(state.profiles.active, state.profiles.activeStore, state.device) {
            sources
        }
        _ = ShellView(profiles: state.profiles, context: { _, _, _ in context }, device: state.device)
        await context.inventory.refresh()
        #expect(context.inventory.shelf.continueReading.count == 4)
        #expect(context.inventory.shelf.kinds.count == 3)
    }

    @Test("Summary: Markdown and link lists drop out, the text stays")
    func summary() {
        let raw = """
            From Hollowbrook Press:
            As a child, Edda sat at the feet of Arvid.

            **Official Japanese:**
            [Comic Harbor](https://comics.example/episode/1), [Pocket](https://pocket.example/2)

            Note: Nominated in 2008. See https://example.org/x for more.
            """
        let clean = Summary.cleaned(raw)
        #expect(clean.hasPrefix("From Hollowbrook Press:\nAs a child"))
        #expect(!clean.contains("**") && !clean.contains("http") && !clean.contains("]("))
        #expect(clean.contains("Official Japanese:\nComic Harbor, Pocket"))
        #expect(clean.hasSuffix("See for more."))
    }

    @Test("Blurb from HTML: paragraphs become lines, tags drop, entities become characters")
    func klappentextHTML() {
        let raw =
            "<p><b>»Ein beklemmender Thriller.« Sandhafener Bote</b></p><br><p>In einer versunkenen Stadt leben nur noch wenige Fischer.</p><br><p><b>»Selten so packend.« Lesebote&nbsp;</b></p>"
        let clean = Summary.cleaned(raw)
        #expect(!clean.contains("<") && !clean.contains("&nbsp;"))
        #expect(clean.hasPrefix("»Ein beklemmender Thriller.« Sandhafener Bote\n"))
        #expect(clean.contains("\nIn einer versunkenen Stadt"))
        #expect(clean.hasSuffix("»Selten so packend.« Lesebote"))
        #expect(Summary.cleaned("Ohne HTML, mit a < b.") == "Ohne HTML, mit a < b.")
    }
}

/// Search and saved: the parts that compute without a screen.
@Suite("Search and saved")
@MainActor
struct SearchSavedTests {

    @Test("The search history: newest first, without duplicates, at most eight, deletable")
    func history() {
        let name = "verlauf-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = SearchHistory(persistence: defaults)
        history.save("Holmes")
        history.save("  ")
        history.save("Piece")
        history.save("holmes")
        #expect(history.entries == ["holmes", "Piece"])
        for i in 0..<10 { history.save("Suche \(i)") }
        #expect(history.entries.count == SearchHistory.atMost)
        #expect(SearchHistory(persistence: defaults).entries == history.entries)
        history.clearOut()
        #expect(history.entries.isEmpty)
        #expect(SearchHistory(persistence: defaults).entries.isEmpty)
    }

    @Test("Dragging on the saved page: visible positions become positions of the full list")
    func spots() async throws {
        let source = MockShelf.grimmoryReadOnly()
        let extract = try await source.library()
        let foreign = TitleID(source: SourceID(provider: .komga, server: "comics2.example"), id: "x")
        let full: [SaveTarget] = [
            .title(extract.title[0].identifier), .title(foreign), .title(extract.title[1].identifier),
            .title(extract.title[2].identifier),
        ]
        let shelf = Shelf(extracts: [extract], saved: full)
        let visible = shelf.savedEntries
        #expect(visible.count == 3, "the foreign entry is missing in the view")
        #expect(SavedView.spots([1], visible: visible, full: full) == [2])
        #expect(SavedView.spot(0, visible: visible, full: full) == 0)
        #expect(SavedView.spot(2, visible: visible, full: full) == 3)
        #expect(SavedView.spot(3, visible: visible, full: full) == 4)
    }

    @Test("The shell with mocks: search finds, saving lands on the shelf")
    func searchAndSave() async throws {
        let sources = MockShelf.base()
        let name = "merken-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = LibraryService(
            persistence: LibraryStore(
                folder: FileManager.default.temporaryDirectory.appending(
                    path: "features-\(UUID().uuidString)")),
            savedList: SavedList(persistence: defaults, cloud: nil), settings: defaults
        ) { sources }
        await service.refresh()
        // Books are bundled: "holmes" hits the series, not two titles.
        let result = service.shelf.search("holmes")
        #expect(result.clusters.map(\.kind) == [.book])
        #expect(SearchView.groupHeader(result.clusters[0]).hasSuffix("1"))
        guard case .series(let bookSeries, _) = result.clusters[0].hit[0] else {
            Issue.record("no series")
            return
        }
        #expect(bookSeries.name == "Sherlock Holmes")
        let holmes = try #require(service.shelf.volumes(bookSeries.identifier).first)
        try await service.save(.title(holmes.identifier), saved: true)
        #expect(service.shelf.savedEntries.map(\.name) == [holmes.name])
        #expect(sources[1].saved == [holmes.identifier])
        // Without bundling, two titles again.
        service.bookSeriesList = []
        #expect(service.shelf.search("holmes").clusters[0].hit.count == 2)
    }
}

@Suite("Translating")
@MainActor
struct TranslateTests {

    @Test("Foreign language detected: Polish and English foreign, the device language not, short texts never")
    func foreignLanguage() {
        let polish =
            "Gdy burza odcięła wyspę od lądu, mieszkańcy zamknęli się w starej latarni morskiej i czekali na świt."
        let device = Locale.current.language.languageCode?.identifier ?? "de"
        let foreign = Summary.foreignLanguage(polish)
        #expect(foreign == (device == "pl" ? nil : "pl"))
        let english =
            "Seventeen-year-old Tomo Varga is tired of the harbour. The work is dull and the winter is long."
        #expect(Summary.foreignLanguage(english) == (device == "en" ? nil : "en"))
        #expect(Summary.foreignLanguage("1905") == nil)
        #expect(Summary.languageName("pl").count > 2)
    }
}

/// The sizes per size class: larger on iPad, on iPhone as
/// before; and in the image loader one tier per device.
@Suite("Tile metrics per size class")
@MainActor
struct TileMetricsTests {

    @Test("Narrow stays 118/110/110, wide becomes 150/140/160")
    func measures() {
        #expect(TileMetrics.line(.compact) == 118)
        #expect(TileMetrics.raster(.compact) == 110)
        #expect(TileMetrics.large(.compact) == 110)
        #expect(TileMetrics.line(nil) == 118, "without a size class as narrow")
        #expect(TileMetrics.line(.regular) == 150)
        #expect(TileMetrics.raster(.regular) == 140)
        #expect(TileMetrics.large(.regular) == 160)
        #expect(TileMetrics.gridCap(.compact) == 150, "the grid cap as before")
    }

    @Test("Image loader: one tier per device, iPhone 560, iPad 480 for all three sizes")
    func levels() {
        let iphone = Set([118, 110, 110].map { Cover.pixels(width: CGFloat($0), displayScale: 3) })
        #expect(iphone == [560])
        let ipad = Set(
            [TileMetrics.line(.regular), TileMetrics.raster(.regular), TileMetrics.large(.regular)].map {
                Cover.pixels(width: $0, displayScale: 2)
            })
        #expect(ipad == [480], "no second store entry next to the detail cover")
    }

    @Test("Volume list: grid up to 30, above that two columns on iPad, otherwise list; AX always list")
    func collectionKind() {
        #expect(SeriesDetailView.collectionKind(volumes: 3, large: false, wide: false) == .raster)
        #expect(SeriesDetailView.collectionKind(volumes: 30, large: false, wide: true) == .raster)
        #expect(SeriesDetailView.collectionKind(volumes: 31, large: false, wide: false) == .list)
        #expect(SeriesDetailView.collectionKind(volumes: 120, large: false, wide: true) == .columns)
        #expect(SeriesDetailView.collectionKind(volumes: 120, large: true, wide: true) == .list)
        #expect(SeriesDetailView.collectionKind(volumes: 3, large: true, wide: false) == .list)
    }

    @Test("Scrolling to the current volume only for a started series")
    func scroll() async throws {
        let started = try await MockShelf.komga().library()
        let shelf = Shelf(extracts: [started])
        let islandTrip = try #require(shelf.allSeries.first)
        #expect(SeriesDetailView.scrollsToCurrent(shelf.seriesState(islandTrip.identifier)))
        let source = SourceID(provider: .komga, server: "comics2.example")
        let long = SeriesID(source: source, id: "LANG")
        let unread = LibraryExtract(
            source: source,
            seriesList: [Series(identifier: long, kind: .manga, name: "Little Nemo", volumeCount: 2)],
            title: (1...2).map {
                Title(
                    identifier: TitleID(source: source, id: "LANG-\($0)"), kind: .manga, name: "Band \($0)",
                    series: SeriesReference(identifier: long, name: "Little Nemo", volume: Double($0)))
            },
            readingStates: [:], state: Date())
        let state = Shelf(extracts: [unread]).seriesState(long)
        #expect(state.current?.series?.volume == 1, "volume 1 is the current one")
        #expect(!SeriesDetailView.scrollsToCurrent(state), "and the header stays on top anyway")
    }
}
