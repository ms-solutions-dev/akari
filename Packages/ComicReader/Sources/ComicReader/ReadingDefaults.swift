import Foundation
import SourcesKit

/// What the reader remembers - per series and as default, in `UserDefaults`.
///
/// **Reading direction: series -> server -> app default.** What the user set for a series
/// beats everything; then what the server carries on the series; then
/// the app default - and that is right-to-left, because all 21 series in the library are
/// manga and Komga set the direction for 0 of 21.
/// The default itself can be switched, for whoever's shelf is Western.
///
/// **Double spread per series:** on until someone switches it off - on iPad in landscape
/// it is what an opened volume is.
///
/// **Webtoon width per series:** how far the user pinched the strip
/// together or apart with two fingers, between 25 and 200 %.
public struct ReadingDefaults: @unchecked Sendable {

    public static let defaultDirectionKey = "leser.vorgabe.richtung"

    private let persistence: UserDefaults

    public init(persistence: UserDefaults = .standard) {
        self.persistence = persistence
    }

    // MARK: - Direction

    /// The app default - right-to-left until someone changes it.
    public var defaultDirection: ReadingDirection {
        persistence.string(forKey: ReadingDefaults.defaultDirectionKey).flatMap(ReadingDirection.init)
            ?? .rightToLeft
    }

    public func set(defaultDirection direction: ReadingDirection) {
        persistence.set(direction.rawValue, forKey: ReadingDefaults.defaultDirectionKey)
    }

    /// What the user chose for this series - `nil` if nothing.
    public func direction(series: String) -> ReadingDirection? {
        persistence.string(forKey: "leser.richtung." + series).flatMap(ReadingDirection.init)
    }

    /// Sets or clears (`nil`) the per-series choice.
    public func set(direction: ReadingDirection?, series: String) {
        if let direction {
            persistence.set(direction.rawValue, forKey: "leser.richtung." + series)
        } else {
            persistence.removeObject(forKey: "leser.richtung." + series)
        }
    }

    /// The resolved direction: series -> server -> default. Vertical means webtoon:
    /// the reader scrolls the pages as one strip from top to bottom.
    public func direction(series: String?, server: ReadingDirection?) -> ReadingDirection {
        series.flatMap { direction(series: $0) } ?? server ?? defaultDirection
    }

    // MARK: - Double spread

    public func doubleSpread(series: String?) -> Bool {
        guard let series, persistence.object(forKey: "leser.doppelseite." + series) != nil else {
            return true
        }
        return persistence.bool(forKey: "leser.doppelseite." + series)
    }

    public func set(doubleSpread: Bool, series: String) {
        persistence.set(doubleSpread, forKey: "leser.doppelseite." + series)
    }

    // MARK: - Webtoon width

    /// How wide the webtoon strip stands, as a fraction of the screen width.
    ///
    /// Down to 25 % ("see more"); before, 50 %. Only viable with the strip made of fixed
    /// positions (``StripLayout``): at a quarter of the width four times as many
    /// pages stand on screen, the LazyVStack would have estimated even more heights.
    public static let widths: ClosedRange<Double> = 0.25...2

    /// The webtoon strip width per series - 1 means screen width.
    public func width(series: String?) -> Double {
        guard let series, let value = persistence.object(forKey: "leser.breite." + series) as? Double else {
            return 1
        }
        return min(max(value, ReadingDefaults.widths.lowerBound), ReadingDefaults.widths.upperBound)
    }

    public func set(width: Double, series: String) {
        if width == 1 {
            persistence.removeObject(forKey: "leser.breite." + series)
        } else {
            persistence.set(width, forKey: "leser.breite." + series)
        }
    }
}
