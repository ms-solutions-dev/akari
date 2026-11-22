import Foundation

/// The three kinds on the shelf — and the library's segment.
///
/// The order is the order in the segment: All · Manga · Books · Audiobooks · Podcasts. A kind
/// that no source delivers is missing from the segment; it is not empty.
///
/// A podcast is a series of episodes: each episode is a title of this kind, the podcast
/// itself the series. As far as the player is concerned, an episode is an audiobook with one
/// track — which is why the UI asks ``isAudible`` and not for the kind when it is about
/// listening.
public enum Kind: String, Sendable, Codable, CaseIterable, Hashable {
    case manga
    case book = "buch"
    case audiobook = "hoerbuch"
    case podcast

    /// Audiobook and podcast — what the player takes and the statistics count as listening time.
    public var isAudible: Bool { self == .audiobook || self == .podcast }
}

/// Which way pages are turned — manga from right to left.
///
/// Komga carries it on the series (`readingDirection`); the comic reader reads it
/// from the title because it only knows that. What the server does not say stays `nil`, and
/// the reader takes its default.
public enum ReadingDirection: String, Sendable, Codable, Hashable {
    case leftToRight = "linksNachRechts"
    case rightToLeft = "rechtsNachLinks"
    case vertical = "vertikal"
}

/// How much a title is — pages for print, duration for listening.
///
/// The UI shows "205 pages" or "9 h 12 min", and the reader computes the fraction
/// from it. What the server does not know stays ``unknown`` — the row is then
/// missing, instead of claiming "0 pages".
public enum Scope: Sendable, Codable, Hashable {
    case pages(Int)
    case duration(TimeInterval)
    case unknown

    enum CodingKeys: String, CodingKey, CaseIterable {
        case pages = "seiten"
        case duration = "dauer"
        case unknown = "unbekannt"
    }
    enum PagesCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum DurationCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
}

/// Community stars with their origin.
///
/// The value is normalised to five stars, whether the server delivers ten points or
/// percent; the origin stands beside it, because "4.2 ★" without "Goodreads" is a
/// number without meaning.
public struct Rating: Sendable, Codable, Hashable {
    /// 0 … 5.
    public let stars: Double
    public let voices: Int?
    /// "Goodreads", "Komga" — as the UI prints it.
    public let origin: String

    public init(stars: Double, voices: Int? = nil, origin: String) {
        self.stars = min(max(stars, 0), 5)
        self.voices = voices
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case stars = "sterne"
        case voices = "stimmen"
        case origin = "herkunft"
    }
}

/// A volume's membership of its series — identifier, name and number.
///
/// The number is a decimal because Komga knows volumes such as 4.5 (special volumes,
/// chapters between two volumes). Without a number the volume is in the series, but
/// nowhere in the sequence.
public struct SeriesReference: Sendable, Codable, Hashable {
    public let identifier: SeriesID
    public let name: String
    public let volume: Double?

    public init(identifier: SeriesID, name: String, volume: Double? = nil) {
        self.identifier = identifier
        self.name = name
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case name
        case volume = "band"
    }
}

/// A title as the UI sees it: a volume, a book or an audiobook.
///
/// **What is missing is `nil` — and the UI omits the row.** No summary means no
/// paragraph, no rating no star block, fewer than two genres no genre row. The title claims
/// nothing the server has not said.
///
/// `added` carries "New on the shelf" and the sort "recently added";
/// the reading state is **not** here but beside it in the ``LibraryExtract`` — it
/// changes with every page turn, the title does not.
public struct Title: Sendable, Codable, Hashable, Identifiable {
    public let identifier: TitleID
    public let kind: Kind
    public let name: String
    /// Audiobookshelf and Grimmory know a subtitle — under the name, never in it.
    public let subtitle: String?
    public let authors: [String]
    public let series: SeriesReference?
    public let cover: URL?
    public let genres: [String]
    public let summary: String?
    public let rating: Rating?
    public let scope: Scope
    /// BCP 47, as the server delivers it (`de`, `en-US`).
    public let language: String?
    /// Minimum age in years — only where the source declares ``Capabilities/ageRating``.
    public let ageRating: Int?
    public let publisher: String?
    /// Audiobooks only; otherwise empty.
    public let narrator: [String]
    public let readingDirection: ReadingDirection?
    public let added: Date?
    /// When the title was published — Komga `releaseDate`, Grimmory `publishedDate`,
    /// Audiobookshelf `publishedYear` (then January 1). The reading order of a
    /// series without volume numbers, and the year in the secondary line.
    public let released: Date?
    /// Audiobooks only: how many chapters — "10 h 36 min · 108 chapters".
    public let chapter: Int?
    /// The file on the server in bytes — what "Keep" will cost; `nil` where
    /// the server does not say.
    public let size: Int64?
    /// The file format as the UI prints it — "EPUB", "PDF", "CBZ", "MP3";
    /// `nil` where the source does not say (Audiobookshelf names the extension only in the
    /// detail).
    public let format: String?

    public var id: TitleID { identifier }

    public init(
        identifier: TitleID, kind: Kind, name: String, subtitle: String? = nil, authors: [String] = [],
        series: SeriesReference? = nil, cover: URL? = nil, genres: [String] = [],
        summary: String? = nil, rating: Rating? = nil, scope: Scope = .unknown,
        language: String? = nil, ageRating: Int? = nil, publisher: String? = nil,
        narrator: [String] = [], readingDirection: ReadingDirection? = nil, added: Date? = nil,
        released: Date? = nil, chapter: Int? = nil, size: Int64? = nil, format: String? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.authors = authors
        self.series = series
        self.cover = cover
        self.genres = genres
        self.summary = summary
        self.rating = rating
        self.scope = scope
        self.language = language
        self.ageRating = ageRating
        self.publisher = publisher
        self.narrator = narrator
        self.readingDirection = readingDirection
        self.added = added
        self.released = released
        self.chapter = chapter
        self.size = size
        self.format = format
    }

    /// The same title with a different cover — the data package of a kept title points to
    /// the file in the offline store.
    public func with(series: SeriesReference?) -> Title {
        Title(
            identifier: identifier, kind: kind, name: name, subtitle: subtitle, authors: authors,
            series: series,
            cover: cover, genres: genres, summary: summary, rating: rating,
            scope: scope,
            language: language, ageRating: ageRating, publisher: publisher, narrator: narrator,
            readingDirection: readingDirection, added: added, released: released, chapter: chapter,
            size: size, format: format)
    }

    public func with(cover: URL?) -> Title {
        Title(
            identifier: identifier, kind: kind, name: name, subtitle: subtitle, authors: authors,
            series: series,
            cover: cover, genres: genres, summary: summary, rating: rating,
            scope: scope,
            language: language, ageRating: ageRating, publisher: publisher, narrator: narrator,
            readingDirection: readingDirection, added: added, released: released, chapter: chapter,
            size: size, format: format)
    }

    /// A release date from what servers send: `2003-07-14`, `2009`
    /// or a full ISO time. Empty or unreadable means `nil`, never 1970 — and a
    /// year before the printing press (`0100`, seen with Grimmory) is a typo,
    /// not a date.
    public static func releaseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let share = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard let year = share.first, year >= 1450 else { return nil }
        let components = DateComponents(
            year: year, month: share.count > 1 ? share[1] : 1, day: share.count > 2 ? share[2] : 1)
        return calendar.date(from: components)
    }

    /// A blurb that is one: not empty, not just digits and punctuation,
    /// not shorter than twenty characters. Audiobookshelf took the ID3 comment
    /// "1905" as the description (7 of 9 audiobooks) — the row is then missing,
    /// instead of claiming a number.
    public static func blurb(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 20,
            t.contains(where: { $0.isLetter })
        else { return nil }
        return t
    }

    /// A language code per BCP 47, from what servers send: `de`, `deu`
    /// (ISO 639-2, Grimmory), `en-US`; `unknown` and empty become `nil`.
    public static func languageCode(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty, t != "unknown",
            t != "und"
        else { return nil }
        let share = t.split(separator: "-", maxSplits: 1).map(String.init)
        guard let code = share.first else { return nil }
        let short = code.count == 3 ? (Locale.LanguageCode(code).identifier(.alpha2) ?? code) : code
        return share.count > 1 ? short + "-" + share[1].uppercased() : short
    }

    /// The format from a file extension or a content type, as the UI
    /// prints it: `.epub` → "EPUB", `application/zip` → "CBZ" (Komga packs images in ZIPs),
    /// `application/x-rar-compressed; version=4` → "CBR", `audio/mpeg` → "MP3",
    /// `audio/mp4` → "M4B". Unknown ones are passed through in upper case if they
    /// look like an extension, otherwise `nil`.
    public static func format(_ text: String?) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if let strich = t.firstIndex(of: ";") {
            t = String(t[..<strich]).trimmingCharacters(in: .whitespaces)
        }
        if let slash = t.lastIndex(of: "/") {
            switch t {
            case "application/zip", "application/x-cbz", "application/vnd.comicbook+zip": return "CBZ"
            case "application/x-rar-compressed", "application/vnd.rar", "application/x-cbr",
                "application/vnd.comicbook-rar":
                return "CBR"
            case "application/epub+zip": return "EPUB"
            case "application/pdf": return "PDF"
            case "audio/mpeg", "audio/mp3": return "MP3"
            case "audio/mp4", "audio/x-m4b", "audio/m4b": return "M4B"
            case "audio/x-m4a", "audio/m4a": return "M4A"
            case "audio/flac", "audio/x-flac": return "FLAC"
            case "audio/ogg": return "OGG"
            default: t = String(t[t.index(after: slash)...])
            }
        }
        if t.hasPrefix(".") { t.removeFirst() }
        guard (2...5).contains(t.count), t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return t.uppercased()
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case kind = "art"
        case name
        case subtitle = "untertitel"
        case authors = "autoren"
        case series = "serie"
        case cover
        case genres
        case summary = "zusammenfassung"
        case rating = "bewertung"
        case scope = "umfang"
        case language = "sprache"
        case ageRating = "altersfreigabe"
        case publisher = "verlag"
        case narrator = "sprecher"
        case readingDirection = "leserichtung"
        case added = "hinzugefuegt"
        case released = "erschienen"
        case chapter = "kapitel"
        case size = "groesse"
        case format
    }
}

/// Whether a series is still growing — Komga `status` (komf: ongoing, ended, abandoned,
/// paused). Where the server says nothing, it stays `nil`.
public enum SeriesStatus: String, Sendable, Codable, Hashable {
    case ongoing = "laufend"
    case completed = "abgeschlossen"
    case cancelled = "abgebrochen"
    case paused = "pausiert"
}

/// A series: the frame around the volumes, with what the series detail shows above the
/// volumes.
///
/// Counters such as "46 read · volume 47" are not here — they are computed from the volumes
/// and their reading states, and computing is the library's business. What is here, the
/// server has said — also ``total``: how long the series really is,
/// not how much of it is on the shelf (a manga series: 9 of 18).
public struct Series: Sendable, Codable, Hashable, Identifiable {
    public let identifier: SeriesID
    public let kind: Kind
    public let name: String
    /// Who writes.
    public let authors: [String]
    /// Who draws — for manga often someone else (Druspind Gugeis, Fugalau); empty if
    /// the server knows no roles or they are the same people.
    public let illustrators: [String]
    public let cover: URL?
    public let genres: [String]
    public let summary: String?
    /// Community stars on the series — Komga from the komf `score`, Grimmory the
    /// average of the volumes.
    public let rating: Rating?
    /// How many volumes are on the shelf.
    public let volumeCount: Int
    /// How many volumes the series has, if the server knows — "Volume 9 of 18".
    public let total: Int?
    public let status: SeriesStatus?
    public let language: String?
    public let ageRating: Int?
    public let readingDirection: ReadingDirection?
    public let added: Date?

    public var id: SeriesID { identifier }

    public init(
        identifier: SeriesID, kind: Kind, name: String, authors: [String] = [], illustrators: [String] = [],
        cover: URL? = nil, genres: [String] = [], summary: String? = nil, rating: Rating? = nil,
        volumeCount: Int, total: Int? = nil, status: SeriesStatus? = nil, language: String? = nil,
        ageRating: Int? = nil, readingDirection: ReadingDirection? = nil, added: Date? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.name = name
        self.authors = authors
        self.illustrators = illustrators
        self.cover = cover
        self.genres = genres
        self.summary = summary
        self.rating = rating
        self.volumeCount = volumeCount
        self.total = total
        self.status = status
        self.language = language
        self.ageRating = ageRating
        self.readingDirection = readingDirection
        self.added = added
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case kind = "art"
        case name
        case authors = "autoren"
        case illustrators = "zeichner"
        case cover
        case genres
        case summary = "zusammenfassung"
        case rating = "bewertung"
        case volumeCount = "anzahlBaende"
        case total = "gesamt"
        case status
        case language = "sprache"
        case ageRating = "altersfreigabe"
        case readingDirection = "leserichtung"
        case added = "hinzugefuegt"
    }
}

/// What a source says about its shelf in one go.
///
/// **An extract, not a page:** 599 volumes and 930 books are a few hundred kilobytes as a
/// model, and the library wants to compute over everything — kinds, counters, genres,
/// "Continue reading" across three servers. Paging would turn each of these questions into
/// a network question.
///
/// The ``readingStates`` are the ones the server delivers with the extract anyway
/// (Komga `readProgress` on the volume, Grimmory `readProgress`, ABS `mediaProgress`) —
/// enough for "Continue reading" and the counters. Before opening a reader,
/// ``Source/progress(_:)`` fetches the state fresh once more.
public struct LibraryExtract: Sendable, Codable, Hashable {
    public let source: SourceID
    public let seriesList: [Series]
    public let title: [Title]
    public let readingStates: [TitleID: ReadingState]
    /// The source's collections — the library attaches them after ``Source/collections()``.
    public let collections: [TitleCollection]
    /// The authors as the server keeps them as entries of their own (Grimmory: with image
    /// and description) — empty where authors are only names on books.
    public let authors: [AuthorReference]
    /// When the server was asked — offline the UI shows the age.
    public let state: Date
    /// Not a catalog of the server, but kept titles that are in no catalog — added from
    /// their data package, so that downloads are always visible.
    /// Never written as persisted data.
    public let isSupplement: Bool

    public init(
        source: SourceID, seriesList: [Series] = [], title: [Title],
        readingStates: [TitleID: ReadingState] = [:], collections: [TitleCollection] = [],
        authors: [AuthorReference] = [],
        state: Date, isSupplement: Bool = false
    ) {
        self.isSupplement = isSupplement
        self.source = source
        self.seriesList = seriesList
        self.title = title
        self.readingStates = readingStates
        self.collections = collections
        self.authors = authors
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case source = "quelle", seriesList = "serien", title = "titel", readingStates = "lesestaende",
            collections = "sammlungen", authors = "autoren", state = "stand", isSupplement = "ergaenzung"
    }

    /// Persisted data from before collections or authors does not have the
    /// key — it stays readable, instead of the start screen being empty on opening.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceID.self, forKey: .source)
        seriesList = try c.decode([Series].self, forKey: .seriesList)
        title = try c.decode([Title].self, forKey: .title)
        readingStates = try c.decode([TitleID: ReadingState].self, forKey: .readingStates)
        collections = try c.decodeIfPresent([TitleCollection].self, forKey: .collections) ?? []
        authors = try c.decodeIfPresent([AuthorReference].self, forKey: .authors) ?? []
        state = try c.decode(Date.self, forKey: .state)
        isSupplement = try c.decodeIfPresent(Bool.self, forKey: .isSupplement) ?? false
    }

    public func with(collections: [TitleCollection]) -> LibraryExtract {
        LibraryExtract(
            source: source, seriesList: seriesList, title: title, readingStates: readingStates,
            collections: collections,
            authors: authors, state: state, isSupplement: isSupplement)
    }
}

/// An author as an entry of their own in a source — Grimmory keeps 547 of them, with images
/// from the Audible sync. The name is the key to the titles
/// (``AuthorName``), the identifier the key to the detail (``Source/author(_:)``).
public struct AuthorReference: Sendable, Codable, Hashable, Identifiable {
    public let source: SourceID
    public let identifier: String
    public let name: String
    /// The image from the server — `nil` if it has none.
    public let image: URL?
    public let count: Int

    public var id: String { source.description + "/" + identifier }

    public init(source: SourceID, identifier: String, name: String, image: URL? = nil, count: Int = 0) {
        self.source = source
        self.identifier = identifier
        self.name = name
        self.image = image
        self.count = count
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source = "quelle"
        case identifier = "kennung"
        case name
        case image = "bild"
        case count = "anzahl"
    }
}

/// What a source says about an author when asked — today the
/// description; no server knows dates of birth, those come from Wikipedia.
public struct SourceAuthor: Sendable, Hashable {
    public let descriptionText: String?

    public init(descriptionText: String?) {
        self.descriptionText = descriptionText
    }
}
