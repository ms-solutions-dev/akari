import Foundation
import SourcesKit

/// Reads an OPDS 2.0 feed (JSON on the Readium Web Publication Manifest) into the same
/// ``OpdsFeed`` as the Atom parser.
///
/// **By hand instead of `Codable`:** The manifest allows almost every field in two shapes —
/// `rel` as text or list, `title` as text or language table, `author` as text, object or list
/// of them, `belongsTo.series` likewise. A `Decodable` would need its own wrapper type for each;
/// a dictionary with three helper functions reads them all the same way.
///
/// **How the editions come together:** `navigation` links become navigation entries (`rel`
/// `subsection` if none is given — they are under `navigation` after all), `publications`
/// become acquisition entries, groups contribute both and name themselves in the entry
/// (``OpdsFeed/Item/cluster``); the `self` link of a group becomes a navigation entry because it
/// leads to the full list. `images` become image links, the Divina manifest and the progression
/// API stay links with their `rel`/`type`. The kit does not read `facets` — the Atom path leaves
/// them out too.
public enum OpdsJsonReader {

    /// Whether a response is OPDS 2.0: the content type says so (`application/opds+json`),
    /// otherwise the body — it starts with `{`. The address does not say: `/opds/v2/` is Komga's
    /// choice, not a standard.
    public static func isJson(_ data: Data, contentType: String?) -> Bool {
        if let type = contentType?.lowercased(), type.contains("json") { return true }
        guard let firstByte = data.first(where: { !Self.blankBytes.contains($0) }) else { return false }
        return firstByte == UInt8(ascii: "{")
    }

    private static let blankBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]

    public static func parse(_ data: Data) throws -> OpdsFeed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "OpdsKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
        }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        var feed = OpdsFeed()
        feed.title = text(metadata["title"]) ?? ""
        feed.links = links(root["links"])
        feed.id = feed.links.first { $0.rel == "self" }?.href ?? ""
        feed.entries += navigation(root["navigation"], cluster: nil)
        feed.entries += publications(root["publications"], cluster: nil)
        for cluster in root["groups"] as? [[String: Any]] ?? [] {
            let name = text((cluster["metadata"] as? [String: Any])?["title"])
            let groupLinks = links(cluster["links"])
            if let selfLink = groupLinks.first(where: { $0.rel == "self" }), selfLink.href != feed.id,
                let name, !name.isEmpty
            {
                var entry = OpdsFeed.Item()
                entry.id = selfLink.href
                entry.title = name
                entry.cluster = name
                entry.links = [
                    OpdsFeed.Link(
                        rel: "subsection", href: selfLink.href, type: selfLink.type ?? "application/opds+json"
                    )
                ]
                feed.entries.append(entry)
            }
            feed.entries += navigation(cluster["navigation"], cluster: name)
            feed.entries += publications(cluster["publications"], cluster: name)
        }
        return feed
    }

    // MARK: - Manifest

    /// A page from the `readingOrder` of a Divina manifest.
    public struct Page: Sendable, Hashable {
        public var href: String
        public var type: String?
        public var width: Int?
        public var height: Int?
    }

    /// The Divina manifest (Readium Web Publication, Divina profile): the pages in reading order
    /// with type and dimensions. Images without dimensions later count as portrait.
    public static func manifest(_ data: Data) throws -> [Page] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let bookSeries = root["readingOrder"] as? [[String: Any]]
        else {
            throw NSError(
                domain: "OpdsKit", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no readingOrder in the manifest"])
        }
        return bookSeries.compactMap { s in
            guard let href = s["href"] as? String else { return nil }
            return Page(
                href: href, type: s["type"] as? String, width: integer(s["width"]),
                height: integer(s["height"]))
        }
    }

    // MARK: - Search

    /// A URI template (RFC 6570, as OPDS 2.0 names it for `rel: search`) brought into the
    /// OpenSearch form with `{searchTerms}` that ``OpdsAccount/search`` carries:
    /// `search{?query}` → `search?query={searchTerms}`, `{&q}` → `&q={searchTerms}`, a bare
    /// `{query}` → `{searchTerms}`. Several variables in one brace: the first gets the search
    /// term, the others drop.
    public static func searchTemplate(_ template: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{([?&]?)([^}]+)\}"#) else { return nil }
        var result = template
        var found = false
        for hit in regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
            .reversed()
        {
            guard let whole = Range(hit.range, in: template),
                let op = Range(hit.range(at: 1), in: template),
                let names = Range(hit.range(at: 2), in: template)
            else { continue }
            let name = template[names].split(separator: ",").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard let name, !name.isEmpty else { continue }
            let replacement =
                switch template[op] {
                case "?": "?\(name)={searchTerms}"
                case "&": "&\(name)={searchTerms}"
                default: "{searchTerms}"
                }
            result.replaceSubrange(whole, with: replacement)
            found = true
        }
        return found ? result : nil
    }

    // MARK: - Entries

    private static func navigation(_ value: Any?, cluster: String?) -> [OpdsFeed.Item] {
        (value as? [[String: Any]] ?? []).compactMap { l in
            guard let href = l["href"] as? String else { return nil }
            var entry = OpdsFeed.Item()
            entry.id = href
            entry.title = text(l["title"]) ?? ""
            entry.cluster = cluster
            let rels = texts(l["rel"])
            entry.links = (rels.isEmpty ? ["subsection"] : rels).map {
                OpdsFeed.Link(rel: $0, href: href, type: l["type"] as? String ?? "application/opds+json")
            }
            return entry
        }
    }

    private static func publications(_ value: Any?, cluster: String?) -> [OpdsFeed.Item] {
        (value as? [[String: Any]] ?? []).compactMap { p in
            let m = p["metadata"] as? [String: Any] ?? [:]
            var e = OpdsFeed.Item()
            e.title = text(m["title"]) ?? ""
            e.cluster = cluster
            e.links = links(p["links"])
            e.links += links(p["images"]).map { image in
                var b = image
                b.rel = "http://opds-spec.org/image"
                return b
            }
            guard e.acquisition != nil || e.manifest != nil || e.pageStream != nil else { return nil }
            e.id =
                text(m["identifier"]) ?? e.links.first { $0.rel == "self" }?.href ?? e.acquisition?.href
                ?? e.manifest?.href ?? e.title
            for role in Self.credits {
                for name in names(m[role]) where !e.authors.contains(name) { e.authors.append(name) }
            }
            e.summary = text(m["description"])
            e.refreshed = text(m["modified"]).flatMap(OpdsParser.date)
            e.released = text(m["published"]).flatMap(OpdsParser.date)
            e.language = texts(m["language"]).first
            e.publisher = names(m["publisher"]).first
            e.categories = names(m["subject"])
            e.pages = integer(m["numberOfPages"])
            if let bookSeries = (m["belongsTo"] as? [String: Any])?["series"] {
                let first = (bookSeries as? [Any])?.first ?? bookSeries
                e.bookSeries = text(first) ?? text((first as? [String: Any])?["name"])
                e.volume = ((first as? [String: Any])?["position"] as? NSNumber)?.doubleValue
            }
            return e
        }
    }

    /// Who took part in the work, in the order in which the app names them — Komga lists the same
    /// person once more per role, the kit once.
    private static let credits = [
        "author", "artist", "illustrator", "penciler", "penciller", "inker", "colorist", "letterer",
        "translator", "editor", "narrator", "contributor",
    ]

    // MARK: - Values in two shapes

    private static func links(_ value: Any?) -> [OpdsFeed.Link] {
        (value as? [[String: Any]] ?? []).flatMap { l -> [OpdsFeed.Link] in
            guard let href = l["href"] as? String else { return [] }
            let rels = texts(l["rel"])
            let template = l["templated"] as? Bool ?? false
            return (rels.isEmpty ? [nil] : rels.map(Optional.some)).map {
                OpdsFeed.Link(
                    rel: $0, href: href, type: l["type"] as? String, title: text(l["title"]), pages: nil,
                    recently: nil, template: template)
            }
        }
    }

    /// A text — or a language table (`{"en": "…"}`), then the first entry.
    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let table = value as? [String: Any] {
            return table.sorted { $0.key < $1.key }.compactMap { $0.value as? String }.first
        }
        return nil
    }

    /// A text or a list of texts.
    private static func texts(_ value: Any?) -> [String] {
        if let s = value as? String { return [s] }
        return (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// Contributors, publishers, keywords: text, object with `name`, or a list of them.
    private static func names(_ value: Any?) -> [String] {
        let list: [Any] = (value as? [Any]) ?? (value.map { [$0] } ?? [])
        return list.compactMap { text($0) ?? text(($0 as? [String: Any])?["name"]) }
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
