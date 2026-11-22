import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import OpdsKit

/// The Atom parser and the catalog crawl — against feeds recorded from a Komga and a Grimmory
/// server; as long as those are missing, against a small OPDS 1.2 feed.
@Suite("OpdsKit")
struct OpdsKitTests {
    let catalog = URL(string: "https://comics.example/opds/v1.2/catalog")!

    private func account() -> OpdsAccount {
        OpdsAccount(catalog: catalog, username: "leser", password: "geheim", title: "Komga")
    }

    static let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog"
              xmlns:pse="http://vaemendis.net/opds-pse/ns" xmlns:dc="http://purl.org/dc/terms/">
          <id>series:1</id>
          <title>Inselreise</title>
          <link rel="self" href="/opds/v1.2/series/1" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
          <link rel="next" href="/opds/v1.2/series/1?page=1" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
          <entry>
            <id>book:46</id>
            <title>Band 46</title>
            <updated>2026-09-01T10:00:00Z</updated>
            <author><name>P. Secan</name></author>
            <summary>Ein Band.</summary>
            <dc:language>de</dc:language>
            <dc:publisher>Piosul</dc:publisher>
            <category term="Abenteuer" label="Abenteuer"/>
            <link rel="http://opds-spec.org/acquisition" href="/opds/v1.2/books/46/file/x.cbz" type="application/zip"/>
            <link rel="http://vaemendis.net/opds-pse/stream" href="/opds/v1.2/books/46/pages/{pageNumber}?zero_based=true" type="image/jpeg" pse:count="198"/>
            <link rel="http://opds-spec.org/image/thumbnail" href="/opds/v1.2/books/46/thumbnail" type="image/jpeg"/>
          </entry>
          <entry>
            <id>book:47</id>
            <title>Plinpro, Teil 1–5</title>
            <author><name>Jegeil Jauthern</name></author>
            <content type="html">&lt;p&gt;Eine Welt unter der Drukat, ganz ausführlich broustiat.&lt;/p&gt;</content>
            <dc:issued>2012</dc:issued>
            <link rel="http://opds-spec.org/acquisition/open-access" href="/opds/v1.2/books/47/file/plinpro.epub" type="application/epub+zip"/>
            <link rel="http://opds-spec.org/image" href="/opds/v1.2/books/47/cover" type="image/jpeg"/>
          </entry>
          <entry>
            <id>book:48</id>
            <title>Ohne Strom</title>
            <link rel="http://opds-spec.org/acquisition" href="/opds/v1.2/books/48/file/x.cbz" type="application/vnd.comicbook+zip"/>
          </entry>
        </feed>
        """

    @Test("The parser: feed, entries, links with rel/type/pse:count, authors, categories, date")
    func parser() throws {
        let feed = try OpdsParser.parse(Data(Self.sample.utf8))
        #expect(feed.title == "Inselreise" && feed.id == "series:1")
        #expect(feed.next?.href == "/opds/v1.2/series/1?page=1")
        #expect(feed.entries.count == 3)
        let volume = feed.entries[0]
        #expect(volume.authors == ["P. Secan"] && volume.categories == ["Abenteuer"])
        #expect(volume.language == "de" && volume.publisher == "Piosul")
        #expect(volume.pageStream?.pages == 198)
        #expect(volume.image?.href == "/opds/v1.2/books/46/thumbnail")
        #expect(volume.refreshed != nil)
        let plinpro = feed.entries[1]
        #expect(plinpro.acquisition?.type == "application/epub+zip")
        #expect(plinpro.content?.contains("Eine Welt unter der Drukat") == true)
        #expect(plinpro.released != nil)
        #expect(!feed.isNavigation)
    }

    @Test(
        "The mapping: manga with stream, book from EPUB, comic without stream drops out; volume number from the title"
    )
    func mapping() throws {
        let feed = try OpdsParser.parse(Data(Self.sample.utf8))
        let source = OpdsSource(account: account(), transport: MockTransport(), persistence: nil)
        let address = URL(string: "https://comics.example/opds/v1.2/series/1")!
        let title = feed.entries.compactMap {
            OpdsMapping.title(
                $0, feed: feed, feedAddress: address, bookSeries: "Inselreise", source: account().identifier,
                resolve: source.absolute)
        }
        #expect(title.count == 2, "the comic without a page stream is not readable")
        let volume = title[0]
        #expect(volume.kind == .manga && volume.series?.volume == 46 && volume.format == "CBZ")
        #expect(volume.cover?.absoluteString == "https://comics.example/opds/v1.2/books/46/thumbnail")
        if case .pageStream(let count, let page, _) = source.content(volume) {
            #expect(count == 198)
            #expect(
                page(1).absoluteString
                    == "https://comics.example/opds/v1.2/books/46/pages/0?zero_based=true",
                "the reader counts 1-based, zero_based turns it to 0")
        } else {
            Issue.record("no page stream")
        }
        let plinpro = title[1]
        #expect(plinpro.kind == .book && plinpro.format == "EPUB")
        #expect(plinpro.summary?.hasPrefix("<p>Eine Welt") == true, "the UI strips HTML")
        #expect(
            source.file(plinpro)?.absoluteString == "https://comics.example/opds/v1.2/books/47/file/plinpro.epub")
        if case .file(let url, _, _) = source.content(plinpro) { #expect(url.path().hasSuffix("plinpro.epub")) }
        #expect(OpdsMapping.volumeNumber("Vol. 12", bookSeries: "x") == 12)
        #expect(OpdsMapping.volumeNumber("Ankerlicht 02 – Gezeiten", bookSeries: "x") == 2)
        #expect(OpdsMapping.volumeNumber("Der Glasgarten", bookSeries: "x") == nil)
        #expect(OpdsMapping.volumeNumber("Band 3", bookSeries: nil) == nil)
    }

    @Test(
        "The crawl: root → series → series; duplicates once; Basic Auth on every request; series from the parent feed"
    )
    func run() async throws {
        let t = MockTransport()
        let root = """
            <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Komga</title>
            <link rel="search" href="/opds/v1.2/search?q={searchTerms}" type="application/atom+xml"/>
            <entry><id>series</id><title>All series</title>
              <link rel="subsection" href="/opds/v1.2/series" type="application/atom+xml;profile=opds-catalog;kind=navigation"/></entry>
            <entry><id>latest</id><title>Latest</title>
              <link rel="subsection" href="/opds/v1.2/latest" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            </feed>
            """
        let seriesList = """
            <feed xmlns="http://www.w3.org/2005/Atom"><id>series</id><title>All series</title>
            <entry><id>series:1</id><title>Inselreise</title>
              <link rel="subsection" href="/opds/v1.2/series/1" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            </feed>
            """
        t.answer("GET", "/opds/v1.2/catalog", with: .init(data: Data(root.utf8)))
        t.answer("GET", "/opds/v1.2/series", with: .init(data: Data(seriesList.utf8)))
        t.answer("GET", "/opds/v1.2/series/1", with: .init(data: Data(Self.sample.utf8)))
        t.answer("GET", "/opds/v1.2/series/1", with: .init(data: Data(Self.sample.utf8)))
        // "Latest" names volume 46 once more — it counts once.
        t.answer("GET", "/opds/v1.2/latest", with: .init(data: Data(Self.sample.utf8)))
        let source = OpdsSource(account: account(), transport: t, persistence: nil)
        let extract = try await source.library()
        #expect(extract.title.count == 2)
        #expect(extract.seriesList.map(\.name) == ["Inselreise"])
        #expect(extract.seriesList[0].volumeCount == 2)
        #expect(
            t.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true
            })
        let addresses = t.requests.compactMap { $0.url?.absoluteString }
        #expect(
            Set(addresses).count == addresses.count && addresses.count == 5,
            "every feed once — the second page of the series is its own")
    }

    @Test(
        "The crawl reads a list to the end before it goes into the branches, and drops branches that bring nothing new five times"
    )
    func branches() async throws {
        let t = MockTransport()
        func book(_ n: Int) -> String {
            """
            <entry><id>book:\(n)</id><title>Buch \(n)</title>
              <link rel="http://opds-spec.org/acquisition" href="/opds/v1.2/books/\(n)/file/b.epub" type="application/epub+zip"/></entry>
            """
        }
        func list(_ title: String, _ books: [Int], proceed: String? = nil) -> String {
            let next = proceed.map {
                "<link rel=\"next\" href=\"\($0)\" type=\"application/atom+xml;profile=opds-catalog;kind=acquisition\"/>"
            }
            return """
                <feed xmlns="http://www.w3.org/2005/Atom"><id>\(title)</id><title>\(title)</title>\(next ?? "")
                \(books.map(book).joined())
                </feed>
                """
        }
        let root = """
            <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Katalog</title>
            <entry><id>all</id><title>All Books</title>
              <link rel="subsection" href="/opds/v1.2/all/1" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            <entry><id>recent</id><title>Recently Added</title>
              <link rel="subsection" href="/opds/v1.2/recent/1" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            <entry><id>authors</id><title>Authors</title>
              <link rel="subsection" href="/opds/v1.2/authors" type="application/atom+xml;profile=opds-catalog;kind=navigation"/></entry>
            </feed>
            """
        t.answer("GET", "/opds/v1.2/catalog", with: .init(data: Data(root.utf8)))
        // "All books": three pages, six books.
        for page in 1...3 {
            let proceed = page < 3 ? "/opds/v1.2/all/\(page + 1)" : nil
            t.answer(
                "GET", "/opds/v1.2/all/\(page)",
                with: .init(data: Data(list("All Books", [page * 2 - 1, page * 2], proceed: proceed).utf8)))
        }
        // "New": twelve pages with the same books.
        for page in 1...12 {
            let proceed = page < 12 ? "/opds/v1.2/recent/\(page + 1)" : nil
            t.answer(
                "GET", "/opds/v1.2/recent/\(page)",
                with: .init(data: Data(list("Recently Added", [page % 6 + 1], proceed: proceed).utf8)))
        }
        // Twelve authors, each with a known book.
        let authors = (1...12).map {
            """
            <entry><id>author:\($0)</id><title>Autor \($0)</title>
              <link rel="subsection" href="/opds/v1.2/author/\($0)" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            """
        }.joined()
        t.answer(
            "GET", "/opds/v1.2/authors",
            with: .init(
                data: Data(
                    "<feed xmlns=\"http://www.w3.org/2005/Atom\"><id>a</id><title>Authors</title>\(authors)</feed>"
                        .utf8)))
        for n in 1...12 {
            t.answer(
                "GET", "/opds/v1.2/author/\(n)",
                with: .init(data: Data(list("Books by \(n)", [n % 6 + 1]).utf8)))
        }
        let source = OpdsSource(account: account(), transport: t, persistence: nil)
        let extract = try await source.library()
        #expect(extract.title.count == 6)
        let paths = t.paths.map { $0.replacingOccurrences(of: "GET /opds/v1.2/", with: "") }
        #expect(
            Array(paths.prefix(4)) == ["catalog", "all/1", "all/2", "all/3"], "the list to the end first")
        #expect(paths.filter { $0.hasPrefix("recent/") }.count == 5, "five empty pages, then stop")
        #expect(paths.filter { $0.hasPrefix("author/") }.count == 5, "five empty authors, then stop")
        #expect(paths.count == 15, "root, three pages All, five New, author list, five authors")
    }

    @Test("Sign-in reads the catalog title and the search template; 401 means signed out")
    func signIn() async throws {
        let t = MockTransport()
        t.answer(
            "GET", "/opds/v1.2/catalog",
            with: .init(
                data: Data(
                    """
                    <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Komga OPDS catalog</title>
                    <link rel="search" href="/opds/v1.2/search?q={searchTerms}" type="application/atom+xml"/></feed>
                    """.utf8)))
        let account = try await OpdsSource.signIn(
            catalog: catalog, username: "leser", password: "geheim", transport: t)
        #expect(account.title == "Komga OPDS catalog")
        #expect(account.search == "https://comics.example/opds/v1.2/search?q={searchTerms}")
        #expect(account.identifier == SourceID(provider: .opds, server: "comics.example"))
        let t2 = MockTransport()
        t2.answer("GET", "/opds/v1.2/catalog", with: .init(status: 401))
        await #expect(throws: SourceError.signedOut(account.identifier)) {
            try await OpdsSource.signIn(catalog: catalog, username: "x", password: "y", transport: t2)
        }
    }

    @Test("Reading state locally: write, read, forget, from disk")
    func readingState() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "opds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let source = OpdsSource(account: account(), transport: MockTransport(), persistence: file)
        let identifier = TitleID(source: account().identifier, id: "book:47")
        #expect(try await source.progress(identifier) == nil)
        let state = ReadingState(position: .position(cfi: "epubcfi(/6/4)", fraction: 0.3), timestamp: Date())
        try await source.write(state, for: identifier)
        #expect(try await source.progress(identifier)?.fraction == 0.3)
        let again = OpdsSource(account: account(), transport: MockTransport(), persistence: file)
        #expect(try await again.progress(identifier)?.fraction == 0.3)
        try await again.forget(progressFor: identifier)
        #expect(try await again.progress(identifier) == nil)
    }
}

/// Against recorded feeds: Komga 1.26 (`/opds/v1.2`) and Grimmory 3.3.3 (`/api/v1/opds`).
@Suite("OPDS — real feeds")
struct OpdsFeedTests {

    private func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("Komga: catalog with nine navigation entries, search as OpenSearch description, v2 alternative")
    func komgaCatalog() throws {
        let feed = try OpdsParser.parse(data("komga-catalog.xml"))
        #expect(feed.title == "Komga OPDS catalog")
        #expect(feed.entries.count == 9 && feed.isNavigation)
        #expect(feed.entries.map(\.title).contains("All series"))
        #expect(feed.search?.href == "https://comics.example/opds/v1.2/search")
        #expect(feed.search?.type == "application/opensearchdescription+xml")
        #expect(
            OpdsParser.searchTemplate(try data("komga-search.xml"))
                == "https://comics.example/opds/v1.2/series?search={searchTerms}")
    }

    @Test("Komga: the series feed pages (next), the series has volumes with page stream, file, image, size")
    func komgaSeries() throws {
        let seriesList = try OpdsParser.parse(data("komga-series.xml"))
        #expect(seriesList.next?.href == "https://comics.example/opds/v1.2/series?page=1")
        #expect(seriesList.isNavigation && seriesList.entries.first?.title == "Fiahot slem Wani")
        let series = try OpdsParser.parse(data("komga-serie.xml"))
        #expect(series.title == "Fiahot slem Wani")
        let volume = try #require(series.entries.first)
        #expect(volume.authors == ["Triadroflur Binsiojiarn"], "six roles, one name")
        #expect(volume.pageStream?.pages == 333)
        #expect(
            volume.acquisition?.href.hasSuffix(".cbr") == true
                && volume.acquisition?.type == "application/zip")
        #expect(volume.size == Int64(457.1 * 1024 * 1024))
        #expect(volume.image?.href.hasSuffix("/thumbnail") == true)
        let source = OpdsSource(
            account: OpdsAccount(
                catalog: URL(string: "https://comics.example/opds/v1.2/catalog")!, username: "",
                password: "", title: "Komga"),
            transport: MockTransport(), persistence: nil)
        let address = URL(string: "https://comics.example/opds/v1.2/series/0RM6ZZJWZS971")!
        let title = series.entries.enumerated().compactMap { i, e in
            OpdsMapping.title(
                e, feed: series, feedAddress: address, bookSeries: series.title, slot: i + 1,
                source: source.identifier, resolve: source.absolute)
        }
        #expect(title.count == series.entries.count, "every volume has a page stream")
        #expect(title[0].kind == .manga && title[0].format == "CBR" && title[1].format == "CBZ")
        #expect(title[0].name == "Fiahot zi Wani Doppelband-Edition 1 - Triadroflur Binsiojiarn")
        #expect(
            title[0].series?.volume == 1 && title[1].series?.volume == 2,
            "volume number from the position in the feed")
        #expect(title[0].summary == nil, "cbr - 457.1 MiB is no blurb")
        #expect(title[0].size == volume.size)
        if case .pageStream(let count, let page, _) = source.content(title[0]) {
            #expect(count == 333)
            #expect(
                page(1).absoluteString == "https://comics.example/opds/v1.2/books/0RM6ZZJX3SFDH/pages/1",
                "without zero_based the reader's number stays")
        } else {
            Issue.record("no page stream")
        }
    }

    @Test(
        "Grimmory: series and volume from the entry, EPUB, publisher, language, category, relative cover; search"
    )
    func grimmorySeries() throws {
        let catalog = try OpdsParser.parse(data("grimmory-catalog.xml"))
        #expect(catalog.title == "Booklore Catalog" && catalog.isNavigation)
        #expect(
            OpdsParser.searchTemplate(try data("grimmory-search.xml"))
                == "/api/v1/opds/catalog?q={searchTerms}"
        )
        let series = try OpdsParser.parse(data("grimmory-serie.xml"))
        let e = try #require(series.entries.first)
        #expect(e.title == "Pe Cannugou" && e.authors == ["Veistiobrairn Sleistiazeind"])
        #expect(e.bookSeries == "Venpaimul Jibiozir" && e.volume == 1)
        #expect(e.publisher == "Stiaflidrorn C-Book" && e.language == "de" && e.categories == ["Thriller"])
        let source = OpdsSource(
            account: OpdsAccount(
                catalog: URL(string: "https://buecher.example/api/v1/opds")!, username: "", password: "",
                title: "Booklore"),
            transport: MockTransport(), persistence: nil)
        let address = URL(string: "https://buecher.example/api/v1/opds/catalog?series=Venpaimul+Jibiozir")!
        let t = try #require(
            OpdsMapping.title(
                e, feed: series, feedAddress: address, bookSeries: nil, source: source.identifier,
                resolve: source.absolute))
        #expect(t.kind == .book && t.format == "EPUB")
        #expect(
            t.series?.name == "Venpaimul Jibiozir" && t.series?.volume == 1,
            "the series is in the entry, no feed needed"
        )
        #expect(t.cover?.absoluteString.hasPrefix("https://buecher.example/api/v1/opds/34/cover") == true)
        #expect(
            source.file(t)?.absoluteString == "https://buecher.example/api/v1/opds/34/download?fileId=50")
        #expect(t.summary?.contains("Description removed") == true)
        let new = try OpdsParser.parse(data("grimmory-recent.xml"))
        #expect(new.entries.count == 50 && new.next?.href == "/api/v1/opds/recent?page=2&size=50")
    }

    @Test(
        "The crawl over the Komga recording: catalog → series → series; unknown branches are skipped"
    )
    func komgaCrawl() async throws {
        let t = MockTransport()
        try t.answer("GET", "/opds/v1.2/catalog", file: "komga-catalog.xml", from: .module)
        try t.answer("GET", "/opds/v1.2/series", file: "komga-series.xml", from: .module)
        try t.answer("GET", "/opds/v1.2/series/0RM6ZZJWZS971", file: "komga-serie.xml", from: .module)
        t.answer("GET", "/opds/v1.2/*", with: .init(status: 404))
        let source = OpdsSource(
            account: OpdsAccount(
                catalog: URL(string: "https://comics.example/opds/v1.2/catalog")!, username: "leser",
                password: "pw", title: "Komga"),
            transport: t, persistence: nil)
        let extract = try await source.library()
        #expect(extract.seriesList.map(\.name) == ["Fiahot slem Wani"])
        #expect(extract.title.count == extract.seriesList[0].volumeCount && extract.title.count > 0)
        #expect(extract.title.allSatisfy { $0.kind == .manga && $0.series?.name == "Fiahot slem Wani" })

        // The local reading state survives signing out and in again: new source, same file, same
        // title (the identifier carries file and stream, which do not change).
        let file = FileManager.default.temporaryDirectory.appending(
            path: "opds-lauf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = OpdsSource(account: source.account, transport: t, persistence: file)
        let volume = extract.title[0]
        try await first.write(
            ReadingState(position: .page(11, from: 333), timestamp: Date()), for: volume.identifier)
        let t2 = MockTransport()
        try t2.answer("GET", "/opds/v1.2/catalog", file: "komga-catalog.xml", from: .module)
        try t2.answer("GET", "/opds/v1.2/series", file: "komga-series.xml", from: .module)
        try t2.answer("GET", "/opds/v1.2/series/0RM6ZZJWZS971", file: "komga-serie.xml", from: .module)
        t2.answer("GET", "/opds/v1.2/*", with: .init(status: 404))
        let second = OpdsSource(account: source.account, transport: t2, persistence: file)
        let again = try await second.library()
        #expect(again.readingStates[volume.identifier]?.fraction == 11.0 / 333.0)
        #expect(again.title[0].identifier == volume.identifier, "same identifier on the second run")
    }

    @Test("A 404 is a dead branch; a disruption aborts the crawl, after a second attempt")
    func disruption() async throws {
        let t = MockTransport()
        try t.answer("GET", "/opds/v1.2/catalog", file: "komga-catalog.xml", from: .module)
        try t.answer("GET", "/opds/v1.2/series", file: "komga-series.xml", from: .module)
        t.answer("GET", "/opds/v1.2/series/0RM6ZZJWZS971", with: .init(status: 503))
        t.answer("GET", "/opds/v1.2/*", with: .init(status: 404))
        let account = OpdsAccount(
            catalog: URL(string: "https://comics.example/opds/v1.2/catalog")!, username: "", password: "",
            title: "Komga")
        let source = OpdsSource(account: account, transport: t, persistence: nil)
        await #expect(throws: SourceError.serverDisruption(account.identifier, status: 503)) {
            try await source.library()
        }
        #expect(t.paths.filter { $0.hasSuffix("/series/0RM6ZZJWZS971") }.count == 2, "a second attempt")
        // If the series arrives the second time, the catalog runs through.
        let t2 = MockTransport()
        try t2.answer("GET", "/opds/v1.2/catalog", file: "komga-catalog.xml", from: .module)
        try t2.answer("GET", "/opds/v1.2/series", file: "komga-series.xml", from: .module)
        t2.answer("GET", "/opds/v1.2/series/0RM6ZZJWZS971", with: .init(status: 503))
        try t2.answer("GET", "/opds/v1.2/series/0RM6ZZJWZS971", file: "komga-serie.xml", from: .module)
        t2.answer("GET", "/opds/v1.2/*", with: .init(status: 404))
        let extract = try await OpdsSource(account: account, transport: t2, persistence: nil).library()
        #expect(extract.seriesList.count == 1)
    }

    @Test("Signing in at Komga: title from the catalog, search template from the OpenSearch description")
    func komgaSignIn() async throws {
        let t = MockTransport()
        try t.answer("GET", "/opds/v1.2/catalog", file: "komga-catalog.xml", from: .module)
        try t.answer("GET", "/opds/v1.2/search", file: "komga-search.xml", from: .module)
        let account = try await OpdsSource.signIn(
            catalog: URL(string: "https://comics.example/opds/v1.2/catalog")!, username: "leser",
            password: "pw",
            transport: t)
        #expect(account.title == "Komga OPDS catalog")
        #expect(account.search == "https://comics.example/opds/v1.2/series?search={searchTerms}")
    }
}
