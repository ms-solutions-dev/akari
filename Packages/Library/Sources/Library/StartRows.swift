import Foundation
import SourcesKit
import Synchronization

/// The three rows of the home page, computed from the shelf — "What now?" in
/// two seconds, offline.
extension Shelf {

    /// A started title with its state — the continue-reading row.
    public struct Reading: Sendable, Hashable, Identifiable {
        public let title: Title
        public let state: ReadingState
        public var id: TitleID { title.identifier }

        /// Public so that tests of other packages (the widget snapshot)
        /// can build a reading without setting up a whole shelf.
        public init(title: Title, state: ReadingState) {
            self.title = title
            self.state = state
        }
    }

    /// Precomputes the start rows — where the shelf is built, off the main
    /// thread. Otherwise Home computed them on first draw after every new shelf,
    /// "new on shelf" over all 36,000 titles (cold start: 160 ms on the main thread per
    /// shelf change, three changes in the first seconds).
    public func precompute() {
        _ = continueReading
        _ = stalled
        _ = asNext
        _ = newOnShelf
    }

    /// Everything started, youngest first — across all sources and kinds
    /// mixed, because the question is "I have ten minutes", not "which manga".
    public var continueReading: [Reading] {
        memo.fetch("weiterlesen") { continueReadingComputed }
    }

    private var continueReadingComputed: [Reading] {
        readingStates.compactMap { identifier, state -> Reading? in
            guard state.started, let title = title(identifier) else { return nil }
            return Reading(title: title, state: state)
        }
        .sorted { a, b in
            if a.state.timestamp != b.state.timestamp { return a.state.timestamp > b.state.timestamp }
            return a.title.name.localizedStandardCompare(b.title.name) == .orderedAscending
        }
    }

    /// How many readings Home shows per row: the hero's row a large card
    /// and three entries, the other row three — continue reading and continue listening are
    /// kept apart, and the hero is the youngest reading across both.
    public static let visibleWithHero = 4
    public static let visibleWithoutHero = 3

    /// What Home actually shows under continue reading **and** continue listening —
    /// the same rule by which Home builds its rows, in one place so that
    /// ``stalled`` cannot deviate from it.
    public var continueReadingVisible: [Reading] {
        let all = continueReading
        guard let hero = all.first else { return [] }
        let heroListens = hero.title.kind.isAudible
        let listening = all.filter { $0.title.kind.isAudible }
        let read = all.filter { !$0.title.kind.isAudible }
        let heroRow = Array((heroListens ? listening : read).prefix(Shelf.visibleWithHero))
        let others = Array((heroListens ? read : listening).prefix(Shelf.visibleWithoutHero))
        return heroRow + others
    }

    /// **Stalled — a field-of-view rule, no deadline:**
    /// started, not finished, and not among the readings Home shows. Whoever has
    /// five books open sees four; the fifth is out of sight, no matter since
    /// when. Sorted by progress — whoever was already far along is more likely to want to finish —
    /// and by recency when equal, the younger first.
    public var stalled: [Reading] {
        memo.fetch("liegengeblieben") { stalledComputed }
    }

    private var stalledComputed: [Reading] {
        let visible = Set(continueReadingVisible.map(\.id))
        return continueReading.filter { !visible.contains($0.id) }
            .sorted { a, b in
                if a.state.fraction != b.state.fraction { return a.state.fraction > b.state.fraction }
                return a.state.timestamp > b.state.timestamp
            }
    }

    /// The next volume of a series in which something was finished.
    public struct Next: Sendable, Hashable, Identifiable {
        public let title: Title
        /// Added in the last 30 days — "New · Volume 48".
        public let new: Bool
        /// When the last volume of the series was finished — the order.
        public let recentlyFinished: Date
        public var id: TitleID { title.identifier }
    }

    /// Per series with at least one finished volume the first unread volume
    /// behind it — also for book and audiobook series. A series in which a
    /// volume is currently open is missing: it already stands under continue reading. Sorted by
    /// most recently finished.
    public var asNext: [Next] {
        memo.fetch("alsNaechstes") { nextUpComputed }
    }

    private var nextUpComputed: [Next] {
        var result: [Next] = []
        for (_, volumes) in seriesWithVolumes {
            var lastNumber: Double = -.infinity
            var recentlyFinished: Date?
            var unresolved = false
            for volume in volumes {
                guard let state = readingStates[volume.identifier] else { continue }
                if state.completed {
                    lastNumber = max(lastNumber, volume.series?.volume ?? -.infinity)
                    recentlyFinished = max(recentlyFinished ?? .distantPast, state.timestamp)
                } else if state.started {
                    unresolved = true
                }
            }
            guard let recentlyFinished, !unresolved else { continue }
            guard
                let next = volumes.first(where: { volume in
                    guard let number = volume.series?.volume, number > lastNumber else { return false }
                    return readingStates[volume.identifier] == nil
                })
            else { continue }
            result.append(
                Next(
                    title: next, new: isNew(next.added), recentlyFinished: recentlyFinished))
        }
        return result.sorted { a, b in
            if a.recentlyFinished != b.recentlyFinished { return a.recentlyFinished > b.recentlyFinished }
            return a.title.name.localizedStandardCompare(b.title.name) == .orderedAscending
        }
    }

    /// What was added in the last 30 days — bundled by series.
    public enum NewArrival: Sendable, Hashable, Identifiable {
        /// A series with new volumes beyond the reading state, or an entirely new one
        /// that nobody has started. `newVolumes` are the new ones, by number.
        case series(Series, newVolumes: [Title])
        /// A book or audiobook without series, not yet started.
        case title(Title)

        public var id: String {
            switch self {
            case .series(let s, _): return s.identifier.description
            case .title(let t): return t.identifier.description
            }
        }
        public var name: String {
            switch self {
            case .series(let s, _): return s.name
            case .title(let t): return t.name
            }
        }
        public var kind: Kind {
            switch self {
            case .series(let s, _): return s.kind
            case .title(let t): return t.kind
            }
        }
        public var cover: URL? {
            switch self {
            case .series(let s, let newOnes): return newOnes.first?.cover ?? s.cover
            case .title(let t): return t.cover
            }
        }
        public var added: Date? {
            switch self {
            case .series(_, let newOnes): return newOnes.compactMap(\.added).max()
            case .title(let t): return t.added
            }
        }
    }

    /// New on shelf: new series and books that nobody has started yet, plus
    /// series with new volumes beyond the reading state — bundled, youngest
    /// first, at most twelve. Twelve new Bokraisik Branbros volumes are one entry.
    public var newOnShelf: [NewArrival] {
        memo.fetch("neuImRegal") { newOnShelfComputed }
    }

    private var newOnShelfComputed: [NewArrival] {
        var result: [NewArrival] = []
        var inSeries = Set<TitleID>()
        for (identifier, volumes) in seriesWithVolumes {
            // Without a new volume the series can contribute nothing — and neither can its volumes
            // as single titles, because none is new. Previously all volumes of every series were
            // copied.
            guard volumes.contains(where: { isNew($0.added) }), let series = seriesIndex[identifier] else {
                continue
            }
            inSeries.formUnion(volumes.map(\.identifier))
            let readUpTo = volumes.compactMap { volume -> Double? in
                readingStates[volume.identifier] != nil ? volume.series?.volume : nil
            }
            .max()
            let newOnes = volumes.filter { volume in
                guard isNew(volume.added), readingStates[volume.identifier] == nil else { return false }
                guard let readUpTo else { return true }
                return (volume.series?.volume ?? -.infinity) > readUpTo
            }
            if !newOnes.isEmpty { result.append(.series(series, newVolumes: newOnes)) }
        }
        // **Single titles only as light keys**: twelve are shown, but on Grimmory's shelf
        // tens of thousands are new after an import. Building an entry with a full `Title`
        // copy for each one and sorting everything cost
        // 165 ms in the release build on the Mac (35,000 fresh titles) and showed up in the hangs
        // behind the open reader. Now: date, name, identifier — the entries only for
        // the twelve that remain.
        var singles: [(date: Date, name: String, identifier: TitleID)] = []
        for (k, title) in titleIndex where isNew(title.added) && !inSeries.contains(k) {
            guard readingStates[k] == nil, let date = title.added else { continue }
            singles.append((date, title.name, k))
        }
        // Series are few; their key once per entry, not per comparison — `added`
        // of a series copies all its new volumes (a 650 ms hang; the same comparison sat in the
        // stack of that day's crash).
        let bookSeriesList = result.map { ($0.added ?? .distantPast, $0.name, $0) }
        func before(_ a: (Date, String), _ b: (Date, String)) -> Bool {
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1.localizedStandardCompare(b.1) == .orderedAscending
        }
        let bestSeries = bookSeriesList.sorted { before(($0.0, $0.1), ($1.0, $1.1)) }.prefix(12)
        let bestSingles = singles.sorted { before(($0.date, $0.name), ($1.date, $1.name)) }.prefix(12)
        let combined: [(Date, String, () -> NewArrival?)] =
            bestSeries.map { r in (r.0, r.1, { r.2 }) }
            + bestSingles.map { e in (e.date, e.name, { titleIndex[e.identifier].map(NewArrival.title) }) }
        return combined.sorted { before(($0.0, $0.1), ($1.0, $1.1)) }.prefix(12).compactMap { $0.2() }
    }

    // MARK: - Series detail

    /// "46 read · Volume 47 · p. 63/205" — what the series detail shows above the volumes,
    /// and the volume behind the primary button.
    public struct SeriesState: Sendable, Hashable {
        public let read: Int
        /// How many volumes the server knows — also those the extract does not bring.
        public let total: Int
        /// The volume that is next: the open one, otherwise the first unread
        /// behind the last read one; `nil` if everything is read.
        public let current: Title?
        public let state: ReadingState?

        public var completed: Bool { current == nil && read > 0 }
        public var fraction: Double { total > 0 ? Double(read) / Double(total) : 0 }
    }

    public func seriesState(_ identifier: SeriesID) -> SeriesState {
        Shelf.seriesState(
            volumes: volumes(identifier), volumeCount: seriesIndex[identifier]?.volumeCount,
            state: { readingStates[$0] })
    }

    /// The state of a series from its volumes — separate so that the ``LibraryService`` can also
    /// compute it from the catalog when the shelf holds only the core.
    public static func seriesState(
        volumes: [Title], volumeCount: Int?, state: (TitleID) -> ReadingState?
    ) -> SeriesState {
        let total = max(volumeCount ?? 0, volumes.count)
        let read = volumes.filter { state($0.identifier)?.completed == true }.count
        // The open volume with the youngest state wins — whoever reads two volumes at the same
        // time means the one held last.
        let openVolumes = volumes.compactMap { volume -> (Title, ReadingState)? in
            guard let s = state(volume.identifier), s.started else { return nil }
            return (volume, s)
        }
        if let (volume, s) = openVolumes.max(by: { $0.1.timestamp < $1.1.timestamp }) {
            return SeriesState(read: read, total: total, current: volume, state: s)
        }
        let lastRead = volumes.lastIndex { state($0.identifier)?.completed == true }
        let from = lastRead.map { $0 + 1 } ?? 0
        let next = volumes[from...].first { state($0.identifier)?.completed != true }
        return SeriesState(read: read, total: total, current: next, state: nil)
    }

    // MARK: - Helpers

    /// All series with their volumes — also those for which no `Series` object came
    /// (Audiobookshelf names the series only on the title).
    private var seriesWithVolumes: [(SeriesID, [Title])] {
        volumeIndex.map { ($0.key, $0.value) }
    }

    func isNew(_ date: Date?) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < Shelf.newArrivalWindow
    }
}

/// What a ``Shelf`` derives from itself and is expensive — the rows of the home page —,
/// computed once per shelf and remembered.
///
/// **Why**: with 24,000 titles Home sorted over the whole shelf on every pass (new on
/// shelf, up next), and the widget watcher twice per second while listening. A shelf is
/// a value and never changes; a new state is a new shelf with an empty memo. For
/// equality and hash the memo does not count.
public final class ShelfNote: @unchecked Sendable, Hashable {

    private let values = Mutex<[String: any Sendable]>([:])

    public init() {}

    /// Whether a value is remembered — for tests that check what was precomputed.
    func holds(_ lookupKey: String) -> Bool {
        values.withLock { $0[lookupKey] != nil }
    }

    func fetch<Value: Sendable>(_ lookupKey: String, _ compute: () -> Value) -> Value {
        if let saved = values.withLock({ $0[lookupKey] }) as? Value { return saved }
        let new = compute()
        values.withLock { $0[lookupKey] = new }
        return new
    }

    /// Takes over a remembered value from the memo of the previous shelf — if the change does not
    /// touch it.
    func adopt(_ lookupKey: String, from old: ShelfNote) {
        guard let value = old.values.withLock({ $0[lookupKey] }) else { return }
        values.withLock { $0[lookupKey] = value }
    }

    public static func == (_: ShelfNote, _: ShelfNote) -> Bool { true }
    public func hash(into _: inout Hasher) {}
}
