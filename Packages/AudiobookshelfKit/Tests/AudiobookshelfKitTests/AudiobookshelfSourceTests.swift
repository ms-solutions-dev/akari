import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import AudiobookshelfKit

/// Checked against responses from a real Audiobookshelf instance: one
/// library, nine audiobooks, one reading state (Faufras Sutblai 1, 176 s).
@Suite("AudiobookshelfQuelle")
struct AudiobookshelfSourceTests {
    let server = URL(string: "https://hoerbuch.example")!
    let library = "eda12180-b631-4b53-b38d-f80bfd8c75e1"
    let sutblai = "b5870c20-7d6d-418b-891a-c8f10fdfb29d"

    private func source(_ t: MockTransport, mayFetch: Bool = true) -> AudiobookshelfSource {
        AudiobookshelfSource(
            account: AudiobookshelfAccount(
                server: server, userId: "c0b03793", username: "leser", token: "tok",
                mayFetch: mayFetch),
            transport: t)
    }

    @Test("Signing in returns token and permissions; a wrong password means signed out")
    func signIn() async throws {
        let t = MockTransport()
        try t.answer("POST", "/login", file: "login.json", from: .module)
        let account = try await AudiobookshelfSource.signIn(
            server: server, username: "leser", password: "pw", transport: t)
        #expect(account.token == "GESCHWAERZT")
        #expect(account.mayFetch)
        #expect(account.capabilities == [.seriesList, .collections, .editCollections, .keep])
        #expect(account.identifier == SourceID(provider: .audiobookshelf, server: "hoerbuch.example"))
        let t2 = MockTransport()
        try t2.answer("POST", "/login", file: "401-login.json", from: .module)
        await #expect(throws: SourceError.signedOut(account.identifier)) {
            try await AudiobookshelfSource.signIn(
                server: server, username: "x", password: "y", transport: t2)
        }
    }

    @Test("The library: 13 audiobooks, two series, three reading states — from three fetches")
    func library() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/libraries", file: "libraries.json", from: .module)
        try t.answer("GET", "/api/libraries/\(library)/items", file: "items.json", from: .module)
        try t.answer("GET", "/api/me", file: "me.json", from: .module)
        let q = source(t)
        let extract = try await q.library()
        #expect(extract.title.count == 13)
        #expect(Set(extract.title.map(\.kind)) == [.audiobook])
        #expect(extract.readingStates.count == 3)
        #expect(t.paths == ["GET /api/libraries", "GET /api/libraries/\(library)/items", "GET /api/me"])
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let state = try #require(extract.readingStates[TitleID(source: q.identifier, id: sutblai)])
        guard case .second(let s, let from) = state.position else {
            Issue.record("Seconds expected")
            return
        }
        #expect(abs(s - 18.0) < 0.01)
        #expect(abs(from - 38_166.99) < 0.01)
        #expect(!state.completed)
        #expect(state.timestamp == Date(timeIntervalSince1970: 1_789_683_432.561))
        let sutblaiSeries = try #require(extract.seriesList.first { $0.name == "Faufras Sutblai" })
        #expect(sutblaiSeries.volumeCount == 7)
        // Fixed on the server since then: before that
        // the narrator was listed as the author.
        #expect(sutblaiSeries.authors == ["W. E. Frioglil"])
    }

    @Test(
        "Collections: recorded empty; collections and playlists per the API contract, create and arrange")
    func collections() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/collections", file: "collections-alle.json", from: .module)
        try t.answer("GET", "/api/playlists", file: "playlists-alle.json", from: .module)
        #expect(try await source(t).collections().isEmpty)
        #expect(t.paths == ["GET /api/collections", "GET /api/playlists"])

        let t2 = MockTransport()
        t2.answer(
            "GET", "/api/collections",
            with: .json(
                #"{"collections":[{"id":"col_1","libraryId":"lib_1","userId":"root","name":"Paipiobau","description":null,"books":[{"id":"li_a"},{"id":"li_b"}],"lastUpdate":1,"createdAt":1}]}"#
            ))
        t2.answer(
            "GET", "/api/playlists",
            with: .json(
                #"{"playlists":[{"id":"pl_1","libraryId":"lib_1","userId":"NUTZER","name":"Urlaub","description":null,"items":[{"libraryItemId":"li_c","episodeId":null}]}]}"#
            ))
        let q = source(t2)
        let list = try await q.collections()
        #expect(list.map(\.name) == ["Paipiobau", "Urlaub"])
        #expect(list[0].collectionKind == .collection && !list[0].isPrivate && list[0].entries.count == 2)
        #expect(list[1].collectionKind == .readingList && list[1].isPrivate && list[1].ordered)
        #expect(list[1].editable == (q.account.userId == "NUTZER"))

        try t2.answer("GET", "/api/libraries", file: "libraries.json", from: .module)
        t2.answer(
            "POST", "/api/playlists",
            with: .json(#"{"id":"pl_9","libraryId":"lib_1","userId":"u","name":"Neu","items":[]}"#))
        t2.answer("POST", "/api/playlists/pl_9/item", with: .json("{}"))
        t2.answer("DELETE", "/api/collections/col_1/book/li_a", with: .json("{}"))
        let new = try await q.create(collection: "Neu", collectionKind: .readingList)
        #expect(new.identifier.id == "pl_9" && new.isPrivate)
        let title = TitleID(source: q.identifier, id: "li_a")
        try await q.arrange(.title(title), in: new.identifier, into: true)
        try await q.arrange(.title(title), in: list[0].identifier, into: false)
        #expect(
            t2.paths.suffix(3) == [
                "POST /api/playlists", "POST /api/playlists/pl_9/item",
                "DELETE /api/collections/col_1/book/li_a",
            ])
        #expect(t2.requests[t2.requests.count - 2].httpBody == Data(#"{"libraryItemId":"li_a"}"#.utf8))
    }

    @Test("A title from the list: duration, narrator, series from “Name #1”, description without HTML")
    func titleFromList() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/libraries", file: "libraries.json", from: .module)
        try t.answer("GET", "/api/libraries/\(library)/items", file: "items.json", from: .module)
        try t.answer("GET", "/api/me", file: "me.json", from: .module)
        let extract = try await source(t).library()
        let eyeCollector = try #require(extract.title.first { $0.name == "Frau Nusklio" })
        #expect(eyeCollector.authors == ["Troto Paipiobau"])
        #expect(eyeCollector.narrator == ["Spaihatdrout Glibipei"])
        #expect(eyeCollector.series?.name == "Gowinklend Mauduslo & Wurotwet Stawupriarn")
        #expect(eyeCollector.series?.volume == 1)
        #expect(
            eyeCollector.genres == ["Thriller", "Psychothriller"], "tags before genres, without duplicates")
        #expect(eyeCollector.chapter != nil)
        let sutblai = try #require(extract.title.first { $0.name.hasSuffix("Drigei prou Jautru") })
        #expect(!sutblai.genres.contains("Audiobook"), "the ID3 scan is not a genre")
        #expect(sutblai.genres.contains("Fantasy"))
        #expect(sutblai.summary == nil, "“1905” is an ID3 comment, not a blurb")
        #expect(sutblai.subtitle != nil)
        #expect(eyeCollector.publisher == "Petdior Grinos")
        #expect(eyeCollector.language == "de")
        #expect(eyeCollector.scope == .duration(39_082.204243000015))
        #expect(eyeCollector.cover?.path() == "/api/items/4a148cc8-a6d8-4649-b9c3-e5a7b4e878e8/cover")
        #expect(
            eyeCollector.released.map { Calendar(identifier: .gregorian).component(.year, from: $0) } == 2006)
        let text = try #require(eyeCollector.summary)
        #expect(text.hasPrefix("Description removed from the test data."))
        #expect(!text.contains("<"))
        #expect(text.contains(">> It was HTML."))
    }

    @Test("The detail with expanded=1: authors and series as lists, 108 chapters")
    func detail() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/items/\(sutblai)", file: "item.json", from: .module)
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: sutblai)
        let title = try await q.title(identifier)
        #expect(title.name == "Faufras Sutblai gris plai Drigei prou Jautru")
        #expect(title.authors == ["W. E. Frioglil"])
        #expect(title.narrator == ["Zouttek Nakrause"])
        #expect(title.series?.name == "Faufras Sutblai")
        #expect(title.series?.volume == 1)
        #expect(t.requests[0].url?.query() == "expanded=1")
        guard case .audioStream(let fetch) = q.content(title) else {
            Issue.record("Audio stream expected")
            return
        }
        let volume = try await fetch()
        #expect(volume.chapter.count == 108)
        #expect(volume.chapter.first == Chapter(name: "Dratzus mol Blodiaskurn", startTime: 0, end: 56.548756))
        #expect(volume.tracks.count == 108)
        #expect(volume.tracks.first?.address.path() == "/api/items/\(sutblai)/file/2162898")
        #expect(volume.tracks.first?.startTime == 0)
        #expect(volume.tracks[1].startTime == volume.tracks[0].duration)
        #expect(volume.duration == 38166.99136200002)
        // For keeping: size and extension per track from `metadata`, the sum on the volume —
        // 672 MB in 108 MP3s; `size` on the entry (673 MB) includes the cover.
        #expect(volume.tracks.first?.size == 1_471_125)
        #expect(volume.tracks.first?.fileExtension == "mp3")
        #expect(volume.size == 672_396_850)
    }

    @Test("Progress individually, and writing as PATCH with seconds")
    func progress() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/me/progress/\(sutblai)", file: "item-progress.json", from: .module)
        t.answer("PATCH", "/api/me/progress/\(sutblai)", with: .init(status: 200))
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: sutblai)
        let state = try #require(try await q.progress(identifier))
        #expect(abs(state.fraction - 0.00047162) < 0.000001)
        try await q.write(
            ReadingState(position: .second(600, from: 38_166.99), timestamp: Date(), device: "iPhone"),
            for: identifier)
        let body =
            try JSONSerialization.jsonObject(with: try #require(t.requests.last?.httpBody))
            as? [String: Double]
        #expect(body?["currentTime"] == 600)
        #expect(body?["isFinished"] == 0)
        #expect(abs((body?["progress"] ?? 0) - 600 / 38_166.99) < 0.000001)
        await #expect(throws: SourceError.notPossible(q.identifier, "Audiobookshelf only knows seconds")) {
            try await q.write(ReadingState(position: .page(3, from: 9), timestamp: Date()), for: identifier)
        }
    }

    @Test("Forgetting deletes via the entry id, not the title id")
    func forgetting() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/me/progress/\(sutblai)", file: "item-progress.json", from: .module)
        t.answer("DELETE", "/api/me/progress/43a10cee-ddde-4ce9-b5c7-1f86edb870a7", with: .init(status: 200))
        let q = source(t)
        try await q.forget(progressFor: TitleID(source: q.identifier, id: sutblai))
        #expect(
            t.paths == [
                "GET /api/me/progress/\(sutblai)",
                "DELETE /api/me/progress/43a10cee-ddde-4ce9-b5c7-1f86edb870a7",
            ])
    }

    @Test("Forgetting without an entry is done, without DELETE")
    func forgetWithoutEntry() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/me/progress/li_1", file: "404.json", from: .module)
        let q = source(t)
        try await q.forget(progressFor: TitleID(source: q.identifier, id: "li_1"))
        #expect(t.paths == ["GET /api/me/progress/li_1"])
    }

    @Test("Without the download permission no keeping")
    func permissions() {
        #expect(!source(MockTransport(), mayFetch: false).capabilities.contains(.keep))
    }

    @Test("401, 404 and cancelled — three directions; missing progress is none")
    func failure() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/libraries", file: "401.json", from: .module)
        try t.answer("GET", "/api/items/gibt-es-nicht", file: "404.json", from: .module)
        try t.answer("GET", "/api/me/progress/gibt-es-nicht", file: "404.json", from: .module)
        let q = source(t)
        await #expect(throws: SourceError.signedOut(q.identifier)) { try await q.library() }
        let foreign = TitleID(source: q.identifier, id: "gibt-es-nicht")
        await #expect(throws: SourceError.notFound(foreign)) { try await q.title(foreign) }
        #expect(try await q.progress(foreign) == nil)
        let t2 = MockTransport()
        try t2.answer("GET", "/api/libraries", file: "libraries.json", from: .module)
        try t2.answer("GET", "/api/libraries/\(library)/items", file: "abgebrochen.json", from: .module)
        do {
            _ = try await source(t2).library()
            Issue.record("cancelled must fail")
        } catch let failure as SourceError {
            #expect(failure.messageKey == "error.unreadable", "\(failure)")
        }
    }

    @Test("Language and description are made readable")
    func mapping() {
        #expect(AudiobookshelfMapping.language("German") == "de")
        #expect(AudiobookshelfMapping.language("Hafenplatt") == "Hafenplatt")
        #expect(AudiobookshelfMapping.language("") == nil)
        #expect(
            AudiobookshelfMapping.text("<p>Eins<br />Zwei</p> <p>Skinboste &amp; vier</p>")
                == "Eins\nZwei\n\nSkinboste & vier")
        #expect(AudiobookshelfMapping.text("<p></p>") == nil)
    }
}
