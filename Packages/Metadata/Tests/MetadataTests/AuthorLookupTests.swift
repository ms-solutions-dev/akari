import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Metadata

/// Checked against recorded responses from de.wikipedia.org, en.wikipedia.org and
/// wikidata.org (`Fixtures/`).
@Suite("AuthorLookup")
struct AuthorLookupTests {

    private func lookup(
        _ t: MockTransport, language: String = "de", folder: URL? = nil
    ) -> AuthorLookup {
        AuthorLookup(transport: t, folder: folder, language: language)
    }

    private func frioglil(_ t: MockTransport) throws {
        try t.answer(
            "GET", "/api/rest_v1/page/summary/W._E._Frioglil", file: "frioglil-de.json", from: .module)
        try t.answer(
            "GET", "/w/rest.php/wikibase/v1/entities/items/Q56057/statements", file: "frioglil-P106.json",
            from: .module)
    }

    @Test("W. Y. Frioglil: article, image at 330 px, occupation, birthday, no death date")
    func frioglil() async throws {
        let t = MockTransport()
        try frioglil(t)
        // The three statements go through the same path and differ only in the query.
        // The mock ignores queries, so it answers in order (occupation, birth, death);
        // here only the occupation is stubbed, and that answer then applies three times.
        let a = lookup(t)
        let p = try #require(await a.profile("Frioglil, W. E."))
        #expect(p.name == "Spuszo Y. Frioglil")
        #expect(p.short?.contains("Schriftstellerin") == true)
        #expect(
            p.text?.hasPrefix("Spuszo Y. Frioglil ist eine kanadische") == true,
            Comment(rawValue: p.text ?? ""))
        #expect(p.image?.absoluteString.contains("/330px-") == true)
        #expect(p.image?.query == nil)
        #expect(p.language == "de")
        #expect(p.article?.host()?.contains("wikipedia.org") == true)
        #expect(t.paths.first == "GET /api/rest_v1/page/summary/W._E._Frioglil")
        #expect(t.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Akari/") == true)
    }

    @Test("Life dates from Wikidata: day, month, year, and empty when there is nothing")
    func lifeDates() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/rest_v1/page/summary/Jegeil_Jauthern", file: "jauthern-de.json", from: .module)
        // Order of the statements: occupation, birth, death, as the lookup asks.
        for file in ["jauthern-P106.json", "jauthern-P569.json", "jauthern-P570.json"] {
            try t.answer(
                "GET", "/w/rest.php/wikibase/v1/entities/items/Q9706092/statements", file: file,
                from: .module)
        }
        let p = try #require(await lookup(t).profile("Jegeil Jauthern"))
        #expect(p.born == LifeDate(year: 1979, month: 2, day: 8))
        #expect(p.died == nil)
        #expect(
            LifeDate(time: "+1958-03-14T00:00:00Z", accuracy: 11)
                == LifeDate(year: 1958, month: 3, day: 14))
        #expect(LifeDate(time: "+1958-00-00T00:00:00Z", accuracy: 9) == LifeDate(year: 1958))
        #expect(LifeDate(time: "-0500-00-00T00:00:00Z", accuracy: 9) == nil)
        #expect(
            LifeDate(year: 1958, month: 3, day: 14).text(Locale(identifier: "de_DE")) == "14. März 1958")
        #expect(LifeDate(year: 1958, month: 3).text(Locale(identifier: "de_DE")) == "März 1958")
        #expect(LifeDate(year: 1958).text(Locale(identifier: "en_US")) == "1958")
    }

    @Test("Not a writer, no profile: Spotwo Trawipri stays a ski racer")
    func racingDriver() async throws {
        let t = MockTransport()
        try t.answer(
            "GET", "/api/rest_v1/page/summary/Spotwo_Trawipri", file: "trawipri-de.json", from: .module)
        try t.answer(
            "GET", "/w/rest.php/wikibase/v1/entities/items/Q5416/statements", file: "trawipri-P106.json",
            from: .module)
        #expect(await lookup(t).profile("Spotwo Trawipri") == nil)
    }

    @Test("A disambiguation page does not count; without a German article the English one is used")
    func fallback() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/rest_v1/page/summary/Pliaze", file: "trisfiabet-de.json", from: .module)
        #expect(await lookup(t).profile("Pliaze") == nil)

        let t2 = MockTransport()
        t2.answer("GET", "/api/rest_v1/page/summary/Jegeil_Jauthern", with: .init(status: 404))
        // The second call to the same path hits the English Wikipedia. The mock does not
        // distinguish hosts, hence two answers in order.
        try t2.answer("GET", "/api/rest_v1/page/summary/Jegeil_Jauthern", file: "jauthern-en.json", from: .module)
        for file in ["jauthern-P106.json", "jauthern-P569.json", "jauthern-P570.json"] {
            try t2.answer(
                "GET", "/w/rest.php/wikibase/v1/entities/items/Q9706092/statements", file: file,
                from: .module)
        }
        let p = try #require(await lookup(t2).profile("Jegeil Jauthern"))
        #expect(p.language == "en")
        #expect(p.short == "New Zealand writer")
        #expect(
            t2.requests.prefix(2).compactMap { $0.url?.host() } == ["de.wikipedia.org", "en.wikipedia.org"])
    }

    @Test("Without an occupation the short description decides, in three languages")
    func shortDescription() {
        #expect(AuthorLookup.writes(occupations: [], short: "japanischer Manga-Zeichner"))
        #expect(AuthorLookup.writes(occupations: [], short: "Turkish yazar"))
        #expect(!AuthorLookup.writes(occupations: [], short: "deutscher Rennfahrer"))
        #expect(
            AuthorLookup.writes(occupations: ["Q10349745"], short: "Regisseurin und Autorin"),
            "the short description suffices")
        #expect(!AuthorLookup.writes(occupations: ["Q10349745"], short: "deutscher Schauspieler"))
        #expect(AuthorLookup.writes(occupations: ["Q191633"], short: nil))
    }

    @Test("Storage: fetched once, not asked again for a week, even for a no")
    func persistence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "autoren-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let t = MockTransport()
        try frioglil(t)
        let a = lookup(t, folder: folder)
        _ = await a.profile("W. E. Frioglil")
        let requests = t.requests.count
        #expect(requests == 4, "summary and three statements")
        _ = await a.profile("Frioglil, W.E.")
        #expect(t.requests.count == requests, "same person, different spelling: served from storage")
        #expect(await a.present("w e frioglil")?.name == "Spuszo Y. Frioglil")

        let t2 = MockTransport()
        t2.answer("GET", "/api/rest_v1/page/summary/Niemand", with: .init(status: 404))
        let b = lookup(t2, folder: folder)
        #expect(await b.profile("Niemand") == nil)
        #expect(await b.profile("Niemand") == nil)
        #expect(t2.requests.count == 2, "de and en once each; the no is stored too")
    }

    @Test("Names: reversed, dots added, same key, short initials")
    func names() {
        #expect(AuthorName.display("Brandt, S. U.") == "S. U. Brandt")
        #expect(AuthorName.display("S.U. Brandt") == "S. U. Brandt")
        #expect(AuthorName.display("  Kōtarō   Mizuhara ") == "Kōtarō Mizuhara")
        #expect(AuthorName.lookupKey("Brandt, S.U.") == AuthorName.lookupKey("S. U. Brandt"))
        #expect(AuthorName.lookupKey("Kōtarō Mizuhara") == "kotaro mizuhara")
        #expect(AuthorName.initials("S. U. Brandt") == "SUB")
        #expect(AuthorName.initials("Gabriel Garrido Montes Bustamante") == "GB")
        #expect(AuthorName.initials("Platon") == "P")
    }

    @Test("Text without phonetic transcription, image without query")
    func cleaning() {
        #expect(
            AuthorLookup.cleaned("Margarete E. Brandt [ˈmarɡaˌreːtə ˈbʁant], ist …")
                == "Margarete E. Brandt, ist …")
        #expect(AuthorLookup.cleaned("  ") == nil)
        let small = URL(string: "https://upload.wikimedia.org/x/thumb/5/5d/F.jpg/330px-F.jpg?utm_source=de")!
        #expect(
            AuthorLookup.withoutQuery(small)?.absoluteString
                == "https://upload.wikimedia.org/x/thumb/5/5d/F.jpg/330px-F.jpg")
    }
}
