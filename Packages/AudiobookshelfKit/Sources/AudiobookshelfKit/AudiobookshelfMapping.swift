import Foundation
import SourcesKit

/// Translates Audiobookshelf's responses into the terms of the source slot.
enum AudiobookshelfMapping {

    static func title(_ e: AudiobookshelfResponses.Item, source: SourceID, baseURL: URL) -> Title {
        let m = e.media.metadata
        let duration = e.media.duration ?? 0
        let kind: Kind = duration > 0 ? .audiobook : .book
        return Title(
            identifier: TitleID(source: source, id: e.id), kind: kind, name: m.title,
            subtitle: text(m.subtitle),
            authors: people(m.authors?.map(\.name), m.authorName),
            series: seriesReference(m, source: source),
            cover: baseURL.appending(path: "api/items/\(e.id)/cover"),
            genres: genres(m.genres, tags: e.media.tags),
            summary: Title.blurb(text(m.description)),
            scope: duration > 0 ? .duration(duration) : .unknown,
            language: language(m.language), ageRating: m.explicit == true ? 18 : nil,
            publisher: text(m.publisher),
            narrator: people(m.narrators, m.narratorName),
            added: Date(timeIntervalSince1970: e.addedAt / 1000),
            released: Title.releaseDate(m.publishedYear),
            chapter: e.media.numChapters.flatMap { $0 > 0 ? $0 : nil }, size: e.size,
            format: format(e.media))
    }

    /// The format: for an e-book from the list, for an audiobook from the tracks — which
    /// only the detail knows (`expanded=1`); in the list it stays `nil`. Mixed
    /// tracks ("MP3/M4B") are rare, but possible.
    static func format(_ m: AudiobookshelfResponses.Item.Medium) -> String? {
        if let e = Title.format(m.ebookFormat ?? m.ebookFile?.ebookFormat) { return e }
        var formats: [String] = []
        for track in m.tracks ?? [] {
            if let f = Title.format(track.metadata?.ext), !formats.contains(f) { formats.append(f) }
        }
        return formats.isEmpty ? nil : formats.joined(separator: "/")
    }

    /// What are not genres: the ID3 scan writes "Audiobook" into `genres` (7 of 9),
    /// the real genres are in `tags` (Audible match). Both
    /// merged, the noise removed — as with Grimmory.
    static let noise: Set<String> = ["audiobook", "audiobooks", "audible", "hörbuch", "hörbücher"]

    static func genres(_ genres: [String]?, tags: [String]?) -> [String] {
        var result: [String] = []
        for g in (tags ?? []) + (genres ?? [])
        where !noise.contains(g.lowercased()) && !result.contains(g) {
            result.append(g)
        }
        return result
    }

    /// The series from the detail (`series[]`) or from the list (`seriesName` as
    /// `Name #1`); the name is the id.
    static func seriesReference(
        _ m: AudiobookshelfResponses.Item.Metadata, source: SourceID
    ) -> SeriesReference? {
        if let bookSeries = m.series?.first {
            return SeriesReference(
                identifier: SeriesID(source: source, id: bookSeries.name), name: bookSeries.name,
                volume: bookSeries.sequence.flatMap(Double.init))
        }
        guard let text = m.seriesName?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let hash = text.range(of: " #", options: .backwards) {
            let name = String(text[..<hash.lowerBound])
            let number = Double(text[hash.upperBound...])
            return SeriesReference(identifier: SeriesID(source: source, id: name), name: name, volume: number)
        }
        return SeriesReference(identifier: SeriesID(source: source, id: text), name: text)
    }

    static func seriesList(from title: [Title]) -> [Series] {
        var clusters: [SeriesID: [Title]] = [:]
        for t in title { if let s = t.series { clusters[s.identifier, default: []].append(t) } }
        return clusters.map { identifier, volumes in
            let ordered = volumes.sorted {
                ($0.series?.volume ?? .infinity) < ($1.series?.volume ?? .infinity)
            }
            let earliest = ordered[0]
            var genres: [String] = []
            var authors: [String] = []
            for b in ordered {
                for g in b.genres where !genres.contains(g) { genres.append(g) }
                for a in b.authors where !authors.contains(a) { authors.append(a) }
            }
            return Series(
                identifier: identifier, kind: earliest.kind, name: earliest.series?.name ?? identifier.id,
                authors: authors,
                cover: earliest.cover, genres: genres, volumeCount: volumes.count,
                language: earliest.language,
                ageRating: volumes.compactMap(\.ageRating).max(),
                added: volumes.compactMap(\.added).min())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Podcasts

    /// The title id of an episode: `item:episode`. Both are UUIDs, the colon
    /// occurs in neither and disturbs neither paths (the offline store scatters the id)
    /// nor links (`akari://…/<id>` carries it as one path component).
    static func episodeKey(_ item: String, _ episodeItem: String) -> String { "\(item):\(episodeItem)" }

    /// `item:episode` back into its two parts — `nil` for an audiobook.
    static func episodeParts(_ id: String) -> (item: String, episodeItem: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    /// A podcast becomes titles — one per episode — and the episodes carry the podcast
    /// as series. The volume number is the order of release (1 = the oldest),
    /// because a lecture cycle is listened to like a series and "Up next" then names the
    /// next episode; an episode number from the feed takes precedence if it is a number.
    static func episodeList(_ e: AudiobookshelfResponses.Item, source: SourceID, baseURL: URL) -> [Title] {
        let m = e.media.metadata
        let podcast = SeriesID(source: source, id: e.id)
        let cover = baseURL.appending(path: "api/items/\(e.id)/cover")
        let ordered = (e.media.episodes ?? []).sorted { ($0.publishedAt ?? 0) < ($1.publishedAt ?? 0) }
        return ordered.enumerated().map { slot, f in
            let duration = f.duration ?? f.audioTrack?.duration ?? 0
            let number = f.episode.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let released = f.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            return Title(
                identifier: TitleID(source: source, id: episodeKey(e.id, f.id)), kind: .podcast,
                name: f.title, subtitle: f.subtitle == f.title ? nil : text(f.subtitle),
                authors: people(nil, m.author ?? m.authorName),
                series: SeriesReference(
                    identifier: podcast, name: m.title, volume: number ?? Double(slot + 1)),
                cover: cover, genres: genres(m.genres, tags: e.media.tags),
                summary: Title.blurb(text(f.description)),
                scope: duration > 0 ? .duration(duration) : .unknown, language: language(m.language),
                ageRating: m.explicit == true ? 18 : nil,
                added: released ?? f.addedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                released: released, chapter: (f.chapters?.count).flatMap { $0 > 0 ? $0 : nil },
                size: f.size ?? f.audioTrack?.metadata?.size,
                format: Title.format(f.audioTrack?.metadata?.ext))
        }
    }

    /// The volume of an episode: one track, the file itself; chapters if the feed has any.
    static func audioManifest(_ f: AudiobookshelfResponses.Item.Episode, baseURL: URL) -> AudioManifest? {
        guard let track = f.audioTrack,
            let address = URL(string: track.contentUrl, relativeTo: baseURL)?.absoluteURL
        else { return nil }
        let duration = f.duration ?? track.duration
        return AudioManifest(
            tracks: [
                AudioTrack(
                    address: address, startTime: 0, duration: duration, size: track.metadata?.size ?? f.size,
                    fileExtension: track.metadata?.ext.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                )
            ],
            chapter: chapter(f.chapters), duration: duration)
    }

    static func readingState(_ f: AudiobookshelfResponses.Progress) -> ReadingState {
        ReadingState(
            position: .second(f.currentTime, from: f.duration),
            timestamp: Date(timeIntervalSince1970: f.lastUpdate / 1000),
            completed: f.isFinished)
    }

    static func chapter(_ list: [AudiobookshelfResponses.Item.Chapter]?) -> [Chapter] {
        (list ?? []).map { Chapter(name: $0.title, startTime: $0.start, end: $0.end) }
    }

    /// Detail lists before the list strings; Audiobookshelf separates the strings
    /// with commas.
    private static func people(_ list: [String]?, _ text: String?) -> [String] {
        if let list, !list.isEmpty { return list }
        return (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
    }

    /// Audiobookshelf spells languages out ("German") — here to BCP-47 where it is
    /// unambiguous; otherwise the word stays.
    static func language(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        switch t.lowercased() {
        case "german", "deutsch": return "de"
        case "english", "englisch": return "en"
        case "turkish", "türkisch": return "tr"
        case "french", "französisch": return "fr"
        case "spanish", "spanisch": return "es"
        default: return t
        }
    }

    /// The description comes as HTML (`<p>`, `<br />`) — for the UI as
    /// text with paragraphs, without tags.
    static func text(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var t = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "</p>\\s*<p>", with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let cleaned = t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
