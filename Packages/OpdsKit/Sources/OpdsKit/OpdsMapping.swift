import Foundation
import SourcesKit

/// Translates OPDS entries into titles and series — and remembers in the title what the
/// reader needs later (file address, page stream), because OPDS has no detail endpoint.
enum OpdsMapping {

    /// What a title carries for the reader, packed into its identifier: the entry ID is not always
    /// an address in OPDS, the file always is.
    struct EntryData: Codable {
        var id: String
        var file: URL?
        var pageStream: String?
        var pages: Int?
        /// OPDS 2.0: the Divina manifest — the pages come from its `readingOrder`.
        var manifest: URL?
        /// OPDS 2.0: the progression API — only set where the reading state can go there too
        /// (pages of a comic); a book from a file stays local.
        var progress: URL?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case file = "datei"
            case pageStream = "seitenStrom"
            case pages = "seiten"
            case manifest
            case progress = "fortschritt"
        }
    }

    /// The title identifier carries the addresses as JSON — the identifier is the only place that
    /// travels from the shelf all the way into the reader, and OPDS has no "fetch title".
    ///
    /// **Sorted keys, no slash escaping:** `JSONEncoder` otherwise orders the fields differently on
    /// each run — the same file got two identifiers, and the local reading state was gone after
    /// signing in again (observed on a device: volume 1 without the ten pages read). Fields without
    /// a value are omitted from the JSON — an Atom title gets no different identifier from the new
    /// OPDS 2.0 fields.
    static func identifier(_ data: EntryData, source: SourceID) -> TitleID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? data.id
        return TitleID(source: source, id: json)
    }

    static func entry(from title: Title) -> EntryData {
        entry(from: title.identifier)
    }

    static func entry(from identifier: TitleID) -> EntryData {
        (try? JSONDecoder().decode(EntryData.self, from: Data(identifier.id.utf8)))
            ?? EntryData(id: identifier.id)
    }

    /// An acquisition feed is a series if its parent feed is called "Serien"/"Series"/"Reihen"
    /// or the feed itself shows a sequence of volumes (Komga: series feed under "All series";
    /// Grimmory: "Series"). "New", "All books", a library are not.
    static func isSeries(feed: OpdsFeed, parent: String?) -> Bool {
        let names = [parent?.lowercased(), feed.title.lowercased()].compactMap { $0 }
        return names.contains { n in ["serie", "series", "reihe", "reihen"].contains { n.contains($0) } }
    }

    /// - Parameters:
    ///   - seriesName: the series from the feed (Komga: series feed); the entry itself takes
    ///     precedence (Grimmory: `belongs-to-collection`).
    ///   - slot: the position in the feed, 1-based — the volume number if neither title nor
    ///     entry names one (Komga orders the series feed by number).
    static func title(
        _ e: OpdsFeed.Item, feed: OpdsFeed, feedAddress: URL, bookSeries: String?, slot: Int? = nil,
        source: SourceID, resolve: (String, URL) -> URL
    ) -> Title? {
        let acquisition = e.acquisition
        let stream = e.pageStream
        let manifest = e.manifest
        guard acquisition != nil || stream != nil || manifest != nil else { return nil }
        // The format: the file extension first (Komga reports `.cbr` as `application/zip`), otherwise
        // the content type.
        let fileExtension = acquisition.flatMap { URL(string: $0.href)?.pathExtension.lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let type = (fileExtension ?? acquisition?.type ?? "").lowercased()
        let kind: Kind
        // Individual pages: OPDS-PSE (Atom) or the Divina manifest (JSON) — both make the title a
        // comic. An EPUB or PDF stays a book from the file, even if Komga puts a Divina manifest
        // next to it.
        let pageable = stream != nil || (manifest != nil && (e.pages ?? 0) > 0)
        if type.contains("epub") || type.contains("pdf") || type.contains("mobi") || type.contains("kepub")
            || type.contains("azw")
        {
            kind = .book
        } else if pageable {
            kind = .manga
        } else if type.contains("cbz") || type.contains("cbr") || type.contains("comicbook")
            || type.contains("zip")
            || type.contains("rar")
        {
            // A comic without page stream and without manifest: the app cannot page through the file —
            // off the shelf.
            return nil
        } else if type.contains("audio") || type.contains("mpeg") || type.contains("m4b")
            || type.contains("mp3")
        {
            return nil
        } else if acquisition != nil {
            kind = .book
        } else {
            return nil
        }
        let data = EntryData(
            id: e.id.isEmpty ? (acquisition?.href ?? stream?.href ?? manifest?.href ?? e.title) : e.id,
            file: acquisition.map { resolve($0.href, feedAddress) },
            pageStream: stream.map {
                resolve($0.href, feedAddress).absoluteString.removingPercentEncoding ?? $0.href
            },
            pages: stream?.pages ?? (kind == .manga ? e.pages : nil),
            manifest: kind == .manga && stream == nil ? manifest.map { resolve($0.href, feedAddress) } : nil,
            progress: kind == .manga ? e.progress.map { resolve($0.href, feedAddress) } : nil)
        let seriesName = e.bookSeries ?? bookSeries
        let volume =
            e.volume ?? volumeNumber(e.title, bookSeries: seriesName)
            ?? (bookSeries != nil ? slot.map(Double.init) : nil)
        let series: SeriesReference? = seriesName.map {
            // The identifier of the series is its name — Grimmory puts it in the entry, so a book under
            // "New" and the same one in the series feed end up in the same series.
            SeriesReference(identifier: SeriesID(source: source, id: "reihe:" + $0), name: $0, volume: volume)
        }
        let text = Title.blurb(e.summary ?? e.content)
        return Title(
            identifier: identifier(data, source: source), kind: kind, name: name(e.title),
            authors: e.authors, series: series, cover: e.image.map { resolve($0.href, feedAddress) },
            genres: e.categories, summary: text,
            scope: data.pages.map { .pages($0) } ?? .unknown,
            language: Title.languageCode(e.language), publisher: e.publisher, added: e.refreshed,
            released: e.released, size: e.size,
            format: Title.format(fileExtension ?? acquisition?.type ?? (pageable ? "cbz" : nil)))
    }

    /// Komga sends the file name as the title ("Fiahot_brur_Wani__Doppelband-Edition_1__-_Triadroflur_Binsiojiarn"):
    /// underscores become spaces, doubled ones drop — a title without any space is a file name, one
    /// with spaces stays as it is.
    static func name(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else {
            return String(localized: "opds.untitled", defaultValue: "Untitled", bundle: .main)
        }
        guard !t.contains(" "), t.contains("_") else { return t }
        return t.replacingOccurrences(of: "_", with: " ").split(separator: " ").joined(separator: " ")
    }

    /// "Band 3", "Vol. 12", "#7", "Holmes 02 – Memoirs" → 3, 12, 7, 2 — only within a series: a word
    /// like "Band" in front wins, otherwise the first standalone number.
    static func volumeNumber(_ title: String, bookSeries: String?) -> Double? {
        guard bookSeries != nil else { return nil }
        let patterns = [
            #"(?i)\b(?:band|bd\.?|vol\.?|volume|tome|kapitel|chapter|#)\s*(\d+(?:[.,]\d+)?)"#,
            #"(?<![\w.])(\d{1,4}(?:[.,]\d+)?)(?![\w.])"#,
        ]
        for m in patterns {
            guard let regex = try? NSRegularExpression(pattern: m),
                let hit = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                let area = Range(hit.range(at: 1), in: title)
            else { continue }
            if let d = Double(title[area].replacingOccurrences(of: ",", with: ".")) { return d }
        }
        return nil
    }

    static func seriesList(from title: [Title], feeds: [String: String]) -> [Series] {
        var clusters: [SeriesID: [Title]] = [:]
        for t in title { if let s = t.series { clusters[s.identifier, default: []].append(t) } }
        return clusters.map { identifier, volumes in
            let sortedVolumes = volumes.sorted {
                ($0.series?.volume ?? .infinity) < ($1.series?.volume ?? .infinity)
            }
            let first = sortedVolumes[0]
            var genres: [String] = []
            var authors: [String] = []
            for b in sortedVolumes {
                for g in b.genres where !genres.contains(g) { genres.append(g) }
                for a in b.authors where !authors.contains(a) { authors.append(a) }
            }
            return Series(
                identifier: identifier, kind: first.kind, name: first.series?.name ?? identifier.id,
                authors: authors,
                cover: first.cover, genres: genres, volumeCount: volumes.count, language: first.language,
                added: volumes.compactMap(\.added).min())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
