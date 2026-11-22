import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import KomgaKit

/// Checked against responses from a real Komga 1.26.3 instance:
/// 22 series, 613 volumes, two reading states.
@Suite("KomgaQuelle")
struct KomgaSourceTests {
    let server = URL(string: "https://comics.example")!

    private func account() -> KomgaAccount {
        KomgaAccount(
            server: server, userId: "0RM392MF9XG8C", email: "leser@example.test", apiKey: "geheim",
            keyId: "0RMZ8016M49TH", roles: ["ADMIN", "FILE_DOWNLOAD", "PAGE_STREAMING", "USER"])
    }

    private func source(_ t: MockTransport) -> KomgaSource {
        KomgaSource(account: account(), transport: t)
    }

    @Test("Sign in: password once, then a key named after the device")
    func signIn() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v2/users/me", file: "me.json", from: .module)
        try t.answer("POST", "/api/v2/users/me/api-keys", file: "api-key-anlegen.json", from: .module)
        let account = try await KomgaSource.signIn(
            server: server, email: "leser@example.test", password: "pw", deviceName: "Alex's iPhone",
            transport: t)
        #expect(account.email == "leser@example.test")
        #expect(account.apiKey == "GESCHWAERZT")
        // The id differs with every recording — it has to match the recording.
        let recorded =
            try JSONSerialization.jsonObject(
                with: try MockTransport.recording("api-key-anlegen.json", from: .module).data)
            as? [String: Any]
        #expect(account.keyId == recorded?["id"] as? String)
        #expect(!account.keyId.isEmpty)
        #expect(
            account.capabilities == [
                .pageStream, .keep, .seriesList, .ageRating, .collections, .editCollections,
            ], "ADMIN may create collections")
        #expect(account.identifier == SourceID(provider: .komga, server: "comics.example"))
        let first = t.requests[0]
        #expect(first.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        let body = String(decoding: t.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix(#"{"comment":"Akari on Alex's iPhone · "#), "\(body)")
        #expect(
            KomgaSource.keyComment(
                "iPad", now: Date(timeIntervalSince1970: 1_789_776_000), locale: Locale(identifier: "en_US")
            )
            .hasPrefix("Akari on iPad · 9/19/2026"),
            "the comment carries date and time — Komga requires it to be unique")
    }

    @Test("A wrong password means signed out, not “error”")
    func wrongPassword() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v2/users/me", file: "401.json", from: .module)
        await #expect(
            throws: SourceError.signedOut(SourceID(provider: .komga, server: "comics.example"))
        ) {
            try await KomgaSource.signIn(
                server: server, email: "x", password: "y", deviceName: "z", transport: t)
        }
    }

    @Test("Without FILE_DOWNLOAD no keeping")
    func withoutDownloadRole() {
        let restricted = KomgaAccount(
            server: server, userId: "s", email: "robin@example.test", apiKey: "k", keyId: "i",
            roles: ["PAGE_STREAMING", "USER"])
        #expect(!restricted.capabilities.contains(.keep))
        #expect(restricted.capabilities.contains(.pageStream))
    }

    @Test("The library: 22 series, 613 volumes, two reading states — from two fetches")
    func library() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/v1/series/list", file: "series.json", from: .module)
        try t.answer("POST", "/api/v1/books/list", file: "books.json", from: .module)
        let extract = try await source(t).library()
        #expect(extract.seriesList.count == 22)
        #expect(extract.title.count == 613)
        #expect(extract.readingStates.count == 2)
        #expect(t.paths == ["POST /api/v1/series/list", "POST /api/v1/books/list"])
        #expect(t.requests[0].url?.query()?.contains("size=500") == true)
        #expect(t.requests[0].value(forHTTPHeaderField: "X-API-Key") == "geheim")
        #expect(Set(extract.title.map(\.kind)) == [.manga])
    }

    @Test("A series carries what komf gave it: genres, age rating, reading direction, language")
    func series() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/v1/series/list", file: "series.json", from: .module)
        try t.answer("POST", "/api/v1/books/list", file: "books.json", from: .module)
        let extract = try await source(t).library()
        let alice = try #require(extract.seriesList.first { $0.name == "Fiahot slem Wani" })
        #expect(alice.ageRating == 16)
        #expect(alice.readingDirection == .rightToLeft)
        #expect(alice.language == "de")
        #expect(alice.genres.count == 14)
        #expect(alice.volumeCount == 6)
        #expect(alice.total == 12, "the run is longer than the shelf")
        #expect(alice.status == .completed)
        #expect(alice.rating?.stars == 4)
        #expect(alice.illustrators.isEmpty, "Triadroflur Binsiojiarn writes and draws")
        let writerAndArtist = try #require(extract.seriesList.first { $0.name == "Druspind Gugeis" })
        #expect(writerAndArtist.authors == ["GIHOUSGLO Flanplias"], "only who writes")
        #expect(writerAndArtist.illustrators == ["SIARI Spaisla"])
        #expect(alice.authors == ["Triadroflur Binsiojiarn"])
        #expect(alice.summary?.hasPrefix("Description removed") == true)
        #expect(alice.cover?.path() == "/api/v1/series/0RM6ZZJWZS971/thumbnail")
    }

    @Test("A volume inherits from the series and carries its reading state: page 4 of 213")
    func volume() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/v1/series/list", file: "series.json", from: .module)
        try t.answer("POST", "/api/v1/books/list", file: "books.json", from: .module)
        let extract = try await source(t).library()
        let volume = try #require(extract.title.first { $0.identifier.id == "0RM4VTYHRPJ30" })
        #expect(volume.series?.name == "Skagrausge-Pau Briatvainkiand")
        #expect(volume.series?.volume == 1)
        #expect(volume.scope == .pages(213))
        #expect(Set(volume.authors) == ["Spitreblas", "Fave Cegra"], "both are listed as writer")
        #expect(volume.summary != nil, "the volume inherits the series summary")
        #expect(!volume.genres.isEmpty)
        #expect(volume.readingDirection == .rightToLeft)
        #expect(volume.cover?.path() == "/api/v1/books/0RM4VTYHRPJ30/thumbnail")
        let state = try #require(extract.readingStates[volume.identifier])
        #expect(state.position == .page(4, from: 213))
        #expect(state.started)
        #expect(!state.completed)
        #expect(state.device == nil)
        #expect(state.timestamp == Date(timeIntervalSince1970: 1_789_406_349))
    }

    @Test(
        "Collections and reading lists: recorded empty, filled per the OpenAPI contract; PATCH writes the whole list"
    )
    func collections() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/collections", file: "collections.json", from: .module)
        try t.answer("GET", "/api/v1/readlists", file: "readlists.json", from: .module)
        #expect(try await source(t).collections().isEmpty)

        let t2 = MockTransport()
        t2.answer(
            "GET", "/api/v1/collections",
            with: .json(
                #"{"content":[{"id":"c1","name":"Shōnen-Klassiker","ordered":false,"seriesIds":["s1","s2"],"createdDate":"2026-09-17T00:00:00Z","lastModifiedDate":"2026-09-17T00:00:00Z","filtered":false}],"totalElements":1,"last":true,"number":0,"totalPages":1}"#
            ))
        t2.answer(
            "GET", "/api/v1/readlists",
            with: .json(
                #"{"content":[{"id":"r1","name":"Einstieg","summary":"","ordered":true,"bookIds":["b1","b2","b3"],"createdDate":"2026-09-17T00:00:00Z","lastModifiedDate":"2026-09-17T00:00:00Z","filtered":false}],"totalElements":1,"last":true,"number":0,"totalPages":1}"#
            ))
        let q = source(t2)
        let list = try await q.collections()
        #expect(list.map(\.name) == ["Shōnen-Klassiker", "Einstieg"])
        #expect(
            list[0].collectionKind == .collection && list[0].entries.count == 2 && !list[0].isPrivate
                && list[0].editable)
        #expect(list[1].collectionKind == .readingList && list[1].ordered)
        #expect(
            list[1].entries == ["b1", "b2", "b3"].map { .title(TitleID(source: q.identifier, id: $0)) })

        t2.answer(
            "GET", "/api/v1/readlists/r1",
            with: .json(
                #"{"id":"r1","name":"Einstieg","summary":"","ordered":true,"bookIds":["b1","b2","b3"],"createdDate":"2026-09-17T00:00:00Z","lastModifiedDate":"2026-09-17T00:00:00Z","filtered":false}"#
            ))
        t2.answer("PATCH", "/api/v1/readlists/r1", with: .json("", status: 204))
        try await q.arrange(
            .title(TitleID(source: q.identifier, id: "b9")), in: list[1].identifier, into: true)
        let body =
            try JSONSerialization.jsonObject(with: try #require(t2.requests.last?.httpBody)) as? [String: Any]
        #expect(body?["bookIds"] as? [String] == ["b1", "b2", "b3", "b9"])
        #expect(t2.paths.last == "PATCH /api/v1/readlists/r1")
    }

    @Test("The score tag becomes stars, a missing one becomes nothing")
    func rating() {
        #expect(
            KomgaMapping.rating(["wedruklur", "score: 8", "urban"]) == Rating(stars: 4, origin: "Komga")
        )
        #expect(KomgaMapping.rating(["score:7"])?.stars == 3.5)
        #expect(KomgaMapping.rating(["shounen"]) == nil)
        #expect(KomgaMapping.rating(["score: hoch"]) == nil)
    }

    @Test("The page stream names 213 pages and the address of each page")
    func content() throws {
        let q = source(MockTransport())
        let volume = Title(
            identifier: TitleID(source: q.identifier, id: "0RM4VTYHRPJ30"), kind: .manga, name: "x",
            scope: .pages(213))
        let stream = q.content(volume)
        #expect(stream.pageCount == 213)
        guard case .pageStream(_, let page, _) = stream else {
            Issue.record("no stream")
            return
        }
        #expect(page(4).absoluteString == "https://comics.example/api/v1/books/0RM4VTYHRPJ30/pages/4")
        #expect(q.headerLines() == ["X-API-Key": "geheim"])
    }

    @Test("The manifest names the dimensions of each page — page 1 is portrait, 1328 × 1920")
    func pageDimensions() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books/0RM4VTYHRPJ30/pages", file: "book-pages.json", from: .module)
        let q = source(t)
        let volume = Title(
            identifier: TitleID(source: q.identifier, id: "0RM4VTYHRPJ30"), kind: .manga, name: "x",
            scope: .pages(213))
        guard case .pageStream(_, _, let measures?) = q.content(volume) else {
            Issue.record("no manifest")
            return
        }
        let list = try await measures()
        #expect(list.count == 213)
        #expect(list[0] == PageSize(width: 1328, height: 1920))
        #expect(list.allSatisfy { !$0.landscape })
    }

    @Test("Title and progress individually: volume plus series")
    func titleAndProgress() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/v1/books/0RM4VTYHRPJ30", file: "book.json", from: .module)
        try t.answer("GET", "/api/v1/series/0RM4VTYHRPJ2Z", file: "serie.json", from: .module)
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: "0RM4VTYHRPJ30")
        let title = try await q.title(identifier)
        #expect(title.series?.name == "Skagrausge-Pau Briatvainkiand")
        #expect(title.scope == .pages(213))
        let state = try await q.progress(identifier)
        #expect(state?.position == .page(4, from: 213))
        #expect(
            t.paths == [
                "GET /api/v1/books/0RM4VTYHRPJ30", "GET /api/v1/series/0RM4VTYHRPJ2Z",
                "GET /api/v1/books/0RM4VTYHRPJ30",
            ])
    }

    @Test("Writing: PATCH read-progress with page and completed; no CFI to Komga")
    func writing() async throws {
        let t = MockTransport()
        t.answer("PATCH", "/api/v1/books/0RM4VTYHRPJ30/read-progress", with: .init(status: 204))
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: "0RM4VTYHRPJ30")
        try await q.write(
            ReadingState(position: .page(112, from: 213), timestamp: Date(), device: "iPhone"),
            for: identifier)
        #expect(try body(t) == ["page": 112, "completed": false])
        try await q.write(
            ReadingState(position: .page(213, from: 213), timestamp: Date(), completed: true),
            for: identifier)
        #expect(try body(t) == ["page": 213, "completed": true])
        await #expect(throws: SourceError.notPossible(q.identifier, "Komga only knows pages")) {
            try await q.write(
                ReadingState(position: .position(cfi: "x", fraction: 0.5), timestamp: Date()), for: identifier
            )
        }
        #expect(t.requests.count == 2)
    }

    @Test("Forgetting: DELETE read-progress — no state with page zero")
    func forgetting() async throws {
        let t = MockTransport()
        t.answer("DELETE", "/api/v1/books/0RM4VTYHRPJ30/read-progress", with: .init(status: 204))
        let q = source(t)
        try await q.forget(progressFor: TitleID(source: q.identifier, id: "0RM4VTYHRPJ30"))
        #expect(t.paths == ["DELETE /api/v1/books/0RM4VTYHRPJ30/read-progress"])
        #expect(t.requests[0].value(forHTTPHeaderField: "X-API-Key") == "geheim")
    }

    @Test("401, 404 and a cancelled response — three directions")
    func failure() async throws {
        let t = MockTransport()
        try t.answer("POST", "/api/v1/series/list", file: "401-api-key.json", from: .module)
        try t.answer("GET", "/api/v1/books/gibt-es-nicht", file: "404.json", from: .module)
        let q = source(t)
        await #expect(throws: SourceError.signedOut(q.identifier)) { try await q.library() }
        let foreign = TitleID(source: q.identifier, id: "gibt-es-nicht")
        await #expect(throws: SourceError.notFound(foreign)) { try await q.title(foreign) }

        let t2 = MockTransport()
        try t2.answer("POST", "/api/v1/series/list", file: "series.json", from: .module)
        try t2.answer("POST", "/api/v1/books/list", file: "abgebrochen.json", from: .module)
        do {
            _ = try await source(t2).library()
            Issue.record("cancelled must fail")
        } catch let failure as SourceError {
            #expect(failure.messageKey == "error.unreadable", "\(failure)")
            #expect(failure.final)
        }
    }

    /// The JSON body of the last request as a dictionary — key order is left
    /// to the encoder.
    private func body(_ t: MockTransport) throws -> [String: AnyHashable] {
        let data = try #require(t.requests.last?.httpBody)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: AnyHashable]
        return try #require(object)
    }
}
