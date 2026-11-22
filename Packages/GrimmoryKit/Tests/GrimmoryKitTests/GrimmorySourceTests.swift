import Foundation
import SourcesKit
import SourcesKitMocks
import Synchronization
import Testing

@testable import GrimmoryKit

/// Checked against recorded responses of a Grimmory 3.4.1 server (mobile API):
/// 854 books, 586 with series, one book with reading state.
@Suite("GrimmorySource")
struct GrimmorySourceTests {
    let server = URL(string: "https://buecher.example")!
    let now = Date()

    private func account(mayFetch: Bool = true, flow: Date? = nil) -> GrimmoryAccount {
        GrimmoryAccount(
            server: server, userId: 1, username: "leser", displayName: "Alex", mayFetch: mayFetch,
            access: GrimmoryAccess(
                token: "alt", refreshToken: "frisch", flow: flow ?? now.addingTimeInterval(7200)))
    }

    private func source(
        _ t: MockTransport, account: GrimmoryAccount? = nil,
        changed: @escaping @Sendable (GrimmoryAccess) -> Void = { _ in }
    )
        -> GrimmorySource
    {
        GrimmorySource(account: account ?? self.account(), transport: t, changed: changed)
    }

    /// The identifier of the recorded book with reading state — taken from the recording
    /// itself, not from memory.
    private func recordedBook() throws -> Int {
        let answer = try MockTransport.recording("app-book.json", from: .module)
        return try ServerFetch.decoder.decode(GrimmoryResponses.Book.self, from: answer.data).id
    }

    @Test("Sign in: token pair expiring in two hours, permissions from the user")
    func signIn() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/v1/auth/login", file: "login.json", from: .module)
        try t.answer("GET", "/api/v1/users/me", file: "me.json", from: .module)
        let account = try await GrimmorySource.signIn(
            server: server, username: "leser", password: "pw", transport: t)
        #expect(account.username == "leser")
        #expect(account.access.token == "GESCHWAERZT")
        #expect(abs(account.access.flow.timeIntervalSinceNow - 7200) < 5)
        #expect(account.mayFetch)
        #expect(
            account.capabilities == [
                .seriesList, .rating, .savedList, .collections, .editCollections, .keep,
            ])
        #expect(
            t.requests[0].httpBody.map { String(decoding: $0, as: UTF8.self) }?.contains(#""password":"pw""#)
                == true)
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer GESCHWAERZT")
        let t2 = MockTransport()
        try t2.answer("POST", "/api/v1/auth/login", file: "401-login.json", from: .module)
        await #expect(throws: SourceError.signedOut(account.identifier)) {
            try await GrimmorySource.signIn(server: server, username: "x", password: "y", transport: t2)
        }
    }

    @Test("Author detail: description from the Audible sync; without the endpoint the list stays empty")
    func author() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/authors/84", file: "author.json", from: .module)
        let reference = AuthorReference(
            source: account().identifier, identifier: "84", name: "F. Biskreirau Dofur")
        let author = try await source(t).author(reference)
        #expect(author?.descriptionText?.hasPrefix("Description removed") == true)

        let t2 = MockTransport()
        try t2.answer("GET", "/api/v1/books", file: "books-voll.json", from: .module)
        oldGrimmory(t2)
        t2.answer("GET", "/api/v1/authors", with: .init(status: 404))
        #expect(try await source(t2).library().authors.isEmpty)
    }

    @Test("expires in three forms")
    func flow() {
        let now = Date(timeIntervalSince1970: 1_789_581_600)
        #expect(GrimmoryAccess.flow(from: 7200, now: now) == now.addingTimeInterval(7200))
        #expect(
            GrimmoryAccess.flow(from: 1_789_588_800, now: now)
                == Date(timeIntervalSince1970: 1_789_588_800))
        #expect(
            GrimmoryAccess.flow(from: 1_789_588_800_000, now: now)
                == Date(timeIntervalSince1970: 1_789_588_800))
        let access = GrimmoryAccess(token: "t", refreshToken: "r", flow: now.addingTimeInterval(120))
        #expect(access.usable(now: now))
        #expect(!access.usable(now: now.addingTimeInterval(61)))
    }

    /// The paths without the Magic Shelves — the source loads them on the side, their fetches arrive
    /// at no fixed time.
    private func withoutMagic(_ t: MockTransport) -> [String] {
        t.paths.filter { !$0.contains("/app/shelves/magic") }
    }

    @Test(
        "Magic Shelves: all pages per shelf, identifier with \"auto-\", not editable, remembered for six hours"
    )
    func magic() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t.answer(
            "GET", "/api/v1/app/shelves/magic",
            with: .json(
                #"[{"id":2,"name":"Faisto","icon":"award","publicShelf":true},{"id":5,"name":"Kurz","icon":"zap"}]"#
            ))
        func page(_ ids: ClosedRange<Int>, total: Int) -> MockTransport.Answer {
            let list = ids.map { "{\"id\":\($0)}" }.joined(separator: ",")
            return .json("{\"content\":[\(list)],\"totalElements\":\(total)}")
        }
        // Shelf 2: 60 books on two pages; shelf 5: three books.
        t.answer("GET", "/api/v1/app/shelves/magic/2/books", with: page(1...50, total: 60))
        t.answer("GET", "/api/v1/app/shelves/magic/2/books", with: page(51...60, total: 60))
        t.answer("GET", "/api/v1/app/shelves/magic/5/books", with: page(7...9, total: 3))
        let q = source(t)
        let collections = try await q.collections()
        let award = try #require(collections.first { $0.name == "Faisto" })
        #expect(award.automatic && !award.editable && !award.isPrivate)
        #expect(award.entries.count == 60)
        #expect(award.symbol == "award")
        let short = try #require(collections.first { $0.name == "Kurz" })
        #expect(short.entries == (7...9).map { .title(TitleID(source: q.identifier, id: "\($0)")) })
        #expect(short.isPrivate, "private without publicShelf")
        let previously = t.requests.count
        _ = try await q.collections()
        #expect(t.requests.count == previously + 1, "only the web shelves, the Magic Shelves are remembered")

        // Older than six hours: the collections still take the remembered data — it is refreshed
        // only in the full sync, not at launch in the middle of reading.
        GrimmorySource.cachedMagic.withLock { saved in
            if let old = saved[q.cacheKey] {
                saved[q.cacheKey] = (Date(timeIntervalSinceNow: -7 * 3600), old.list)
            }
        }
        let before = t.requests.count
        let stale = try await q.collections()
        try await Task.sleep(for: .milliseconds(100))
        #expect(t.requests.count == before + 1, "no Magic Shelves run from the collections")
        #expect(stale.contains { $0.name == "Faisto" })
    }

    @Test("Magic Shelves still loading: the collections do not wait for them, the next call has them")
    func magicDoesNotHoldCollections() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t.answer("GET", "/api/v1/app/shelves/magic", with: .json(#"[{"id":2,"name":"Faisto"}]"#))
        t.answer(
            "GET", "/api/v1/app/shelves/magic/2/books",
            with: .json(#"{"content":[{"id":1},{"id":2}],"totalElements":2}"#))
        // Every fetch 300 ms: the run takes 600 ms, the collections wait only 100.
        t.set(delay: .milliseconds(300))
        let q = source(t)
        let start = ContinuousClock.now
        let first = try await q.collections(magicWait: .milliseconds(100))
        #expect(first.isEmpty, "without the Magic Shelves that are still loading")
        #expect(
            ContinuousClock.now - start < .milliseconds(900), "the shelves fetch plus the wait, not the run")
        try await Task.sleep(for: .milliseconds(900))
        let later = try await q.collections(magicWait: .milliseconds(100))
        #expect(later.first { $0.name == "Faisto" }?.entries.count == 2, "the run finished on its own")
    }

    @Test(
        "Incremental sync: after a full one only the changes — new via batch, gone drops, read states checked"
    )
    func incrementalSync() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books", file: "books-voll.json", from: .module)
        oldGrimmory(t)
        try t.answer("GET", "/api/v1/authors", file: "authors.json", from: .module)
        let q = source(t)
        let full = try await q.library(previously: nil) { _, _ in }
        #expect(full.title.count == 865)

        let raw = try MockTransport.recording("books-voll.json", from: .module).data
        let books = try #require(try JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        let ids = books.compactMap { $0["id"] as? Int }
        let route = try #require(ids.first { $0 != 755 })
        var new = books[0]
        new["id"] = 999_999
        let list = ids.filter { $0 != route } + [999_999]
        t.answer(
            "GET", "/api/v1/books/ids", with: .json("[" + list.map(String.init).joined(separator: ",") + "]")
        )
        t.answer(
            "GET", "/api/v1/books/batch",
            with: MockTransport.Answer(
                data: try JSONSerialization.data(withJSONObject: [new]),
                headerLines: ["Content-Type": "application/json"]))
        t.answer(
            "GET", "/api/v1/app/books",
            with: .json(
                #"{"content":[{"id":755,"readStatus":"READ","lastReadTime":"2030-01-01T00:00:00Z"},{"id":59,"readStatus":"READING","lastReadTime":"2001-01-01T00:00:00Z"}]}"#
            ))
        t.answer(
            "GET", "/api/v1/app/books/755/progress",
            with: .json(#"{"readStatus":"READ","lastReadTime":"2030-01-01T00:00:00Z"}"#))
        let previously = t.requests.count

        let synced = try await q.library(previously: full) { _, _ in }
        let paths = Array(t.paths.dropFirst(previously)).filter { !$0.contains("/app/shelves/magic") }
        #expect(
            paths == [
                "GET /api/v1/books/ids", "GET /api/v1/books/batch", "GET /api/v1/app/books",
                "GET /api/v1/app/books/755/progress",
            ], "no full fetch, only one state checked (59 is older than the extract)")
        #expect(synced.title.count == 865)
        #expect(synced.title.contains { $0.identifier.id == "999999" })
        #expect(!synced.title.contains { $0.identifier.id == String(route) })
        let state = try #require(synced.readingStates[TitleID(source: q.identifier, id: "755")])
        #expect(state.completed)
        #expect(synced.authors.count == full.authors.count)
    }

    @Test("Library picker: disabled libraries are missing from the extract, the list comes from the server")
    func libraries() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/page", with: try bookPage(total: 865))
        try t.answer("GET", "/api/v1/authors", file: "authors.json", from: .module)
        t.answer(
            "GET", "/api/v1/libraries", with: .json(#"[{"id":1,"name":"Bücher"},{"id":2,"name":"Fach"}]"#))
        let persistence = try #require(UserDefaults(suiteName: "bibliotheken-\(UUID())"))
        let q = GrimmorySource(account: account(), transport: t, persistence: persistence)
        #expect(try await q.subLibraries().map(\.name) == ["Bücher", "Fach"])
        LibraryPicker.set(from: ["1"], for: q.identifier, persistence)
        let extract = try await q.library()
        #expect(extract.title.isEmpty, "all recorded books are in library 1")
        #expect(!t.paths.contains("GET /api/v1/books"), "filtered to empty does not mean pages broken")
    }

    @Test("Series that differ only in spelling are one — other names are not")
    func seriesSpellings() {
        let q = SourceID(provider: .grimmory, server: "x")
        func t(_ id: String, _ bookSeries: String) -> Title {
            Title(
                identifier: TitleID(source: q, id: id), kind: .book, name: id,
                series: SeriesReference(
                    identifier: SeriesID(source: q, id: bookSeries), name: bookSeries, volume: 1))
        }
        let title = GrimmoryMapping.unifySeries([
            t("1", "Prai touklouglorn Fudaislun"), t("2", "Prai touklouglorn Fudaislun"), t("3", "Prai touklouglorn Fudaislun"), t("4", "Deiwetrol Griadok"),
            t("5", "Deiwetrol’ Griadok"), t("6", "Deiwetrol Griadok"), t("7", "Ziokreigand"), t("8", "Bo Ziokreigand-Saga"),
        ])
        #expect(Set(title.prefix(3).map { $0.series?.identifier.id }) == ["Prai touklouglorn Fudaislun"])
        #expect(Set(title[3...5].map { $0.series?.name }) == ["Deiwetrol Griadok"])
        #expect(
            title[6].series?.name == "Ziokreigand" && title[7].series?.name == "Bo Ziokreigand-Saga",
            "other names stay")
    }

    /// A Grimmory without the page endpoint — the source then loads everything at once.
    private func oldGrimmory(_ t: MockTransport) {
        t.answer("GET", "/api/v1/books/page", with: .json("{}", status: 404))
    }

    /// The recorded books as a page of `/api/v1/books/page`; `offset` shifts the identifiers so
    /// that a second page carries other books.
    private func bookPage(
        total: Int, offset: Int = 0, atMost: Int = .max
    ) throws
        -> MockTransport.Answer
    {
        let raw = try MockTransport.recording("books-voll.json", from: .module).data
        var books = try #require(try JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        books = Array(books.prefix(atMost)).map { b in
            var b = b
            b["id"] = (b["id"] as? Int ?? 0) + offset
            return b
        }
        let answer: [String: Any] = ["content": books, "page": ["totalElements": total]]
        return MockTransport.Answer(
            data: try JSONSerialization.data(withJSONObject: answer),
            headerLines: ["Content-Type": "application/json"])
    }

    @Test("Paged: page 0 first, the others in parallel via page=n, progress reported")
    func paged() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_065))
        t.answer(
            "GET", "/api/v1/books/page", with: try bookPage(total: 1_065, offset: 100_000, atMost: 100))
        try t.answer("GET", "/api/v1/authors", file: "authors.json", from: .module)
        let reports = Mutex<[Int]>([])
        let extract = try await source(t).library { loaded, total in
            #expect(total == 1_065)
            reports.withLock { $0.append(loaded) }
        }
        #expect(extract.title.count == 965)
        #expect(reports.withLock { $0 } == [865, 965])
        #expect(!t.paths.contains("GET /api/v1/books"), "no longer everything at once")
        let queries = t.requests.filter { $0.url?.path() == "/api/v1/books/page" }.compactMap {
            $0.url?.query()
        }
        #expect(
            queries == ["page=0&size=1000&withDescription=false", "page=1&size=1000&withDescription=false"])
    }

    @Test("Full sync resumes: stored pages come from disk, page 0 fresh; another total starts over")
    func pageCheckpoint() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "seiten-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func pageFetches(_ t: MockTransport) -> Int {
            t.paths.filter { $0 == "GET /api/v1/books/page" }.count
        }

        let t1 = MockTransport()
        t1.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_065))
        t1.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_065, offset: 100_000, atMost: 100))
        t1.answer("GET", "/api/v1/authors", with: .json("[]"))
        _ = try await GrimmorySource(account: account(), transport: t1, pageStore: folder).library()
        #expect(PageCheckpoint(folder: folder).stored() == [1], "page 1 on disk, page 0 always fresh")

        // The app was gone before the extract was stored: the next sync takes page 1 from disk.
        let t2 = MockTransport()
        t2.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_065))
        t2.answer("GET", "/api/v1/authors", with: .json("[]"))
        let resumed = try await GrimmorySource(account: account(), transport: t2, pageStore: folder).library()
        #expect(resumed.title.count == 965)
        #expect(pageFetches(t2) == 1, "only page 0 from the server")

        // The catalog changed in between: the stored pages no longer count.
        let t3 = MockTransport()
        t3.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_066))
        t3.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_066, offset: 100_000, atMost: 101))
        t3.answer("GET", "/api/v1/authors", with: .json("[]"))
        let fresh = try await GrimmorySource(account: account(), transport: t3, pageStore: folder).library()
        #expect(fresh.title.count == 966)
        #expect(pageFetches(t3) == 2)
    }

    @Test("Magic Shelves resume: completed shelves of an interrupted run are not fetched again")
    func magicResumes() async throws {
        let store = FileManager.default.temporaryDirectory.appending(path: "magisch-\(UUID().uuidString)")
        let partStore = store.deletingLastPathComponent().appending(path: store.lastPathComponent + ".teil")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: partStore)
        }
        let shelves = #"[{"id":2,"name":"Faisto"},{"id":5,"name":"Kurz"}]"#
        func page(_ ids: ClosedRange<Int>, total: Int) -> MockTransport.Answer {
            .json(
                "{\"content\":[\(ids.map { "{\"id\":\($0)}" }.joined(separator: ","))],\"totalElements\":\(total)}"
            )
        }

        // Shelf 5 completes, shelf 2 breaks off on its second page.
        let t1 = MockTransport()
        t1.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t1.answer("GET", "/api/v1/app/shelves/magic", with: .json(shelves))
        t1.answer("GET", "/api/v1/app/shelves/magic/2/books", with: page(1...50, total: 60))
        t1.answer("GET", "/api/v1/app/shelves/magic/2/books", with: .json("{}", status: 400))
        t1.answer("GET", "/api/v1/app/shelves/magic/5/books", with: page(7...9, total: 3))
        let q1 = GrimmorySource(account: account(), transport: t1, magicStore: store)
        let interrupted = try await q1.collections(magicWait: .seconds(5))
        #expect(interrupted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: partStore.path(percentEncoded: false)))

        // The next run fetches only shelf 2; shelf 5 comes from disk.
        let t2 = MockTransport()
        t2.answer("GET", "/api/v1/shelves", with: .json("[]"))
        t2.answer("GET", "/api/v1/app/shelves/magic", with: .json(shelves))
        t2.answer("GET", "/api/v1/app/shelves/magic/2/books", with: page(1...50, total: 60))
        t2.answer("GET", "/api/v1/app/shelves/magic/2/books", with: page(51...60, total: 60))
        let q2 = GrimmorySource(account: account(), transport: t2, magicStore: store)
        let list = try await q2.collections(magicWait: .seconds(5))
        #expect(list.first { $0.name == "Faisto" }?.entries.count == 60)
        #expect(list.first { $0.name == "Kurz" }?.entries.count == 3)
        #expect(!t2.paths.contains("GET /api/v1/app/shelves/magic/5/books"))
        #expect(
            !FileManager.default.fileExists(atPath: partStore.path(percentEncoded: false)), "done: part gone")
    }

    @Test("If the server ignores page, the same books would arrive twice — then everything at once")
    func pageIgnored() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_730))
        t.answer("GET", "/api/v1/books/page", with: try bookPage(total: 1_730))
        try t.answer("GET", "/api/v1/books", file: "books-voll.json", from: .module)
        try t.answer("GET", "/api/v1/authors", file: "authors.json", from: .module)
        let extract = try await source(t).library()
        #expect(extract.title.count == 865)
        #expect(t.paths.contains("GET /api/v1/books"))
    }

    @Test("The library: 865 books from one fetch, series from the books, a reading state with CFI")
    func library() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books", file: "books-voll.json", from: .module)
        oldGrimmory(t)
        // The author list — recorded after a Wikipedia fill run, duplicate run, repair and junk-author
        // run: 547 authors (Grimmory keeps creating new ones from the file scan), 865 books.
        try t.answer("GET", "/api/v1/authors", file: "authors.json", from: .module)
        let extract = try await source(t).library()
        #expect(extract.title.count == 865)
        #expect(withoutMagic(t) == ["GET /api/v1/books/page", "GET /api/v1/books", "GET /api/v1/authors"])
        #expect(extract.authors.count == 547)
        #expect(extract.authors.filter { $0.image != nil }.count == 400, "no photo, no address")
        // The duplicate "A Biskreirau Dofur" has been gone since the merge.
        #expect(extract.authors.filter { $0.name.hasSuffix("Biskreirau Dofur") }.count == 1)
        let dofur = try #require(extract.authors.first { $0.name == "F. Biskreirau Dofur" })
        #expect(dofur.identifier == "84" && dofur.count == 8)
        #expect(dofur.image?.path() == "/api/v1/media/author/84/thumbnail")
        #expect(
            t.requests[1].url?.query() == "withDescription=false&stripForListView=true",
            "without the parameters no blurb and no series length")
        let plinproSeries = try #require(extract.seriesList.first { $0.name == "Plinpro" })
        #expect(plinproSeries.total == 4 && plinproSeries.volumeCount == 3)
        #expect(
            extract.seriesList.contains { ($0.total ?? 0) > $0.volumeCount },
            "a series is longer than the shelf")
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer alt")
        // Plinpro (113) was reset: UNREAD, state 0, `lastReadTime` stays — no reading state. Two books
        // are being read on the device: states with CFI at 1 %; Plinpro (113) is at 0.1 %.
        #expect(extract.readingStates.count == 2, "Plinpro (113) at 0.1 % without CFI does not count")
        let state = try #require(extract.readingStates[TitleID(source: account().identifier, id: "755")])
        #expect(state.fraction < 0.05 && state.completed == false)
        let plinpro = try #require(extract.title.first { $0.identifier.id == "113" })
        #expect(plinpro.name.hasPrefix("Plinpro"))
        // The number grows while the blurb run is going on at the server; what is checked is that the
        // parameter takes effect, not the current count.
        #expect(extract.title.filter { $0.summary != nil }.count >= 100, "withDescription takes effect")
        #expect(!extract.seriesList.isEmpty)
        for series in extract.seriesList {
            #expect(
                extract.title.filter { $0.series?.identifier == series.identifier }.count
                    == series.volumeCount)
        }
        #expect(Set(extract.title.map(\.identifier.id)).count == extract.title.count)
    }

    @Test("One book: Goodreads stars with votes, categories without noise, cover via media")
    func book() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books", file: "books.json", from: .module)
        oldGrimmory(t)
        let extract = try await source(t).library()
        let slezevei = try #require(extract.title.first { $0.identifier.id == "1" })
        #expect(slezevei.name == "Slezevei Mouplun")
        #expect(slezevei.rating == Rating(stars: 2.64, voices: 46_919, origin: "Goodreads"))
        #expect(slezevei.scope == .pages(203))
        #expect(slezevei.publisher?.hasPrefix("sepraun freisrahiom") == true)
        #expect(slezevei.language == "de-DE")
        #expect(slezevei.series == nil)
        // Since the blurb run, Slezevei Mouplun has a text.
        #expect(slezevei.summary != nil)
        let withSeries = try #require(extract.title.first { $0.series != nil })
        #expect(extract.seriesList.contains { $0.identifier == withSeries.series?.identifier })
        #expect(
            extract.title.allSatisfy { !$0.genres.contains("Audiobook") && !$0.genres.contains("Ebooks") })
        #expect(extract.title.allSatisfy { $0.cover?.path().hasPrefix("/api/v1/media/book/") == true })
        #expect(extract.title.allSatisfy { $0.kind == .book || $0.kind == .manga })
        #expect(
            extract.title.filter { $0.released != nil }.count > 40, "publishedDate comes from the metadata")
    }

    @Test("The detail brings description and reading state with position")
    func detailAndProgress() async throws {
        let id = try recordedBook()
        let t = MockTransport()
        try t.answer("GET", "/api/v1/app/books/\(id)", file: "app-book.json", from: .module)
        try t.answer(
            "GET", "/api/v1/app/books/\(id)/progress", file: "app-book-progress.json", from: .module)
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: String(id))
        let title = try await q.title(identifier)
        #expect(!title.name.isEmpty)
        // Recorded: "Wand Liwikia" (59) at 89.9 % with CFI.
        let progress = try #require(try await q.progress(identifier))
        #expect(abs(progress.fraction - 0.899) < 0.001 && !progress.completed)
        guard case .file(let address, _, let area) = q.content(title) else {
            Issue.record("file expected")
            return
        }
        #expect(address.path() == "/api/v1/books/\(id)/content")
        #expect(area)
    }

    @Test("Writing: CFI as epubProgress in percent, page as pdf or cbxProgress, finished with date")
    func writing() throws {
        let cfi = ReadingState(
            position: .position(cfi: "epubcfi(/6/12!/4/2)", fraction: 0.016), timestamp: now)
        let m1 = GrimmoryMapping.report(cfi, fileType: "EPUB")
        #expect(m1.epubProgress?.cfi == "epubcfi(/6/12!/4/2)")
        #expect(abs((m1.epubProgress?.percentage ?? 0) - 1.6) < 0.0001)
        #expect(m1.pdfProgress == nil && m1.dateFinished == nil)
        let page = ReadingState(position: .page(12, from: 100), timestamp: now)
        #expect(GrimmoryMapping.report(page, fileType: "PDF").pdfProgress?.page == 12)
        #expect(GrimmoryMapping.report(page, fileType: "CBX").cbxProgress?.page == 12)
        let done = ReadingState(position: .fraction(1), timestamp: now, completed: true)
        #expect(GrimmoryMapping.report(done, fileType: "EPUB").dateFinished != nil)
        let data = try JSONEncoder().encode(m1)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == ["epubProgress"])
    }

    @Test("Writing goes as PUT to the mobile API — and sets READING if the status is still UNREAD")
    func writingPut() async throws {
        let t = MockTransport()
        t.answer("PUT", "/api/v1/app/books/113/progress", with: .init(status: 200))
        t.answer("PUT", "/api/v1/app/books/113/status", with: .init(status: 200))
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: "113")
        try await q.write(
            ReadingState(position: .position(cfi: "epubcfi(/6/2!/4/2)", fraction: 0.2), timestamp: now),
            for: identifier)
        #expect(t.paths == ["PUT /api/v1/app/books/113/progress", "PUT /api/v1/app/books/113/status"])
        #expect(t.requests[1].httpBody == Data(#"{"status":"READING"}"#.utf8))
        try await q.write(
            ReadingState(position: .position(cfi: "epubcfi(/6/4!/4/2)", fraction: 0.3), timestamp: now),
            for: identifier)
        #expect(t.paths.count == 3, "READING is already set — no second status PUT")
        try await q.write(
            ReadingState(position: .fraction(1), timestamp: now, completed: true), for: identifier)
        #expect(t.paths.count == 5)
        #expect(t.requests[4].httpBody == Data(#"{"status":"READ"}"#.utf8))
    }

    @Test("Forgetting: progress to zero, then UNREAD — Grimmory has no delete")
    func forgetting() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/app/books/113", file: "app-book.json", from: .module)
        t.answer("PUT", "/api/v1/app/books/113/progress", with: .init(status: 200))
        t.answer("PUT", "/api/v1/app/books/113/status", with: .init(status: 200))
        let q = source(t)
        try await q.forget(progressFor: TitleID(source: q.identifier, id: "113"))
        #expect(
            t.paths == [
                "GET /api/v1/app/books/113", "PUT /api/v1/app/books/113/progress",
                "PUT /api/v1/app/books/113/status",
            ])
        let body =
            try JSONSerialization.jsonObject(with: try #require(t.requests[1].httpBody)) as? [String: Any]
        let epub = try #require(body?["epubProgress"] as? [String: Any])
        #expect(epub["percentage"] as? Double == 0)
        #expect(t.requests[2].httpBody == Data(#"{"status":"UNREAD"}"#.utf8))
    }

    @Test("Saved list: the shelf \"Favorites\" yields identifiers — empty if the shelf is empty or missing")
    func savedList() async throws {
        // A shelf with one book, inline according to the web-book contract; the recording (four books)
        // follows below.
        let t = MockTransport()
        try t.answer("GET", "/api/v1/app/shelves", file: "app-shelves.json", from: .module)
        t.answer(
            "GET", "/api/v1/shelves/1/books",
            with: .json(
                #"[{"id":113,"libraryId":1,"metadata":{"title":"Plinpro"},"shelves":[{"id":1,"name":"Favorites"}]}]"#
            ))
        let q = source(t)
        let saved = try await q.savedList()
        #expect(saved == [TitleID(source: q.identifier, id: "113")])
        #expect(t.paths == ["GET /api/v1/app/shelves", "GET /api/v1/shelves/1/books"])
        // The recording: five saved books.
        let real = MockTransport()
        try real.answer("GET", "/api/v1/app/shelves", file: "app-shelves.json", from: .module)
        try real.answer("GET", "/api/v1/shelves/1/books", file: "shelf-books.json", from: .module)
        #expect(try await source(real).savedList().count == 5)
        let without = MockTransport()
        without.answer("GET", "/api/v1/app/shelves", with: .json("[]"))
        #expect(try await source(without).savedList().isEmpty)
        #expect(without.paths == ["GET /api/v1/app/shelves"])
    }

    @Test(
        "Saving puts the book on the shelf, un-saving takes it off; a missing shelf is created"
    )
    func save() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/app/shelves", file: "app-shelves.json", from: .module)
        try t.answer("GET", "/api/v1/app/shelves", file: "app-shelves.json", from: .module)
        t.answer("POST", "/api/v1/books/shelves", with: .json("[]"))
        t.answer("POST", "/api/v1/books/shelves", with: .json("[]"))
        let q = source(t)
        let book = TitleID(source: q.identifier, id: "113")
        try await q.save(book, saved: true)
        try await q.save(book, saved: false)
        #expect(
            t.paths == [
                "GET /api/v1/app/shelves", "POST /api/v1/books/shelves", "GET /api/v1/app/shelves",
                "POST /api/v1/books/shelves",
            ])
        let added =
            try JSONSerialization.jsonObject(with: try #require(t.requests[1].httpBody)) as? [String: Any]
        #expect(added?["bookIds"] as? [Int] == [113])
        #expect(added?["shelvesToAssign"] as? [Int] == [1])
        #expect(added?["shelvesToUnassign"] as? [Int] == [])
        let removed =
            try JSONSerialization.jsonObject(with: try #require(t.requests[3].httpBody)) as? [String: Any]
        #expect(removed?["shelvesToAssign"] as? [Int] == [])
        #expect(removed?["shelvesToUnassign"] as? [Int] == [1])

        // No shelf: saving creates one, un-saving leaves it alone.
        let t2 = MockTransport()
        t2.answer("GET", "/api/v1/app/shelves", with: .json("[]"))
        t2.answer("POST", "/api/v1/shelves", with: .json(#"{"id":7,"name":"Favorites"}"#))
        t2.answer("POST", "/api/v1/books/shelves", with: .json("[]"))
        t2.answer("GET", "/api/v1/app/shelves", with: .json("[]"))
        let q2 = source(t2)
        try await q2.save(book, saved: true)
        try await q2.save(book, saved: false)
        #expect(
            t2.paths == [
                "GET /api/v1/app/shelves", "POST /api/v1/shelves", "POST /api/v1/books/shelves",
                "GET /api/v1/app/shelves",
            ])
        let created =
            try JSONSerialization.jsonObject(with: try #require(t2.requests[1].httpBody)) as? [String: Any]
        #expect(created?["name"] as? String == "Favorites")
        #expect(created?["publicShelf"] as? Bool == false)
    }

    @Test("Collections: the web shelves without \"Favorites\", with books; create and arrange")
    func collections() async throws {
        let t = MockTransport()
        // Recorded: only "Favorites" (4 books) — next to it a second shelf under the same contract.
        t.answer(
            "GET", "/api/v1/shelves",
            with: .json(
                #"[{"id":1,"name":"Favorites","icon":"heart","iconType":"LUCIDE","userId":1,"publicShelf":false,"bookCount":4},"#
                    + #"{"id":2,"name":"Sommer","icon":"sun","iconType":"LUCIDE","userId":1,"publicShelf":false,"bookCount":1},"#
                    + #"{"id":3,"name":"Eltern","icon":"users","iconType":"LUCIDE","userId":2,"publicShelf":true,"bookCount":0}]"#
            ))
        try t.answer("GET", "/api/v1/shelves/2/books", file: "shelf-books.json", from: .module)
        t.answer("GET", "/api/v1/shelves/3/books", with: .json("[]"))
        let q = source(t)
        let list = try await q.collections()
        #expect(list.map(\.name) == ["Sommer", "Eltern"], "Favorites is the saved list, not a collection")
        #expect(list[0].entries.count == 5)
        #expect(list[0].editable && list[0].isPrivate)
        #expect(
            !list[1].editable && !list[1].isPrivate, "someone else's public shelf: read, not write")
        #expect(
            t.paths.filter { !$0.contains("/app/shelves/magic") } == [
                "GET /api/v1/shelves", "GET /api/v1/shelves/2/books", "GET /api/v1/shelves/3/books",
            ])

        let t2 = MockTransport()
        t2.answer("POST", "/api/v1/shelves", with: .json(#"{"id":7,"name":"Urlaub","icon":"library"}"#))
        t2.answer("POST", "/api/v1/books/shelves", with: .json("[]"))
        let q2 = source(t2)
        let new = try await q2.create(collection: "Urlaub", collectionKind: .shelf)
        #expect(new.identifier.id == "7" && new.collectionKind == .shelf && new.editable)
        try await q2.arrange(
            .title(TitleID(source: q2.identifier, id: "113")), in: new.identifier, into: true)
        let body =
            try JSONSerialization.jsonObject(with: try #require(t2.requests[1].httpBody)) as? [String: Any]
        #expect(body?["shelvesToAssign"] as? [Int] == [7])
        await #expect(throws: SourceError.self) {
            try await q2.arrange(
                .series(SeriesID(source: q2.identifier, id: "x")), in: new.identifier, into: true)
        }
    }

    @Test("The read status follows the state but does not override the user's choice")
    func readStatus() {
        let started = ReadingState(position: .fraction(0.2), timestamp: now)
        #expect(GrimmoryMapping.readStatus(for: started, previous: "UNREAD") == "READING")
        #expect(GrimmoryMapping.readStatus(for: started, previous: nil) == "READING")
        #expect(GrimmoryMapping.readStatus(for: started, previous: "READING") == nil)
        #expect(GrimmoryMapping.readStatus(for: started, previous: "PAUSED") == nil)
        #expect(
            GrimmoryMapping.readStatus(
                for: ReadingState(position: .fraction(0), timestamp: now), previous: "UNREAD") == nil)
        let done = ReadingState(position: .fraction(1), timestamp: now, completed: true)
        #expect(GrimmoryMapping.readStatus(for: done, previous: "READING") == "READ")
        #expect(GrimmoryMapping.readStatus(for: done, previous: "READ") == nil)
    }

    @Test("An expired access is refreshed once, the new pair reported — and the mirror follows")
    func refresh() async throws {
        let t = MockTransport()
        t.answer(
            "POST", "/api/v1/auth/refresh",
            with: .json(
                #"{"accessToken":"neu","refreshToken":"frisch2","expires":7200,"isDefaultPassword":false}"#))
        try t.answer("GET", "/api/v1/app/books/1", file: "app-book.json", from: .module)
        let reported = Mutex<[GrimmoryAccess]>([])
        let q = source(t, account: account(flow: now.addingTimeInterval(-10))) { new in
            reported.withLock { $0.append(new) }
        }
        #expect(q.headerLines() == ["Authorization": "Bearer alt"])
        _ = try await q.title(TitleID(source: q.identifier, id: "1"))
        #expect(t.paths == ["POST /api/v1/auth/refresh", "GET /api/v1/app/books/1"])
        #expect(t.requests[0].httpBody == Data(#"{"refreshToken":"frisch"}"#.utf8))
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer neu")
        #expect(reported.withLock { $0.map(\.refreshToken) } == ["frisch2"])
        #expect(q.headerLines() == ["Authorization": "Bearer neu"])
        _ = try await q.title(TitleID(source: q.identifier, id: "1"))
        #expect(t.requests.count == 3)
    }

    @Test(
        "401 despite valid access: refresh once and retry; if that fails, the account is signed out"
    )
    func signedOut() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books/page", file: "401.json", from: .module)
        try t.answer("POST", "/api/v1/auth/refresh", file: "refresh.json", from: .module)
        let q = source(t)
        await #expect(throws: SourceError.signedOut(q.identifier)) { try await q.library() }
        #expect(withoutMagic(t) == ["GET /api/v1/books/page", "POST /api/v1/auth/refresh"])
    }

    @Test("404 and cancelled")
    func failure() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/app/books/999999999", file: "404.json", from: .module)
        try t.answer("GET", "/api/v1/books/page", file: "abgebrochen.json", from: .module)
        let q = source(t)
        let foreign = TitleID(source: q.identifier, id: "999999999")
        await #expect(throws: SourceError.notFound(foreign)) { try await q.title(foreign) }
        do {
            _ = try await q.library()
            Issue.record("cancelled must fail")
        } catch let failure as SourceError {
            #expect(failure.messageKey == "error.unreadable", "\(failure)")
        }
    }

    @Test("Without canDownload no keeping; categories become genres (GrimmoryGenres); series from the name")
    func mapping() {
        #expect(!account(mayFetch: false).capabilities.contains(.keep))
        #expect(
            GrimmoryMapping.genres([
                "Fantasy", "Audiobook", "Ebooks", "Book Club", "Dark Fantasy", "Thriller",
            ])
                == ["Fantasy", "Krimi & Thriller"])
        #expect(GrimmoryMapping.genres(nil) == [])
        #expect(GrimmoryMapping.fraction(1.6) == 0.016)
        #expect(GrimmoryMapping.fraction(nil) == 0)
        #expect(GrimmoryMapping.kind("PDF") == .book)
        #expect(GrimmoryMapping.kind("CBX") == .manga)
    }
}
