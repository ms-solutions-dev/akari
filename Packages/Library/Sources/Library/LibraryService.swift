import Bedrock
import Foundation
import Observation
import ReadingProgress
import SourcesKit

/// The library on the main thread: holds the ``Shelf``, refreshes it from the sources
/// and writes reading states optimistically — the tile shows the new state before
/// the server has answered, and takes it back if the server refuses.
///
/// **Cache first, network after.** On opening, the shelf stands from the
/// ``LibraryStore`` before any source was asked; then all sources
/// are asked side by side, and each that answers replaces its extract. One that
/// does not answer keeps its old one — Home stays full, only ``failure`` names it.
///
/// **The saved list lives in the app and is mirrored:** ``save(_:saved:)``
/// writes first into the ``SavedList``, then — where the source declares
/// the saved-list capability — to the server; if it refuses, the old state is back. On
/// refresh, for the titles of such a source what the server says holds.
///
/// **Nothing is lost without network:** if the server refuses a
/// state *definitively* (401, 403, 404), the old one is back and the error
/// goes to the caller. If it is merely *unreachable*, the new state stays on the shelf
/// and moves into the ``Queue``; ``supply()`` takes it there on the next
/// contact — after refreshing and when the network returns —, with
/// stale protection: if the server meanwhile has a newer, different state, that one holds.
///
/// Knows the sources only via the slot: `sources` returns what is currently
/// signed in — in operation from the account registry, in tests mocks.
@MainActor
@Observable
public final class LibraryService {

    public private(set) var shelf: Shelf = .empty {
        didSet { memo.clearOut() }
    }
    /// What is derived from the shelf and expensive — remembered until the next change.
    @ObservationIgnored private let memo = ShelfMemo()
    /// Whether sources are currently being asked — for the spinner when pulling.
    public private(set) var refreshing = false
    /// Whether the store was read or refreshed once — until then an empty
    /// shelf means "not loaded yet", not "nothing there". Since the store reads in
    /// the background, the empty state otherwise showed briefly on launch.
    public private(set) var ready = false
    /// Which source did not deliver on the last refresh.
    public private(set) var failure: [SourceID: SourceError] = [:]
    /// When at least one source last answered — `nil` as long as everything comes
    /// from the store.
    public private(set) var renewed: Date?
    /// What the offline store holds on the device — filled by the offline store; empty until then.
    public var keep: Set<TitleID> = [] {
        didSet { shelf = shelf.with(keep: keep) }
    }
    /// Titles fetched fresh from the server because the catalog shortened them (without blurb) or does not
    /// hold them at all — the detail asks for them (``details(for:)``). With a catalog of 35,000
    /// books the blurbs no longer come along.
    public private(set) var backfilled: [TitleID: Title] = [:]
    @ObservationIgnored private var holtNach: Set<TitleID> = []

    /// The title as the detail shows it: backfilled, otherwise from the shelf.
    public func titleForDetail(_ identifier: TitleID) -> Title? {
        backfilled[identifier] ?? shelf.title(identifier)
    }

    /// Fetches a title fresh if its blurb is missing or the shelf does not know it —
    /// once per program run; if that fails, what is there stays.
    public func details(for identifier: TitleID) async {
        let known = titleForDetail(identifier)
        guard known?.summary == nil, backfilled[identifier] == nil,
            holtNach.insert(identifier).inserted, let source = source(identifier.source)
        else { return }
        defer { holtNach.remove(identifier) }
        guard let fresh = try? await source.title(identifier) else { return }
        backfilled[identifier] = fresh
    }

    /// The kept titles from their data packets (the offline store's snapshots) — whatever
    /// of them is in no catalog supplements the shelf: downloaded items are
    /// always visible, offline, with a source whose catalog does not come, and after
    /// signing out of an account.
    public var stockTitle: [Title] = [] {
        didSet {
            guard stockTitle != oldValue else { return }
            shelf = Shelf(
                extracts: LibraryService.withStock(shelf.extracts, stockTitle),
                capabilities: shelf.capabilities,
                keep: shelf.keep, saved: shelf.saved, bookSeriesList: shelf.bookSeriesList,
                maxAge: maxAge,
                now: shelf.now)
        }
    }
    /// The saved list — the shelf carries a copy so that filter and start row
    /// compute from one value.
    public let savedList: SavedList
    /// For which kinds series stand as a series in the grid — remembered in
    /// `UserDefaults` so that the choice survives a restart.
    public var bookSeriesList: Set<Kind> {
        didSet {
            shelf = shelf.with(bookSeriesList: bookSeriesList)
            settings.set(bookSeriesList.map(\.rawValue).sorted(), forKey: LibraryService.bookSeriesKey)
        }
    }
    public static let bookSeriesKey = "library.reihen"
    /// The limit of the child profile — the shelf filters with it at the entrance.
    public let maxAge: Int?

    /// What the server does not have yet, and the device trace.
    public let queue: Queue
    /// How many states are pending — for the row in the storage sheet and the tests.
    public private(set) var pending = 0
    /// Counts up when a collection overview from the background is ready
    /// (``overview(in:)``).
    public private(set) var overviewState = 0
    @ObservationIgnored private var overviewRuns = Set<String>()
    /// When pending states last arrived at the server and how many — the
    /// banner briefly says "resubmitted" so that nobody thinks the offline-read
    /// is lost.
    public private(set) var supplied: (count: Int, around: Date)?

    private let sources: @MainActor () -> [any Source]
    private let persistence: LibraryStore
    /// Writes the store off the main thread, reading states bundled.
    private let writer: StoreWriter
    /// The catalog of all sources on the device — library, filter and
    /// search read from it; refreshing fills it as well.
    public let catalog: CatalogIndex?
    /// The last pending write — in sequence so the newest extract arrives last and
    /// ``secureStore()`` waits for all.
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    private let settings: UserDefaults
    private var suppliesPending = false

    public init(
        persistence: LibraryStore = LibraryStore(), savedList: SavedList = SavedList(),
        settings: UserDefaults = .standard, queue: Queue = Queue(),
        maxAge: Int? = nil, catalog: CatalogIndex? = nil,
        sources: @escaping @MainActor () -> [any Source]
    ) {
        self.persistence = persistence
        // Without a file an index in memory (tests, preview).
        self.catalog = catalog ?? (try? CatalogIndex(file: nil))
        self.writer = StoreWriter(persistence: persistence)
        self.savedList = savedList
        self.settings = settings
        self.queue = queue
        self.maxAge = maxAge
        self.pending = queue.all.count
        self.sources = sources
        if let saved = settings.stringArray(forKey: LibraryService.bookSeriesKey) {
            self.bookSeriesList = Set(saved.compactMap(Kind.init(rawValue:)))
        } else {
            self.bookSeriesList = Shelf.bookSeriesDefault
        }
    }

    /// Everything comes from the store — offline the banner shows the age.
    public var fromCache: Bool { renewed == nil && !shelf.empty }

    public func source(_ identifier: SourceID) -> (any Source)? {
        sources().first { $0.identifier == identifier }
    }

    /// What the image loader must attach to a cover request of this source.
    public func headerLines(_ identifier: SourceID) -> [String: String] {
        source(identifier)?.headerLines() ?? [:]
    }

    // MARK: - Refreshing

    /// Builds the shelf from the store — without network. The first step on opening;
    /// ``refresh()`` follows.
    ///
    /// Reading and building run off the main thread: the store
    /// of Grimmory is 30 MB, decoding alone costs an iPhone a second — that is how long
    /// the app stood still on launch before. If someone else has filled the shelf in the meantime
    /// (a fast refresh), that wins.
    /// Whether the store was read. Not `shelf.empty`: the downloaded titles are already
    /// on the shelf beforehand (``stockTitle``), and with "empty" as the condition the app never read the store on
    /// a device with downloads — every launch then reloaded everything and Home showed "nothing
    /// started yet".
    public private(set) var storeRead = false
    /// The shelf stands from the cores, the whole extract is still reading — then nothing is written to the
    /// store (the core would otherwise replace the whole version).
    @ObservationIgnored private var regalAusKern = false
    @ObservationIgnored private var statesDuringCore: [TitleID: ReadingState?] = [:]

    public func fromStore() async {
        guard !storeRead else { return }
        // One run for all: when launched from the widget, the shell and the audiobook starter ask at the same time —
        // decoding 30 MB twice cost double time and memory.
        if let ongoing = storeReading { return await ongoing.value }
        let run = Task { await readStore() }
        storeReading = run
        await run.value
        storeReading = nil
    }

    @ObservationIgnored private var storeReading: Task<Void, Never>?

    private func readStore() async {
        let sources = sources()
        let identifiers = sources.map(\.identifier)
        let persistence = persistence
        let capabilities = LibraryService.capabilities(sources)
        let keep = keep
        let saved = savedList.entries
        let bookSeriesList = bookSeriesList
        let maxAge = maxAge
        let stockTitle = stockTitle
        // First the cores of the large sources (milliseconds), so that Home stands at once with the readings
        // — instead of a second of "nothing started yet" while 30 MB decode.
        // Then the whole extract, which replaces the core.
        let fast = await Task.detached(priority: .userInitiated) { () -> Shelf? in
            var withCore = false
            let extracts = identifiers.compactMap { k -> LibraryExtract? in
                if let core = persistence.readCore(k) {
                    withCore = true
                    return core
                }
                return persistence.loadExtract(k)
            }
            guard withCore else { return nil }
            let shelf = Shelf(
                extracts: LibraryService.withStock(LibraryService.ordered(extracts), stockTitle),
                capabilities: capabilities,
                keep: keep, saved: saved, bookSeriesList: bookSeriesList, maxAge: maxAge)
            shelf.precompute()
            return shelf
        }.value
        if let fast, !shelf.extracts.contains(where: { !$0.isSupplement }) {
            shelf = await withPending(fast)
            regalAusKern = true
            ready = true
        }
        // The whole extract only once the lantern is out (``LaunchQuiet``): decoding 30 MB took
        // the two performance cores exactly while it burned. The core above carries Home until then.
        await LaunchQuiet.wait()
        let built = await Task.detached(priority: .userInitiated) {
            let extracts = identifiers.compactMap { persistence.loadExtract($0) }
            let shelf = Shelf(
                extracts: LibraryService.withStock(LibraryService.ordered(extracts), stockTitle),
                capabilities: capabilities,
                keep: keep, saved: saved, bookSeriesList: bookSeriesList, maxAge: maxAge)
            shelf.precompute()
            return shelf
        }.value
        defer {
            ready = true
            storeRead = true
        }
        // Only as long as no fresh extract is there — the titles from the store and the core do not
        // count. States that came during the core go onto the whole shelf.
        guard regalAusKern || !shelf.extracts.contains(where: { !$0.isSupplement }) else { return }
        var whole = await withPending(built)
        for (identifier, state) in statesDuringCore { whole = whole.with(state, for: identifier) }
        let toWrite = Set(statesDuringCore.keys.map(\.source))
        statesDuringCore = [:]
        regalAusKern = false
        shelf = whole
        for source in toWrite { enqueueStore(source, statesOnly: true) }
        // The catalog is new (first launch with index): fill it from the store so that the
        // library does not wait for the refresh.
        if let catalog, (try? catalog.count(CatalogQuery())) == 0 {
            await fillCatalog(built.extracts)
        }
    }

    /// Builds a shelf off the main thread — with 24,000 titles the lookups cost
    /// an iPhone noticeable time, and refreshing runs while one is already scrolling. If
    /// keep or saved list change meanwhile, they are applied afterwards.
    private func build(_ extracts: [LibraryExtract], sources: [any Source]) async -> Shelf {
        let capabilities = LibraryService.capabilities(sources)
        let keep = keep
        let saved = savedList.entries
        let bookSeriesList = bookSeriesList
        let maxAge = maxAge
        let stockTitle = stockTitle
        var built = await Task.detached(priority: .userInitiated) {
            let shelf = Shelf(
                extracts: LibraryService.withStock(LibraryService.ordered(extracts), stockTitle),
                capabilities: capabilities,
                keep: keep, saved: saved, bookSeriesList: bookSeriesList, maxAge: maxAge)
            shelf.precompute()
            return shelf
        }.value
        // Changed while it was built: adjust, and precompute again off the main thread — a `with`
        // starts with an empty memo (see ``withPending(_:)``).
        var adjusted = false
        if self.keep != keep {
            built = built.with(keep: self.keep)
            adjusted = true
        }
        if savedList.entries != saved {
            built = built.with(saved: savedList.entries)
            adjusted = true
        }
        if self.bookSeriesList != bookSeriesList {
            built = built.with(bookSeriesList: self.bookSeriesList)
            adjusted = true
        }
        if adjusted {
            let shelf = built
            built = await Task.detached(priority: .userInitiated) {
                shelf.precompute()
                return shelf
            }.value
        }
        return built
    }

    // MARK: - Lookup in the shelf, otherwise in the catalog

    /// A title: from the shelf, and if it does not hold it, from the catalog. For large sources
    /// the shelf holds only the core (started, saved, new); detail, reader and
    /// series ask here, not the shelf directly.
    public func title(_ identifier: TitleID) -> Title? {
        shelf.title(identifier) ?? backfilled[identifier] ?? (try? catalog?.title(identifier)) ?? nil
    }

    /// A series — shelf, otherwise catalog.
    public func series(_ identifier: SeriesID) -> Series? {
        shelf.series(identifier) ?? (try? catalog?.series(identifier)) ?? nil
    }

    /// The volumes of a series — from the catalog if it knows more than the shelf.
    ///
    /// The catalog only if the shelf does not know the series at all — otherwise a SQLite query ran per series tile and
    /// pass on the main thread.
    public func volumes(_ series: SeriesID) -> [Title] {
        let imRegal = shelf.volumes(series)
        guard imRegal.isEmpty, let fromCatalog = try? catalog?.volumes(series) else { return imRegal }
        return fromCatalog
    }

    /// The state of a series — from the catalog if it knows more volumes than the shelf.
    public func seriesState(_ identifier: SeriesID) -> Shelf.SeriesState {
        guard shelf.volumes(identifier).isEmpty else { return shelf.seriesState(identifier) }
        let volumes = volumes(identifier)
        return Shelf.seriesState(
            volumes: volumes, volumeCount: series(identifier)?.volumeCount, state: { readingState($0) })
    }

    /// What is missing in a series — likewise.
    public func gaps(_ identifier: SeriesID) -> SeriesGaps? {
        guard shelf.volumes(identifier).isEmpty else { return shelf.gaps(identifier) }
        let volumes = volumes(identifier)
        return SeriesGaps(numbers: volumes.compactMap { $0.series?.volume }, total: series(identifier)?.total)
    }

    /// A reading state — shelf, otherwise the state in the catalog.
    ///
    /// The catalog only for titles the shelf does not hold: an unread title has no state on the
    /// shelf either, and per tile a query ran on every pass otherwise.
    /// A retained state (``retained``) counts before the shelf.
    public func readingState(_ identifier: TitleID) -> ReadingState? {
        if let back = retained[identifier] { return back }
        if let state = shelf.readingState(identifier) { return state }
        guard shelf.title(identifier) == nil, let s = try? catalog?.state(identifier) else { return nil }
        if s.completed {
            return ReadingState(position: .fraction(1), timestamp: s.timestamp, completed: true)
        }
        return s.fraction > 0 ? ReadingState(position: .fraction(s.fraction), timestamp: s.timestamp) : nil
    }

    /// The search over everything: candidates from the catalog's full-text search (word starts in title,
    /// series, author, genre) and from the shelf, ranked and grouped as before
    /// (``Shelf/search(_:kind:)``). So it also finds the books of large sources that the shelf
    /// does not hold in memory.
    public func search(_ text: String, kind: Kind? = nil) -> Shelf.SearchResult {
        LibraryService.search(
            text, kind: kind, catalog: catalog, shelf: shelf, bookSeriesList: bookSeriesList, maxAge: maxAge,
            series: { [catalog] k in self.shelf.series(k) ?? (try? catalog?.series(k)) ?? nil })
    }

    /// The same search off the main thread — for the search field that asks on every keystroke
    /// (full-text search, shelf pass and a new shelf per
    /// key ran in the `body` of the search).
    public func searchInBackground(_ text: String, kind: Kind? = nil) async -> Shelf.SearchResult {
        let (catalog, shelf, bookSeriesList, maxAge) = (catalog, shelf, bookSeriesList, maxAge)
        return await Task.detached(priority: .userInitiated) {
            LibraryService.search(
                text, kind: kind, catalog: catalog, shelf: shelf, bookSeriesList: bookSeriesList,
                maxAge: maxAge,
                series: { k in shelf.series(k) ?? (try? catalog?.series(k)) ?? nil })
        }.value
    }

    nonisolated static func search(
        _ text: String, kind: Kind?, catalog: CatalogIndex?, shelf: Shelf, bookSeriesList: Set<Kind>,
        maxAge: Int?,
        series: (SeriesID) -> Series?
    ) -> Shelf.SearchResult {
        guard let catalog, let candidates = try? catalog.search(text, kind: kind, atMost: 400),
            !candidates.isEmpty
        else { return shelf.search(text, kind: kind) }
        var title: [SourceID: [TitleID: Title]] = [:]
        for t in candidates { title[t.identifier.source, default: [:]][t.identifier] = t }
        let words = Shelf.searchWords(text)
        if !words.isEmpty {
            for case .title(let t) in shelf.entries(kind)
            where title[t.identifier.source]?[t.identifier] == nil {
                if Shelf.matches(words, on: [t.name] + t.authors) {
                    title[t.identifier.source, default: [:]][t.identifier] = t
                }
            }
        }
        let extracts = title.map { source, list in
            let seriesList = Set(list.values.compactMap { $0.series?.identifier }).compactMap(series)
            return LibraryExtract(
                source: source, seriesList: seriesList, title: Array(list.values), readingStates: [:],
                state: shelf.now)
        }
        return Shelf(extracts: extracts, bookSeriesList: bookSeriesList, maxAge: maxAge, now: shelf.now)
            .search(text, kind: kind)
    }

    /// How far a source is in importing — "Being imported · 12,000 of 35,551". Only sources
    /// that load page by page report; empty if nothing is running.
    public struct ScanState: Sendable, Hashable {
        public let loaded: Int
        public let total: Int
        public let since: Date
    }
    public private(set) var scan: [SourceID: ScanState] = [:] {
        didSet {
            if scan.isEmpty {
                scanShow = false
            } else if oldValue.isEmpty {
                // Only show after three seconds: a sync that finishes faster should
                // not flash up. Here instead of in the view, so that the view without a banner is not
                // in the stack at all (otherwise an empty row with spacing above the home page).
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !self.scan.isEmpty else { return }
                    self.scanShow = true
                }
            }
        }
    }
    /// Whether the import banner stands — three seconds after an import begins.
    public private(set) var scanShow = false

    private func report(_ source: SourceID, loaded: Int, total: Int) {
        guard refreshing, loaded < total else {
            scan[source] = nil
            return
        }
        scan[source] = ScanState(
            loaded: loaded, total: total, since: scan[source]?.since ?? Date())
    }

    /// Counts up whenever the catalog has changed — the library then asks anew.
    public private(set) var catalogState = 0
    /// Counts up whenever a reading state has arrived in the catalog.
    public private(set) var readingStateState = 0
    /// The genre rows from the catalog, per kind, with the catalog state they belong to.
    private var catalogGenres: [Kind?: (state: Int, list: [Shelf.Genre])] = [:]
    private var catalogAuthors: [Kind?: (state: Int, list: [Shelf.Author])] = [:]
    @ObservationIgnored private var genreRuns: Set<String> = []

    /// The question to the catalog for a library view: kind, place (genre, author, publisher)
    /// and the criteria of the filter sheet. What only the device knows (downloaded,
    /// saved, series with gaps) comes in as a selection.
    public func catalogQuery(
        kind: Kind?, genre: Shelf.Genre.EntryKey? = nil, author: String? = nil, publisher: String? = nil,
        sorting: Sorting, filtering: Filtering = Filtering()
    ) -> CatalogQuery {
        var a = CatalogQuery(kind: kind, sorting: sorting)
        a.maxAge = maxAge
        switch genre {
        case .name(let n)?: a.genres = [n]
        case .without?: a.withoutGenre = true
        case nil: break
        }
        if let author { a.authors = [author] }
        if let publisher { a.publishers = [publisher] }
        a.phase = filtering.phase
        a.languages = filtering.languages
        a.formats = filtering.formats
        a.publishers.formUnion(filtering.publishers)
        a.years = filtering.years
        a.genres.formUnion(filtering.genres)
        a.authors.formUnion(filtering.authors)
        a.seriesList = filtering.seriesList
        if !filtering.shelves.isEmpty {
            var selection = CatalogQuery.Selection()
            for collection in shelf.collections
            where filtering.shelves.contains(collection.identifier.description) {
                for target in collection.entries {
                    switch target {
                    case .title(let k): selection.title.insert(k.description)
                    case .series(let k): selection.seriesList.insert(k.description)
                    }
                }
            }
            a.selection.append(selection)
        }
        if filtering.downloaded {
            a.selection.append(.init(title: Set(keep.map(\.description))))
        }
        if filtering.saved {
            var selection = CatalogQuery.Selection()
            for target in savedList.entries {
                switch target {
                case .title(let k): selection.title.insert(k.description)
                case .series(let k): selection.seriesList.insert(k.description)
                }
            }
            a.selection.append(selection)
        }
        if filtering.gaps {
            let withGaps = shelf.allSeries.filter {
                shelf.gaps($0.identifier).map { !$0.complete } ?? false
            }
            a.selection.append(.init(seriesList: Set(withGaps.map(\.identifier.description))))
        }
        return a
    }

    /// A reading state into the shelf and into the catalog.
    /// **Hold reading states while a reader is open.**
    ///
    /// The reader reports its state every two seconds. Each went into the observed shelf, and
    /// behind the reader the shell and Home rebuilt — "Up next" and the genres from the
    /// whole library, in the middle of paging. Measured in the simulator: main thread 570 ms
    /// blocked while reading a webtoon. Now the state goes at once to server, catalog and
    /// queue, into the shelf only on closing — nobody sees it there beforehand.
    ///
    /// **And at the latest before securing** (``secureStore()``): if the app
    /// is quit while a reader is open — the normal case on a device when one
    /// locks while reading and iOS later closes it —, the retained state never reached the
    /// store. On the next launch the old one counted as the own one and was resubmitted
    /// to the server: seen in the simulator, "here 1 %, server 7 % → here, resubmit".
    public var holdsBack = false {
        didSet {
            guard oldValue, !holdsBack else { return }
            adoptRetained()
        }
    }

    /// Puts the retained states onto the shelf and schedules their sources for securing.
    private func adoptRetained() {
        guard !retained.isEmpty else { return }
        var new = shelf
        var sources = Set<SourceID>()
        for (identifier, state) in retained {
            new = new.with(state, for: identifier)
            sources.insert(identifier.source)
        }
        retained = [:]
        shelf = new
        readingStateState += 1
        for source in sources { enqueueStore(source, statesOnly: true) }
    }
    @ObservationIgnored private var retained: [TitleID: ReadingState?] = [:]

    private func setState(_ state: ReadingState?, for identifier: TitleID) {
        if regalAusKern { statesDuringCore[identifier] = state }
        if holdsBack {
            retained[identifier] = .some(state)
            if let catalog {
                Task.detached(priority: .utility) { try? catalog.set(state, for: identifier) }
            }
            return
        }
        shelf = shelf.with(state, for: identifier)
        guard let catalog else { return }
        Task {
            await Task.detached(priority: .utility) { try? catalog.set(state, for: identifier) }.value
            // Not `catalogState`: that made the library grid reload from page 1 on every reading
            // state (while reading, every few seconds). Only grids that filter or sort by the reading state
            // listen to this counter.
            readingStateState += 1
        }
    }

    /// Puts extracts into the catalog, off the main thread — plus the kept titles
    /// of the same source that its extract does not hold (``stockTitle``).
    ///
    /// With `previously`: if nothing changed in a source's titles (the sync of only the
    /// changes usually returns the same extract), it writes only the changed states
    /// and series — instead of all 35,000 rows anew in one transaction, during which the catalog
    /// was locked to every query from the main thread.
    private func fillCatalog(
        _ extracts: [LibraryExtract], previously: [SourceID: LibraryExtract] = [:]
    ) async {
        guard let catalog, !extracts.isEmpty else { return }
        let stock = stockTitle
        let titlesChanged = await Task.detached(priority: .utility) { () -> Bool in
            var changed = false
            for extract in extracts where !extract.isSupplement {
                do {
                    if let old = previously[extract.source], old.title == extract.title {
                        for k in Set(old.readingStates.keys).union(extract.readingStates.keys)
                        where old.readingStates[k] != extract.readingStates[k] {
                            try catalog.set(extract.readingStates[k], for: k)
                        }
                        if old.seriesList != extract.seriesList {
                            try catalog.create(seriesList: extract.seriesList)
                        }
                        continue
                    }
                    changed = true
                    try catalog.replace(extract)
                    let known = Set(extract.title.map(\.identifier))
                    let missing = stock.filter {
                        $0.identifier.source == extract.source && !known.contains($0.identifier)
                    }
                    if !missing.isEmpty { try catalog.create(missing) }
                } catch {
                    Diagnostics.network.error(
                        "Catalog: \(extract.source.description, privacy: .public) not written: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            return changed
        }.value
        if titlesChanged { catalogState += 1 } else { readingStateState += 1 }
    }

    /// Whether two extracts of the same source carry the same content — the timestamp does not count.
    nonisolated static func sameContent(_ a: LibraryExtract, _ b: LibraryExtract) -> Bool {
        catalogEqual(a, b) && a.readingStates == b.readingStates
    }

    /// Everything except the reading states equal.
    nonisolated static func catalogEqual(_ a: LibraryExtract, _ b: LibraryExtract) -> Bool {
        a.source == b.source && a.isSupplement == b.isSupplement && a.title == b.title
            && a.seriesList == b.seriesList && a.collections == b.collections && a.authors == b.authors
    }

    /// Writes scheduled stores at once — when the app goes to the background.
    public func secureStore() async {
        adoptRetained()
        await pendingTask?.value
        await writer.secure()
    }

    /// Puts the pending states over the shelf — the server does not know them yet,
    /// its extract carries the old ones.
    ///
    /// **Off the main thread, and precomputed again:** every `with` makes a new shelf with an
    /// empty memo, so the start rows ("continue reading", "up next", …) were recomputed over all
    /// 36,000 titles on the main thread at the next draw — the 103–144 ms hang right after the
    /// last source answered (device reports 02.11.). Without pending states the shelf stays as
    /// it is, memo included. A state that arrives while this runs is laid on afterwards.
    func withPending(_ shelf: Shelf) async -> Shelf {
        let entries = queue.all.map { (identifier: $0.identifier, state: $0.state) }
        guard !entries.isEmpty else { return shelf }
        var new = await Task.detached(priority: .userInitiated) {
            var new = shelf
            for entry in entries { new = new.with(entry.state, for: entry.identifier) }
            new.precompute()
            return new
        }.value
        for late in queue.all
        where !entries.contains(where: { $0.identifier == late.identifier && $0.state == late.state }) {
            new = new.with(late.state, for: late.identifier)
        }
        return new
    }

    /// Asks each source for its shelf — side by side; whoever answers replaces
    /// its extract, whoever does not keeps the old one and appears in ``failure``. Sources
    /// that no longer exist (signed out) drop out of the shelf.
    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        // Leaving the app in the middle of the sync must not throw it away (``BackgroundTime``).
        let backgroundTime = BackgroundTime("Library refresh")
        defer { backgroundTime.end() }
        // First the store: without it the previous extract is missing, and a source that could only fetch changes
        // fetched everything (Grimmory: 36 MB instead of 232 KB). On launch the refresh ran
        // half a second before reading ended.
        if !storeRead { await fromStore() }
        defer {
            refreshing = false
            ready = true
        }
        let sources = sources()
        var extracts = Dictionary(
            uniqueKeysWithValues: shelf.extracts.filter { !$0.isSupplement }.map { ($0.source, $0) })
        var newFailures: [SourceID: SourceError] = [:]
        var answered = false
        var fresh: [LibraryExtract] = []
        let report: @Sendable (SourceID, Int, Int) -> Void = { [weak self] source, loaded, total in
            Task { @MainActor in self?.report(source, loaded: loaded, total: total) }
        }
        defer { scan = [:] }
        let prior = extracts
        var unchanged: Set<SourceID> = []
        await withTaskGroup(of: (SourceID, Result<Answer, SourceError>).self) { cluster in
            for source in sources {
                cluster.addTask {
                    do {
                        let identifier = source.identifier
                        var extract = try await source.library(previously: prior[identifier]) {
                            report(identifier, $0, $1)
                        }
                        // Saved list and collections of the server hang on the extract — if
                        // one fails alone, the extract stays and the sync waits for the next time.
                        let saved: Set<TitleID>? =
                            source.capabilities.contains(.savedList) ? try? await source.savedList() : nil
                        if source.capabilities.contains(.collections),
                            let collections = try? await source.collections()
                        {
                            extract = extract.with(collections: collections)
                        }
                        return (source.identifier, .success(Answer(extract: extract, saved: saved)))
                    } catch {
                        return (
                            source.identifier, .failure(SourceError.from(error, source: source.identifier))
                        )
                    }
                }
            }
            for await (identifier, result) in cluster {
                switch result {
                case .success(let response):
                    extracts[identifier] = response.extract
                    fresh.append(response.extract)
                    answered = true
                    if let saved = response.saved { savedList.adopt(saved, source: identifier) }
                    // First the running schedules, then the fresh extract — otherwise an
                    // older scheduled one would arrive afterwards and overwrite it.
                    await pendingTask?.value
                    // Unchanged: do not rewrite 30 MB of JSON (the sync of only the
                    // changes usually returns the same extract).
                    let old = prior[identifier]
                    let new = response.extract
                    var catalogEqual = false
                    var statesEqual = false
                    if let old {
                        (catalogEqual, statesEqual) = await Task.detached(priority: .utility) {
                            (LibraryService.catalogEqual(old, new), old.readingStates == new.readingStates)
                        }.value
                    }
                    if catalogEqual && statesEqual {
                        unchanged.insert(identifier)
                        await writer.coreIfMissing(new)
                    } else if catalogEqual {
                        // Only states from the server: the small file instead of 25 MB.
                        await writer.writeStates(new)
                    } else {
                        await writer.write(new)
                    }
                case .failure(let failure):
                    newFailures[identifier] = failure
                    Diagnostics.network.error(
                        "Inventory: \(identifier.description, privacy: .public) \(String(describing: failure), privacy: .public)"
                    )
                }
            }
        }
        let signedIn = Set(sources.map(\.identifier))
        let remaining = extracts.values.filter { signedIn.contains($0.source) }
        for identifier in extracts.keys where !signedIn.contains(identifier) {
            await writer.remove(identifier)
            if let catalog { try? catalog.remove(source: identifier) }
        }
        await fillCatalog(fresh, previously: prior)
        // Nothing changed and no source is gone: the shelf stays — a new one would let
        // every view recompute, and that on every return to the app.
        let nothingNew =
            fresh.allSatisfy { unchanged.contains($0.source) }
            && Set(prior.keys) == Set(remaining.map(\.source))
        if !nothingNew {
            shelf = await withPending(await build(remaining, sources: sources))
        } else if shelf.saved != savedList.entries {
            // The server's saved list comes alongside the extract — it can change on its own.
            shelf = shelf.with(saved: savedList.entries)
        }
        failure = newFailures
        planFullSync(sources)
        if answered {
            renewed = Date()
            await supply()
        }
    }

    private struct Answer: Sendable {
        let extract: LibraryExtract
        let saved: Set<TitleID>?
    }

    /// A source alone — after an import on the device the title should stand in the
    /// shelf at once, without asking three servers (and without waiting for a running
    /// refresh). Saved list and collections stay as they are.
    /// What the shelf knows of a source — for the "Catalog" section in the account.
    public func catalogRevision(_ identifier: SourceID) -> (title: Int, state: Date)? {
        guard let extract = shelf.extracts.first(where: { $0.source == identifier && !$0.isSupplement })
        else {
            return nil
        }
        return (extract.title.count, extract.state)
    }

    @ObservationIgnored private var fullPlanned: Set<SourceID> = []

    /// The full sync of the sources that fetch only changes — now and then, quietly in the
    /// background, twenty seconds after the start sync: without banner, the app is long
    /// usable. If the app is closed before, it comes the next time.
    ///
    /// **Not while a reader is open** (``retained``): for Grimmory that is 35 MB of catalog and about 500 fetches
    /// of the magic shelves, then store, catalog and a new shelf — almost a minute of network and compute
    /// time. If that ran while scrolling in the webtoon, the first page took 1.6 s and the
    /// reader 60–75 % CPU.
    private func planFullSync(_ sources: [any Source]) {
        for source in sources where source.fullSyncDue && !fullPlanned.contains(source.identifier) {
            let identifier = source.identifier
            fullPlanned.insert(identifier)
            Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                while self?.holdsBack == true {
                    try? await Task.sleep(for: .seconds(5))
                }
                await self?.refresh(only: identifier)
                self?.fullPlanned.remove(identifier)
            }
        }
    }

    /// "Rebuild catalog": take the source out of the catalog and fetch it anew, without the
    /// sync of only the changes — if something looks wrong.
    public func rebuild(_ identifier: SourceID) async {
        if let catalog {
            await Task.detached(priority: .userInitiated) { try? catalog.remove(source: identifier) }.value
            catalogState += 1
        }
        await refresh(only: identifier)
    }

    public func refresh(only identifier: SourceID) async {
        let sources = sources()
        guard let source = sources.first(where: { $0.identifier == identifier }),
            var extract = try? await source.library()
        else { return }
        // Collections and saved list as in the big refresh — otherwise the shelves (also
        // the magic shelves) would drop out of the shelf after a sync of only this source.
        if source.capabilities.contains(.collections) {
            if let collections = try? await source.collections() {
                extract = extract.with(collections: collections)
            } else if let old = shelf.extracts.first(where: { $0.source == identifier && !$0.isSupplement }) {
                extract = extract.with(collections: old.collections)
            }
        }
        if source.capabilities.contains(.savedList), let saved = try? await source.savedList() {
            savedList.adopt(saved, source: identifier)
        }
        await pendingTask?.value
        await writer.write(extract)
        await fillCatalog([extract])
        var extracts = shelf.extracts.filter { $0.source != identifier && !$0.isSupplement }
        extracts.append(extract)
        // Built and precomputed off the main thread like in ``refresh()`` — this runs as the quiet
        // full sync twenty seconds after the start, while the app is in use.
        shelf = await withPending(await build(extracts, sources: sources))
    }

    // MARK: - Saving

    /// Saves or forgets — first in the list, then on the server where there is
    /// one; if it refuses, the list is back as before.
    public func save(_ target: SaveTarget, saved: Bool) async throws {
        let previously = savedList.entries
        if saved { savedList.save(target) } else { savedList.forget(target) }
        shelf = shelf.with(saved: savedList.entries)
        guard case .title(let identifier) = target, let source = source(identifier.source),
            source.capabilities.contains(.savedList)
        else { return }
        do {
            try await source.save(identifier, saved: saved)
        } catch {
            savedList.adopt(
                Set(
                    previously.compactMap { if case .title(let k) = $0 { k } else { nil } }
                        .filter { $0.source == identifier.source }), source: identifier.source)
            shelf = shelf.with(saved: savedList.entries)
            throw SourceError.from(error, source: identifier.source)
        }
    }

    // MARK: - Collections

    /// Puts a target into a collection or takes it out — first on the shelf, then on
    /// the server; if it refuses, the collection is back as before.
    public func arrange(_ target: SaveTarget, in identifier: CollectionID, into: Bool) async throws {
        guard let source = source(identifier.source) else { throw SourceError.unreachable(identifier.source) }
        guard let previously = shelf.collection(identifier) else {
            throw SourceError.notPossible(identifier.source, "Collection unknown")
        }
        shelf = shelf.with(previously.with(target, into: into))
        do {
            try await source.arrange(target, in: identifier, into: into)
        } catch {
            shelf = shelf.with(previously)
            throw SourceError.from(error, source: identifier.source)
        }
        writeStore(identifier.source)
    }

    /// Creates a collection and puts the target into it at once.
    public func create(
        collection name: String, for target: SaveTarget, collectionKind: TitleCollection.CollectionKind
    ) async throws {
        guard let source = source(target.source) else { throw SourceError.unreachable(target.source) }
        do {
            let new = try await source.create(collection: name, collectionKind: collectionKind)
            shelf = shelf.with(new)
            try await arrange(target, in: new.identifier, into: true)
        } catch {
            throw SourceError.from(error, source: target.source)
        }
    }

    private func writeStore(_ source: SourceID) {
        enqueueStore(source)
    }

    /// Schedules a source's extract for bundled writing (``StoreWriter``).
    /// - Parameter statesOnly: only reading states changed — then the writer writes only them.
    private func enqueueStore(_ source: SourceID, statesOnly: Bool = false) {
        guard !regalAusKern,
            let extract = shelf.extracts.first(where: { $0.source == source && !$0.isSupplement })
        else {
            return
        }
        let writer = writer
        let previously = pendingTask
        pendingTask = Task {
            await previously?.value
            await writer.schedule(extract, statesOnly: statesOnly)
        }
    }

    /// After dragging on the saved page — the order is the app's business.
    public func moveSaved(from source: IndexSet, to target: Int) {
        savedList.move(from: source, to: target)
        shelf = shelf.with(saved: savedList.entries)
    }

    // MARK: - Writing

    /// Writes a state optimistically: first onto the shelf, then to the server; if it
    /// refuses, the old state is back and the error goes to the caller.
    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        try await change(identifier, on: state) { source in try await source.write(state, for: identifier) }
    }

    /// Forgets a state — on the server and on the shelf.
    public func forget(progressFor identifier: TitleID) async throws {
        try await change(identifier, on: nil) { source in try await source.forget(progressFor: identifier) }
    }

    // MARK: - Progress: deciding and resubmitting

    /// Before opening a reader: the fresh state from the server against the local one,
    /// by the ``ConflictRule``. What the server wins silently stands on the shelf afterwards;
    /// what wins here is already there. With `.question` the caller decides with
    /// ``adopt(_:for:)`` or ``retain(at:for:)``.
    public func decide(for identifier: TitleID) async -> Resolution {
        let local = shelf.readingState(identifier)
        guard let source = source(identifier.source) else {
            return local.map { .take($0, supply: false) } ?? .begin
        }
        var reachable = true
        var server: ReadingState?
        do {
            server = try await LibraryService.withDeadline(LibraryService.standFrist) {
                try await source.progress(identifier)
            }
        } catch is DeadlineExpired {
            // The server does not answer in time: read with the state from here, as without network
            // — the reader otherwise stood black with a spinner for up to 60 s.
            reachable = false
        } catch {
            reachable = SourceError.from(error, source: identifier.source).final
        }
        let decision = ConflictRule.decide(
            local: local, server: server, own: queue.own(identifier), reachable: reachable)
        Diagnostics.step(
            "Progress: \(identifier.id) here \(local.map { String(format: "%.0f %%", $0.fraction * 100) } ?? "—"), Server \(reachable ? server.map { String(format: "%.0f %%", $0.fraction * 100) } ?? "—" : "unreachable") → \(decision.short)",
            since: nil, area: "Progress")
        switch decision {
        case .take(let state, supply: false) where state != local:
            setState(state, for: identifier)
        case .take(let state, supply: true) where queue.pending(identifier) == nil:
            // Here it is further than on the server — send it, without asking.
            try? await write(state, for: identifier)
        default:
            break
        }
        return decision
    }

    /// How long opening a title waits for the server's state.
    static let standFrist: Duration = .seconds(4)

    struct DeadlineExpired: Error {}

    /// The result of `work`, or ``DeadlineExpired`` after `deadline`.
    nonisolated static func withDeadline<T: Sendable>(
        _ frist: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { cluster in
            cluster.addTask { try await work() }
            cluster.addTask {
                try await Task.sleep(for: frist)
                throw DeadlineExpired()
            }
            defer { cluster.cancelAll() }
            guard let first = try await cluster.next() else { throw DeadlineExpired() }
            return first
        }
    }

    /// Conflict sheet: "Continue there" — the server state holds here.
    public func adopt(_ state: ReadingState, for identifier: TitleID) {
        setState(state, for: identifier)
        queue.remove(identifier)
        pending = queue.all.count
    }

    /// Conflict sheet: "Stay here" — the local state goes to the server so that it
    /// is the truth again.
    public func retain(at state: ReadingState, for identifier: TitleID) async {
        try? await write(
            ReadingState(
                position: state.position, timestamp: Date(), device: state.device,
                completed: state.completed), for: identifier)
    }

    /// Resubmits what was written without network — one after the other, with
    /// stale protection: if the server meanwhile carries a newer, different state, that
    /// one holds and the pending one drops. Definitive refusals (404, 403) clear
    /// the entry, everything else stays until the next attempt.
    public func supply() async {
        guard !suppliesPending, !queue.empty else { return }
        suppliesPending = true
        defer { suppliesPending = false }
        var arrived = 0
        defer { if arrived > 0 { supplied = (arrived, Date()) } }
        for entry in queue.all {
            guard let source = source(entry.identifier.source) else { continue }
            do {
                if let state = entry.state, let server = try await source.progress(entry.identifier),
                    server.timestamp > state.timestamp, !ConflictRule.equal(server, state)
                {
                    setState(server, for: entry.identifier)
                    queue.remove(entry.identifier)
                    Diagnostics.step(
                        "Progress: \(entry.identifier.id) — server was newer, pending state dropped",
                        since: nil, area: "Progress")
                    continue
                }
                if let state = entry.state {
                    try await source.write(state, for: entry.identifier)
                } else {
                    try await source.forget(progressFor: entry.identifier)
                }
                queue.remove(entry.identifier)
                arrived += 1
                Diagnostics.step(
                    "Progress: \(entry.identifier.id) delivered late", since: nil, area: "Progress")
            } catch {
                let failure = SourceError.from(error, source: entry.identifier.source)
                if failure.final {
                    queue.remove(entry.identifier)
                    Diagnostics.network.error(
                        "Progress: \(entry.identifier.description, privacy: .public) discarded: \(String(describing: failure), privacy: .public)"
                    )
                } else {
                    break
                }
            }
        }
        pending = queue.all.count
    }

    /// Sets the read status from the context menu: Unread forgets the state,
    /// Started writes the beginning, Read the end — as page,
    /// second or fraction depending on the scope, so that every server understands it.
    public func set(_ status: ReadStatus, for identifier: TitleID) async throws {
        guard let title = shelf.title(identifier) else { return }
        switch status {
        case .unread:
            try await forget(progressFor: identifier)
        case .started:
            try await write(
                ReadingState(position: LibraryService.start(title.scope), timestamp: Date()), for: identifier)
        case .read:
            try await write(
                ReadingState(
                    position: LibraryService.end(title.scope), timestamp: Date(), completed: true),
                for: identifier)
        }
    }

    /// "All read" in the series detail — volume by volume, those already read
    /// skipped; the first error aborts, what was before stays.
    public func allRead(_ series: SeriesID) async throws {
        for volume in shelf.volumes(series) where shelf.readingState(volume.identifier)?.completed != true {
            try await set(.read, for: volume.identifier)
        }
    }

    private func change(
        _ identifier: TitleID, on state: ReadingState?, _ action: (any Source) async throws -> Void
    ) async throws {
        guard let source = source(identifier.source) else { throw SourceError.unreachable(identifier.source) }
        let previously = readingState(identifier)
        setState(state, for: identifier)
        queue.save(own: state, for: identifier)
        do {
            try await action(source)
            queue.remove(identifier)
        } catch {
            let failure = SourceError.from(error, source: identifier.source)
            guard failure.final else {
                // No network: the state stays here and goes there later.
                queue.spot(state, for: identifier)
                pending = queue.all.count
                enqueueStore(identifier.source, statesOnly: true)
                return
            }
            setState(previously, for: identifier)
            throw failure
        }
        pending = queue.all.count
        enqueueStore(identifier.source, statesOnly: true)
    }

    static func start(_ scope: Scope) -> ReadingState.Position {
        switch scope {
        case .pages(let n): return .page(1, from: n)
        case .duration(let d): return .second(1, from: d)
        case .unknown: return .fraction(0.001)
        }
    }

    static func end(_ scope: Scope) -> ReadingState.Position {
        switch scope {
        case .pages(let n): return .page(n, from: n)
        case .duration(let d): return .second(d, from: d)
        case .unknown: return .fraction(1)
        }
    }

    // MARK: - Helpers

    /// The order of the bar — manga, books, audiobooks — so that the entries
    /// of "All" do not lie differently with every refresh.
    /// The genuine extracts plus per source a supplemented one with the kept titles that are in
    /// no catalog. Supplemented ones from before drop out and are built anew.
    nonisolated static func withStock(_ extracts: [LibraryExtract], _ stock: [Title]) -> [LibraryExtract] {
        let genuine = extracts.filter { !$0.isSupplement }
        guard !stock.isEmpty else { return genuine }
        var known = Set<TitleID>()
        for extract in genuine { for t in extract.title { known.insert(t.identifier) } }
        let missing = stock.filter { !known.contains($0.identifier) }
        let perSource = Dictionary(grouping: missing) { $0.identifier.source }
        let supplemented = perSource.keys.sorted { $0.description < $1.description }.map { source in
            // The reading states come from the store of the genuine extract, if there is one.
            let states = genuine.first { $0.source == source }?.readingStates ?? [:]
            let title = perSource[source] ?? []
            return LibraryExtract(
                source: source, seriesList: [], title: title,
                readingStates: states.filter { k, _ in title.contains { $0.identifier == k } }, state: Date(),
                isSupplement: true)
        }
        return genuine + supplemented
    }

    nonisolated static func ordered(_ extracts: [LibraryExtract]) -> [LibraryExtract] {
        let rang = Dictionary(uniqueKeysWithValues: Provider.allCases.enumerated().map { ($1, $0) })
        return extracts.sorted { a, b in
            let x = rang[a.source.provider] ?? 9
            let y = rang[b.source.provider] ?? 9
            return x != y ? x < y : a.source.server < b.source.server
        }
    }

    static func capabilities(_ sources: [any Source]) -> [SourceID: Capabilities] {
        Dictionary(sources.map { ($0.identifier, $0.capabilities) }) { a, _ in a }
    }
}

// MARK: - Remembered derivations

extension LibraryService {

    /// ``Shelf/parts(kind:genre:author:publisher:collection:sorting:filtering:)``, remembered until
    /// the next change of the shelf.
    ///
    /// The library asked anew on every pass — 4 to 9 ms with 1,700 titles, on a device
    /// twice that, i.e. a lost frame on every reading state, every download step,
    /// every tab change. Whoever reads here reads `shelf` too and is
    /// redrawn on a change.
    public func parts(
        kind: Kind? = nil, genre: Shelf.Genre.EntryKey? = nil, author: String? = nil,
        publisher: String? = nil,
        collection: CollectionID? = nil, sorting: Sorting, filtering: Filtering = Filtering()
    ) -> [Shelf.Part] {
        let shelf = shelf
        let lookupKey = ShelfMemo.EntryKey(
            kind: kind, genre: genre, author: author, publisher: publisher, collection: collection,
            sorting: sorting,
            filtering: filtering)
        if let saved = memo.parts[lookupKey] { return saved }
        let new = shelf.parts(
            kind: kind, genre: genre, author: author, publisher: publisher, collection: collection,
            sorting: sorting,
            filtering: filtering)
        memo.parts[lookupKey] = new
        return new
    }

    /// The genres of a kind: from the catalog (numbers as in the filter sheet, books instead of
    /// bundled series), loaded in the background and remembered until the next change; until it has
    /// answered, from the shelf.
    ///
    /// **An empty answer is remembered too.** If only a full one counted as remembered,
    /// every empty one asked anew at once — and because the answer went into an observed value,
    /// the shell rebuilt, asked again, endlessly: 100 % CPU at idle (simulator,
    /// iPad), an empty battery on the tablet and a stuttering reader, since the shell lies beneath it.
    public func genres(_ kind: Kind? = nil) -> [Shelf.Genre] {
        let state = catalogState
        if let catalog {
            // An empty catalog (first launch, not yet filled) shows the genres of the shelf.
            if let saved = catalogGenres[kind], saved.state == state {
                if !saved.list.isEmpty { return saved.list }
            } else {
                ladeGenres(kind, catalog: catalog, state: state)
                if let old = catalogGenres[kind], !old.list.isEmpty { return old.list }
            }
        }
        let shelf = shelf
        if let saved = memo.genres[kind] { return saved }
        let new = shelf.genres(kind)
        memo.genres[kind] = new
        return new
    }

    /// What stands in a shelf as the grid knows it — also the titles the shelf does not hold in
    /// memory (catalog). Remembered until the next change.
    public func entries(in collection: TitleCollection) -> [Shelf.Item] {
        let lookupKey = collection.identifier.description + "#\(catalogState)"
        if let saved = memo.collections[lookupKey] { return saved }
        // What neither shelf nor backfilled knows, with one bulk query from the catalog instead of
        // one per title (a 609 ms hang in the library).
        let missing = collection.entries.compactMap { target -> TitleID? in
            guard case .title(let k) = target, shelf.title(k) == nil, backfilled[k] == nil else { return nil }
            return k
        }
        let fromCatalog = missing.isEmpty ? [:] : ((try? catalog?.title(missing)) ?? [:])
        var seen = Set<String>()
        let list = collection.entries.compactMap { target -> Shelf.Item? in
            let e: Shelf.Item?
            switch target {
            case .title(let k): e = (shelf.title(k) ?? backfilled[k] ?? fromCatalog[k]).map { .title($0) }
            case .series(let k): e = series(k).map { .series($0) }
            }
            guard let e, seen.insert(e.id).inserted else { return nil }
            return e
        }
        memo.collections[lookupKey] = list
        return list
    }

    /// How many entries a collection has and which kinds are in it — **without reading a title
    /// and without the main thread**: the row under each
    /// collection and the filter by kind loaded every collection fully from the catalog for it, on an
    /// iPhone 605 ms on the main thread; even just looking up the kinds cost 660 ms with the
    /// big magic shelves of Grimmory. Therefore: what the shelf knows, at once; what
    /// the catalog contributes, in the background — afterwards ``overviewState`` counts up, and whoever
    /// read the overview sees the complete one. Counts like ``entries(in:)``: every entry
    /// once, unknown ones not.
    public func overview(in collection: TitleCollection) -> (count: Int, kinds: Set<Kind>) {
        _ = overviewState
        let lookupKey = collection.identifier.description + "#\(catalogState)"
        if let saved = memo.overviews[lookupKey] { return saved }
        let missing = collection.entries.compactMap { target -> TitleID? in
            guard case .title(let k) = target, shelf.title(k) == nil, backfilled[k] == nil else { return nil }
            return k
        }
        let provisional = tally(collection, catalogKinds: [:])
        guard !missing.isEmpty, let catalog else {
            memo.overviews[lookupKey] = provisional
            return provisional
        }
        if overviewRuns.insert(lookupKey).inserted {
            Task {
                let kinds = await Task.detached(priority: .userInitiated) {
                    (try? catalog.kinds(missing)) ?? [:]
                }.value
                overviewRuns.remove(lookupKey)
                memo.overviews[lookupKey] = tally(collection, catalogKinds: kinds)
                overviewState += 1
            }
        }
        return provisional
    }

    /// Counts the entries of a collection — shelf and backfilled, plus the kinds from the catalog.
    private func tally(
        _ collection: TitleCollection, catalogKinds: [String: Kind]
    ) -> (count: Int, kinds: Set<Kind>) {
        var seen = Set<String>()
        var kinds = Set<Kind>()
        for target in collection.entries {
            let kind: Kind?
            let id: String
            switch target {
            case .title(let k):
                id = k.description
                kind = (shelf.title(k) ?? backfilled[k])?.kind ?? catalogKinds[k.description]
            case .series(let k):
                id = k.description
                kind = series(k)?.kind
            }
            guard let kind, seen.insert(id).inserted else { continue }
            kinds.insert(kind)
        }
        return (seen.count, kinds)
    }

    /// The first three covers of a shelf — for its card.
    public func cover(for collection: TitleCollection) -> [Shelf.CoverReference] {
        entries(in: collection).prefix(3).map {
            Shelf.CoverReference(address: $0.cover, source: $0.source, kind: $0.kind)
        }
    }

    /// The authors of a kind — from the catalog (all books, not just the shelf), loaded in the
    /// background; until then from the shelf. Image and description still come from the
    /// author entry of the server.
    public func authors(_ kind: Kind? = nil) -> [Shelf.Author] {
        let state = catalogState
        if let catalog {
            // An empty answer is remembered too — reasoning at ``genres(_:)``.
            if let saved = catalogAuthors[kind], saved.state == state {
                if !saved.list.isEmpty { return saved.list }
            } else {
                loadAuthors(kind, catalog: catalog, state: state)
                if let old = catalogAuthors[kind], !old.list.isEmpty { return old.list }
            }
        }
        return shelf.authors(kind)
    }

    private func loadAuthors(_ kind: Kind?, catalog: CatalogIndex, state: Int) {
        let lookupKey = "autoren-" + (kind?.rawValue ?? "alle") + "#\(state)"
        guard genreRuns.insert(lookupKey).inserted else { return }
        let maxAge = maxAge
        let serverAuthors = shelf.extracts.flatMap(\.authors)
        Task {
            let list = await Task.detached(priority: .userInitiated) { () -> [Shelf.Author] in
                let raw = (try? catalog.authorOverview(kind: kind, maxAge: maxAge)) ?? []
                // Look up the server entry per name once, not the whole list per author
                // (25,000 entries with Grimmory) — with image preferred.
                var references: [String: AuthorReference] = [:]
                for b in serverAuthors {
                    let k = AuthorName.lookupKey(b.name)
                    if references[k] == nil || (references[k]?.image == nil && b.image != nil) {
                        references[k] = b
                    }
                }
                var combined: [String: (name: String, count: [Kind: Int])] = [:]
                for (name, count) in raw {
                    let k = AuthorName.lookupKey(name)
                    var entry = combined[k] ?? (name, [:])
                    entry.count.merge(count, uniquingKeysWith: +)
                    combined[k] = entry
                }
                return combined.map { k, e in
                    Shelf.Author(
                        lookupKey: k, name: e.name, count: e.count, cover: nil, reference: references[k])
                }
                .sorted { Shelf.byLastName($0.name) < Shelf.byLastName($1.name) }
            }.value
            genreRuns.remove(lookupKey)
            catalogAuthors[kind] = (state, list)
        }
    }

    private func ladeGenres(_ kind: Kind?, catalog: CatalogIndex, state: Int) {
        let lookupKey = (kind?.rawValue ?? "alle") + "#\(state)"
        guard genreRuns.insert(lookupKey).inserted else { return }
        let maxAge = maxAge
        Task {
            let list = await Task.detached(priority: .userInitiated) {
                (try? catalog.genreOverview(kind: kind, maxAge: maxAge)) ?? []
            }.value
            genreRuns.remove(lookupKey)
            catalogGenres[kind] = (state, list)
        }
    }
}

/// The memo of the ``LibraryService`` — outside observation, so that remembering
/// during a pass does not trigger a new one.
@MainActor
final class ShelfMemo {

    struct EntryKey: Hashable {
        let kind: Kind?
        let genre: Shelf.Genre.EntryKey?
        let author: String?
        let publisher: String?
        let collection: CollectionID?
        let sorting: Sorting
        let filtering: Filtering
    }

    var parts: [EntryKey: [Shelf.Part]] = [:]
    var genres: [Kind?: [Shelf.Genre]] = [:]
    var collections: [String: [Shelf.Item]] = [:]
    var overviews: [String: (count: Int, kinds: Set<Kind>)] = [:]

    func clearOut() {
        parts.removeAll(keepingCapacity: true)
        genres.removeAll(keepingCapacity: true)
        collections.removeAll(keepingCapacity: true)
        overviews.removeAll(keepingCapacity: true)
    }
}
