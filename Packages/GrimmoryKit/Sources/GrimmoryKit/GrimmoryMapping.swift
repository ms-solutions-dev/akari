import Foundation
import SourcesKit

/// Translates Grimmory's responses into the terms of the source protocol.
enum GrimmoryMapping {

    static func kind(_ fileType: String?) -> Kind {
        switch fileType?.uppercased() {
        case "CBX", "CBZ", "CBR": return .manga
        case "AUDIOBOOK": return .audiobook
        default: return .book
        }
    }

    static func title(_ b: GrimmoryResponses.Book, source: SourceID, baseURL: URL) -> Title {
        let kind = kind(b.primaryFileType)
        let scope: Scope =
            if let pages = b.pageCount, pages > 0 { .pages(pages) } else { .unknown }
        return Title(
            identifier: TitleID(source: source, id: String(b.id)), kind: kind, name: b.title,
            subtitle: b.subtitle.flatMap(nilIfEmpty),
            authors: b.authors ?? [], series: seriesReference(b, source: source),
            cover: baseURL.appending(path: "api/v1/media/book/\(b.id)/thumbnail"),
            genres: genres(b.categories),
            summary: Title.blurb(b.description), rating: rating(b), scope: scope,
            language: Title.languageCode(b.language), ageRating: b.ageRating,
            publisher: nilIfEmpty(b.publisher),
            narrator: b.narrator.flatMap(nilIfEmpty).map { [$0] } ?? [], added: b.addedOn,
            released: Title.releaseDate(b.publishedDate), size: b.fileSizeKb.map { $0 * 1024 },
            format: format(b.primaryFileType))
    }

    /// "CBX" is Grimmory's collective name for CBZ and CBR — the UI prints what the file
    /// really is, and Grimmory does not know that; hence "CBZ/CBR".
    static func format(_ type: String?) -> String? {
        type?.uppercased() == "CBX" ? "CBZ/CBR" : Title.format(type)
    }

    /// An author with image — `/api/v1/media/author/{id}/thumbnail`, only if the server has one
    /// ("Administrator" and duplicates such as "A Biskreirau Dofur"/"A. Biskreirau Dofur" are the
    /// server's business; the app merges spellings via ``AuthorName``).
    static func author(_ a: GrimmoryResponses.Author, source: SourceID, baseURL: URL) -> AuthorReference {
        AuthorReference(
            source: source, identifier: String(a.id), name: a.name,
            image: a.hasPhoto == true
                ? baseURL.appending(path: "api/v1/media/author/\(a.id)/thumbnail") : nil,
            count: a.bookCount ?? 0)
    }

    /// Grimmory knows series only as a name on the book; the name is the identifier.
    static func seriesReference(_ b: GrimmoryResponses.Book, source: SourceID) -> SeriesReference? {
        guard let name = b.seriesName.flatMap(nilIfEmpty) else { return nil }
        return SeriesReference(
            identifier: SeriesID(source: source, id: name), name: name, volume: b.seriesNumber)
    }

    /// Series names that differ only in case, apostrophe, hyphen or whitespace
    /// ("Kram touklouglorn Fudaislun" / "Kram touklouglorn Fudaislun", "Deiwetrol Griadok" / "Deiwetrol’ Griadok") are one series — under
    /// the spelling most volumes carry (so the identifier of a series that was saved mostly stays
    /// the same). Different names ("Ziokreigand" / "Kram Ziokreigand-Saga") are not merged by the app:
    /// that is a matter of the data.
    static func unifySeries(_ title: [Title]) -> [Title] {
        var spellings: [String: [String: Int]] = [:]
        for t in title {
            guard let name = t.series?.name else { continue }
            spellings[seriesKey(name), default: [:]][name, default: 0] += 1
        }
        var canonical: [String: String] = [:]
        for (lookupKey, variants) in spellings where variants.count > 1 {
            canonical[lookupKey] =
                variants.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!.key
        }
        guard !canonical.isEmpty else { return title }
        return title.map { t in
            guard let s = t.series, let target = canonical[seriesKey(s.name)], target != s.name else {
                return t
            }
            return t.with(
                series: SeriesReference(
                    identifier: SeriesID(source: s.identifier.source, id: target), name: target,
                    volume: s.volume))
        }
    }

    static func seriesKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// The series derived from the books: one per name, volumes counted, cover from the lowest
    /// volume, genres merged; the length of the series (`seriesTotal`) from the book that knows it.
    static func seriesList(from title: [Title], lengths: [SeriesID: Int] = [:]) -> [Series] {
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
                cover: first.cover, genres: genres, rating: average(volumes.compactMap(\.rating)),
                volumeCount: volumes.count,
                total: lengths[identifier].flatMap { $0 >= volumes.count ? $0 : nil },
                language: first.language,
                ageRating: volumes.compactMap(\.ageRating).max(),
                added: volumes.compactMap(\.added).min())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The stars of a series: the average of its volumes, votes summed, the origin the most
    /// common one — Grimmory does not rate series itself.
    static func average(_ ratings: [Rating]) -> Rating? {
        guard !ratings.isEmpty else { return nil }
        let stars = ratings.map(\.stars).reduce(0, +) / Double(ratings.count)
        let voices = ratings.compactMap(\.voices).reduce(0, +)
        var origin: [String: Int] = [:]
        for b in ratings { origin[b.origin, default: 0] += 1 }
        let mostCommon = origin.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!
            .key
        return Rating(stars: stars, voices: voices > 0 ? voices : nil, origin: mostCommon)
    }

    /// The raw categories (Goodreads shelves, Amazon headings) become the library's genres —
    /// table and figures in ``GrimmoryGenres``.
    static func genres(_ categories: [String]?) -> [String] {
        GrimmoryGenres.map(categories ?? [])
    }

    /// Goodreads before Amazon: both are normalized to five stars; Goodreads has the
    /// larger sample (66,425 against 252 for "Slezevei Mouplun").
    static func rating(_ b: GrimmoryResponses.Book) -> Rating? {
        if let g = b.goodreadsRating, g > 0 {
            return Rating(stars: g, voices: b.goodreadsReviewCount, origin: "Goodreads")
        }
        if let a = b.amazonRating, a > 0 {
            return Rating(stars: a, voices: b.amazonReviewCount, origin: "Amazon")
        }
        return nil
    }

    /// The reading state from the list entry: only fraction and time — the detail supplies
    /// the position. No state without `lastReadTime`: a book that was never opened has no
    /// state, not even "0 %".
    static func readingState(list b: GrimmoryResponses.Book) -> ReadingState? {
        guard let time = b.lastReadTime else { return nil }
        return state(
            position(b.epubProgress, b.pdfProgress, b.cbxProgress, b.audiobookProgress, pages: b.pageCount)
                ?? .fraction(fraction(b.readProgress)), time: time, status: b.readStatus)
    }

    static func readingState(_ f: GrimmoryResponses.Progress, pages: Int?) -> ReadingState? {
        guard let time = f.lastReadTime else { return nil }
        return state(
            position(f.epubProgress, f.pdfProgress, f.cbxProgress, f.audiobookProgress, pages: pages)
                ?? .fraction(fraction(f.readProgress)), time: time, status: f.readStatus)
    }

    /// Grimmory has no delete: a reset book is `UNREAD`, keeps `lastReadTime` and, in the web
    /// list, even the old `epubProgress` (recorded after "reset progress": list 0.1 %, detail 0).
    /// `UNREAD` is the user's statement — no reading state, otherwise the book would show up
    /// under Continue Reading with "1 %". The web reader sets READING on opening, the kit on
    /// the first state above zero; a real state is never UNREAD.
    private static func state(_ position: ReadingState.Position, time: Date, status: String?) -> ReadingState?
    {
        if status == "UNREAD" { return nil }
        return ReadingState(position: position, timestamp: time, completed: status == "READ")
    }

    private static func position(
        _ epub: GrimmoryResponses.EpubProgress?, _ pdf: GrimmoryResponses.PageProgress?,
        _ cbx: GrimmoryResponses.PageProgress?, _ audio: GrimmoryResponses.AudioProgress?, pages: Int?
    ) -> ReadingState.Position? {
        if let epub, let cfi = epub.cfi, !cfi.isEmpty {
            return .position(cfi: cfi, fraction: epub.percentage / 100)
        }
        if let s = pdf ?? cbx {
            if let pages, pages > 0 { return .page(s.page, from: pages) }
            return .fraction(s.percentage / 100)
        }
        if let audio { return .fraction(audio.percentage / 100) }
        if let epub { return .fraction(epub.percentage / 100) }
        return nil
    }

    /// `readProgress` is 0 … 100 like `percentage` — measured: both 0.0786703 for the same
    /// book. (An earlier gap analysis had noted 0 … 1; that was the reading, not the value.)
    static func fraction(_ value: Double?) -> Double {
        (value ?? 0) / 100
    }

    /// What goes to the server — one branch per position.
    static func report(_ state: ReadingState, fileType: String?) -> GrimmoryResponses.ProgressReport {
        var m = GrimmoryResponses.ProgressReport()
        let percent = state.fraction * 100
        switch state.position {
        case .position(let cfi, _):
            m.epubProgress = .init(cfi: cfi, href: nil, percentage: percent)
        case .page(let n, _):
            let s = GrimmoryResponses.PageProgress(page: n, percentage: percent)
            if fileType?.uppercased() == "PDF" { m.pdfProgress = s } else { m.cbxProgress = s }
        case .second(let s, _):
            m.audiobookProgress = .init(positionMs: Int64(s * 1000), percentage: percent)
        case .fraction:
            m.epubProgress = .init(cfi: nil, href: nil, percentage: percent)
        }
        if state.completed { m.dateFinished = ISO8601DateFormatter().string(from: state.timestamp) }
        return m
    }

    /// Which read status belongs to a written state — or `nil` if the previous one already fits.
    /// A deliberately set status (PAUSED, ABANDONED, WONT_READ) stays: the user chose it, the
    /// state did not.
    static func readStatus(for state: ReadingState, previous: String?) -> String? {
        if state.completed { return previous == "READ" ? nil : "READ" }
        guard state.started else { return nil }
        switch previous {
        case "READING", "RE_READING", "PAUSED", "ABANDONED", "WONT_READ": return nil
        default: return "READING"
        }
    }

    static func nilIfEmpty(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
