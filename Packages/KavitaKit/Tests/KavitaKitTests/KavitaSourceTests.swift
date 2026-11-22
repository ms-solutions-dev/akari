import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import KavitaKit

/// Checked against responses from a real Kavita 0.9.1.4 instance: the extract is
/// the four series "Jis Gunwond Plugrim…" of the books library (manga and comics
/// had not been scanned yet), plus one book with a state (page 120 of 317, written
/// specially for the recording and reset afterwards).
@Suite("KavitaQuelle")
struct KavitaSourceTests {
    let server = URL(string: "https://kavita.example")!
    var identifier: SourceID { SourceID(provider: .kavita, server: "kavita.example") }

    private func account(roles: [String] = ["Admin", "Login"]) -> KavitaAccount {
        KavitaAccount(
            server: server, userId: 1, username: "leser", apiKey: "geheim", keyId: 9,
            roles: roles)
    }

    private func source(_ t: any Transport, savedStore: URL? = nil) -> KavitaSource {
        KavitaSource(
            account: account(), transport: t, savedStore: savedStore,
            persistence: UserDefaults(suiteName: "kavita-prüfung-\(UUID().uuidString)")!)
    }

    /// The router with the extract: four series, one reading profile, the volumes per series.
    private func extractRouter() throws -> KavitaRoutingTransport {
        let w = KavitaRoutingTransport()
        try w.remainder.answer("POST", "/api/Series/all-v2", file: "series.json", from: .module)
        try w.remainder.answer(
            "GET", "/api/reading-profile/all", file: "reading-profiles.json", from: .module)
        return w
    }

    // MARK: - Sign in

    @Test("Sign in: password once, then a dedicated auth key named after the device")
    func signIn() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/Account/login", file: "login.json", from: .module)
        // The response to `create-auth-key` per the OpenAPI contract (`AuthKeyDto`) — the
        // recording does not create a key on the server.
        t.answer(
            "POST", "/api/Account/create-auth-key",
            with: .json(#"{"id":12,"key":"eigener-schluessel","name":"Akari on iPhone","provider":0}"#))
        let account = try await KavitaSource.signIn(
            server: server, username: "leser", password: "pw", deviceName: "iPhone", transport: t)
        #expect(account.apiKey == "eigener-schluessel")
        #expect(account.keyId == 12)
        #expect(account.username == "leser")
        #expect(account.roles == ["Admin", "Login"])
        #expect(account.capabilities.contains(.keep), "Admin may fetch")
        #expect(account.identifier == identifier)
        #expect(t.paths == ["POST /api/Account/login", "POST /api/Account/create-auth-key"])
        let signInResult = String(decoding: t.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(signInResult.contains(#""username":"leser""#))
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer attrappe")
        let body = String(decoding: t.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""keyLength":32"#))
        #expect(body.contains("Akari on iPhone · "), "\(body)")
    }

    @Test("Without a dedicated auth key (404 before 0.9) the account key from the sign-in stays")
    func signInWithoutOwnKey() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/Account/login", file: "login.json", from: .module)
        t.answer("POST", "/api/Account/create-auth-key", with: .init(status: 404))
        let account = try await KavitaSource.signIn(
            server: server, username: "leser", password: "pw", deviceName: "iPhone", transport: t)
        #expect(account.apiKey == "attrappe")
        #expect(account.keyId == nil, "signing out does not delete the account key")
    }

    @Test("A wrong password means signed out")
    func wrongPassword() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/Account/login", file: "401-login.json", from: .module)
        await #expect(throws: SourceError.signedOut(identifier)) {
            try await KavitaSource.signIn(
                server: server, username: "leser", password: "falsch", deviceName: "iPhone", transport: t
            )
        }
    }

    @Test("Signing out deletes the dedicated auth key")
    func signOut() async throws {
        let t = MockTransport()
        t.answer("DELETE", "/api/Account/auth-key", with: .init(status: 200))
        try await source(t).signOut()
        #expect(t.paths == ["DELETE /api/Account/auth-key"])
        #expect(t.requests[0].url?.query() == "authKeyId=9")
        #expect(t.requests[0].value(forHTTPHeaderField: "x-api-key") == "geheim")
    }

    @Test("Verify: 200 with key, 401 means signed out")
    func verify() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/Account/refresh-account", file: "refresh-account.json", from: .module)
        try await source(t).verify()
        let route = MockTransport()
        try route.answer("GET", "/api/Account/refresh-account", file: "401.json", from: .module)
        await #expect(throws: SourceError.signedOut(identifier)) { try await source(route).verify() }
    }

    // MARK: - Extract

    @Test("The extract: four series, one chapter per title — one fetch per series")
    func library() async throws {
        let w = try extractRouter()
        let extract = try await source(w).library()
        #expect(extract.seriesList.count == 4)
        #expect(extract.title.count == 4)
        #expect(extract.readingStates.isEmpty)
        #expect(w.volumeFetches == 4)
        #expect(Set(extract.title.map(\.kind)) == [.book])
        let list = try #require(w.requests.first { $0.url?.path() == "/api/Series/all-v2" })
        #expect(list.url?.query()?.contains("PageSize=500") == true)
        #expect(list.value(forHTTPHeaderField: "x-api-key") == "geheim")
        let body = String(decoding: list.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""statements":[]"#))
    }

    @Test("A book as a volume: title from the metadata, volume 2, genres, EPUB without a page count")
    func volume() async throws {
        let extract = try await source(try extractRouter()).library()
        let third = try #require(extract.title.first { $0.identifier.id == "6687" })
        #expect(third.name == "Skinboste", "titleName, not the placeholder -100000")
        #expect(third.series?.name == "Haut kasaiplou Raglu")
        #expect(third.series?.volume == 2, "the chapter has no number, the volume does")
        #expect(third.authors == ["Kouflauter Pandrigrour"])
        #expect(third.genres == ["horror", "fantasy"])
        #expect(third.kind == .book)
        #expect(third.scope == .unknown, "Kavita counts sections for an EPUB")
        #expect(third.format == "EPUB")
        #expect(third.size == 571_727)
        #expect(third.language == "de")
        #expect(third.ageRating == nil, "Unknown is not a rating")
        #expect(third.readingDirection == nil, "a book has no reading direction")
        #expect(third.released == Title.releaseDate("2007-04-11"))
        #expect(third.cover?.path() == "/api/Image/chapter-cover")
        #expect(third.cover?.query() == "chapterId=6687")
        let glass = try #require(extract.title.first { $0.identifier.id == "233" })
        #expect(glass.name == "Haut Kasaiplou Raglu 4 - Setjefliak")
        #expect(glass.series?.volume == nil, "a special volume is not part of the series")
        let series = try #require(extract.seriesList.first { $0.identifier.id == "6115" })
        #expect(series.kind == .book)
        #expect(series.volumeCount == 1)
        #expect(series.cover?.query() == "seriesId=6115")
    }

    @Test("A state in the extract: page 120 of 317 in the EPUB is the fraction")
    func stateInExtract() async throws {
        let w = KavitaRoutingTransport()
        // A series the router knows as `volumes-buch.json` — by its id 395.
        w.remainder.answer(
            "POST", "/api/Series/all-v2",
            with: .json(#"[{"id":395,"name":"Tauspa","pages":317,"pagesRead":120,"format":3,"libraryId":1}]"#)
        )
        w.remainder.answer("GET", "/api/reading-profile/all", with: .json("[]"))
        let extract = try await source(w).library()
        let title = try #require(extract.title.first)
        #expect(title.publisher == "Gleiblabria Verlag GmbH & Bler. YR (com)")
        let state = try #require(extract.readingStates[title.identifier])
        #expect(state.position == .fraction(120.0 / 317.0))
        #expect(!state.completed)
        #expect(state.started)
    }

    @Test("With a previous extract, only series whose marker changed are fetched")
    func changesOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kavita-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = folder.appending(path: "marken.json")
        let firstRun = try extractRouter()
        let previously = try await source(firstRun, savedStore: persistence).library()
        #expect(firstRun.volumeFetches == 4)
        // A new source (the next launch), the same series: no fetch per series.
        let secondRun = try extractRouter()
        let after = try await source(secondRun, savedStore: persistence).library(previously: previously) {
            _, _ in
        }
        #expect(secondRun.volumeFetches == 0)
        #expect(Set(after.title.map(\.identifier)) == Set(previously.title.map(\.identifier)))
        #expect(after.seriesList.count == 4)
        // A previous extract with a different state (not the most recently remembered extract) does not count.
        let foreign = LibraryExtract(
            source: previously.source, seriesList: previously.seriesList, title: previously.title,
            state: Date.distantPast)
        let again = try extractRouter()
        _ = try await source(again, savedStore: persistence).library(previously: foreign) { _, _ in }
        #expect(again.volumeFetches == 4)
    }

    @Test("Paging: the Pagination header says how many pages all-v2 has")
    func paging() async throws {
        let w = KavitaRoutingTransport()
        w.remainder.answer(
            "POST", "/api/Series/all-v2",
            with: .init(
                data: Data(#"[{"id":6115,"name":"Haut kasaiplou Raglu","format":3,"libraryId":1}]"#.utf8),
                headerLines: [
                    "Pagination": #"{"currentPage":1,"itemsPerPage":1,"totalItems":2,"totalPages":2}"#
                ]))
        w.remainder.answer(
            "POST", "/api/Series/all-v2",
            with: .init(
                data: Data(#"[{"id":226,"name":"Setjefliak","format":3,"libraryId":1}]"#.utf8),
                headerLines: [
                    "Pagination": #"{"currentPage":2,"itemsPerPage":1,"totalItems":2,"totalPages":2}"#
                ]))
        w.remainder.answer("GET", "/api/reading-profile/all", with: .json("[]"))
        let extract = try await source(w).library()
        #expect(extract.seriesList.count == 2)
        let pages = w.requests.filter { $0.url?.path() == "/api/Series/all-v2" }.compactMap {
            $0.url?.query()
        }
        #expect(pages.count == 2)
        #expect(pages.last?.contains("PageNumber=2") == true)
    }

    @Test("Disabled libraries are missing from the extract, without a fetch per series")
    func libraryChoice() async throws {
        let persistence = UserDefaults(suiteName: "kavita-wahl-\(UUID().uuidString)")!
        LibraryPicker.set(from: ["1"], for: identifier, persistence)
        let w = try extractRouter()
        let q = KavitaSource(account: account(), transport: w, persistence: persistence)
        let extract = try await q.library()
        #expect(extract.title.isEmpty)
        #expect(w.volumeFetches == 0)
    }

    @Test("Libraries and title count from the header")
    func subLibraries() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/Library/libraries", file: "libraries.json", from: .module)
        try t.answer("POST", "/api/Series/all-v2", file: "series-zahl.json", from: .module)
        let q = source(t)
        let list = try await q.subLibraries()
        #expect(Set(list.map(\.name)) == ["Bücher", "Manga", "Comics"])
        #expect(try await q.titleCount() ?? 0 > 0)
    }

    // MARK: - Title, content, state

    private func titleSource() throws -> (MockTransport, KavitaSource) {
        let t = MockTransport()
        try t.answer("GET", "/api/Series/chapter", file: "chapter.json", from: .module)
        try t.answer("GET", "/api/Volume", file: "volume.json", from: .module)
        try t.answer("GET", "/api/Series/6115", file: "serie.json", from: .module)
        try t.answer("GET", "/api/Rating/overall-series", file: "rating.json", from: .module)
        // The default from `reading-profiles.json`, as `/{libraryId}/{seriesId}` names it individually.
        t.answer(
            "GET", "/api/reading-profile/1/6115",
            with: .json(
                #"{"id":1,"kind":0,"seriesIds":[],"libraryIds":[],"readingDirection":0,"readerMode":0}"#))
        return (t, source(t))
    }

    @Test("A title fresh: chapter, volume, series — no stars if nobody rated")
    func title() async throws {
        let (_, q) = try titleSource()
        let t = try await q.title(TitleID(source: identifier, id: "6687"))
        #expect(t.name == "Skinboste")
        #expect(t.series?.name == "Haut kasaiplou Raglu")
        #expect(t.series?.volume == 2)
        #expect(t.rating == nil, "averageScore 0")
        #expect(t.readingDirection == nil, "an EPUB has no reading direction, even if the profile names one")
    }

    @Test("An unknown chapter is not found")
    func notFound() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/Series/chapter", file: "404.json", from: .module)
        let chapter = TitleID(source: identifier, id: "999999999")
        await #expect(throws: SourceError.notFound(chapter)) { try await source(t).title(chapter) }
    }

    @Test("Without a state Kavita answers pageNum 0 — that means never started")
    func withoutState() async throws {
        let (t, q) = try titleSource()
        try t.answer("GET", "/api/Reader/get-progress", file: "progress.json", from: .module)
        #expect(try await q.progress(TitleID(source: identifier, id: "6687")) == nil)
    }

    @Test("Writing: chapter, volume, series and library; for an EPUB the section of the fraction")
    func writing() async throws {
        let (t, q) = try titleSource()
        t.answer("POST", "/api/Reader/progress", with: .init(status: 200))
        let chapter = TitleID(source: identifier, id: "6687")
        try await q.write(
            ReadingState(position: .position(cfi: "epubcfi(/6/8!/4/2)", fraction: 0.5), timestamp: Date()),
            for: chapter)
        let body = try #require(t.requests.last?.httpBody)
        let sent = try JSONDecoder().decode(KavitaResponses.Progress.self, from: body)
        #expect(sent.chapterId == 6687)
        #expect(sent.volumeId == 6634)
        #expect(sent.seriesId == 6115)
        #expect(sent.libraryId == 1)
        #expect(sent.pageNum == 17, "half of 34 sections")
        // Forgetting is page 0, through the same endpoint — without fetching the reference again.
        let previously = t.requests.count
        try await q.forget(progressFor: chapter)
        #expect(t.requests.count == previously + 1)
        let null = try JSONDecoder().decode(
            KavitaResponses.Progress.self, from: t.requests.last!.httpBody!)
        #expect(null.pageNum == 0)
    }

    @Test("Content: EPUB as a file with a range; pages with apiKey and page from 0")
    func content() async throws {
        let extract = try await source(try extractRouter()).library()
        let q = source(MockTransport())
        let book = try #require(extract.title.first { $0.identifier.id == "6687" })
        guard case .file(let address, let size, let area) = q.content(book) else {
            Issue.record("File expected")
            return
        }
        #expect(address.path() == "/api/Download/chapter")
        #expect(address.query() == "chapterId=6687")
        #expect(size == 571_727)
        #expect(area, "206 with Content-Range in the recording")
        // A comic (the kit decides by kind): page counts from 0, the key in the query.
        let comic = Title(
            identifier: TitleID(source: identifier, id: "13383"), kind: .manga, name: "PDF", scope: .pages(4),
            format: "PDF")
        guard case .pageStream(let count, let page, let measures) = q.content(comic) else {
            Issue.record("Page stream expected")
            return
        }
        #expect(count == 4)
        let first = page(1)
        #expect(first.path() == "/api/Reader/image")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map {
                    ($0.name, $0.value ?? "")
                })
        #expect(query == ["chapterId": "13383", "extractPdf": "true", "page": "0", "apiKey": "geheim"])
        #expect(measures != nil)
    }

    @Test("Page dimensions from file-dimensions — empty for an EPUB")
    func measures() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/Reader/file-dimensions", file: "file-dimensions.json", from: .module)
        let q = source(t)
        let comic = Title(
            identifier: TitleID(source: identifier, id: "6687"), kind: .manga, name: "x", scope: .pages(2))
        guard case .pageStream(_, _, let measures) = q.content(comic), let measures else {
            Issue.record("Dimensions expected")
            return
        }
        #expect(try await measures().isEmpty)
        let portrait = MockTransport()
        portrait.answer(
            "GET", "/api/Reader/file-dimensions",
            with: .json(
                #"[{"width":1080,"height":1394,"pageNumber":1,"isWide":false},{"width":2160,"height":1394,"pageNumber":0,"isWide":true}]"#
            ))
        guard case .pageStream(_, _, let dimensions) = source(portrait).content(comic), let dimensions else {
            return
        }
        let list = try await dimensions()
        #expect(list.map(\.landscape) == [true, false], "ordered by page number")
    }

    // MARK: - Saved list and collections

    @Test("Saved list: want-to-read series as their first title; saving writes the series")
    func savedList() async throws {
        let w = try extractRouter()
        let q = source(w)
        _ = try await q.library()
        w.remainder.answer(
            "POST", "/api/want-to-read/v2", with: .json(#"[{"id":6115,"name":"Haut kasaiplou Raglu"}]"#))
        #expect(try await q.savedList() == [TitleID(source: identifier, id: "6687")])
        w.remainder.answer("POST", "/api/want-to-read/add-series", with: .init(status: 200))
        try await q.save(TitleID(source: identifier, id: "6687"), saved: true)
        let body = String(decoding: w.requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(body == #"{"seriesIds":[6115]}"#)
    }

    @Test("Recorded empty: no saved list, no collections")
    func empty() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/want-to-read/v2", file: "want-to-read.json", from: .module)
        try t.answer("GET", "/api/Collection", file: "collections.json", from: .module)
        try t.answer("POST", "/api/ReadingList/lists", file: "readinglists.json", from: .module)
        let q = source(t)
        #expect(try await q.savedList().isEmpty)
        #expect(try await q.collections().isEmpty)
    }

    @Test("Collections per the OpenAPI contract: collection with series, reading list with chapters")
    func collections() async throws {
        let t = MockTransport()
        t.answer(
            "GET", "/api/Collection",
            with: .json(
                #"[{"id":3,"title":"Sommer","promoted":false,"owner":"leser"},{"id":4,"title":"Admin-Liste","promoted":true,"owner":"chef"}]"#
            ))
        t.answer("GET", "/api/Series/series-by-collection", with: .json(#"[{"id":6115},{"id":226}]"#))
        t.answer(
            "POST", "/api/ReadingList/lists",
            with: .json(#"[{"id":3,"title":"Reihenfolge","promoted":false,"ownerUserName":"leser"}]"#))
        t.answer(
            "GET", "/api/ReadingList/items",
            with: .json(
                #"[{"id":21,"order":1,"chapterId":233,"seriesId":226},{"id":20,"order":0,"chapterId":6687}]"#)
        )
        let list = try await source(t).collections()
        #expect(
            list.map(\.identifier.id) == ["c3", "c4", "l3"],
            "Collections and reading lists are counted separately")
        #expect(list[0].collectionKind == .collection)
        #expect(
            list[0].entries == [
                .series(SeriesID(source: identifier, id: "6115")),
                .series(SeriesID(source: identifier, id: "226")),
            ])
        #expect(list[0].editable && list[0].isPrivate)
        #expect(!list[1].editable && !list[1].isPrivate, "promoted and foreign")
        #expect(list[2].collectionKind == .readingList && list[2].ordered)
        #expect(list[2].entries.first == .title(TitleID(source: identifier, id: "6687")), "by order")
    }
}
