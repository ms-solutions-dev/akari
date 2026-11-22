import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import OpdsKit

/// OPDS 2.0 (JSON) against a recording of Komga v2 (1.26): catalog, browse, series, search, 401 —
/// plus Divina manifest and progression, which are built from the specification and the Komga
/// source (see `Fixtures/_index.txt`).
@Suite("OPDS 2.0 — Komga v2")
struct OpdsJsonTests {
    let catalog = URL(string: "https://comics.example/opds/v2/catalog")!

    private func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func account(search: String? = nil) -> OpdsAccount {
        OpdsAccount(
            catalog: catalog, username: "leser", password: "geheim", title: "Komga", search: search,
            edition: .json)
    }

    /// The transport with what is recorded; everything else under `/opds/v2/` is a 404.
    private func transport() throws -> MockTransport {
        let t = MockTransport()
        try t.answer("GET", "/opds/v2/catalog", file: "komga-v2-catalog.json", from: .module)
        try t.answer("GET", "/opds/v2/libraries/browse", file: "komga-v2-browse.json", from: .module)
        try t.answer("GET", "/opds/v2/series/0RM6ZZJWZS971", file: "komga-v2-serie.json", from: .module)
        try t.answer(
            "GET", "/opds/v2/books/0RM6ZZJX3SFDH/manifest", file: "komga-v2-manifest.json", from: .module)
        t.answer("GET", "/opds/v2/*", with: .init(status: 404))
        return t
    }

    @Test("Detection: by content type or first character, not by address")
    func detection() throws {
        #expect(
            OpdsJsonReader.isJson(try data("komga-v2-catalog.json"), contentType: "application/opds+json"))
        #expect(OpdsJsonReader.isJson(try data("komga-v2-catalog.json"), contentType: nil))
        #expect(OpdsJsonReader.isJson(Data("  \n{}".utf8), contentType: "text/plain"))
        #expect(!OpdsJsonReader.isJson(try data("komga-catalog.xml"), contentType: "application/atom+xml"))
        #expect(!OpdsJsonReader.isJson(try data("komga-catalog.xml"), contentType: nil))
    }

    @Test("The catalog: navigation, groups with navigation and publications, search as template")
    func readCatalog() throws {
        let feed = try OpdsJsonReader.parse(try data("komga-v2-catalog.json"))
        #expect(feed.title == "All libraries - Recommended")
        #expect(feed.id == "https://comics.example/opds/v2/libraries")
        #expect(
            feed.search?.href == "https://comics.example/opds/v2/search{?query}"
                && feed.search?.template == true
        )
        let navigation = feed.entries.filter { $0.acquisition == nil }
        #expect(navigation.map(\.title).prefix(2) == ["Recommended", "Browse"])
        #expect(navigation.allSatisfy { $0.navigation != nil }, "without rel, subsection applies")
        let library = try #require(navigation.first { $0.title == "Comics & Manga" })
        #expect(library.cluster == "Libraries")
        #expect(library.navigation?.href == "https://comics.example/opds/v2/libraries/0RM392RM9XMC6")
        #expect(
            navigation.contains {
                $0.title == "Latest Books" && $0.navigation?.href.hasSuffix("/books/latest") == true
            },
            "the self link of a group leads to the whole list")
        #expect(
            navigation.filter { $0.navigation?.href == feed.id }.count == 1,
            "Recommended points to the feed itself; the self link of the Libraries group does not count")
        #expect(
            navigation.filter { $0.cluster == "Latest Series" }.count == 6,
            "the group itself and five series"
        )
        let volumes = feed.entries.filter { $0.acquisition != nil }
        #expect(volumes.count == 7)
        let blawosfil = try #require(volumes.first)
        #expect(blawosfil.cluster == "Keep Reading")
        #expect(blawosfil.bookSeries == "Blawosfil Saga" && blawosfil.volume == 1 && blawosfil.pages == 227)
        #expect(blawosfil.authors == ["PAKLOLOND Kuklantou"], "five roles, one name")
        #expect(blawosfil.manifest?.href.hasSuffix("/books/0RM4VTYG4PR2H/manifest") == true)
        #expect(blawosfil.progress?.href.hasSuffix("/books/0RM4VTYG4PR2H/progression") == true)
        #expect(blawosfil.acquisition?.type == "application/vnd.comicbook+zip")
        #expect(blawosfil.image?.href.hasSuffix("/thumbnail") == true)
        #expect(blawosfil.refreshed != nil)
        #expect(volumes.last?.bookSeries == "Spionfleklam tros Gubli" && volumes.last?.volume == 4)
    }

    @Test("Browse: series as navigation in a group, next, no acquisition")
    func browse() throws {
        let feed = try OpdsJsonReader.parse(try data("komga-v2-browse.json"))
        #expect(feed.title == "All libraries")
        #expect(feed.next?.href == "https://comics.example/opds/v2/libraries/browse?page=1")
        #expect(feed.isNavigation)
        let seriesList = feed.entries.filter { $0.cluster == "Series" }
        #expect(seriesList.count == 20 && seriesList.first?.title == "Fiahot slem Wani")
        #expect(feed.entries.filter { $0.cluster == "Publisher" }.count == 18)
    }

    @Test(
        "The series: volumes with series and volume number from belongsTo, page count, manifest, progression")
    func series() throws {
        let feed = try OpdsJsonReader.parse(try data("komga-v2-serie.json"))
        #expect(feed.title == "Fiahot slem Wani" && feed.entries.count == 9)
        let volume = try #require(feed.entries.first)
        #expect(volume.authors == ["Triadroflur Binsiojiarn"] && volume.pages == 333)
        #expect(volume.bookSeries == "Fiahot slem Wani" && volume.volume == 1)
        #expect(volume.manifest?.type == "application/divina+json" && volume.pageStream == nil)
        let source = OpdsSource(account: account(), transport: MockTransport(), persistence: nil)
        let address = URL(string: "https://comics.example/opds/v2/series/0RM6ZZJWZS971")!
        let title = feed.entries.enumerated().compactMap { i, e in
            OpdsMapping.title(
                e, feed: feed, feedAddress: address, bookSeries: nil, slot: i + 5, source: source.identifier,
                resolve: source.absolute)
        }
        #expect(title.count == 9, "every volume has a manifest")
        #expect(title[0].kind == .manga && title[0].format == "CBZ")
        #expect(title[0].name == "Fiahot zi Wani Doppelband-Edition 1 - Triadroflur Binsiojiarn")
        #expect(title[0].series?.name == "Fiahot slem Wani")
        #expect(
            title[0].series?.volume == 1 && title[8].series?.volume == 9,
            "the volume number from belongsTo, not the position")
        #expect(title[0].scope == .pages(333))
        #expect(
            title[0].cover?.absoluteString == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/thumbnail")
        #expect(
            source.file(title[0])?.absoluteString
                == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/file")
        let data = OpdsMapping.entry(from: title[0])
        #expect(
            data.manifest?.absoluteString == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/manifest")
        #expect(
            data.progress?.absoluteString
                == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/progression"
        )
        #expect(title[0].identifier.id.hasPrefix("{\"datei\":"), "sorted keys")
        #expect(
            OpdsMapping.identifier(data, source: source.identifier) == title[0].identifier,
            "same data, same identifier")
    }

    @Test("The crawl: catalog → browse → series; volumes with series and volume number from belongsTo")
    func run() async throws {
        let t = try transport()
        let source = OpdsSource(account: account(), transport: t, persistence: nil)
        let extract = try await source.library()
        #expect(extract.title.count == 16, "seven from the catalog, nine from the series")
        // Content and order apart: the public export renames the series, which moves them in the list.
        let counts = Dictionary(uniqueKeysWithValues: extract.seriesList.map { ($0.name, $0.volumeCount) })
        #expect(
            counts == [
                "Fiahot slem Wani": 9, "Skagrausge-Pau Briatvainkiand": 1, "Spionfleklam tros Gubli": 5, "Blawosfil Saga": 1,
            ])
        let seriesNames = extract.seriesList.map(\.name)
        #expect(
            seriesNames == seriesNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "sorted by name")
        let alice = extract.title.filter { $0.series?.name == "Fiahot slem Wani" }
        #expect(alice.map { $0.series?.volume } == (1...9).map { Double($0) })
        #expect(extract.title.allSatisfy { $0.kind == .manga && $0.scope != .unknown })
        let paths = t.paths
        #expect(paths.first == "GET /opds/v2/catalog")
        #expect(
            paths.filter { $0.hasSuffix("/libraries/browse") }.count == 7,
            "page 0, page 1 and five publisher filters that bring nothing new — then the branch is dead")
        #expect(paths.filter { $0.contains("/series/0RM6ZZJWZS971") }.count == 1)
        #expect(
            t.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true
            })
        #expect(
            t.requests.first?.value(forHTTPHeaderField: "Accept")?.hasPrefix("application/opds+json") == true)
    }

    @Test(
        "Sign-in detects the edition from the response, takes title and search template; 401 means signed out"
    )
    func signIn() async throws {
        let t = try transport()
        let account = try await OpdsSource.signIn(
            catalog: catalog, username: "leser", password: "geheim", transport: t)
        #expect(account.edition == .json)
        #expect(account.title == "All libraries - Recommended")
        #expect(account.search == "https://comics.example/opds/v2/search?query={searchTerms}")
        #expect(t.paths == ["GET /opds/v2/catalog"], "the template is in the link, nothing more to fetch")
        let t2 = MockTransport()
        try t2.answer("GET", "/opds/v2/catalog", file: "komga-v2-401.json", from: .module)
        await #expect(throws: SourceError.signedOut(account.identifier)) {
            try await OpdsSource.signIn(catalog: catalog, username: "x", password: "y", transport: t2)
        }
        let legacy = try JSONDecoder().decode(
            OpdsAccount.self,
            from: Data(
                #"{"katalog":"https://comics.example/opds/v1.2/catalog","benutzername":"a","passwort":"b","titel":"Komga"}"#
                    .utf8))
        #expect(legacy.edition == .atom, "an account from older builds counts as Atom")
    }

    @Test("Search templates: {?query}, {&q}, {query}; the search asks the server with the term")
    func search() async throws {
        #expect(
            OpdsJsonReader.searchTemplate("https://x/search{?query}")
                == "https://x/search?query={searchTerms}")
        #expect(
            OpdsJsonReader.searchTemplate("https://x/s?a=1{&q,page}") == "https://x/s?a=1&q={searchTerms}")
        #expect(OpdsJsonReader.searchTemplate("https://x/s/{query}") == "https://x/s/{searchTerms}")
        #expect(OpdsJsonReader.searchTemplate("https://x/s") == nil)
        let t = MockTransport()
        try t.answer("GET", "/opds/v2/search", file: "komga-v2-search.json", from: .module)
        let source = OpdsSource(
            account: account(search: "https://comics.example/opds/v2/search?query={searchTerms}"),
            transport: t,
            persistence: nil)
        let empty = try await source.search("Plinpro")
        #expect(empty.isEmpty, "Komga found nothing for Plinpro")
        #expect(t.requests.first?.url?.query() == "query=Plinpro")
        // Hits look like a catalog: publications in groups, series as navigation.
        let t2 = try transport()
        try t2.answer("GET", "/opds/v2/search", file: "komga-v2-catalog.json", from: .module)
        let source2 = OpdsSource(
            account: account(search: "https://comics.example/opds/v2/search?query={searchTerms}"),
            transport: t2,
            persistence: nil)
        let hit = try await source2.search("Spionfleklam")
        #expect(hit.count >= 7)
        #expect(hit.contains { $0.series?.name == "Spionfleklam tros Gubli" && $0.series?.volume == 19 })
    }

    @Test(
        "Progression there and back: page, fraction, device, completed on the last page; empty without a position"
    )
    func progression() throws {
        let remote = try OpdsProgression.parse(try data("komga-v2-progression.json"))
        let state = try #require(remote.readingState(pages: 333))
        #expect(state.position == .page(12, from: 333) && !state.completed)
        #expect(state.device == "Alex's iPad")
        #expect(state.timestamp == OpdsParser.date("2026-09-18T20:15:42.318Z"))
        let web = try OpdsProgression.parse(try data("komga-v2-progression-web.json"))
        #expect(web.readingState(pages: 333) == nil, "the web reader writes no locator")
        let end = ReadingState(
            position: .page(333, from: 333), timestamp: Date(timeIntervalSince1970: 1_800_000_000.5),
            device: "Cauveit iPad", completed: true)
        let outgoing = try #require(
            OpdsProgression(end, page: ("https://comics.example/x/pages/333", "image/jpeg")))
        let body = try outgoing.body()
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.hasPrefix(#"{"device":{"id":"cauveit-ipad","name":"Cauveit iPad"}"#), "sorted keys")
        #expect(text.contains(#""position":333"#) && text.contains(#""totalProgression":1"#))
        #expect(text.contains(#""modified":"2027-01-15T08:00:00.500Z""#))
        let back = try OpdsProgression.parse(body).readingState(pages: 333)
        #expect(back?.completed == true && back?.position == .page(333, from: 333))
        #expect(back?.device == "Cauveit iPad")
        #expect(
            OpdsProgression(ReadingState(position: .fraction(0.5), timestamp: Date()), page: ("", nil)) == nil
        )
    }

    @Test("The reading state of a comic goes to the progression API, that of an Atom title into the store")
    func readingStateOnServer() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "opds2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let t = try transport()
        try t.answer(
            "GET", "/opds/v2/books/0RM6ZZJX3SFDH/progression", file: "komga-v2-progression.json",
            from: .module)
        t.answer("PUT", "/opds/v2/books/0RM6ZZJX3SFDH/progression", with: .init(status: 204))
        let source = OpdsSource(account: account(), transport: t, persistence: file)
        let extract = try await source.library()
        let volume = try #require(
            extract.title.first { $0.name.hasPrefix("Fiahot zi Wani Doppelband-Edition 1") })
        #expect(extract.readingStates[volume.identifier] == nil, "the crawl does not fetch 700 single states")

        let remote = try await source.progress(volume.identifier)
        #expect(remote?.position == .page(12, from: 333))
        #expect(t.paths.last == "GET /opds/v2/books/0RM6ZZJX3SFDH/progression")
        #expect(
            source.states.state(volume.identifier)?.position == .page(12, from: 333),
            "the mirror for the shelf"
        )

        let new = ReadingState(position: .page(20, from: 333), timestamp: Date(), device: "iPad")
        try await source.write(new, for: volume.identifier)
        let put = try #require(t.requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.path() == "/opds/v2/books/0RM6ZZJX3SFDH/progression")
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(put.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains(#""position":20"#) && body.contains(#""name":"iPad""#))
        #expect(
            body.contains(#""href":"https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/manifest""#),
            "without a fetched manifest the manifest address is in the locator")
        let again = OpdsSource(account: account(), transport: t, persistence: file)
        let shelf = try await again.library()
        #expect(
            shelf.readingStates[volume.identifier]?.position == .page(20, from: 333),
            "the mirror survives the restart")

        await #expect(throws: SourceError.self) {
            try await source.forget(progressFor: volume.identifier)
        }

        // 204: never started — the mirror is emptied too.
        let t2 = try transport()
        t2.answer("GET", "/opds/v2/books/0RM6ZZJX3SFDH/progression", with: .init(status: 204))
        t2.answer("PUT", "/opds/v2/books/0RM6ZZJX3SFDH/progression", with: .init(status: 204))
        let empty = OpdsSource(account: account(), transport: t2, persistence: file)
        #expect(try await empty.progress(volume.identifier) == nil)
        #expect(empty.states.state(volume.identifier) == nil)

        // A state from the web reader without a position leaves the mirror alone.
        try await empty.write(new, for: volume.identifier)
        let t3 = try transport()
        try t3.answer(
            "GET", "/opds/v2/books/0RM6ZZJX3SFDH/progression", file: "komga-v2-progression-web.json",
            from: .module)
        let web = OpdsSource(account: account(), transport: t3, persistence: file)
        #expect(try await web.progress(volume.identifier)?.position == .page(20, from: 333))

        // An Atom title (identifier without progression) stays in the store, without a request.
        let atom = TitleID(source: account().identifier, id: "book:47")
        let previously = t3.requests.count
        try await web.write(ReadingState(position: .fraction(0.4), timestamp: Date()), for: atom)
        #expect(try await web.progress(atom)?.fraction == 0.4)
        try await web.forget(progressFor: atom)
        #expect(try await web.progress(atom) == nil)
        #expect(t3.requests.count == previously)
    }

    @Test("The Divina manifest: pages with dimensions; the page stream reads the addresses from it, 1-based")
    func manifest() async throws {
        let pages = try OpdsJsonReader.manifest(try data("komga-v2-manifest.json"))
        #expect(pages.count == 4)
        #expect(pages[2].width == 2800 && pages[2].height == 2100 && pages[2].type == "image/png")
        #expect(pages[3].width == nil)
        let t = try transport()
        let source = OpdsSource(account: account(), transport: t, persistence: nil)
        let feed = try OpdsJsonReader.parse(try data("komga-v2-serie.json"))
        let address = URL(string: "https://comics.example/opds/v2/series/0RM6ZZJWZS971")!
        let volume = try #require(
            OpdsMapping.title(
                feed.entries[0], feed: feed, feedAddress: address, bookSeries: nil, source: source.identifier,
                resolve: source.absolute))
        guard case .pageStream(let count, let page, let measures) = source.content(volume) else {
            Issue.record("kein Seiten-Strom")
            return
        }
        #expect(count == 333)
        let fetchMeasures = try #require(measures)
        let measureList = try await fetchMeasures()
        #expect(measureList.count == 4 && measureList[2].landscape && !measureList[0].landscape)
        #expect(measureList[3] == PageSize(width: 0, height: 1), "without dimensions portrait")
        #expect(
            page(3).absoluteString
                == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/pages/3?contentNegotiation=false")
        #expect(page(1).absoluteString.hasSuffix("/pages/1?contentNegotiation=false"))
        #expect(
            page(300).absoluteString == "https://comics.example/opds/v2/books/0RM6ZZJX3SFDH/pages/300",
            "beyond the (short) manifest the fallback")
        #expect(
            t.paths.filter { $0.hasSuffix("/manifest") }.count <= 2,
            "once in the background, then from memory")
        // Without a manifest a CBZ stays out.
        var without = feed.entries[0]
        without.links.removeAll { $0.type == "application/divina+json" }
        #expect(
            OpdsMapping.title(
                without, feed: feed, feedAddress: address, bookSeries: nil, source: source.identifier,
                resolve: source.absolute)
                == nil)
    }

    @Test("A feed that does not exist is a dead branch — Komga's /series/latest is a 404")
    func deadBranch() async throws {
        let t = MockTransport()
        try t.answer("GET", "/opds/v2/catalog", file: "komga-v2-catalog.json", from: .module)
        try t.answer("GET", "/opds/v2/*", file: "komga-v2-latest.json", from: .module)
        let source = OpdsSource(account: account(), transport: t, persistence: nil)
        let extract = try await source.library()
        #expect(extract.title.count == 7, "what the catalog names itself")
    }
}
