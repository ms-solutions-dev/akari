import Foundation
import SourcesKit

/// What is missing in a series — computed from the volume numbers on the shelf and, if the
/// server knows it, the length of the series.
///
/// **Only whole numbers count.** A volume 2.5 is a special volume between two and
/// three (Komga, Grimmory "Deswutgou 2.2"); it fills no slot and tears no gap.
/// Volume 0 (prequel) likewise — counting starts at 1. Without a whole number from 1 on
/// there is no statement: ``init(numbers:total:)`` returns `nil`, and the row is omitted.
///
/// **The length from the server only if it fits the volumes.** Grimmory writes
/// Goodreads' `seriesTotal` onto every book, and that is often noise: "Miakus" carries 2, 3
/// and 9 on volumes 6–10, "Skeitau" 3 on volume 5, "Hei prot Faskek" 6 with
/// seven volumes. A length below the largest number on the
/// shelf cannot be right — it is discarded (``total`` stays `nil`), and the
/// gaps end at the largest number. A length above it is believed: it is the
/// only source for "volumes 7–38 missing" for a series of which three volumes are present.
/// What the rule does not catch: `11` appears with six trilogies (Spoukre me Kloulen, Girun
/// Problou, Penstu Skaceind …) — those are suspects for a manual check;
/// the app shows "volumes 4–11 missing" until Grimmory is corrected. A rule like "11
/// is always wrong" would stand in the way of a real eleven-volume series.
public struct SeriesGaps: Sendable, Hashable {

    /// The missing whole numbers, ascending.
    public let missing: [Int]
    /// The largest whole number on the shelf.
    public let highest: Int
    /// The length of the series — only if the server knows it and it fits the volumes.
    public let total: Int?

    public var complete: Bool { missing.isEmpty }
    public var count: Int { missing.count }

    /// The missing numbers as ranges: 3, 5, 7…38 — the UI prints from them
    /// "volumes 3, 5 and 7–38 missing".
    public var areas: [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for n in missing {
            if let last = result.last, last.upperBound + 1 == n {
                result[result.count - 1] = last.lowerBound...n
            } else {
                result.append(n...n)
            }
        }
        return result
    }

    /// - Parameter numbers: The volume numbers on the shelf as the servers deliver them —
    ///   fractions allowed, order irrelevant.
    /// - Parameter total: The length of the series from the server, if it names one.
    public init?(numbers: [Double], total: Int?) {
        let wholeNumbers = Set(
            numbers.compactMap { n -> Int? in
                guard n >= 1, n == n.rounded(), n < Double(Int.max) else { return nil }
                return Int(n)
            })
        guard let highest = wholeNumbers.max() else { return nil }
        let length = total.flatMap { $0 >= highest ? $0 : nil }
        self.highest = highest
        self.total = length
        self.missing = (1...(length ?? highest)).filter { !wholeNumbers.contains($0) }
    }
}

extension Shelf {
    /// What is missing in a series — `nil` if no volume carries a whole number.
    public func gaps(_ series: SeriesID) -> SeriesGaps? {
        SeriesGaps(
            numbers: volumes(series).compactMap { $0.series?.volume }, total: seriesIndex[series]?.total)
    }

    /// Whether an entry is a series with a gap — the filter "series with gaps"; a
    /// title never is one.
    func hasGaps(_ entry: Item) -> Bool {
        guard case .series(let s) = entry, let l = gaps(s.identifier) else { return false }
        return !l.complete
    }
}
