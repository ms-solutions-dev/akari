import Foundation

/// An OPDS feed as far as the kit reads it: title, entries, links — the one model for both
/// editions. ``OpdsParser`` fills it from Atom (OPDS 1.2), ``OpdsJsonReader`` from JSON (OPDS
/// 2.0); the catalog crawl does not know the difference.
///
/// An entry is either **navigation** (leads to another feed, `rel` `subsection` or a link of
/// type `application/atom+xml` / `application/opds+json`) or **acquisition** (has a link with
/// `rel` `http://opds-spec.org/acquisition…` — the file — or a Divina manifest). A feed full of
/// acquisition entries is a series, a shelf, a search.
public struct OpdsFeed: Sendable, Hashable {
    public var id: String = ""
    public var title: String = ""
    public var links: [Link] = []
    public var entries: [Item] = []

    public struct Link: Sendable, Hashable {
        public var rel: String?
        public var href: String
        public var type: String?
        public var title: String?
        /// OPDS-PSE: how many pages the stream has (`pse:count`).
        public var pages: Int?
        /// OPDS-PSE: the last page read (`pse:lastRead`) — Kavita only.
        public var recently: Int?
        /// OPDS 2.0: `templated: true` — the address is a URI template (`{?query}`), not a finished
        /// address.
        public var template: Bool = false
    }

    public struct Item: Sendable, Hashable {
        public var id: String = ""
        public var title: String = ""
        public var authors: [String] = []
        public var summary: String?
        public var content: String?
        public var refreshed: Date?
        public var released: Date?
        public var language: String?
        public var publisher: String?
        public var categories: [String] = []
        public var links: [Link] = []
        /// The series if the entry names it itself — Grimmory/BookLore writes
        /// `<meta property="belongs-to-collection">Venpaimul Jibiozir</meta>` and
        /// `<meta property="group-position">1.0</meta>` like an EPUB OPF; Komga names it only via the
        /// feed.
        public var bookSeries: String?
        public var volume: Double?
        /// Size from Komga's `<content>cbr - 457.1 MiB</content>` if nothing else names it.
        public var size: Int64?
        /// OPDS 2.0: `numberOfPages` from the metadata — the page count that hangs on the PSE link
        /// in the Atom path (`pse:count`).
        public var pages: Int?
        /// OPDS 2.0: the title of the group the entry was in ("Series", "Latest Books") — for the
        /// crawl what the parent feed is in the Atom path.
        public var cluster: String?

        public var navigation: Link? {
            links.first { l in
                l.rel == "subsection" || l.rel == "http://opds-spec.org/subsection"
                    || ((l.type?.hasPrefix("application/atom+xml") == true
                        || l.type?.hasPrefix("application/opds+json") == true) && l.rel != "self"
                        && l.rel != "alternate" && l.rel != "related" && !(l.rel?.contains("facet") ?? false))
            }
        }

        /// The file link — the first acquisition; the kit does not distinguish `open-access`, `buy`,
        /// `sample`, it takes what it may fetch.
        public var acquisition: Link? {
            links.first { $0.rel?.hasPrefix("http://opds-spec.org/acquisition") == true }
        }

        public var pageStream: Link? {
            links.first { $0.rel == "http://vaemendis.net/opds-pse/stream" }
        }

        /// The Divina manifest (Readium Web Publication, `application/divina+json`) — for Komga v2 the
        /// `self` link of a comic, for a PDF a second link without `rel`. The type counts, not the `rel`.
        public var manifest: Link? {
            links.first { $0.type?.hasPrefix("application/divina+json") == true }
        }

        /// The progression API (`http://www.cantook.com/api/progression`) — the reading state on the
        /// server where the catalog offers it (Komga v2).
        public var progress: Link? {
            links.first { $0.rel == "http://www.cantook.com/api/progression" }
        }

        public var image: Link? {
            links.first { $0.rel == "http://opds-spec.org/image" }
                ?? links.first { $0.rel == "http://opds-spec.org/image/thumbnail" }
                ?? links.first {
                    $0.rel == "http://opds-spec.org/cover" || $0.rel == "http://opds-spec.org/thumbnail"
                }
        }
    }

    public var next: Link? { links.first { $0.rel == "next" } }
    public var search: Link? { links.first { $0.rel == "search" } }

    /// A feed is a navigation feed if its entries lead on instead of naming files.
    public var isNavigation: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.acquisition == nil && $0.navigation != nil }
    }
}

/// Reads an Atom feed with `XMLParser` — namespaces do not matter (only the local name counts),
/// text between the tags is collected, HTML in `content` stays text.
public final class OpdsParser: NSObject, XMLParserDelegate {

    private var feed = OpdsFeed()
    private var entry: OpdsFeed.Item?
    private var text = ""
    private var path: [String] = []
    private var authorName: String?
    private var metaProperty: String?
    private var template: String?

    public static func parse(_ data: Data) throws -> OpdsFeed {
        let parser = XMLParser(data: data)
        let reader = OpdsParser()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "OpdsKit", code: 1)
        }
        return reader.feed
    }

    /// An OpenSearch description (`<Url template="…{searchTerms}…">`) — Komga and Grimmory point to
    /// such a document with `rel="search"`, not to the template.
    public static func searchTemplate(_ data: Data) -> String? {
        let parser = XMLParser(data: data)
        let reader = OpdsParser()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.parse()
        return reader.template
    }

    public func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        path.append(element)
        text = ""
        switch element {
        case "entry":
            entry = OpdsFeed.Item()
        case "link":
            guard let href = attributes["href"] else { return }
            let link = OpdsFeed.Link(
                rel: attributes["rel"], href: href, type: attributes["type"], title: attributes["title"],
                pages: attributes["pse:count"].flatMap(Int.init) ?? attributes["count"].flatMap(Int.init),
                recently: attributes["pse:lastRead"].flatMap(Int.init)
                    ?? attributes["lastRead"].flatMap(Int.init))
            if entry != nil { entry?.links.append(link) } else { feed.links.append(link) }
        case "category":
            if let term = attributes["label"] ?? attributes["term"], entry != nil {
                entry?.categories.append(term)
            }
        case "author":
            authorName = nil
        case "meta":
            metaProperty = attributes["property"]
        case "Url":
            // OpenSearch: the Atom template, not the HTML search.
            if let t = attributes["template"], t.contains("{searchTerms}"),
                template == nil || attributes["type"]?.contains("atom") == true
            {
                template = t
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        defer { path.removeLast(); text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inEntry = entry != nil
        let inAuthor = path.dropLast().last == "author"
        switch element {
        case "entry":
            if let e = entry { feed.entries.append(e) }
            entry = nil
        case "id":
            if inEntry { entry?.id = value } else if path.count == 2 { feed.id = value }
        case "title":
            if inEntry {
                if entry?.title.isEmpty == true { entry?.title = value }
            } else if path.count == 2 {
                feed.title = value
            }
        case "name":
            if inAuthor { authorName = value }
        case "author":
            // Komga names the same author once more per role (writer, penciller, …).
            if inEntry, let n = authorName, !n.isEmpty, entry?.authors.contains(n) == false {
                entry?.authors.append(n)
            }
        case "summary":
            if inEntry, !value.isEmpty { entry?.summary = value }
        case "content":
            if inEntry, !value.isEmpty {
                entry?.content = value
                entry?.size = OpdsParser.size(value)
            }
        case "meta":
            if inEntry {
                switch metaProperty {
                case "belongs-to-collection": if !value.isEmpty { entry?.bookSeries = value }
                case "group-position": entry?.volume = Double(value)
                default: break
                }
            }
            metaProperty = nil
        case "updated":
            if inEntry { entry?.refreshed = OpdsParser.date(value) }
        case "published", "date", "issued":
            if inEntry, entry?.released == nil { entry?.released = OpdsParser.date(value) }
        case "language":
            if inEntry { entry?.language = value }
        case "publisher":
            if inEntry { entry?.publisher = value }
        default:
            break
        }
    }

    /// "cbr - 457.1 MiB" → bytes; `nil` if the text names no size.
    nonisolated static func size(_ text: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*(KiB|MiB|GiB|KB|MB|GB)"#),
            let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let z = Range(m.range(at: 1), in: text), let e = Range(m.range(at: 2), in: text),
            let integer = Double(text[z].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let factor: Double =
            switch text[e].uppercased() {
            case "KIB", "KB": 1024
            case "MIB", "MB": 1024 * 1024
            default: 1024 * 1024 * 1024
            }
        return Int64(integer * factor)
    }

    /// ISO-8601 with or without fractions, or just a year.
    nonisolated static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let share = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard let year = share.first, year > 1000 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(
                year: year, month: share.count > 1 ? share[1] : 1, day: share.count > 2 ? share[2] : 1))
    }
}
