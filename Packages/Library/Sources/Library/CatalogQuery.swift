import Foundation
import SourcesKit

/// A question to the ``CatalogIndex``: which kind, which criteria, which order.
///
/// The criteria follow the filter sheet (library stage 2): within a field OR
/// ("German or English"), between fields AND ("unread and crime"). What the
/// device knows itself (saved, downloaded, the titles of a shelf) comes in as an
/// identifier set.
public struct CatalogQuery: Sendable, Hashable {

    public var kind: Kind?
    public var phase: ReadStatus?
    public var genres: Set<String> = []
    public var authors: Set<String> = []
    /// Series identifiers (`SeriesID.description`).
    public var seriesList: Set<String> = []
    public var languages: Set<String> = []
    public var formats: Set<String> = []
    public var publishers: Set<String> = []
    public var years: ClosedRange<Int>?
    /// Only these titles — saved, downloaded, a shelf; several sets intersect.
    public var onlyIdentifiers: [Set<String>] = []
    /// The limit of a child profile.
    public var maxAge: Int?
    /// Only titles without genre — the genre page "without genre".
    public var withoutGenre = false
    /// Titles that are in themselves or whose series is in — saved, a shelf, series
    /// with gaps. Several intersect.
    public var selection: [Selection] = []

    public struct Selection: Sendable, Hashable {
        public var title: Set<String>
        public var seriesList: Set<String>

        public init(title: Set<String> = [], seriesList: Set<String> = []) {
            self.title = title
            self.seriesList = seriesList
        }
    }
    public var sorting: Sorting

    public init(kind: Kind? = nil, sorting: Sorting = .title) {
        self.kind = kind
        self.sorting = sorting
    }

    /// The same query without the field's own criterion — for the counts in the filter sheet.
    func without(_ field: Facet) -> CatalogQuery {
        var new = self
        switch field {
        case .genre: new.genres = []
        case .author: new.authors = []
        case .series: new.seriesList = []
        case .language: new.languages = []
        case .format: new.formats = []
        case .publisher: new.publishers = []
        }
        return new
    }

    /// The WHERE condition with values; `t` is the title table, `s` the reading state.
    func condition() -> (String, [Database.Value]) {
        var share: [String] = ["1 = 1"]
        var values: [Database.Value] = []
        // Pass the column without "t.": as text with a dot, the check of the
        // language keys would take it for one.
        func list(titleColumn: String, _ choices: Set<String>) {
            guard !choices.isEmpty else { return }
            let column = "t." + titleColumn
            share.append(
                "\(column) IN (\(Array(repeating: "?", count: choices.count).joined(separator: ", ")))")
            values += choices.sorted().map { .text($0) }
        }
        if let kind {
            share.append("t.art = ?")
            values.append(.text(kind.rawValue))
        }
        switch phase {
        case .unread?: share.append("(s.kennung IS NULL OR (s.abgeschlossen = 0 AND s.anteil <= 0))")
        case .started?: share.append("(s.abgeschlossen = 0 AND s.anteil > 0)")
        case .read?: share.append("s.abgeschlossen = 1")
        case nil: break
        }
        if !genres.isEmpty {
            share.append(
                "t.kennung IN (SELECT kennung FROM titel_genre WHERE genre IN (\(Array(repeating: "?", count: genres.count).joined(separator: ", "))))"
            )
            values += genres.sorted().map { .text($0) }
        }
        if !authors.isEmpty {
            share.append(
                "t.kennung IN (SELECT kennung FROM titel_autor WHERE autor IN (\(Array(repeating: "?", count: authors.count).joined(separator: ", "))))"
            )
            values += authors.sorted().map { .text($0) }
        }
        list(titleColumn: "serie", seriesList)
        list(titleColumn: "sprache", languages)
        list(titleColumn: "format", formats)
        list(titleColumn: "verlag", publishers)
        if let years {
            share.append("t.jahr BETWEEN ? AND ?")
            values += [.integer(years.lowerBound), .integer(years.upperBound)]
        }
        for choices in onlyIdentifiers {
            list(titleColumn: "kennung", choices.isEmpty ? [""] : choices)
        }
        if withoutGenre { share.append("t.kennung NOT IN (SELECT kennung FROM titel_genre)") }
        for a in selection {
            var oder: [String] = []
            if !a.title.isEmpty {
                oder.append(
                    "t.kennung IN (\(Array(repeating: "?", count: a.title.count).joined(separator: ", ")))")
                values += a.title.sorted().map { .text($0) }
            }
            if !a.seriesList.isEmpty {
                oder.append(
                    "t.serie IN (\(Array(repeating: "?", count: a.seriesList.count).joined(separator: ", ")))"
                )
                values += a.seriesList.sorted().map { .text($0) }
            }
            share.append(oder.isEmpty ? "0 = 1" : "(" + oder.joined(separator: " OR ") + ")")
        }
        if let maxAge {
            share.append("(t.altersfreigabe IS NULL OR t.altersfreigabe <= ?)")
            values.append(.integer(maxAge))
        }
        return (share.joined(separator: " AND "), values)
    }
}

extension Sorting {
    /// The order over the groups (series or single title) of ``CatalogIndex/entries(_:bundled:from:atMost:)``.
    var groupOrderBy: String {
        switch self {
        case .title: "sortname, gruppe"
        case .author: "autorsort IS NULL, autorsort, sortname, gruppe"
        case .recentlyAdded: "neu IS NULL, neu DESC, sortname, gruppe"
        case .recentlyRead: "gelesen IS NULL, gelesen DESC, neu DESC, sortname, gruppe"
        case .bookSeries: "seriesort IS NULL, seriesort, sortname, gruppe"
        case .rating: "bewertung IS NULL, bewertung DESC, sortname, gruppe"
        }
    }

    /// The ORDER BY clause; ties always by sort name and identifier, so that a
    /// page never overlaps the next.
    var orderBy: String {
        switch self {
        case .title: "t.sortname, t.kennung"
        case .author: "t.autorsort IS NULL, t.autorsort, t.sortname, t.kennung"
        case .recentlyAdded: "t.hinzugefuegt IS NULL, t.hinzugefuegt DESC, t.sortname, t.kennung"
        case .recentlyRead:
            "s.zeitstempel IS NULL, s.zeitstempel DESC, t.hinzugefuegt DESC, t.sortname, t.kennung"
        case .bookSeries: "t.seriesort IS NULL, t.seriesort, t.band, t.sortname, t.kennung"
        case .rating: "t.bewertung IS NULL, t.bewertung DESC, t.sortname, t.kennung"
        }
    }
}
