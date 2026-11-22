import Foundation
import SourcesKit

/// The sum of the sources as one value: everything the screens ask, without
/// any of them knowing which server answered.
///
/// **A value, not a service.** The shelf is built from the extracts and
/// then only computes — kinds, counters, genres, continue reading, up next, new on shelf.
/// It knows no source by name, only its identifier and its capabilities. Whoever
/// tests it gives it three extracts and reads off; no network, no clock except the one
/// one gives it.
///
/// **What an entry in the grid is is decided by the kind — and the user:** manga
/// stand as a series in the grid, their volumes in the series detail — 21 series instead of 599
/// tiles. Books and audiobooks stand as titles, unless their kind is in
/// ``bookSeriesList`` — then a series from two volumes on likewise stands as a series (586 of
/// 854 books belong to 222 series; requested: "a collection view
/// over the books"). What belongs to no series always stands as a title.
///
/// **A child profile sees a smaller shelf**: with ``maxAge`` series and titles
/// whose age rating lies above it drop out when building — and the
/// volumes of a blocked series with it, even if the volume itself carries none. Without
/// a rating a title counts as free; the server rule (Komga per
/// account) remains the first barrier, this is the second. Filtering happens once
/// at the entrance, so that search, continue reading, genres and counters need not know anything of it.
public struct Shelf: Sendable, Hashable {

    public let extracts: [LibraryExtract]
    /// The limit of the child profile — `nil` means: everything.
    public let maxAge: Int?
    public let capabilities: [SourceID: Capabilities]
    /// What is held on the device — the "Keep" filter. Filled by the offline store.
    public let keep: Set<TitleID>
    /// The saved list in its order — the row on Home, the filter
    /// "Saved". Filled by the `LibraryService` from the ``SavedList``.
    public let saved: [SaveTarget]
    /// For which kinds series stand as a series in the grid — manga always, books and
    /// audiobooks by choice (default: both).
    public let bookSeriesList: Set<Kind>
    /// The clock for "new" — a fixed one in tests, the real one in operation.
    public let now: Date

    /// How long something is "new".
    public static let newArrivalWindow: TimeInterval = 30 * 86_400
    /// Books and audiobooks bundled until someone opts out. Podcasts are not
    /// here because they are not selectable: a podcast is always the folder of its episodes.
    public static let bookSeriesDefault: Set<Kind> = [.book, .audiobook]

    let titleIndex: [TitleID: Title]
    let seriesIndex: [SeriesID: Series]
    /// The kinds that occur — counted once when building. Previously a computed value over
    /// all titles, which the library read six times per pass (35,000 titles).
    public let kinds: [Kind]
    let volumeIndex: [SeriesID: [Title]]
    public let readingStates: [TitleID: ReadingState]
    /// Remembered derivations — new per shelf, do not count for equality.
    let memo = ShelfNote()

    public init(
        extracts: [LibraryExtract], capabilities: [SourceID: Capabilities] = [:],
        keep: Set<TitleID> = [], saved: [SaveTarget] = [],
        bookSeriesList: Set<Kind> = Shelf.bookSeriesDefault,
        maxAge: Int? = nil, now: Date = Date()
    ) {
        let extracts = maxAge.map { limit in extracts.map { $0.withinLimit(until: limit) } } ?? extracts
        self.extracts = extracts
        self.maxAge = maxAge
        self.capabilities = capabilities
        self.keep = keep
        self.saved = saved
        self.bookSeriesList = bookSeriesList
        self.now = now
        var title: [TitleID: Title] = [:]
        var seriesList: [SeriesID: Series] = [:]
        var volumes: [SeriesID: [Title]] = [:]
        var states: [TitleID: ReadingState] = [:]
        for extract in extracts {
            for t in extract.title {
                title[t.identifier] = t
                if let reference = t.series { volumes[reference.identifier, default: []].append(t) }
            }
            for s in extract.seriesList { seriesList[s.identifier] = s }
            states.merge(extract.readingStates) { _, new in new }
        }
        for (identifier, list) in volumes { volumes[identifier] = list.sorted(by: Shelf.nachBand) }
        self.titleIndex = title
        self.seriesIndex = seriesList
        self.volumeIndex = volumes
        self.readingStates = states
        let present = Set(title.values.map(\.kind))
        self.kinds = Kind.allCases.filter { present.contains($0) }
    }

    /// The same shelf with other fields but the finished lookups — for the
    /// changes that touch no title and no series. The full build costs
    /// barely 2 ms at 1,700 titles and ran every two seconds while reading.
    private init(
        copying: Shelf, extracts: [LibraryExtract]? = nil, keep: Set<TitleID>? = nil,
        saved: [SaveTarget]? = nil, readingStates: [TitleID: ReadingState]? = nil
    ) {
        self.extracts = extracts ?? copying.extracts
        self.maxAge = copying.maxAge
        self.capabilities = copying.capabilities
        self.keep = keep ?? copying.keep
        self.saved = saved ?? copying.saved
        self.bookSeriesList = copying.bookSeriesList
        self.now = copying.now
        self.titleIndex = copying.titleIndex
        self.kinds = copying.kinds
        self.seriesIndex = copying.seriesIndex
        self.volumeIndex = copying.volumeIndex
        self.readingStates = readingStates ?? copying.readingStates
    }

    public static let empty = Shelf(extracts: [])

    // MARK: - Lookup

    public var empty: Bool { titleIndex.isEmpty }
    public var allTitles: [Title] { extracts.flatMap(\.title) }
    public var allSeries: [Series] { extracts.flatMap(\.seriesList) }
    /// The oldest state among the extracts — offline the number in the banner.
    public var state: Date? { extracts.map(\.state).min() }
    /// The state of a source — the number in the outage banner when only it is missing:
    /// "Manga: unreachable · as of yesterday 21:14".
    public func state(_ source: SourceID) -> Date? { extracts.first { $0.source == source }?.state }

    public func title(_ identifier: TitleID) -> Title? { titleIndex[identifier] }
    public func series(_ identifier: SeriesID) -> Series? { seriesIndex[identifier] }
    public func readingState(_ identifier: TitleID) -> ReadingState? { readingStates[identifier] }
    public func capabilities(_ identifier: TitleID) -> Capabilities { capabilities[identifier.source] ?? [] }

    /// The volumes of a series, by number; without number at the end, by name.
    public func volumes(_ series: SeriesID) -> [Title] { volumeIndex[series] ?? [] }

    static func nachBand(_ a: Title, _ b: Title) -> Bool {
        switch (a.series?.volume, b.series?.volume) {
        case (let x?, let y?) where x != y: return x < y
        case (nil, .some): return false
        case (.some, nil): return true
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Kinds and counters

    /// The kinds a source delivers — in the order of the segment. A
    /// kind without titles is missing; it is not empty.

    /// "21 series · 599 volumes" for manga, "930 books" for books.
    public struct Counter: Sendable, Hashable {
        public let seriesList: Int
        public let title: Int
    }

    public func counter(_ kind: Kind) -> Counter {
        let title = titleIndex.values.filter { $0.kind == kind }
        let seriesList = Set(title.compactMap { $0.series?.identifier })
        return Counter(seriesList: seriesList.count, title: title.count)
    }

    // MARK: - Entries

    /// A slot in the grid — a series or a title, depending on the kind.
    public enum Item: Sendable, Hashable, Identifiable {
        case series(Series)
        case title(Title)

        public var id: String {
            switch self {
            case .series(let s): return s.identifier.description
            case .title(let t): return t.identifier.description
            }
        }
        public var name: String {
            switch self {
            case .series(let s): return s.name
            case .title(let t): return t.name
            }
        }
        public var kind: Kind {
            switch self {
            case .series(let s): return s.kind
            case .title(let t): return t.kind
            }
        }
        public var authors: [String] {
            switch self {
            case .series(let s): return s.authors
            case .title(let t): return t.authors
            }
        }
        public var cover: URL? {
            switch self {
            case .series(let s): return s.cover
            case .title(let t): return t.cover
            }
        }
        public var genres: [String] {
            switch self {
            case .series(let s): return s.genres
            case .title(let t): return t.genres
            }
        }
        public var source: SourceID {
            switch self {
            case .series(let s): return s.identifier.source
            case .title(let t): return t.identifier.source
            }
        }
        /// The stars — on the series from the server, on the title its own.
        public var rating: Rating? {
            switch self {
            case .series(let s): return s.rating
            case .title(let t): return t.rating
            }
        }
    }

    /// A cover with what the image loader needs: the source for headers and
    /// transport, the kind for the placeholder.
    public struct CoverReference: Sendable, Hashable {
        /// `nil` if the server has none — the card then shows the placeholder.
        public let address: URL?
        public let source: SourceID
        public let kind: Kind

        public init(address: URL?, source: SourceID, kind: Kind) {
            self.address = address
            self.source = source
            self.kind = kind
        }
    }

    /// All entries of a kind (or all), unordered — the base set for grid,
    /// genres and counters.
    public func entries(_ kind: Kind? = nil) -> [Item] {
        var seriesSeen = Set<SeriesID>()
        var result: [Item] = []
        for extract in extracts {
            for t in extract.title where kind == nil || t.kind == kind {
                if let reference = t.series, let series = seriesIndex[reference.identifier],
                    bundled(t.kind, series)
                {
                    if seriesSeen.insert(series.identifier).inserted { result.append(.series(series)) }
                } else {
                    result.append(.title(t))
                }
            }
        }
        return result
    }

    /// Manga and podcasts always; books and audiobooks if the kind is chosen and the
    /// series has at least two volumes on the shelf — a folder for one book is not worth it.
    private func bundled(_ kind: Kind, _ series: Series) -> Bool {
        if kind == .manga || kind == .podcast { return true }
        return bookSeriesList.contains(kind) && (volumeIndex[series.identifier]?.count ?? 0) >= 2
    }

    public func with(bookSeriesList: Set<Kind>) -> Shelf {
        Shelf(
            extracts: extracts, capabilities: capabilities, keep: keep, saved: saved,
            bookSeriesList: bookSeriesList, maxAge: maxAge,
            now: now)
    }

    // MARK: - Collections

    /// All collections of the signed-in sources, by name.
    public var collections: [TitleCollection] {
        extracts.flatMap(\.collections).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func collection(_ identifier: CollectionID) -> TitleCollection? {
        extracts.first { $0.source == identifier.source }?.collections.first { $0.identifier == identifier }
    }

    /// The entries of a collection as the grid knows them — for an ordered one
    /// in the server's order; a volume whose series is bundled stands
    /// as a volume, not as a series: in a reading list the volume counts.
    public func entries(in collection: TitleCollection) -> [Item] {
        var seen = Set<String>()
        return collection.entries.compactMap { target -> Item? in
            let e: Item?
            switch target {
            case .title(let k): e = titleIndex[k].map { .title($0) }
            case .series(let k): e = seriesIndex[k].map { .series($0) }
            }
            guard let e, seen.insert(e.id).inserted else { return nil }
            return e
        }
    }

    /// The three youngest covers of a collection — for the card in the row.
    public func cover(for collection: TitleCollection) -> [CoverReference] {
        entries(in: collection).prefix(3).map {
            CoverReference(address: $0.cover, source: $0.source, kind: $0.kind)
        }
    }

    /// Which collections contain an entry — a title also via its series.
    public func collections(with entry: Item) -> [TitleCollection] {
        collections.filter { s in
            switch entry {
            case .title(let t): return s.contains(.title(t.identifier))
            case .series(let ser): return s.contains(.series(ser.identifier))
            }
        }
    }

    /// The same shelf with a changed collection — optimistic writing.
    public func with(_ collection: TitleCollection) -> Shelf {
        let new = extracts.map { extract -> LibraryExtract in
            guard extract.source == collection.identifier.source else { return extract }
            var list = extract.collections
            if let i = list.firstIndex(where: { $0.identifier == collection.identifier }) {
                list[i] = collection
            } else {
                list.append(collection)
            }
            return extract.with(collections: list)
        }
        return Shelf(
            extracts: new, capabilities: capabilities, keep: keep, saved: saved,
            bookSeriesList: bookSeriesList,
            maxAge: maxAge, now: now)
    }

    /// When an entry was last read — for a series the youngest volume.
    public func recentlyRead(_ entry: Item) -> Date? {
        switch entry {
        case .title(let t): return readingStates[t.identifier]?.timestamp
        case .series(let s):
            return volumes(s.identifier).compactMap { readingStates[$0.identifier]?.timestamp }.max()
        }
    }

    /// The youngest first, without date last, ties by name — **the date once per
    /// entry**: for a series ``added(_:)``
    /// and ``recentlyRead(_:)`` go over all volumes, and called in the comparison that meant
    /// n·log n such passes — hangs when opening the library.
    ///
    /// Indices are sorted, **not the entries**: an entry carries a whole title,
    /// and every swap while sorting would have copied it — measured 40 % slower than before.
    static func nachDatum(_ list: [Item], _ date: (Item) -> Date?) -> [Item] {
        let data = list.map(date)
        let names = list.map(\.name)
        return list.indices.sorted { a, b in
            switch (data[a], data[b]) {
            case (let x?, let y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return names[a].localizedStandardCompare(names[b]) == .orderedAscending
            }
        }
        .map { list[$0] }
    }

    public func added(_ entry: Item) -> Date? {
        switch entry {
        case .title(let t): return t.added
        case .series(let s): return s.added ?? volumes(s.identifier).compactMap(\.added).max()
        }
    }

    /// The read status of an entry — for a series computed from all volumes.
    public func status(_ entry: Item) -> ReadStatus {
        switch entry {
        case .title(let t):
            return ReadStatus(readingStates[t.identifier])
        case .series(let s):
            let states = volumes(s.identifier).map { ReadStatus(readingStates[$0.identifier]) }
            if states.isEmpty || states.allSatisfy({ $0 == .unread }) { return .unread }
            if states.allSatisfy({ $0 == .read }) { return .read }
            return .started
        }
    }

    public func isKept(_ entry: Item) -> Bool {
        switch entry {
        case .title(let t): return keep.contains(t.identifier)
        case .series(let s): return volumes(s.identifier).contains { keep.contains($0.identifier) }
        }
    }

    /// Saved is a title if it is saved itself; a series if it or
    /// one of its volumes is saved.
    public func isSaved(_ entry: Item) -> Bool {
        switch entry {
        case .title(let t): return saved.contains(.title(t.identifier))
        case .series(let s):
            return saved.contains(.series(s.identifier))
                || volumes(s.identifier).contains { saved.contains(.title($0.identifier)) }
        }
    }

    /// The saved list as entries, in its order — what the shelf does not
    /// (any longer) know is missing: a signed-out account, a deleted title.
    public var savedEntries: [Item] {
        saved.compactMap { target in
            switch target {
            case .title(let k): return titleIndex[k].map { .title($0) }
            case .series(let k): return seriesIndex[k].map { .series($0) }
            }
        }
    }

    /// The grid: filtered, sorted, in sections. Without section headers for the
    /// time sortings — a date per row is noise; for title and author a
    /// header per initial letter or per author.
    public func parts(
        kind: Kind? = nil, genre: Genre.EntryKey? = nil, author: String? = nil,
        collection: CollectionID? = nil,
        sorting: Sorting, filter: Filter? = nil
    ) -> [Part] {
        parts(
            kind: kind, genre: genre, author: author, collection: collection, sorting: sorting,
            filtering: filter.map(Filtering.init) ?? Filtering())
    }

    /// The grid with several criteria at once — and narrowed to a publisher
    /// when `publisher` is set (the page behind the publisher link).
    public func parts(
        kind: Kind? = nil, genre: Genre.EntryKey? = nil, author: String? = nil, publisher: String? = nil,
        collection: CollectionID? = nil,
        sorting: Sorting, filtering: Filtering
    ) -> [Part] {
        var list = entries(kind)
        if let collection {
            guard let s = self.collection(collection) else { return [] }
            list = entries(in: s).filter { kind == nil || $0.kind == kind }
            // An ordered collection has its own order — no sorting on top of it.
            if s.ordered {
                let filtered = filtered(list, filtering)
                return filtered.isEmpty ? [] : [Part(header: nil, entries: filtered)]
            }
        }
        if let genre { list = list.filter { Genre.lookupKey(for: $0.genres).contains(genre) } }
        if let author {
            let searched = AuthorName.lookupKey(author)
            list = list.filter { $0.authors.contains { AuthorName.lookupKey($0) == searched } }
        }
        if let publisher {
            list = list.filter {
                title($0).contains { $0.publisher?.caseInsensitiveCompare(publisher) == .orderedSame }
            }
        }
        list = filtered(list, filtering)
        switch sorting {
        case .recentlyRead:
            let ordered = Shelf.nachDatum(list, recentlyRead)
            return ordered.isEmpty ? [] : [Part(header: nil, entries: ordered)]
        case .recentlyAdded:
            let ordered = Shelf.nachDatum(list, added)
            return ordered.isEmpty ? [] : [Part(header: nil, entries: ordered)]
        case .rating:
            // The best first, without stars last; equal stars by votes.
            let ordered = list.sorted { a, b in
                switch (a.rating, b.rating) {
                case (let x?, let y?):
                    if x.stars != y.stars { return x.stars > y.stars }
                    if (x.voices ?? 0) != (y.voices ?? 0) { return (x.voices ?? 0) > (y.voices ?? 0) }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            return ordered.isEmpty ? [] : [Part(header: nil, entries: ordered)]
        case .title:
            return Shelf.grouped(
                list, to: { .text(Shelf.initialLetter($0.name)) }, without: .withoutAuthor)
        case .author:
            return Shelf.grouped(list, to: { $0.authors.first.map { .text($0) } }, without: .withoutAuthor)
        case .bookSeries:
            return Shelf.bySeries(list)
        }
    }

    private func filtered(_ list: [Item], _ f: Filtering) -> [Item] {
        guard !f.empty else { return list }
        return list.filter { entry in
            if let phase = f.phase, status(entry) != phase { return false }
            if f.downloaded, !isKept(entry) { return false }
            if f.saved, !isSaved(entry) { return false }
            if f.gaps, !hasGaps(entry) { return false }
            // Year, language, format, publisher are on the title; a series fits if
            // one of its volumes fits.
            let title = title(entry)
            if let years = f.years,
                !title.contains(where: { $0.released.map { years.contains(Shelf.year($0)) } ?? false })
            {
                return false
            }
            if !f.languages.isEmpty,
                !title.contains(where: { $0.language.map(f.languages.contains) ?? false })
            {
                return false
            }
            if !f.formats.isEmpty, !title.contains(where: { $0.format.map(f.formats.contains) ?? false }) {
                return false
            }
            if !f.publishers.isEmpty,
                !title.contains(where: { $0.publisher.map(f.publishers.contains) ?? false })
            {
                return false
            }
            return true
        }
    }

    /// The titles behind an entry — the title itself or the volumes of the series.
    func title(_ entry: Item) -> [Title] {
        switch entry {
        case .title(let t): return [t]
        case .series(let s): return volumes(s.identifier)
        }
    }

    static func year(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }

    /// What can be filtered in a kind — the values for the filter sheet, each with a
    /// counter, languages and publishers by frequency, formats by name.
    public struct FilterValues: Sendable, Hashable {
        public struct Value: Sendable, Hashable, Identifiable {
            public let value: String
            public let count: Int
            public var id: String { value }
        }
        /// The oldest and the youngest publication year; `nil` if none has one.
        public let years: ClosedRange<Int>?
        public let languages: [Value]
        public let formats: [Value]
        public let publishers: [Value]
    }

    public func filterValues(
        _ kind: Kind? = nil, genre: Genre.EntryKey? = nil, author: String? = nil
    )
        -> FilterValues
    {
        var title = entries(kind).flatMap(self.title)
        if let genre { title = title.filter { Genre.lookupKey(for: $0.genres).contains(genre) } }
        if let author {
            let searched = AuthorName.lookupKey(author)
            title = title.filter { $0.authors.contains { AuthorName.lookupKey($0) == searched } }
        }
        let years = title.compactMap { $0.released.map(Shelf.year) }
        func counted(_ values: [String], nachName: Bool = false) -> [FilterValues.Value] {
            var count: [String: Int] = [:]
            for w in values { count[w, default: 0] += 1 }
            return count.map { FilterValues.Value(value: $0.key, count: $0.value) }.sorted {
                if !nachName, $0.count != $1.count { return $0.count > $1.count }
                return $0.value.localizedStandardCompare($1.value) == .orderedAscending
            }
        }
        return FilterValues(
            years: years.min().flatMap { min in years.max().map { min...$0 } },
            languages: counted(title.compactMap(\.language)),
            formats: counted(title.compactMap(\.format), nachName: true),
            publishers: counted(title.compactMap { $0.publisher.flatMap { $0.isEmpty ? nil : $0 } }))
    }

    /// A section of the grid — with a header for title, author and series, without for
    /// time.
    public struct Part: Sendable, Hashable, Identifiable {
        /// The header: a text (letter, author, series) or one of the two
        /// collective headers that the UI names itself.
        public enum Header: Sendable, Hashable {
            case text(String)
            case withoutBookSeries
            case withoutAuthor
        }
        public let header: Header?
        public let entries: [Item]

        public init(header: Header?, entries: [Item]) {
            self.header = header
            self.entries = entries
        }

        public var id: String {
            switch header {
            case .text(let s): return s
            case .withoutBookSeries: return "\u{1}ohneReihe"
            case .withoutAuthor: return "\u{1}ohneAutor"
            case nil: return ""
            }
        }
    }

    private static func grouped(
        _ list: [Item], to lookupKey: (Item) -> Part.Header?, without: Part.Header
    ) -> [Part] {
        var clusters: [String: [Item]] = [:]
        var withoutHeader: [Item] = []
        for e in list {
            if case .text(let k)? = lookupKey(e) {
                clusters[k, default: []].append(e)
            } else {
                withoutHeader.append(e)
            }
        }
        var parts = clusters.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { k in
                Part(
                    header: .text(k),
                    entries: clusters[k]!.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    })
            }
        if !withoutHeader.isEmpty {
            parts.append(
                Part(
                    header: without,
                    entries: withoutHeader.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    })
            )
        }
        return parts
    }

    /// By series: one section per series with the volumes in reading order —
    /// volume number, else publication date, else name. Series (manga) stand
    /// without header first, what belongs to no series last, by publication
    /// date (requested: "so that I know what belongs together and in which
    /// order").
    static func bySeries(_ list: [Item]) -> [Part] {
        var seriesList: [Item] = []
        var bookSeriesList: [String: [Title]] = [:]
        var singles: [Title] = []
        for e in list {
            switch e {
            case .series: seriesList.append(e)
            case .title(let t):
                if let name = t.series?.name, !name.isEmpty {
                    bookSeriesList[name, default: []].append(t)
                } else {
                    singles.append(t)
                }
            }
        }
        var parts: [Part] = []
        if !seriesList.isEmpty {
            parts.append(
                Part(
                    header: nil,
                    entries: seriesList.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }))
        }
        for name in bookSeriesList.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            parts.append(
                Part(
                    header: .text(name),
                    entries: bookSeriesList[name]!.sorted(by: readingOrder).map { .title($0) }
                ))
        }
        if !singles.isEmpty {
            parts.append(
                Part(
                    header: .withoutBookSeries,
                    entries: singles.sorted(by: readingOrder).map { .title($0) })
            )
        }
        return parts
    }

    /// Volume number before publication date before name; whatever has neither, last.
    static func readingOrder(_ a: Title, _ b: Title) -> Bool {
        switch (a.series?.volume, b.series?.volume) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        switch (a.released, b.released) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// "A" for "Ruslistran trai Klipliospeis", "#" for "404" — umlauts and accents folded.
    static func initialLetter(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let first = folded.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return first.isNumber ? "#" : String(first).uppercased()
    }

    // MARK: - Genres

    /// A genre with counter and the three youngest covers — the card in the
    /// genre row. `without` bundles what carries no genre (on Komga today 21 of 21).
    public struct Genre: Sendable, Hashable, Identifiable {
        public enum EntryKey: Sendable, Hashable {
            case name(String)
            case without
        }
        public let lookupKey: EntryKey
        public let count: Int
        /// The count per kind — "2 books · 1 audiobook" under "All"; for
        /// manga the series counts, not the volume.
        public let countPerKind: [Kind: Int]
        /// The three youngest entries as covers — with source and kind so the card can fetch them.
        public let cover: [CoverReference]

        public init(lookupKey: EntryKey, count: Int, countPerKind: [Kind: Int], cover: [CoverReference]) {
            self.lookupKey = lookupKey
            self.count = count
            self.countPerKind = countPerKind
            self.cover = cover
        }

        public var id: EntryKey { lookupKey }
        public var name: String? {
            if case .name(let n) = lookupKey { return n }
            return nil
        }

        /// The keys of an entry — normalized via ``GenreNames`` and without duplicates:
        /// "Sci-Fi" and "Science Fiction" on the same book are one genre.
        static func lookupKey(for genres: [String]) -> [EntryKey] {
            var seen = Set<String>()
            let names = genres.map(GenreNames.normal).filter { !$0.isEmpty && seen.insert($0).inserted }
            return names.isEmpty ? [.without] : names.map { .name($0) }
        }
    }

    /// The genres of a kind, by frequency; "without genre" last. Fewer than two
    /// genres empty — a genre row with one entry is no choice.
    public func genres(_ kind: Kind? = nil) -> [Genre] {
        // The date once per entry, not per comparison: for
        // a series ``added(_:)`` searches over all volumes — in the comparison that held the
        // main thread for 616 ms when opening the library.
        let all = entries(kind)
        let date = all.map { added($0) ?? .distantPast }
        let list = all.indices.sorted { date[$0] > date[$1] }.map { all[$0] }
        var count: [Genre.EntryKey: Int] = [:]
        var perKind: [Genre.EntryKey: [Kind: Int]] = [:]
        var cover: [Genre.EntryKey: [CoverReference]] = [:]
        for e in list {
            for s in Genre.lookupKey(for: e.genres) {
                count[s, default: 0] += 1
                perKind[s, default: [:]][e.kind, default: 0] += 1
                if cover[s, default: []].count < 3 {
                    cover[s, default: []].append(
                        CoverReference(address: e.cover, source: e.source, kind: e.kind))
                }
            }
        }
        guard count.count >= 2 else { return [] }
        return count.keys.sorted { a, b in
            switch (a, b) {
            case (.without, _): return false
            case (_, .without): return true
            case (.name(let x), .name(let y)):
                if count[a] != count[b] { return count[a]! > count[b]! }
                return x.localizedStandardCompare(y) == .orderedAscending
            }
        }
        .map {
            Genre(lookupKey: $0, count: count[$0]!, countPerKind: perKind[$0] ?? [:], cover: cover[$0] ?? [])
        }
    }

    // MARK: - Authors

    /// A person on the shelf — with the spelling that occurs most often, and
    /// the titles per kind. Three servers, three spellings (``AuthorName``): "Brandt,
    /// M. L." and "M. L. Brandt" are one here.
    public struct Author: Sendable, Hashable, Identifiable {
        public let lookupKey: String
        public let name: String
        /// Titles per kind — volumes, not series.
        public let count: [Kind: Int]
        /// The youngest cover — for the picture, as long as Wikipedia supplies none.
        public let cover: CoverReference?
        /// The entry on the server that keeps authors as their own (Grimmory) — with image
        /// and the way to the description; `nil` for Komga and Audiobookshelf.
        public let reference: AuthorReference?

        public var id: String { lookupKey }
        public var title: Int { count.values.reduce(0, +) }

        public init(
            lookupKey: String, name: String, count: [Kind: Int], cover: CoverReference?,
            reference: AuthorReference? = nil
        ) {
            self.lookupKey = lookupKey
            self.name = name
            self.count = count
            self.cover = cover
            self.reference = reference
        }
    }

    /// The server entry for a name — with image preferred if there are several
    /// (Grimmory keeps "A Biskreirau Dofur" and "A. Biskreirau Dofur" apart).
    public func authorReference(_ name: String) -> AuthorReference? {
        let k = AuthorName.lookupKey(name)
        let matching = extracts.flatMap(\.authors).filter { AuthorName.lookupKey($0.name) == k }
        return matching.first { $0.image != nil } ?? matching.first
    }

    /// All authors of a kind (or all), sorted by last name — the fourth
    /// view of the library.
    public func authors(_ kind: Kind? = nil) -> [Author] {
        var names: [String: [String: Int]] = [:]
        var count: [String: [Kind: Int]] = [:]
        var cover: [String: (Date, CoverReference)] = [:]
        for extract in extracts {
            for t in extract.title where kind == nil || t.kind == kind {
                for raw in t.authors {
                    let display = AuthorName.display(raw)
                    guard !display.isEmpty else { continue }
                    let k = AuthorName.lookupKey(display)
                    names[k, default: [:]][display, default: 0] += 1
                    count[k, default: [:]][t.kind, default: 0] += 1
                    let date = t.added ?? .distantPast
                    if cover[k].map({ date > $0.0 }) ?? true {
                        cover[k] = (
                            date, CoverReference(address: t.cover, source: t.identifier.source, kind: t.kind)
                        )
                    }
                }
            }
        }
        var references: [String: AuthorReference] = [:]
        for b in extracts.flatMap(\.authors) {
            let k = AuthorName.lookupKey(b.name)
            if references[k] == nil || (references[k]?.image == nil && b.image != nil) { references[k] = b }
        }
        return count.keys.map { k in
            let name = names[k]!.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }!.key
            return Author(
                lookupKey: k, name: name, count: count[k]!, cover: cover[k]?.1, reference: references[k])
        }
        .sorted { Shelf.byLastName($0.name) < Shelf.byLastName($1.name) }
    }

    /// "Brandt M. L." — for sorting by last name; a single word stays as it is.
    static func byLastName(_ name: String) -> String {
        let share = name.split(separator: " ")
        guard share.count > 1, let last = share.last else { return name.lowercased() }
        return (String(last) + " " + share.dropLast().joined(separator: " ")).lowercased()
    }

    // MARK: - Changing

    /// The same shelf with another state — for optimistic writing: the
    /// tile shows the new state before the server has answered.
    public func with(_ state: ReadingState?, for identifier: TitleID) -> Shelf {
        let new = extracts.map { extract -> LibraryExtract in
            guard extract.source == identifier.source else { return extract }
            var states = extract.readingStates
            states[identifier] = state
            // With collections and authors: without them both would drop out of the shelf with every new
            // reading state, until the next refresh.
            return LibraryExtract(
                source: extract.source, seriesList: extract.seriesList, title: extract.title,
                readingStates: states,
                collections: extract.collections, authors: extract.authors, state: extract.state,
                isSupplement: extract.isSupplement)
        }
        var states = readingStates
        states[identifier] = state
        let shelf = Shelf(copying: self, extracts: new, readingStates: states)
        // "New on shelf" asks only WHETHER a title has a state — another state of an
        // already started book (while reading every few seconds) does not change it. It used to go per state
        // over all 35,000 titles.
        if (readingStates[identifier] != nil) == (state != nil) {
            shelf.memo.adopt("neuImRegal", from: memo)
        }
        return shelf
    }

    public func with(keep: Set<TitleID>) -> Shelf {
        let shelf = Shelf(copying: self, keep: keep)
        shelf.memo.adopt("neuImRegal", from: memo)
        return shelf
    }

    public func with(saved: [SaveTarget]) -> Shelf {
        let shelf = Shelf(copying: self, saved: saved)
        shelf.memo.adopt("neuImRegal", from: memo)
        return shelf
    }
}

/// Unread, started, read — the three states of the filter and of the
/// read-status menu.
public enum ReadStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case unread = "ungelesen"
    case started = "angefangen"
    case read = "gelesen"

    public init(_ state: ReadingState?) {
        guard let state else {
            self = .unread
            return
        }
        if state.completed {
            self = .read
        } else if state.fraction > 0 {
            self = .started
        } else {
            self = .unread
        }
    }
}

/// The six sortings of the library (plus "series" and "rating").
public enum Sorting: String, Sendable, Hashable, CaseIterable, Codable {
    case recentlyRead = "zuletztGelesen"
    case recentlyAdded = "zuletztHinzugefuegt"
    case title = "titel"
    case author = "autor"
    /// By series bundled, within it in reading order — the default on the genre page.
    case bookSeries = "reihe"
    /// The community stars, the best first — what has no stars, last.
    case rating = "bewertung"

    /// Manga "recently read" — one is in the middle of a series; books "recently
    /// added" — one looks for the new. Without kind the new applies.
    public static func preset(for kind: Kind?) -> Sorting {
        kind == .manga ? .recentlyRead : .recentlyAdded
    }

    /// On the genre page: by series — whoever opens a genre wants to see what
    /// belongs together and where to start. Manga are already series there.
    public static func defaultInGenre(for kind: Kind?) -> Sorting {
        kind == .manga ? .recentlyRead : .bookSeries
    }
}

/// The five filters of the library — one or none. "Saved" is the shelf
/// of the saved list in the library.
public enum Filter: String, Sendable, Hashable, CaseIterable, Codable {
    case unread = "ungelesen"
    case started = "angefangen"
    case read = "gelesen"
    case keep = "behalten"
    case saved = "gemerkt"
}

/// Several criteria at once: a read status, downloaded,
/// saved, series with gaps, shelves, genres, authors, series, a span of years, languages,
/// formats, publishers — empty means "all". Within a field OR, between fields AND.
public struct Filtering: Sendable, Hashable, Codable {
    public var phase: ReadStatus?
    public var downloaded = false
    public var saved = false
    /// Only series in which a volume is missing (``SeriesGaps``) — single titles drop out.
    public var gaps = false
    public var years: ClosedRange<Int>?
    /// BCP-47 code as on the title (`de`, `en-US`).
    public var languages: Set<String> = []
    /// "EPUB", "CBZ" — like ``SourcesKit/Title/format``.
    public var formats: Set<String> = []
    public var publishers: Set<String> = []
    /// Shelves as `CollectionID.description` — also magic shelves.
    public var shelves: Set<String> = []
    /// Genre names per ``GenreNames``.
    public var genres: Set<String> = []
    public var authors: Set<String> = []
    /// Series as `SeriesID.description`.
    public var seriesList: Set<String> = []

    public init() {}

    /// From the one old filter — for the callers that set only one.
    public init(_ filter: Filter) {
        switch filter {
        case .unread: phase = .unread
        case .started: phase = .started
        case .read: phase = .read
        case .keep: downloaded = true
        case .saved: saved = true
        }
    }

    public var empty: Bool { count == 0 }

    /// How many criteria are set — the number on the filter button.
    public var count: Int {
        (phase == nil ? 0 : 1) + (downloaded ? 1 : 0) + (saved ? 1 : 0) + (gaps ? 1 : 0)
            + (years == nil ? 0 : 1) + languages.count + formats.count + publishers.count + shelves.count
            + genres.count
            + authors.count + seriesList.count
    }

    private enum CodingKeys: String, CodingKey {
        case phase = "zustand", downloaded = "heruntergeladen", saved = "gemerkt", gaps = "luecken", years =
            "jahre", languages = "sprachen", formats = "formate", publishers = "verlage", shelves = "regale",
            genres,
            authors,
            seriesList
    }

    /// A remembered filter from before does not know the new fields — they are empty then.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(ReadStatus.self, forKey: .phase)
        downloaded = try c.decodeIfPresent(Bool.self, forKey: .downloaded) ?? false
        saved = try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        gaps = try c.decodeIfPresent(Bool.self, forKey: .gaps) ?? false
        years = try c.decodeIfPresent(ClosedRange<Int>.self, forKey: .years)
        languages = try c.decodeIfPresent(Set<String>.self, forKey: .languages) ?? []
        formats = try c.decodeIfPresent(Set<String>.self, forKey: .formats) ?? []
        publishers = try c.decodeIfPresent(Set<String>.self, forKey: .publishers) ?? []
        shelves = try c.decodeIfPresent(Set<String>.self, forKey: .shelves) ?? []
        genres = try c.decodeIfPresent(Set<String>.self, forKey: .genres) ?? []
        authors = try c.decodeIfPresent(Set<String>.self, forKey: .authors) ?? []
        seriesList = try c.decodeIfPresent(Set<String>.self, forKey: .seriesList) ?? []
    }
}

extension LibraryExtract {
    /// The same extract without everything above the limit: series by their rating, titles
    /// by their own and that of their series; without a rating free.
    func withinLimit(until limit: Int) -> LibraryExtract {
        let blockedSeries = Set(seriesList.filter { ($0.ageRating ?? 0) > limit }.map(\.identifier))
        let title = title.filter { t in
            (t.ageRating ?? 0) <= limit
                && !(t.series.map { blockedSeries.contains($0.identifier) } ?? false)
        }
        let allowed = Set(title.map(\.identifier))
        return LibraryExtract(
            source: source, seriesList: seriesList.filter { !blockedSeries.contains($0.identifier) },
            title: title,
            readingStates: readingStates.filter { allowed.contains($0.key) }, collections: collections,
            authors: authors, state: state, isSupplement: isSupplement)
    }
}
