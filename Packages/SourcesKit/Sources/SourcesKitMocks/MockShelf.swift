import Foundation
import SourcesKit

/// Three sources as they stand on a home server — shaped after real responses. The
/// titles are public domain or freely licensed (Project Gutenberg, LibriVox, Pepper&Carrot
/// under CC BY 4.0, Little Nemo by Winsor McCay); their covers are the files in
/// `Features/SampleCovers`, served by the preview transport under `/covers/<slug>.jpg`.
///
/// - ``komga(server:)``: manga in series, page stream, age rating, no
///   saved list (Komga knows no per-user favorites).
/// - ``grimmoryReadOnly(server:)``: books with Goodreads stars and saved list — but
///   **without `keep`**: `robin` may not fetch files.
/// - ``audiobookshelf(server:)``: audiobooks **without `seriesList`** — tier 1 binds ABS
///   only as a library.
///
/// The times are fixed so that "Continue reading" has a testable order:
/// the book last (15 Sep 18:00), three hours before it the volume, before that the audiobook.
public enum MockShelf {

    /// The extract time of all three — 16 Sep 2026, 18:00 UTC.
    public static let state = Date(timeIntervalSince1970: 1_789_581_600)

    static func date(_ days: Int, _ hours: Int = 0) -> Date {
        state.addingTimeInterval(TimeInterval(-days * 86_400 + hours * 3_600))
    }

    /// The address of a bundled sample cover — the preview transport answers `/covers/<slug>.jpg`.
    static func cover(_ source: SourceID, _ slug: String) -> URL {
        URL(string: "https://\(source.server)/covers/\(slug).jpg")!
    }

    public static func komga(server: String = "comics.example") -> MockSource {
        let source = SourceID(provider: .komga, server: server)
        let bookSeries = SeriesID(source: source, id: "0K7Q3XJ1")
        let series = Series(
            identifier: bookSeries, kind: .manga, name: "Pepper&Carrot", authors: ["David Revoy"],
            cover: cover(source, "pepper-carrot-36"),
            genres: ["Fantasy", "Humor"], volumeCount: 3, language: "en", ageRating: 12,
            added: date(40))
        func volume(_ n: Int, id: String, pages: Int, days: Int) -> Title {
            Title(
                identifier: TitleID(source: source, id: id), kind: .manga, name: "Pepper&Carrot \(n)",
                authors: ["David Revoy"],
                series: SeriesReference(identifier: bookSeries, name: "Pepper&Carrot", volume: Double(n)),
                cover: cover(source, "pepper-carrot-\(n)"),
                genres: ["Fantasy", "Humor"], scope: .pages(pages), language: "en",
                ageRating: 12, added: date(days), size: Int64(pages) * 400_000, format: "CBZ"
            )
        }
        let volumes = [
            volume(36, id: "0K7Q3XJ1-46", pages: 198, days: 40),
            volume(37, id: "0K7Q3XJ1-47", pages: 205, days: 40),
            volume(38, id: "0K7Q3XJ1-48", pages: 201, days: 2),
        ]
        let readingStates: [TitleID: ReadingState] = [
            volumes[0].identifier: ReadingState(
                position: .page(198, from: 198), timestamp: date(9), completed: true),
            volumes[1].identifier: ReadingState(position: .page(63, from: 205), timestamp: date(1, -3)),
        ]
        // `AKARI_VIELE=1`: adds a series of 120 volumes (Little Nemo in Slumberland) — for everything that only becomes
        // visible with long lists (the scroll handle, the section headers).
        var seriesList = [series]
        var title = volumes
        if ProcessInfo.processInfo.environment["AKARI_VIELE"] == "1" {
            let longSeries = SeriesID(source: source, id: "LANG")
            seriesList.append(
                Series(
                    identifier: longSeries, kind: .manga, name: "Little Nemo", authors: ["Winsor McCay"],
                    cover: cover(source, "little-nemo"),
                    genres: ["Fantasy"], volumeCount: 120, language: "en", added: date(300)))
            for n in 1...120 {
                title.append(
                    Title(
                        identifier: TitleID(source: source, id: "LANG-\(n)"), kind: .manga,
                        name: "Little Nemo \(n)", authors: ["Winsor McCay"],
                        series: SeriesReference(
                            identifier: longSeries, name: "Little Nemo", volume: Double(n)),
                        cover: cover(source, "little-nemo"),
                        genres: ["Fantasy"], scope: .pages(190), language: "en",
                        added: date(300 - n),
                        size: 76_000_000, format: "CBZ"))
            }
        }
        return MockSource(
            identifier: source, capabilities: [.pageStream, .keep, .seriesList, .ageRating],
            extract: LibraryExtract(
                source: source, seriesList: seriesList, title: title, readingStates: readingStates,
                state: state))
    }

    public static func grimmoryReadOnly(server: String = "buecher.example") -> MockSource {
        let source = SourceID(provider: .grimmory, server: server)
        let bookSeries = SeriesID(source: source, id: "12")
        var series = Series(
            identifier: bookSeries, kind: .book, name: "Sherlock Holmes", authors: ["Arthur Conan Doyle"],
            cover: cover(source, "holmes-adventures"),
            genres: ["Mystery", "Detective Fiction"],
            volumeCount: 2, language: "en", added: date(20))
        /// A title of the Gutenberg shelf; the series bit is only set for the Holmes volumes.
        func book(
            _ name: String, id: String, author: String, volume: Double?, pages: Int, days: Int,
            stars: Double, year: Int, genres: [String], summary: String, cover slug: String
        )
            -> Title
        {
            Title(
                identifier: TitleID(source: source, id: id), kind: .book, name: name,
                authors: [author],
                series: volume.map {
                    SeriesReference(identifier: bookSeries, name: "Sherlock Holmes", volume: $0)
                },
                cover: cover(source, slug),
                genres: genres, summary: summary,
                rating: Rating(stars: stars, voices: 41_200, origin: "Goodreads"),
                scope: .pages(pages), language: "en", publisher: "Project Gutenberg", added: date(days),
                released: Title.releaseDate(String(year)),
                size: Int64(pages) * 2_000, format: "EPUB")
        }
        func holmes(
            _ name: String, id: String, volume: Double, pages: Int, days: Int, stars: Double, year: Int,
            cover slug: String
        ) -> Title {
            book(
                name, id: id, author: "Arthur Conan Doyle", volume: volume, pages: pages, days: days,
                stars: stars, year: year, genres: ["Mystery", "Detective Fiction"],
                summary: "Cases of the consulting detective in Victorian London.", cover: slug)
        }
        var books = [
            holmes(
                "The Adventures of Sherlock Holmes", id: "1041", volume: 1, pages: 540, days: 20,
                stars: 4.2, year: 1892, cover: "holmes-adventures"),
            holmes(
                "The Memoirs of Sherlock Holmes", id: "1042", volume: 2, pages: 610, days: 20, stars: 3.9,
                year: 1894, cover: "holmes-memoirs"),
            book(
                "Frankenstein", id: "1077", author: "Mary Shelley", volume: nil, pages: 380, days: 5,
                stars: 4.4, year: 1818, genres: ["Gothic Fiction", "Horror"],
                summary: "A young scientist creates life and cannot control what he has made.",
                cover: "frankenstein"),
        ]
        // `AKARI_PROBE=reihenluecken`: Sherlock Holmes gets volume 5 and length 6 — so that
        // the series header shows "Volumes 3–4 and 6 missing (3)" and the tile "3 missing".
        if ProcessInfo.processInfo.environment["AKARI_PROBE"] == "reihenluecken" {
            books.append(
                holmes(
                    "The Case-Book of Sherlock Holmes", id: "1045", volume: 5, pages: 590, days: 3,
                    stars: 4.0, year: 1927, cover: "holmes-case-book"))
            series = Series(
                identifier: bookSeries, kind: .book, name: "Sherlock Holmes",
                authors: ["Arthur Conan Doyle"], cover: cover(source, "holmes-adventures"),
                genres: ["Mystery", "Detective Fiction"],
                volumeCount: 3, total: 6, language: "en", added: date(20))
        }
        var readingStates: [TitleID: ReadingState] = [
            books[0].identifier: ReadingState(
                position: .position(cfi: "epubcfi(/6/2!/4/2)", fraction: 0.001), timestamp: date(30)),
            books[1].identifier: ReadingState(
                // Points into the built EPUB (``MockBook``): chapter 2, fifth paragraph —
                // so the preview really jumps to a spot.
                position: .position(cfi: "epubcfi(/6/4!/4/2[kap2]/12[k2a5])", fraction: 0.4),
                timestamp: date(1, 0),
                device: "justread (iPad)"),
        ]
        let probe = ProcessInfo.processInfo.environment["AKARI_PROBE"] ?? ""
        if probe.hasPrefix("statistik") || probe == "liegengeblieben" {
            /// More books, started long ago — only for `AKARI_PROBE=statistik…|
            /// liegengeblieben`: with four started ones the start screen shows all, and
            /// "Left lying" would have nothing to name. Only for the probes, so that
            /// the shelf tests stay with their numbers.
            func addBook(
                _ name: String, id: String, author: String, genre: String, pages: Int, fraction: Double,
                days: Int, cover slug: String
            ) {
                let title = Title(
                    identifier: TitleID(source: source, id: id), kind: .book, name: name, authors: [author],
                    cover: cover(source, slug),
                    genres: [genre], scope: .pages(pages), language: "en", publisher: "Project Gutenberg",
                    added: date(days + 30), size: Int64(pages) * 2_000, format: "EPUB")
                books.append(title)
                readingStates[title.identifier] = ReadingState(
                    position: .position(cfi: "epubcfi(/6/2!/4/2)", fraction: fraction), timestamp: date(days))
            }
            addBook(
                "Twenty Thousand Leagues Under the Seas", id: "1101", author: "Jules Verne",
                genre: "Adventure Fiction", pages: 420, fraction: 0.55, days: 35,
                cover: "twenty-thousand-leagues")
            addBook(
                "Alice's Adventures in Wonderland", id: "1102", author: "Lewis Carroll", genre: "Fantasy",
                pages: 200, fraction: 0.7, days: 60, cover: "alice")
            addBook(
                "Pride and Prejudice", id: "1103", author: "Jane Austen", genre: "Regency Romance",
                pages: 430, fraction: 0.3, days: 45, cover: "pride-and-prejudice")
        }
        let mock = MockSource(
            identifier: source,
            capabilities: [.seriesList, .rating, .savedList, .collections, .editCollections],
            extract: LibraryExtract(
                source: source, seriesList: [series], title: books, readingStates: readingStates,
                state: state))
        // A shelf "Summer Reading" with Frankenstein — so the library has a
        // collection row to show.
        mock.collectionList = [
            TitleCollection(
                identifier: CollectionID(source: source, id: "2"), name: "Summer Reading",
                collectionKind: .shelf,
                entries: [.title(books[2].identifier)], isPrivate: true, editable: true, symbol: "sun")
        ]
        return mock
    }

    public static func audiobookshelf(server: String = "hoerbuch.example") -> MockSource {
        let source = SourceID(provider: .audiobookshelf, server: server)
        func audiobook(
            _ name: String, id: String, author: String, seconds: TimeInterval, days: Int,
            cover slug: String
        ) -> Title {
            Title(
                identifier: TitleID(source: source, id: id), kind: .audiobook, name: name,
                authors: [author], cover: cover(source, slug),
                genres: ["Classic Literature"], scope: .duration(seconds),
                language: "en",
                narrator: ["LibriVox volunteers"], added: date(days), size: Int64(seconds) * 16_000,
                format: "MP3")
        }
        let title = [
            audiobook(
                "The Time Machine", id: "li_a1", author: "H. G. Wells", seconds: 38_000, days: 60,
                cover: "time-machine-square"),
            audiobook(
                "Treasure Island", id: "li_a2", author: "Robert Louis Stevenson", seconds: 41_500,
                days: 60, cover: "treasure-island-square"),
            audiobook(
                "The Jungle Book", id: "li_a3", author: "Rudyard Kipling", seconds: 36_200, days: 3,
                cover: "jungle-book-square"),
        ]
        let readingStates: [TitleID: ReadingState] = [
            title[0].identifier: ReadingState(position: .second(176, from: 38_000), timestamp: date(4))
        ]
        return MockSource(
            identifier: source, capabilities: [.keep],
            extract: LibraryExtract(source: source, title: title, readingStates: readingStates, state: state))
    }

    /// A second Audiobookshelf with a podcast: four episodes, identifier `item:episode`
    /// as on the real server, volume = order of release, the latest three days old,
    /// episode 2 started. A source of its own and not part of ``audiobookshelf(server:)``, so that
    /// the shelf tests of the three core sources (counter, continue-reading order, New on the
    /// shelf) keep their numbers; ``all()`` includes it, ``base()`` does not.
    public static func podcasts(server: String = "podcasts.example") -> MockSource {
        let source = SourceID(provider: .audiobookshelf, server: server)
        let podcast = SeriesID(source: source, id: "li_p1")
        func episode(_ name: String, number: Int, minutes: Double, days: Int) -> Title {
            Title(
                identifier: TitleID(source: source, id: "li_p1:ep_\(number)"), kind: .podcast, name: name,
                authors: ["Moonlit Tales"],
                series: SeriesReference(
                    identifier: podcast, name: "Moonlit Tales Podcast", volume: Double(number)),
                genres: ["Talks"], summary: "A talk from the series — \(name).",
                scope: .duration(minutes * 60), language: "en", added: date(days),
                released: date(days),
                size: Int64(minutes * 60) * 16_000, format: "MP3")
        }
        let title = [
            episode("A Day by the Sea", number: 1, minutes: 83, days: 40),
            episode("After the Rain", number: 2, minutes: 90, days: 26),
            episode("An Old Letter", number: 3, minutes: 100, days: 12),
            episode("The Night Train", number: 4, minutes: 87, days: 3),
        ]
        let seriesList = [
            Series(
                identifier: podcast, kind: .podcast, name: "Moonlit Tales Podcast",
                authors: ["Moonlit Tales"],
                genres: ["Talks"], volumeCount: 4, language: "en", added: date(40))
        ]
        let readingStates: [TitleID: ReadingState] = [
            title[1].identifier: ReadingState(position: .second(1_900, from: 5_400), timestamp: date(2))
        ]
        return MockSource(
            identifier: source, capabilities: [.keep],
            extract: LibraryExtract(
                source: source, seriesList: seriesList, title: title, readingStates: readingStates,
                state: state))
    }

    /// The three core sources, as they would be signed in — the tests compute with them.
    public static func base() -> [MockSource] {
        [komga(), grimmoryReadOnly(), audiobookshelf()]
    }

    /// All four: the three core sources and the podcast server — what the simulator
    /// shows with `-attrappen`.
    public static func all() -> [MockSource] {
        base() + [podcasts()]
    }
}
