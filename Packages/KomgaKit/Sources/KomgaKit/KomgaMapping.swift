import Foundation
import SourcesKit

/// Translates Komga's responses into the terms of the source slot.
///
/// What a volume lacks comes from its series: genres, age rating, reading direction,
/// language, publisher, stars — and the summary: komf writes it on the series, and 612
/// of 613 volumes have none of their own. The title gets it anyway, because the UI only
/// knows the title.
enum KomgaMapping {

    static func series(_ s: KomgaResponses.Series, source: SourceID, baseURL: URL) -> Series {
        Series(
            identifier: SeriesID(source: source, id: s.id), kind: .manga,
            name: s.metadata.title, authors: authors(s.booksMetadata.authors),
            illustrators: illustrators(s.booksMetadata.authors),
            cover: baseURL.appending(path: "api/v1/series/\(s.id)/thumbnail"), genres: s.metadata.genres,
            summary: Title.blurb(s.metadata.summary), rating: rating(s.metadata.tags),
            volumeCount: s.booksCount, total: s.metadata.totalBookCount.flatMap { $0 > 0 ? $0 : nil },
            status: status(s.metadata.status), language: Title.languageCode(s.metadata.language),
            ageRating: s.metadata.ageRating, readingDirection: readingDirection(s.metadata.readingDirection),
            added: s.created)
    }

    static func title(
        _ b: KomgaResponses.Book, series: KomgaResponses.Series?, source: SourceID, baseURL: URL
    )
        -> Title
    {
        let seriesIdentifier = SeriesID(source: source, id: b.seriesId)
        return Title(
            identifier: TitleID(source: source, id: b.id),
            kind: b.media.mediaProfile == "EPUB" ? .book : .manga,
            name: b.metadata.title,
            authors: authors(
                b.metadata.authors.isEmpty ? series?.booksMetadata.authors ?? [] : b.metadata.authors),
            series: SeriesReference(
                identifier: seriesIdentifier, name: b.seriesTitle, volume: b.metadata.numberSort),
            cover: baseURL.appending(path: "api/v1/books/\(b.id)/thumbnail"),
            genres: series?.metadata.genres ?? [],
            summary: Title.blurb(b.metadata.summary)
                ?? series.flatMap { Title.blurb($0.metadata.summary) },
            rating: series.flatMap { rating($0.metadata.tags) },
            scope: .pages(b.media.pagesCount),
            language: series.flatMap { Title.languageCode($0.metadata.language) },
            ageRating: series?.metadata.ageRating,
            publisher: series.flatMap { emptyIsNil($0.metadata.publisher) },
            readingDirection: readingDirection(series?.metadata.readingDirection), added: b.created,
            released: Title.releaseDate(b.metadata.releaseDate), size: b.sizeBytes,
            format: Title.format(b.media.mediaType))
    }

    static func readingState(_ f: KomgaResponses.ReadProgress, pages: Int) -> ReadingState {
        ReadingState(
            position: .page(f.page, from: pages), timestamp: f.readDate, device: emptyIsNil(f.deviceName),
            completed: f.completed)
    }

    /// komf's `score: 8` tag — ten points, here mapped to five stars. The origin
    /// is "Komga" because the tag does not say who gave the eight.
    static func rating(_ tags: [String]) -> Rating? {
        for tag in tags {
            let share = tag.split(separator: ":", maxSplits: 1)
            guard share.count == 2, share[0].trimmingCharacters(in: .whitespaces) == "score",
                let points = Double(share[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            return Rating(stars: points / 2, origin: "Komga")
        }
        return nil
    }

    static func status(_ text: String?) -> SeriesStatus? {
        switch text {
        case "ONGOING": return .ongoing
        case "ENDED": return .completed
        case "ABANDONED": return .cancelled
        case "HIATUS": return .paused
        default: return nil
        }
    }

    static func readingDirection(_ text: String?) -> ReadingDirection? {
        switch text {
        case "LEFT_TO_RIGHT": return .leftToRight
        case "RIGHT_TO_LEFT": return .rightToLeft
        case "VERTICAL", "WEBTOON": return .vertical
        default: return nil
        }
    }

    /// The authors: who writes. komf enters the same name as writer, penciller,
    /// inker, colorist, letterer and cover — and in Druspind Gugeis someone other than the writer
    /// draws; that person belongs to ``illustrators(_:)``, not here.
    /// If the server knows no writers, every name counts once.
    static func authors(_ list: [KomgaResponses.Author]) -> [String] {
        var seen = Set<String>()
        let writerNames = list.filter { $0.role == "writer" }
        return (writerNames.isEmpty ? list : writerNames).compactMap {
            seen.insert($0.name).inserted ? $0.name : nil
        }
    }

    /// Who draws, when they are not the same as those who write — for 9
    /// of 22 series (Druspind Gugeis: Gihousglo writes, Siari draws).
    static func illustrators(_ list: [KomgaResponses.Author]) -> [String] {
        let writerNames = Set(list.filter { $0.role == "writer" }.map(\.name))
        var seen = Set<String>()
        return list.filter { $0.role == "penciller" && !writerNames.contains($0.name) }
            .compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    private static func emptyIsNil(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
