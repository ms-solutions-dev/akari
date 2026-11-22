import Foundation
import SourcesKit

/// Translates Kavita's responses into the terms of the source slot.
///
/// **A title is a chapter.** Kavita orders series → volume → chapter, and only the
/// chapter carries file, pages and reading state (`/api/Reader/progress` wants a
/// `chapterId`). A book in Kavita is a volume with one chapter, a manga volume
/// as one CBZ likewise — the title in Akari is in both cases the same thing you
/// look up in Kavita.
///
/// Kavita's placeholders for "no volume" and "no chapter" are ±100000
/// (`LooseLeafVolumeNumber`, `SpecialVolumeNumber`, `DefaultChapterNumber`) — the
/// number never appears as a volume number on the shelf.
enum KavitaMapping {

    /// What ``KavitaSource/write(_:for:)`` needs to know about a chapter: Kavita's
    /// `ProgressDto` demands volume, series and library next to the chapter — and the
    /// page count, because an EPUB's fraction only becomes a page through it.
    struct ChapterReference: Sendable, Codable, Hashable {
        let volumeId: Int
        let seriesId: Int
        let libraryId: Int
        let pages: Int
        let epub: Bool

        enum CodingKeys: String, CodingKey, CaseIterable {
            case volumeId
            case seriesId
            case libraryId
            case pages = "seiten"
            case epub
        }
    }

    static let placeholder: Double = 100_000

    /// 3 means EPUB — in `SeriesDto.format`, `ChapterDto.format` and `MangaFileDto.format`.
    static let formatEpub = 3
    /// 4 means PDF: Kavita then delivers the pages as an image only with `extractPdf=true`.
    static let formatPdf = 4

    static func epub(_ k: KavitaResponses.Chapter, series: KavitaResponses.Series?) -> Bool {
        (k.format ?? k.files?.first?.format ?? series?.format) == formatEpub
    }

    static func pdf(_ k: KavitaResponses.Chapter, series: KavitaResponses.Series?) -> Bool {
        (k.format ?? k.files?.first?.format ?? series?.format) == formatPdf
    }

    static func series(
        _ s: KavitaResponses.Series, chapter: [KavitaResponses.Chapter], source: SourceID, baseURL: URL,
        readingDirection: ReadingDirection? = nil
    ) -> Series {
        let firstChapter = chapter.first
        return Series(
            identifier: SeriesID(source: source, id: String(s.id)),
            kind: s.format == formatEpub ? .book : .manga,
            name: name(s),
            authors: names(firstChapter?.writers),
            illustrators: illustrators(firstChapter),
            cover: address(baseURL, "api/Image/series-cover", "seriesId", s.id),
            genres: genres(chapter.flatMap { ($0.genres ?? []) + ($0.tags ?? []) }),
            summary: chapter.lazy.compactMap { Title.blurb($0.summary) }.first,
            volumeCount: chapter.count,
            language: Title.languageCode(firstChapter?.language),
            ageRating: chapter.compactMap { ageRating($0.ageRating) }.max(),
            readingDirection: s.format == formatEpub ? nil : readingDirection,
            added: realDate(s.createdUtc))
    }

    static func title(
        _ k: KavitaResponses.Chapter, volume: KavitaResponses.Volume?, series: KavitaResponses.Series?,
        seriesId: Int, source: SourceID, baseURL: URL, rating: Rating? = nil,
        readingDirection: ReadingDirection? = nil
    ) -> Title {
        let seriesName = series.map(name) ?? ""
        let isEpub = epub(k, series: series)
        let pages = k.pages ?? 0
        return Title(
            identifier: TitleID(source: source, id: String(k.id)),
            kind: isEpub ? .book : .manga,
            name: displayName(k, volume: volume, seriesName: seriesName),
            authors: names(k.writers),
            series: SeriesReference(
                identifier: SeriesID(source: source, id: String(seriesId)), name: seriesName,
                volume: number(k, volume: volume)),
            cover: address(baseURL, "api/Image/chapter-cover", "chapterId", k.id),
            // Genres first, then Kavita's tags — `Title` has no line of its own
            // for them, and Grimmory puts its categories there as well.
            genres: genres((k.genres ?? []) + (k.tags ?? [])),
            summary: Title.blurb(k.summary),
            rating: rating,
            // For an EPUB Kavita counts sections, not pages ("12 pages" for a
            // novel) — better to leave the line out then.
            scope: isEpub || pages == 0 ? .unknown : .pages(pages),
            language: Title.languageCode(k.language),
            ageRating: ageRating(k.ageRating),
            publisher: names(k.publishers).first,
            readingDirection: isEpub ? nil : readingDirection,
            added: realDate(k.createdUtc),
            released: realDate(k.releaseDate),
            size: size(k.files),
            format: Title.format(k.files?.first?.fileExtension))
    }

    /// The name Kavita shows: the title from the metadata (`titleName` — for an
    /// EPUB the book title), otherwise the one from the file name (`title`), otherwise series and
    /// number. A placeholder like `-100000` is not a name.
    static func displayName(
        _ k: KavitaResponses.Chapter, volume: KavitaResponses.Volume?, seriesName: String
    )
        -> String
    {
        for candidate in [k.titleName, k.title] {
            if let t = emptyIsNil(candidate), !isPlaceholder(t) { return t }
        }
        if let n = number(k, volume: volume) {
            let integer = n.rounded() == n ? String(Int(n)) : String(n)
            return seriesName.isEmpty ? integer : seriesName + " " + integer
        }
        return seriesName.isEmpty ? (emptyIsNil(k.range) ?? String(k.id)) : seriesName
    }

    /// The number in the series: the chapter's, where it has one, otherwise the volume's —
    /// a volume as one file has a chapter without a number. Special volumes have none.
    static func number(_ k: KavitaResponses.Chapter, volume: KavitaResponses.Volume?) -> Double? {
        if k.isSpecial == true { return nil }
        if let n = k.minNumber, abs(n) < placeholder { return n }
        if let n = volume?.minNumber, abs(n) < placeholder { return n }
        return nil
    }

    /// Kavita's state in Akari's terms.
    ///
    /// `pageNum` counts from 0 and is the page that is open — except on the last one:
    /// there Kavita's reader writes the page count itself, and the chapter is read.
    /// Page 1 of 213 at Akari is therefore `pageNum` 0. A state of 0 is at Kavita
    /// at the same time "never started" — `nil`.
    ///
    /// For an EPUB `pageNum` counts sections of the spine; the book reader searches by
    /// the fraction, not by Readium positions — hence ``ReadingState/Position/fraction(_:)``.
    static func readingState(page pageNum: Int?, pages: Int, epub: Bool, time: Date?) -> ReadingState? {
        guard let pageNum, pageNum > 0, pages > 0 else { return nil }
        let done = pageNum >= pages
        let position: ReadingState.Position =
            epub
            ? .fraction(done ? 1 : Double(pageNum) / Double(pages))
            : .page(min(pageNum + 1, pages), from: pages)
        return ReadingState(position: position, timestamp: realDate(time) ?? Date(), completed: done)
    }

    /// Akari's state as `pageNum` — the inverse of ``readingState(page:pages:epub:time:)``.
    /// A CFI becomes the section the fraction falls in: Kavita's reader looks up the
    /// section, not the spot inside it (`bookScrollId` is an XPath in Kavita's
    /// own representation and cannot be built from Readium).
    static func pageNumber(_ state: ReadingState, pages: Int) -> Int {
        if state.completed { return pages }
        switch state.position {
        case .page(let n, _):
            return min(max(n - 1, 0), max(pages - 1, 0))
        case .position, .fraction, .second:
            let part = Int((state.fraction * Double(pages)).rounded(.down))
            return min(max(part, 0), max(pages - 1, 0))
        }
    }

    /// The stars of all accounts of this server — `averageScore` in percent, here mapped to
    /// five stars. The origin is whoever gave them: "Kavita" for the own users, the
    /// service where Kavita+ fetches foreign ones. Nobody rated: no rating.
    static func rating(_ r: KavitaResponses.Rating) -> Rating? {
        guard let percent = r.averageScore, percent > 0 else { return nil }
        let origin =
            switch r.provider ?? 0 {
            case 1: "AniList"
            case 2: "MyAnimeList"
            case 4: "Comicbook Roundup"
            case 5: "Hardcover"
            case 6: "MangaBaka"
            default: "Kavita"
            }
        return Rating(stars: Double(percent) / 20, origin: origin)
    }

    /// The reading profile Kavita uses for a series: the series' own, otherwise its
    /// library's, otherwise the default — the same way as `/api/reading-profile/{l}/{s}`.
    /// The silent profiles (`kind` 2) that Kavita's reader creates per series while reading
    /// are not named by `/all`; they are missing here.
    static func readingProfile(
        _ profiles: [KavitaResponses.ReadingProfile], series: Int, library: Int?
    ) -> KavitaResponses.ReadingProfile? {
        profiles.first { $0.seriesIds?.contains(series) == true }
            ?? library.flatMap { b in profiles.first { $0.libraryIds?.contains(b) == true } }
            ?? profiles.first { $0.kind == 0 }
    }

    /// Webtoon (`readerMode` 2) scrolls vertically — like Komga's `WEBTOON`; otherwise the direction.
    /// Kavita's automatic webtoon detection (`allowAutomaticWebtoonReaderDetection`,
    /// very tall narrow pages) decides in the reader by the page dimensions — the extract
    /// does not know them; it is left to the reader.
    static func readingDirection(_ p: KavitaResponses.ReadingProfile?) -> ReadingDirection? {
        guard let p else { return nil }
        if p.readerMode == 2 { return .vertical }
        switch p.readingDirection {
        case 1: return .rightToLeft
        case 0: return .leftToRight
        default: return nil
        }
    }

    /// Kavita's `AgeRating` (a number) in years — the same levels Komga reads from
    /// ComicInfo. "Unknown", "pending" and "not applicable" are not a
    /// rating.
    static func ageRating(_ value: Int?) -> Int? {
        switch value ?? -1 {
        case 2: 3  // Early Childhood
        case 3, 4: 0  // Everyone, G
        case 5: 10  // Everyone 10+
        case 6: 8  // PG
        case 7: 6  // Kids to Adults
        case 8: 13  // Teen
        case 9: 15  // MA15+
        case 10, 11: 17  // Mature 17+, M
        case 12, 13, 14: 18  // R18+, Adults Only 18+, X18+
        default: nil
        }
    }

    /// A date that is one — `0001-01-01` means "never" at Kavita.
    static func realDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    static func address(_ baseURL: URL, _ path: String, _ name: String, _ id: Int) -> URL {
        baseURL.appending(path: path).appending(queryItems: [URLQueryItem(name: name, value: String(id))])
    }

    private static func name(_ s: KavitaResponses.Series) -> String {
        emptyIsNil(s.localizedName) ?? emptyIsNil(s.name) ?? String(s.id)
    }

    private static func size(_ files: [KavitaResponses.FileInfo]?) -> Int64? {
        let sum = (files ?? []).compactMap(\.bytes).reduce(0, +)
        return sum > 0 ? sum : nil
    }

    private static func names(_ list: [KavitaResponses.Person]?) -> [String] {
        var seen = Set<String>()
        return (list ?? []).compactMap { emptyIsNil($0.name) }.filter { seen.insert($0).inserted }
    }

    /// Who draws, when they are not the same as those who write — as with Komga.
    private static func illustrators(_ k: KavitaResponses.Chapter?) -> [String] {
        let writerNames = Set(names(k?.writers))
        return names(k?.pencillers).filter { !writerNames.contains($0) }
    }

    private static func genres(_ list: [KavitaResponses.Genre]?) -> [String] {
        var seen = Set<String>()
        return (list ?? []).compactMap { emptyIsNil($0.title) }.filter { seen.insert($0).inserted }
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        Double(text).map { abs($0) >= placeholder } ?? false
    }

    static func emptyIsNil(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
