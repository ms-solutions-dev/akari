import Foundation
import SourcesKit

/// The catalog of all sources as a small database on the device (library stage 2).
///
/// **Why**: Grimmory has 35,551 books. Fetching the catalog all at once,
/// storing it as JSON and decoding on launch no longer scaled — 35 MB, 50 s, through the
/// tunnel not at all. Here each title keeps only what library, filter and search need,
/// together with the full ``SourcesKit/Title`` as JSON. Sorting, filtering, counting and searching are
/// queries, in milliseconds, with 100 as with 100,000 books; the grid fetches only the
/// page it shows.
public final class CatalogIndex: Sendable {

    /// The schema version — a new one rebuilds the index (it is only a mirror).
    static let edition = 3

    let db: Database

    /// - Parameter file: the profile's file; `nil` keeps the index in memory.
    public init(file: URL?) throws {
        db = try Database(file: file)
        try setUp()
    }

    private func setUp() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS meta (schluessel TEXT PRIMARY KEY, wert TEXT)")
        let old =
            try db.query("SELECT wert FROM meta WHERE schluessel = 'fassung'") { $0.text(0) }.first ?? nil
        if old != String(CatalogIndex.edition) {
            try db.execute(
                """
                DROP TABLE IF EXISTS titel; DROP TABLE IF EXISTS titel_genre; DROP TABLE IF EXISTS titel_autor;
                DROP TABLE IF EXISTS stand; DROP TABLE IF EXISTS suche; DROP TABLE IF EXISTS serie;
                """)
        }
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS titel (
                kennung TEXT PRIMARY KEY,
                quelle TEXT NOT NULL,
                art TEXT NOT NULL,
                name TEXT NOT NULL,
                sortname TEXT NOT NULL,
                autor TEXT,
                autorsort TEXT,
                serie TEXT,
                seriesort TEXT,
                band REAL,
                sprache TEXT,
                verlag TEXT,
                format TEXT,
                jahr INTEGER,
                hinzugefuegt REAL,
                bewertung REAL,
                altersfreigabe INTEGER,
                daten BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS titel_art_name ON titel (art, sortname);
            CREATE INDEX IF NOT EXISTS titel_art_neu ON titel (art, hinzugefuegt);
            CREATE INDEX IF NOT EXISTS titel_art_autor ON titel (art, autorsort, sortname);
            CREATE INDEX IF NOT EXISTS titel_serie ON titel (serie, band);
            CREATE INDEX IF NOT EXISTS titel_quelle ON titel (quelle);
            CREATE TABLE IF NOT EXISTS titel_genre (kennung TEXT NOT NULL, genre TEXT NOT NULL, PRIMARY KEY (kennung, genre));
            CREATE INDEX IF NOT EXISTS titel_genre_genre ON titel_genre (genre);
            CREATE TABLE IF NOT EXISTS titel_autor (kennung TEXT NOT NULL, autor TEXT NOT NULL, PRIMARY KEY (kennung, autor));
            CREATE INDEX IF NOT EXISTS titel_autor_autor ON titel_autor (autor);
            CREATE TABLE IF NOT EXISTS stand (
                kennung TEXT PRIMARY KEY, anteil REAL NOT NULL, abgeschlossen INTEGER NOT NULL, zeitstempel REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS serie (
                kennung TEXT PRIMARY KEY, quelle TEXT NOT NULL, art TEXT NOT NULL, name TEXT NOT NULL, daten BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS serie_quelle ON serie (quelle);
            CREATE VIRTUAL TABLE IF NOT EXISTS suche USING fts5(
                kennung UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        try db.write(
            "INSERT OR REPLACE INTO meta (schluessel, wert) VALUES ('fassung', ?)",
            [.text(String(CatalogIndex.edition))])
    }

    // MARK: - Writing

    /// Replaces everything of a source with its extract — for sources that deliver their catalog whole
    /// (Komga, Audiobookshelf, OPDS, WebDAV, device). One transaction.
    public func replace(_ extract: LibraryExtract) throws {
        let source = extract.source.description
        try db.transaction { s in
            try deleteSource(source, s)
            for series in extract.seriesList { try create(series, s) }
            for t in extract.title { try create(t, s) }
            for (identifier, state) in extract.readingStates { try create(state, for: identifier, s) }
        }
    }

    /// Creates or replaces titles — the sync of large sources in packets.
    public func create(_ title: [Title], readingStates: [TitleID: ReadingState] = [:]) throws {
        try db.transaction { s in
            for t in title { try create(t, s) }
            for (identifier, state) in readingStates { try create(state, for: identifier, s) }
        }
    }

    /// A reading state — `nil` forgets it.
    public func set(_ state: ReadingState?, for identifier: TitleID) throws {
        try db.transaction { s in
            if let state {
                try create(state, for: identifier, s)
            } else {
                try s.write("DELETE FROM stand WHERE kennung = ?", [.text(identifier.description)])
            }
        }
    }

    /// Removes titles — deleted on the server.
    public func remove(_ identifiers: [TitleID]) throws {
        try db.transaction { s in
            for k in identifiers {
                let w: [Database.Value] = [.text(k.description)]
                try s.write(
                    "DELETE FROM suche WHERE rowid = (SELECT rowid FROM titel WHERE kennung = ?)", w)
                for table in ["titel", "titel_genre", "titel_autor", "stand"] {
                    try s.write("DELETE FROM \(table) WHERE kennung = ?", w)
                }
            }
        }
    }

    /// Removes a source entirely — account signed out.
    public func remove(source: SourceID) throws {
        try db.transaction { s in try deleteSource(source.description, s) }
    }

    private func deleteSource(_ source: String, _ s: Database.Writer) throws {
        let w: [Database.Value] = [.text(source)]
        let selection = "(SELECT kennung FROM titel WHERE quelle = ?)"
        // The search row hangs on the row number of the title: deleting by `kennung` would mean
        // walking the search table per title (35,000 titles: a minute).
        try s.write("DELETE FROM suche WHERE rowid IN (SELECT rowid FROM titel WHERE quelle = ?)", w)
        for table in ["titel_genre", "titel_autor", "stand"] {
            try s.write("DELETE FROM \(table) WHERE kennung IN \(selection)", w)
        }
        try s.write("DELETE FROM titel WHERE quelle = ?", w)
        try s.write("DELETE FROM serie WHERE quelle = ?", w)
    }

    /// Creates series — the sync of large sources brings them in packets.
    public func create(seriesList: [Series]) throws {
        try db.transaction { s in for series in seriesList { try create(series, s) } }
    }

    private func create(_ series: Series, _ s: Database.Writer) throws {
        try s.write(
            "INSERT OR REPLACE INTO serie (kennung, quelle, art, name, daten) VALUES (?, ?, ?, ?, ?)",
            [
                .text(series.identifier.description), .text(series.identifier.source.description),
                .text(series.kind.rawValue),
                .text(series.name), .data(try CatalogIndex.encoder.encode(series)),
            ])
    }

    private static let encoder: JSONEncoder = {
        let k = JSONEncoder()
        k.dateEncodingStrategy = .secondsSince1970
        return k
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private func create(_ t: Title, _ s: Database.Writer) throws {
        let identifier = t.identifier.description
        // Authors in their display form ("Brandt, M. L." → "M. L. Brandt"), as the shelf
        // counts them — otherwise the same author would stand twice in the filter.
        let authors = t.authors.map(AuthorName.display).filter { !$0.isEmpty }
        let author = authors.first
        let values: [Database.Value] = [
            .text(identifier), .text(t.identifier.source.description), .text(t.kind.rawValue), .text(t.name),
            .text(SortKey.from(t.name)), .text(author), .text(author.map(SortKey.author)),
            .text(t.series?.identifier.description), .text(t.series.map { SortKey.from($0.name) }),
            .decimalNumber(t.series?.volume), .text(t.language), .text(t.publisher), .text(t.format),
            .integer(t.released.map { Calendar(identifier: .gregorian).component(.year, from: $0) }),
            .decimalNumber(t.added?.timeIntervalSince1970), .decimalNumber(t.rating?.stars),
            .integer(t.ageRating), .data(try CatalogIndex.encoder.encode(t)),
        ]
        try s.write(
            "DELETE FROM suche WHERE rowid = (SELECT rowid FROM titel WHERE kennung = ?)", [.text(identifier)]
        )
        try s.write(
            """
            INSERT OR REPLACE INTO titel (kennung, quelle, art, name, sortname, autor, autorsort, serie, seriesort,
                band, sprache, verlag, format, jahr, hinzugefuegt, bewertung, altersfreigabe, daten)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values)
        let k: Database.Value = .text(identifier)
        try s.write("DELETE FROM titel_genre WHERE kennung = ?", [k])
        for genre in Shelf.Genre.lookupKey(for: t.genres) {
            guard case .name(let name) = genre else { continue }
            try s.write(
                "INSERT OR IGNORE INTO titel_genre (kennung, genre) VALUES (?, ?)", [k, .text(name)])
        }
        try s.write("DELETE FROM titel_autor WHERE kennung = ?", [k])
        for a in Set(authors) {
            try s.write("INSERT OR IGNORE INTO titel_autor (kennung, autor) VALUES (?, ?)", [k, .text(a)])
        }
        let text =
            ([t.name, t.subtitle, t.series?.name] + t.authors.map(Optional.some)
            + t.genres.map(Optional.some))
            .compactMap { $0 }.joined(separator: " ")
        try s.write(
            "INSERT INTO suche (rowid, kennung, text) VALUES ((SELECT rowid FROM titel WHERE kennung = ?), ?, ?)",
            [k, k, .text(text)])
    }

    private func create(_ state: ReadingState, for identifier: TitleID, _ s: Database.Writer) throws {
        try s.write(
            "INSERT OR REPLACE INTO stand (kennung, anteil, abgeschlossen, zeitstempel) VALUES (?, ?, ?, ?)",
            [
                .text(identifier.description), .decimalNumber(state.fraction),
                .integer(state.completed ? 1 : 0),
                .decimalNumber(state.timestamp.timeIntervalSince1970),
            ])
    }

    // MARK: - Reading

    /// How many titles the query hits.
    public func count(_ query: CatalogQuery) throws -> Int {
        let (condition, values) = query.condition()
        return try db.query(
            "SELECT COUNT(*) FROM titel t LEFT JOIN stand s ON s.kennung = t.kennung WHERE \(condition)",
            values
        ) { $0.integer(0) }.first ?? 0
    }

    /// One page of titles in the sorting of the query.
    public func title(_ query: CatalogQuery, from: Int = 0, atMost: Int = 120) throws -> [Title] {
        let (condition, values) = query.condition()
        return try db.query(
            """
            SELECT t.daten FROM titel t LEFT JOIN stand s ON s.kennung = t.kennung
            WHERE \(condition) ORDER BY \(query.sorting.orderBy) LIMIT ? OFFSET ?
            """, values + [.integer(atMost), .integer(from)]
        ) { line in try line.data(0).map { try CatalogIndex.decoder.decode(Title.self, from: $0) } }
        .compactMap { $0 }
    }

    /// One page of entries for the grid: titles, and with `bundled` series as one entry —
    /// manga and podcasts always, books and audiobooks if their kind is in `bundled` and
    /// the series has at least two volumes (like ``Shelf/entries(_:)``). A series stands in the
    /// grid if one of its volumes meets the criteria; sorted by its youngest,
    /// most recently read or best-rated volume.
    public func entries(
        _ query: CatalogQuery, bundled: Set<Kind>, from: Int = 0, atMost: Int = 120
    ) throws -> [Shelf.Item] {
        let (sql, values) = grouped(query, bundled: bundled)
        let rows = try db.query(
            "SELECT gruppe, erster, buendel FROM (\(sql)) ORDER BY \(query.sorting.groupOrderBy) LIMIT ? OFFSET ?",
            values + [.integer(atMost), .integer(from)]
        ) { ($0.text(0) ?? "", $0.text(1) ?? "", $0.integer(2) == 1) }
        let titleIdentifiers = rows.filter { !$0.2 }.map(\.1)
        let seriesIdentifiers = rows.filter(\.2).map(\.0)
        let title = try data("titel", titleIdentifiers, Title.self)
        let seriesList = try data("serie", seriesIdentifiers, Series.self)
        return rows.compactMap { cluster, first, bundle in
            if bundle, let series = seriesList[cluster] { return .series(series) }
            return title[first].map { .title($0) }
        }
    }

    /// How many entries ``entries(_:bundled:from:atMost:)`` delivers in total.
    public func entryCount(_ query: CatalogQuery, bundled: Set<Kind>) throws -> Int {
        let (sql, values) = grouped(query, bundled: bundled)
        return try db.query("SELECT COUNT(*) FROM (\(sql))", values) { $0.integer(0) }.first ?? 0
    }

    /// Per group (series or single title) a row with the values for sorting. `bundle`
    /// says whether the group stands as a series.
    private func grouped(_ query: CatalogQuery, bundled: Set<Kind>) -> (String, [Database.Value]) {
        let (condition, values) = query.condition()
        let kinds = (bundled.union([.manga, .podcast])).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        // Books and audiobooks only from two volumes in the whole stock — manga and podcasts always.
        let bundled = """
            CASE WHEN t.serie IS NOT NULL AND t.art IN (\(kinds)) AND EXISTS (SELECT 1 FROM serie WHERE serie.kennung = t.serie)
                AND (t.art IN ('manga', 'podcast') OR (SELECT COUNT(*) FROM titel b WHERE b.serie = t.serie) >= 2)
            THEN 1 ELSE 0 END
            """
        let sql = """
            SELECT CASE WHEN \(bundled) = 1 THEN t.serie ELSE t.kennung END AS gruppe,
                MIN(t.kennung) AS erster, MAX(\(bundled)) AS buendel,
                MIN(CASE WHEN \(bundled) = 1 THEN t.seriesort ELSE t.sortname END) AS sortname,
                MAX(t.hinzugefuegt) AS neu, MAX(s.zeitstempel) AS gelesen, MIN(t.autorsort) AS autorsort,
                MAX(t.bewertung) AS bewertung, MIN(t.seriesort) AS seriesort
            FROM titel t LEFT JOIN stand s ON s.kennung = t.kennung
            WHERE \(condition)
            GROUP BY gruppe
            """
        return (sql, values)
    }

    private func data<T: Decodable>(
        _ table: String, _ identifiers: [String], _ type: T.Type
    ) throws -> [String: T] {
        guard !identifiers.isEmpty else { return [:] }
        var result: [String: T] = [:]
        // In chunks: SQLite takes at most a few hundred placeholders per statement well.
        for chunk in stride(from: 0, to: identifiers.count, by: 200).map({
            Array(identifiers[$0..<min($0 + 200, identifiers.count)])
        }) {
            let slot = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for (k, d) in try db.query(
                "SELECT kennung, daten FROM \(table) WHERE kennung IN (\(slot))", chunk.map { .text($0) },
                { ($0.text(0) ?? "", $0.data(1)) })
            {
                if let d, let value = try? CatalogIndex.decoder.decode(T.self, from: d) {
                    result[k] = value
                }
            }
        }
        return result
    }

    /// A title by identifier.
    public func title(_ identifier: TitleID) throws -> Title? {
        try db.query("SELECT daten FROM titel WHERE kennung = ?", [.text(identifier.description)]) { line in
            try line.data(0).map { try CatalogIndex.decoder.decode(Title.self, from: $0) }
        }.first ?? nil
    }

    /// Many titles with few queries — one per ``bulkSize`` identifiers (a 609 ms
    /// hang): the library's collections asked for every title individually, on the
    /// main thread, and held it.
    public func title(_ identifiers: [TitleID]) throws -> [TitleID: Title] {
        var found: [TitleID: Title] = [:]
        var remainder = identifiers[...]
        while !remainder.isEmpty {
            let chunk = remainder.prefix(CatalogIndex.bulkSize)
            remainder = remainder.dropFirst(chunk.count)
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let list = try db.query(
                "SELECT daten FROM titel WHERE kennung IN (\(placeholders))",
                chunk.map { .text($0.description) }
            ) { line in
                try line.data(0).map { try CatalogIndex.decoder.decode(Title.self, from: $0) }
            }
            for case let t? in list { found[t.identifier] = t }
        }
        return found
    }

    /// Only the kind of many titles, without reading them — for counters and filters that need no title
    /// (the collection row otherwise read every collection whole, 605 ms).
    /// The key is the description of the identifier.
    public func kinds(_ identifiers: [TitleID]) throws -> [String: Kind] {
        var found: [String: Kind] = [:]
        var remainder = identifiers[...]
        while !remainder.isEmpty {
            let chunk = remainder.prefix(CatalogIndex.bulkSize)
            remainder = remainder.dropFirst(chunk.count)
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let list = try db.query(
                "SELECT kennung, art FROM titel WHERE kennung IN (\(placeholders))",
                chunk.map { .text($0.description) }
            ) { line in (line.text(0), line.text(1).flatMap(Kind.init(rawValue:))) }
            for case (let k?, let a?) in list { found[k] = a }
        }
        return found
    }

    /// This many identifiers per query — below SQLite's limit for placeholders.
    static let bulkSize = 500

    /// A series by identifier.
    public func series(_ identifier: SeriesID) throws -> Series? {
        try db.query("SELECT daten FROM serie WHERE kennung = ?", [.text(identifier.description)]) { line in
            try line.data(0).map { try CatalogIndex.decoder.decode(Series.self, from: $0) }
        }.first ?? nil
    }

    /// The volumes of a series in reading order.
    public func volumes(_ series: SeriesID) throws -> [Title] {
        var a = CatalogQuery(sorting: .bookSeries)
        a.seriesList = [series.description]
        return try title(a, atMost: 5_000)
    }

    /// The reading state of a title as the catalog knows it (share, finished, when).
    public func state(
        _ identifier: TitleID
    ) throws -> (fraction: Double, completed: Bool, timestamp: Date)? {
        try db.query(
            "SELECT anteil, abgeschlossen, zeitstempel FROM stand WHERE kennung = ?",
            [.text(identifier.description)]
        ) {
            (
                $0.decimalNumber(0) ?? 0, $0.integer(1) == 1,
                Date(timeIntervalSince1970: $0.decimalNumber(2) ?? 0)
            )
        }.first
    }

    /// The identifiers of a source — for the comparison against the server's list.
    public func identifiers(source: SourceID) throws -> Set<String> {
        Set(
            try db.query("SELECT kennung FROM titel WHERE quelle = ?", [.text(source.description)]) {
                $0.text(0)
            }
            .compactMap { $0 })
    }

    /// The reading states — the core needs all (a few hundred).
    public func readingStates() throws -> [String: (fraction: Double, completed: Bool, timestamp: Date)] {
        var result: [String: (fraction: Double, completed: Bool, timestamp: Date)] = [:]
        for (k, a, from, z) in try db.query(
            "SELECT kennung, anteil, abgeschlossen, zeitstempel FROM stand", [],
            {
                ($0.text(0) ?? "", $0.decimalNumber(1) ?? 0, $0.integer(2) == 1, $0.decimalNumber(3) ?? 0)
            })
        {
            result[k] = (a, from, Date(timeIntervalSince1970: z))
        }
        return result
    }

    /// A value with its count — a row in the filter sheet.
    public struct FacetValue: Sendable, Hashable {
        public let value: String
        public let count: Int
    }

    /// The values of a field with their counts, counted under the **other** criteria of the
    /// query (the field's own stays out) — so beside "Krimi" stands what would remain with all
    /// other filters. Most frequent first.
    public func facet(
        _ field: Facet, _ query: CatalogQuery, atMost: Int = 200
    ) throws -> [FacetValue] {
        let (condition, values) = query.without(field).condition()
        let sql: String
        switch field {
        case .genre:
            sql = """
                SELECT g.genre, COUNT(*) FROM titel t JOIN titel_genre g ON g.kennung = t.kennung
                LEFT JOIN stand s ON s.kennung = t.kennung WHERE \(condition)
                GROUP BY g.genre ORDER BY 2 DESC, 1 LIMIT ?
                """
        case .author:
            sql = """
                SELECT a.autor, COUNT(*) FROM titel t JOIN titel_autor a ON a.kennung = t.kennung
                LEFT JOIN stand s ON s.kennung = t.kennung WHERE \(condition)
                GROUP BY a.autor ORDER BY 2 DESC, 1 LIMIT ?
                """
        case .language, .format, .publisher, .series:
            let column = field.column
            sql = """
                SELECT t.\(column), COUNT(*) FROM titel t LEFT JOIN stand s ON s.kennung = t.kennung
                WHERE \(condition) AND t.\(column) IS NOT NULL AND t.\(column) != ''
                GROUP BY t.\(column) ORDER BY 2 DESC, 1 LIMIT ?
                """
        }
        return try db.query(sql, values + [.integer(atMost)]) {
            FacetValue(value: $0.text(0) ?? "", count: $0.integer(1))
        }
    }

    /// The genres of a kind (or all) by frequency, with the count per kind and three youngest
    /// covers for the foremost — the genre row of the library. Fewer than two genres empty, like
    /// ``Shelf/genres(_:)``.
    public func genreOverview(kind: Kind?, maxAge: Int?, withCovers: Int = 12) throws -> [Shelf.Genre] {
        var base = CatalogQuery(kind: kind)
        base.maxAge = maxAge
        let all = try facet(.genre, base, atMost: 500)
        guard all.count >= 2 else { return [] }
        var perKind: [String: [Kind: Int]] = [:]
        if let kind {
            for w in all { perKind[w.value] = [kind: w.count] }
        } else {
            for a in Kind.allCases {
                var q = base
                q.kind = a
                for w in try facet(.genre, q, atMost: 500) { perKind[w.value, default: [:]][a] = w.count }
            }
        }
        var result: [Shelf.Genre] = []
        for (i, w) in all.enumerated() {
            var cover: [Shelf.CoverReference] = []
            if i < withCovers {
                var q = base
                q.genres = [w.value]
                q.sorting = .recentlyAdded
                cover = try title(q, atMost: 3).map {
                    Shelf.CoverReference(address: $0.cover, source: $0.identifier.source, kind: $0.kind)
                }
            }
            result.append(
                Shelf.Genre(
                    lookupKey: .name(w.value), count: w.count, countPerKind: perKind[w.value] ?? [:],
                    cover: cover))
        }
        var without = base
        without.withoutGenre = true
        let withoutCount = try count(without)
        if withoutCount > 0 {
            result.append(Shelf.Genre(lookupKey: .without, count: withoutCount, countPerKind: [:], cover: []))
        }
        return result
    }

    /// The authors of a kind (or all) with their count per kind — the authors view.
    public func authorOverview(
        kind: Kind?, maxAge: Int?
    ) throws -> [(name: String, count: [Kind: Int])] {
        var result: [String: [Kind: Int]] = [:]
        for a in kind.map({ [$0] }) ?? Kind.allCases {
            var q = CatalogQuery(kind: a)
            q.maxAge = maxAge
            for w in try facet(.author, q, atMost: 100_000) {
                result[w.value, default: [:]][a] = w.count
            }
        }
        return result.map { ($0.key, $0.value) }
    }

    /// The names of series — for chips and the filter sheet.
    public func seriesNames(_ identifiers: [String]) throws -> [String: String] {
        guard !identifiers.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for chunk in stride(from: 0, to: identifiers.count, by: 200).map({
            Array(identifiers[$0..<min($0 + 200, identifiers.count)])
        }) {
            let slot = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for (k, n) in try db.query(
                "SELECT kennung, name FROM serie WHERE kennung IN (\(slot))", chunk.map { .text($0) },
                { ($0.text(0) ?? "", $0.text(1) ?? "") })
            {
                result[k] = n
            }
        }
        return result
    }

    /// The earliest and latest publication year under the other criteria.
    public func years(_ query: CatalogQuery) throws -> ClosedRange<Int>? {
        var a = query
        a.years = nil
        let (condition, values) = a.condition()
        let paar = try db.query(
            "SELECT MIN(t.jahr), MAX(t.jahr) FROM titel t LEFT JOIN stand s ON s.kennung = t.kennung WHERE \(condition) AND t.jahr IS NOT NULL",
            values
        ) { ($0.decimalNumber(0), $0.decimalNumber(1)) }.first
        guard let from = paar?.0, let until = paar?.1 else { return nil }
        return Int(from)...Int(until)
    }

    /// Full-text search over title, subtitle, series, authors and genres — word starts, without
    /// accents and capitalization.
    public func search(_ text: String, kind: Kind? = nil, atMost: Int = 200) throws -> [Title] {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !words.isEmpty else { return [] }
        var values: [Database.Value] = [.text(words.joined(separator: " "))]
        var kindCondition = ""
        if let kind {
            kindCondition = "AND t.art = ?"
            values.append(.text(kind.rawValue))
        }
        return try db.query(
            """
            SELECT t.daten FROM suche JOIN titel t ON t.kennung = suche.kennung
            WHERE suche MATCH ? \(kindCondition) ORDER BY rank LIMIT ?
            """, values + [.integer(atMost)]
        ) { line in try line.data(0).map { try CatalogIndex.decoder.decode(Title.self, from: $0) } }
        .compactMap { $0 }
    }
}

/// A field the filter sheet counts by.
public enum Facet: String, Sendable, Hashable, CaseIterable {
    case genre, author = "autor", series = "serie", language = "sprache", format, publisher = "verlag"

    var column: String {
        switch self {
        case .genre: "genre"
        case .author: "autor"
        case .series: "serie"
        case .language: "sprache"
        case .format: "format"
        case .publisher: "verlag"
        }
    }
}

/// Sort keys that SQLite can compare bytewise and that still order like
/// `localizedStandardCompare`: lowercase, without accents, numbers with leading zeros ("Volume 2" before
/// "Volume 10").
enum SortKey {

    static func from(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var digits = ""
        func clearOut() {
            if !digits.isEmpty {
                result += String(repeating: "0", count: max(0, 8 - digits.count)) + digits
                digits = ""
            }
        }
        for character in folded {
            if character.isNumber, character.isASCII {
                digits.append(character)
            } else {
                clearOut()
                result.append(character)
            }
        }
        clearOut()
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Authors by last name: "Frida Schöllang" → "schollang frida" — as ``Shelf`` orders them.
    static func author(_ name: String) -> String {
        from(Shelf.byLastName(name))
    }
}
