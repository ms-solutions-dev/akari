import Foundation
import Library
import SourcesKit
import SwiftUI

/// Sentences with numbers, from the app's catalog, filled with `String(format:)`.
///
/// `Text(app:)` has no placeholders; for "Page 63 of 205" the detour through `String` is
/// needed. The key is written as a literal so the key checker sees it.
enum Phrase {
    static func from(_ lookupKey: String, _ values: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(lookupKey), bundle: .main)
        return String(format: template, locale: .current, arguments: values)
    }
}

extension Kind {
    /// "Manga" / "Book" / "Audiobook": the badge on the cover.
    var lookupKey: String {
        switch self {
        case .manga: "kind.manga"
        case .book: "kind.book"
        case .audiobook: "kind.audiobook"
        case .podcast: "kind.podcast"
        }
    }

    /// "Continue reading"; for audiobooks and podcasts "Continue listening", since nobody reads an audiobook.
    var continueKey: String { isAudible ? "start.continueListening" : "start.continueReading" }

    /// "Read" / "Listen": the primary button, which never changes its text.
    var readingKey: String { isAudible ? "title.listen" : "title.read" }

    /// "Read again" / "Listen again": for completed items, in the title and the series
    /// detail alike.
    var againKey: String { isAudible ? "series.listenAgain" : "series.again" }

    /// "Read" / "Heard": nobody reads an audiobook.
    var isReadKey: String { isAudible ? "readStatus.heard" : "readStatus.read" }
    var asReadKey: String { isAudible ? "readStatus.asHeard" : "readStatus.asRead" }
    var asUnreadKey: String {
        isAudible ? "readStatus.asUnheard" : "readStatus.asUnread"
    }

    /// "Open" for unread items; for audiobooks and podcasts "Listen".
    var openKey: String { isAudible ? "menu.listen" : "menu.open" }

    /// "Manga" / "Books" / "Audiobooks": the field in the segment.
    var segmentKey: String {
        switch self {
        case .manga: "segment.manga"
        case .book: "segment.buch"
        case .audiobook: "segment.hoerbuch"
        case .podcast: "segment.podcast"
        }
    }
}

extension Sorting {
    var lookupKey: String {
        switch self {
        case .recentlyRead: "sorting.recentlyRead"
        case .recentlyAdded: "sorting.recentlyAdded"
        case .title: "sorting.alphabetical"
        case .author: "sorting.author"
        case .bookSeries: "sorting.bookSeries"
        case .rating: "sorting.rating"
        }
    }
}

extension SeriesStatus {
    var lookupKey: String {
        switch self {
        case .ongoing: "series.status.ongoing"
        case .completed: "series.status.completed"
        case .cancelled: "series.status.cancelled"
        case .paused: "series.status.paused"
        }
    }
}

extension Filter {
    var lookupKey: String {
        switch self {
        case .unread: "filter.unread"
        case .started: "filter.started"
        case .read: "filter.read"
        case .keep: "filter.keep"
        case .saved: "filter.saved"
        }
    }
}

/// How a title is named where it appears: the one rule for tile, row and detail. For manga
/// the volume number is the main text and the Komga file name is never visible.
///
/// - Outside the series (Start, "All" grid, search): name = series name, the secondary
///   line begins with "Volume 1".
/// - Inside the series (series detail, "From the same series"): name = "Volume 1".
/// - Manga without number, books, audiobooks: the name as the server gives it; Grimmory and
///   Audiobookshelf carry real titles.
struct Display {
    let name: String
    /// "Volume 1" if the number is not already in the name, placed before the state.
    let volume: String?

    init(_ title: Title, inBookSeries: Bool) {
        if title.kind == .manga, let series = title.series, let number = series.volume {
            name = inBookSeries ? Formats.volume(number) : series.name
            volume = inBookSeries ? nil : Formats.volume(number)
        } else {
            name = title.name
            volume = nil
        }
    }

    /// The secondary line: "Volume 1 · p. 8/227", "Volume 1", "p. 8/227", or the stars with
    /// the author ("4.2 ★ · A. C. Doyle"), whichever is available. A state comes first: whoever
    /// is reading wants to know where they are, not what others thought. The stars come
    /// first because a 110 pt tile cuts off the end: "3,..." says nothing, "...Pratch..."
    /// still says the name.
    func secondaryLine(_ remainder: String?, author: String?, stars: Rating? = nil) -> String? {
        let share = [volume, remainder].compactMap { $0 }
        if !share.isEmpty { return share.joined(separator: " · ") }
        let rest = [stars.map(Formats.stars), author].compactMap { $0 }
        return rest.isEmpty ? nil : rest.joined(separator: " · ")
    }
}

/// The UI's numbers, formed in one place: "p. 63/205", "62 %", "3 h 12 min left",
/// "Volume 4.5".
enum Formats {

    /// The state, short, for secondary lines: "p. 63/205", "62 %", "3 h 12 min left".
    static func short(_ state: ReadingState) -> String {
        switch state.position {
        case .page(let n, let from): return Phrase.from("progress.page.short", n, from)
        case .second(let s, let from):
            return Phrase.from("progress.remainder", duration(max(from - s, 0), short: true))
        case .position, .fraction: return percent(state.fraction)
        }
    }

    /// "2 %", and "1 %" instead of "0 %" for a book that was just opened: zero would mean
    /// not started, and that never appears in the continue-reading row.
    static func percent(_ fraction: Double) -> String {
        (fraction > 0 ? max(fraction, 0.01) : 0).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The state written out, for the large card: "Page 63 of 205".
    static func long(_ state: ReadingState) -> String {
        switch state.position {
        case .page(let n, let from): return Phrase.from("progress.page.long", n, from)
        case .second(let s, let from):
            return Phrase.from("progress.remainder", duration(max(from - s, 0), short: false))
        case .position, .fraction: return percent(state.fraction)
        }
    }

    /// "205 pages" / "9 h 12 min"; the row is absent for `unknown`.
    static func scope(_ scope: Scope) -> String? {
        switch scope {
        case .pages(let n): return Phrase.from("scope.pages", n)
        case .duration(let d): return duration(d, short: false)
        case .unknown: return nil
        }
    }

    /// "10 h 30 min" / "12 min": one format for row, tile and player (before there were
    /// three spellings of the same number).
    static func duration(_ seconds: TimeInterval, short: Bool) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        if hours > 0 { return Phrase.from("player.hoursMinutes", hours, minutes % 60) }
        return Phrase.from("player.minutes", minutes)
    }

    /// "47" or "4.5": volume numbers are decimals, but rarely.
    static func volumeNumber(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "Volume 47"; for podcasts "Episode 47", since nobody calls an episode a volume.
    static func volume(_ number: Double, kind: Kind = .book) -> String {
        Phrase.from(kind == .podcast ? "episode.number" : "volume.number", volumeNumber(number))
    }

    /// For a podcast the volume is called "Episode": the same key with suffix `.folge`, so
    /// the sentence form stays per language in the catalog and not in code ("50 volumes" ->
    /// "50 episodes", "Continue listening at volume 9" -> "at episode 9").
    static func lookupKey(_ base: String, kind: Kind?) -> String {
        kind == .podcast ? base + ".folge" : base
    }

    /// "yesterday", "3 days ago": for "New on the shelf".
    static func her(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    static func integer(_ n: Int) -> String {
        n.formatted(.number)
    }

    /// "4.2 ★": the stars, short, for secondary lines and headers.
    static func stars(_ b: Rating) -> String {
        b.stars.formatted(.number.precision(.fractionLength(1))) + " ★"
    }

    /// "2012": the year of a date.
    static func year(_ date: Date) -> String {
        String(Calendar(identifier: .gregorian).component(.year, from: date))
    }

    /// "Volume 3 of 12" if the server knows the length, otherwise "Volume 3"; podcasts "Episode".
    static func volume(_ number: Double, from total: Int?, kind: Kind = .book) -> String {
        guard let total, total > 0 else { return volume(number, kind: kind) }
        return Phrase.from(kind == .podcast ? "episode.from" : "volume.from", volumeNumber(number), total)
    }

    /// The gap line in the series header: "Volumes 3 and 5 missing", "Volumes 7-38 missing (32)",
    /// "complete · 6 of 6", and `nil` if nothing is missing but nobody knows the length:
    /// "complete" would then be claimed, not known. The number in parentheses appears only
    /// when a range is involved; for "3 and 5" one can see it.
    static func gaps(_ l: SeriesGaps) -> String? {
        if l.complete {
            return l.total.map { Phrase.from("series.gaps.complete", $0, $0) }
        }
        var phrase = Phrase.from(l.count == 1 ? "series.gaps.one" : "series.gaps.multiple", gapList(l))
        if l.areas.contains(where: { $0.count > 1 }) { phrase += " (\(integer(l.count)))" }
        return phrase
    }

    /// "3, 5 and 7-38": the ranges as an enumeration in the device's language.
    static func gapList(_ l: SeriesGaps) -> String {
        l.areas.map(area).formatted(.list(type: .and))
    }

    /// "7-38" or "3": a range of missing numbers, with an en dash.
    static func area(_ b: ClosedRange<Int>) -> String {
        b.count == 1 ? String(b.lowerBound) : "\(b.lowerBound)–\(b.upperBound)"
    }
}
