import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import GrimmoryKit

/// The genre mapping against a recording of the full list
/// (865 books, 507 distinct categories) — the figures are documented in ``GrimmoryGenres``.
@Suite("GrimmoryGenres")
struct GrimmoryGenresTests {

    private func books() throws -> [GrimmoryResponses.Book] {
        let answer = try MockTransport.recording("books-voll.json", from: .module)
        return try ServerFetch.decoder.decode([GrimmoryResponses.WebBook].self, from: answer.data).map(
            \.asBook)
    }

    @Test("Single categories: subgenres land in the target, noise drops, unknown stays raw")
    func single() {
        #expect(GrimmoryGenres.hit("Military Fantasy") == .genres([GrimmoryGenres.fantasy]))
        #expect(
            GrimmoryGenres.hit("Dragons & Mythical Creatures Fantasy")
                == .genres([GrimmoryGenres.fantasy]))
        #expect(GrimmoryGenres.hit("Mystery Thriller") == .genres([GrimmoryGenres.crime]))
        #expect(
            GrimmoryGenres.hit("Ghost Thrillers")
                == .genres([GrimmoryGenres.crime, GrimmoryGenres.horror]),
            "keywords add up")
        #expect(
            GrimmoryGenres.hit("Humorous Science Fiction")
                == .genres([GrimmoryGenres.scienceFiction, GrimmoryGenres.humor]))
        #expect(
            GrimmoryGenres.hit("Comic Fantasy")
                == .genres([GrimmoryGenres.fantasy, GrimmoryGenres.humor]),
            "the table takes precedence over the keyword \"comics\"")
        #expect(
            GrimmoryGenres.hit("Alternate History") == .genres([GrimmoryGenres.scienceFiction]),
            "not nonfiction")
        #expect(
            GrimmoryGenres.hit("Urban Fantasy (Kindle Store)") == .genres([GrimmoryGenres.fantasy]),
            "store suffix drops")
        #expect(
            GrimmoryGenres.hit("Science Fiction History & Criticism")
                == .genres([GrimmoryGenres.scienceFiction]))
        #expect(
            GrimmoryGenres.hit("Fantasy Romance for Young Adults")
                == .genres([GrimmoryGenres.youngAdult, GrimmoryGenres.fantasy, GrimmoryGenres.romance]))
        #expect(GrimmoryGenres.hit("Audiobook") == .noise)
        #expect(GrimmoryGenres.hit("Book Club") == .noise)
        #expect(GrimmoryGenres.hit("Klufluve 3926") == .noise, "publisher number")
        #expect(GrimmoryGenres.hit("Vou JIOSSKOHAI (Band 3)") == .noise, "volume count")
        #expect(GrimmoryGenres.hit("Fleidro 26 509") == .noise, "ISBN fragment")
        #expect(GrimmoryGenres.hit("20th Century") == .noise)
        #expect(GrimmoryGenres.hit("Fiction") == .general)
        #expect(GrimmoryGenres.hit("German Literature") == .general)
        #expect(GrimmoryGenres.hit("Bergsteigen") == .raw("Bergsteigen"), "unknown stays")
        #expect(GrimmoryGenres.hit("  Roman  ") == .general, "edges drop")
    }

    @Test("One book: order of first appearance, no duplicates, \"Roman\" only without another genre")
    func book() {
        #expect(
            GrimmoryGenres.map([
                "Fiction", "Fantasy", "Audiobook", "Military Fantasy", "Thriller", "Adult",
            ])
                == [GrimmoryGenres.fantasy, GrimmoryGenres.crime])
        #expect(
            GrimmoryGenres.map(["Fiction", "Novels", "German Literature"]) == [GrimmoryGenres.novel])
        #expect(
            GrimmoryGenres.map(["Audiobook", "Ebooks"]) == [], "noise only — no genre, no novel")
        #expect(GrimmoryGenres.map([]) == [])
        #expect(
            GrimmoryGenres.map(["Fantasy", "Bergsteigen", "Bergsteigen"]) == [
                GrimmoryGenres.fantasy, "Bergsteigen",
            ], "raw stays, at the end, once")
    }

    @Test("Discarded targets: Sachbuch, Biografie, Comic, Liebesroman never appear; romantasy stays Fantasy")
    func weakTargets() {
        #expect(
            GrimmoryGenres.map(["Communication & Relations", "Mystery Thriller", "Fiction"]) == [
                GrimmoryGenres.crime
            ], "Fliaflaglin Glitar is not nonfiction")
        // "Spifliga" carries the headings of a Spaihatdrout Draizugrair book — no genre instead of nonfiction.
        #expect(GrimmoryGenres.map(["Computers", "Popular Science", "Nonfiction", "Mathematics"]) == [])
        #expect(GrimmoryGenres.map(["Nonfiction", "Biography", "Memoir"]) == [])
        // Spocas: Paranormal Romance is fantasy with a love story, not a romance novel.
        #expect(
            GrimmoryGenres.map(["Romance", "Paranormal Vampire Romance", "Romantic Fantasy"]) == [
                GrimmoryGenres.fantasy
            ])
        // Miakus prequel with "Manga" — noise, the kind comes from the file type.
        #expect(
            GrimmoryGenres.map(["Comics & Graphic Novels by Genre", "Manga", "Science Fiction"]) == [
                GrimmoryGenres.scienceFiction
            ])
        #expect(GrimmoryGenres.map(["Childrens", "Horror"]) == [GrimmoryGenres.horror])
        #expect(
            GrimmoryGenres.map(["Russian & Soviet Poetry", "Poetry (English)", "Epics"]) == [
                GrimmoryGenres.fantasy
            ])
    }

    @Test(
        "Over the recording: 507 raw categories become 11 genres, nothing stays raw, nothing is lost"
    )
    func recording() throws {
        let books = try books()
        #expect(books.count == 865)
        var raw = Set<String>()
        var after: [String: Int] = [:]
        var withCategoriesNoGenre = 0
        for b in books {
            let categories = b.categories ?? []
            raw.formUnion(categories)
            let genres = GrimmoryGenres.map(categories)
            if !categories.isEmpty && genres.isEmpty { withCategoriesNoGenre += 1 }
            for g in genres { after[g, default: 0] += 1 }
        }
        // 508 before the cleanup; "Fleidro 26 509" has been gone since.
        #expect(raw.count == 507)
        #expect(after.count == 11, "\(after.keys.sorted())")
        #expect(after.keys.allSatisfy { GrimmoryGenres.targets.contains($0) }, "no raw category left")
        #expect(after[GrimmoryGenres.fantasy] == 538)
        #expect(after[GrimmoryGenres.crime] == 237)
        #expect(after[GrimmoryGenres.horror] == 140)
        #expect(after[GrimmoryGenres.scienceFiction] == 135)
        #expect(after[GrimmoryGenres.novel] == 28)
        // Never: Sachbuch, Biografie, Kinderbuch, Lyrik, Comic, Liebesroman.
        for z in GrimmoryGenres.discarded { #expect(after[z] == nil, "\(z)") }
        #expect(after[GrimmoryGenres.poetry] == nil, "Amazon attaches poetry to Stader epics")
        // 52 books carry only noise (publisher numbers, "ebook german", Kindle-store football, and
        // nonfiction/comic/children's headings on novels); "Rausiahaurn" has no category at all
        // after the cleanup.
        #expect(withCategoriesNoGenre == 52)
        #expect(!raw.contains(GrimmoryGenres.crime), "the target \"Krimi & Thriller\" does not occur raw")
    }

    @Test("The series merges the mapped genres of its volumes, not the raw ones")
    func series() throws {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let title = try books()
            .filter { $0.seriesName == "Plinpro" }
            .map {
                GrimmoryMapping.title($0, source: source, baseURL: URL(string: "https://buecher.example")!)
            }
        #expect(title.count == 3)
        let series = try #require(GrimmoryMapping.seriesList(from: title).first)
        #expect(!series.genres.isEmpty)
        #expect(series.genres.allSatisfy { GrimmoryGenres.targets.contains($0) }, "\(series.genres)")
        #expect(!series.genres.contains("Audiobook") && !series.genres.contains("Fiction"))
        for t in title { for g in t.genres { #expect(series.genres.contains(g)) } }
    }
}
