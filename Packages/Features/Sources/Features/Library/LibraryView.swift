import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The library: segment above genre row above grid. The segment shows only kinds that a
/// source delivers; the genre row is missing below two genres; the grid becomes a list
/// from the accessibility sizes on.
///
/// On iPad no split view of its own any more (in landscape two sidebars stood next to
/// each other): the genres live in the shell's system sidebar, and a genre chosen there
/// comes in as ``genre``; the header is then the genre name, without segment and genre
/// row. Without a genre, every size class shows the same stack as on iPhone, with the
/// genre row, which on iPad portrait is the way to a genre.
struct LibraryView: View {

    /// The genre from the sidebar, with its kind; `nil` is the whole library.
    var genre: (kind: Kind, lookupKey: Shelf.Genre.EntryKey)? = nil

    @Environment(LibraryService.self) private var inventory
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.dynamicTypeSize) private var fontSize
    @State private var lock = SwipeLock()
    @AppStorage("library.segment") private var segment = ""
    @AppStorage(ViewMode.storeKey) private var viewModeValue = ViewMode.bookSeriesList.rawValue

    /// The view: titles, series or collections.
    private var viewMode: Binding<ViewMode> {
        Binding(
            get: { ViewMode(rawValue: viewModeValue) ?? .bookSeriesList },
            set: { viewModeValue = $0.rawValue })
    }

    /// The chosen segment; `nil` is "All". Stored so it is still there on the next open;
    /// a kind that no longer exists falls back to "All".
    private var kind: Binding<Kind?> {
        Binding(
            get: {
                guard let a = Kind(rawValue: segment), inventory.shelf.kinds.contains(a) else { return nil }
                return a
            },
            set: { segment = $0?.rawValue ?? "" })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let genre {
                    genreContent(genre.kind, genre.lookupKey)
                } else {
                    content
                }
            }
            .targets()
        }
    }

    /// The tab for a genre from the sidebar: the genre page's grid with the genre name as
    /// header, sorting "Series" as there.
    private func genreContent(_ kind: Kind, _ lookupKey: Shelf.Genre.EntryKey) -> some View {
        ShelfView(
            kind: kind, genre: lookupKey, title: GenreRow.name(lookupKey),
            preset: Sorting.defaultInGenre(for:)
        ) {
            DisruptionBanner()
            StatusBanner()
        }
        .navigationTitle(GenreRow.name(lookupKey))
    }

    private var content: some View {
        segmentContent
            // Swiping changes the segment: horizontal, clearly more horizontal than
            // vertical so scrolling is unaffected; the stack behind stays, only the
            // choice changes.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > 60, abs(dx) > abs(dy) * 2 else { return }
                        // If the drag began on a scrolling row (genres, shelves), it scrolls.
                        guard !lock.locked(value.startLocation) else { return }
                        switchSegment(before: dx < 0)
                    }
            )
            .environment(lock)
    }

    /// One segment onward: left goes forward, right goes back, and at the ends it wraps:
    /// after "Audiobooks" comes "All" again, and before "All" comes "Audiobooks".
    private func switchSegment(before: Bool) {
        let bookSeries: [Kind?] = [nil] + inventory.shelf.kinds
        guard bookSeries.count > 1, let i = bookSeries.firstIndex(of: kind.wrappedValue) else { return }
        let target = (i + (before ? 1 : bookSeries.count - 1)) % bookSeries.count
        Haptics.selection()
        withAnimation(Motion.short(calm)) { kind.wrappedValue = bookSeries[target] }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch viewMode.wrappedValue {
        case .collections:
            CollectionGrid(kind: kind.wrappedValue, viewMode: viewMode) {
                viewHeader("square.stack")
                header
            }
            .navigationTitle(Text(app: "tab.library"))
            .withoutBar()
        case .authors:
            AuthorList(kind: kind.wrappedValue) {
                viewHeader("person.2")
                header
            }
            .navigationTitle(Text(app: "tab.library"))
            .withoutBar()
        case .shelf:
            // Books as objects: the shelf made of book spines.
            BookSpineShelf(kind: kind.wrappedValue) {
                viewHeader("books.vertical.fill")
                header
            }
            .navigationTitle(Text(app: "tab.library"))
            .withoutBar()
        default:
            ShelfView(
                kind: kind.wrappedValue, genre: nil, viewMode: viewMode, title: Text(app: "tab.library"),
                gridTitle: Text(appKey: LibraryView.shelfHeader(kind.wrappedValue)), save: true
            ) {
                header
                // Both row blocks including headings and the space between are one
                // surface for the swipe lock: a drag used to begin in the gap and the
                // segment changed.
                VStack(alignment: .leading, spacing: 20) {
                    GenreRow(kind: kind.wrappedValue)
                    CollectionRow(kind: kind.wrappedValue)
                }
                .swipeLocked()
            }
            .navigationTitle(Text(app: "tab.library"))
            // The view decides whether series are bundled; the library computes it.
            .onChange(of: viewModeValue, initial: true) { _, value in
                inventory.bookSeriesList = ViewMode(rawValue: value) == .title ? [] : Shelf.bookSeriesDefault
            }
        }
    }

    /// The header row of the views without a grid: title, the menu only with the view
    /// picker, the account circle.
    private func viewHeader(_ glyph: String) -> some View {
        PageHeader {
            PageTitle(text: Text(app: "tab.library"))
        } trailing: {
            Menu {
                ViewModePicker(viewMode: viewMode)
            } label: {
                Label(app: "sorting.menu", systemImage: glyph)
            }
            .labelStyle(.iconOnly)
            .glassCircle()
            AccountCircle().glassCircle()
        }
    }

    /// Banner, segment and counter, the same above every view.
    @ViewBuilder
    private var header: some View {
        DisruptionBanner()
        StatusBanner()
        // From the accessibility sizes on, a menu instead of four segment rows, and the
        // counter row is dropped; otherwise the first cover lies below the fold.
        if inventory.shelf.kinds.count > 1 {
            if fontSize.isAccessibilitySize {
                Picker(selection: kind) {
                    ForEach(fields, id: \.value) { field in
                        field.name.tag(field.value)
                    }
                } label: {
                    Text(app: "segment.alle")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast, alignment: .leading)
                .padding(.horizontal)
            } else {
                Segment(selection: kind, fields: fields)
                    .padding(.horizontal)
            }
        }
    }

    private var fields: [(value: Kind?, name: Text)] {
        [(nil, Text(app: "segment.alle"))]
            + inventory.shelf.kinds.map { ($0, Text(appKey: $0.segmentKey)) }
    }

    /// "21 series, 599 volumes, 930 books, 12 audiobooks" under "All", otherwise only the
    /// chosen kind.
    private var counter: String {
        let kinds = kind.wrappedValue.map { [$0] } ?? inventory.shelf.kinds
        return kinds.map { LibraryView.counterText($0, inventory.shelf.counter($0)) }.joined(
            separator: " · ")
    }

    /// "All series" / "All books" / "All audiobooks" / "Everything": the header above the
    /// grid that separates it from the genre row.
    static func shelfHeader(_ kind: Kind?) -> String {
        switch kind {
        case .manga: "shelf.all.manga"
        case .book: "shelf.all.book"
        case .audiobook: "shelf.all.audiobook"
        case .podcast: "shelf.all.podcast"
        case nil: "shelf.all"
        }
    }

    /// With an active filter "Books" instead of "All books", since not all remain.
    static func shortHeader(_ kind: Kind?) -> String {
        switch kind {
        case .manga: "shelf.short.manga"
        case .book: "shelf.short.book"
        case .audiobook: "shelf.short.audiobook"
        case .podcast: "shelf.short.podcast"
        case nil: "shelf.short"
        }
    }

    static func counterText(_ kind: Kind, _ z: Shelf.Counter) -> String {
        switch kind {
        case .manga:
            Phrase.from("counter.seriesList", z.seriesList) + " · " + Phrase.from("counter.volumes", z.title)
        case .book: Phrase.from("counter.books", z.title)
        case .audiobook: Phrase.from("counter.audiobooks", z.title)
        case .podcast:
            Phrase.from("counter.podcasts", z.seriesList) + " · " + Phrase.from("counter.episodes", z.title)
        }
    }
}

/// The grid with sorting and filter, shared by the library and the genre page. The header
/// (segment, genre row) comes from the caller.
struct ShelfView<Header: View>: View {

    let kind: Kind?
    let genre: Shelf.Genre.EntryKey?
    /// Narrowed to an author: the page behind the author hit in search.
    var author: String? = nil
    /// Narrowed to a publisher: the page behind the publisher link in the detail.
    var publisher: String? = nil
    /// Narrowed to a collection, ordered as the server orders it.
    var collection: CollectionID? = nil
    /// The view choice in the menu; only the library itself has it.
    var viewMode: Binding<ViewMode>? = nil
    /// With a title the header row sits in the content (title, menu, account) and the
    /// system bar stays off (the tab); without a title the bar carries the menu, as on
    /// the pages behind (genre, author, shelf).
    var title: Text? = nil
    /// The sorting while nobody chooses one; the genre page bundles by series.
    var preset: (Kind?) -> Sorting = Sorting.preset(for:)
    /// The title in the ``GridHeader``, "All books"; none on pages with their own title.
    var gridTitle: Text? = nil
    /// Remember filter and sorting per kind across restarts, only for the library itself;
    /// pages behind cards are places and remember nothing.
    var save = false
    @ViewBuilder let header: Header

    @Environment(LibraryService.self) private var inventory
    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width
    @State private var sortings: [Kind?: Sorting] = [:]
    /// The filters per segment, remembered like the sorting while the view lives.
    @State private var filterings: [Kind?: Filtering] = [:]
    @State private var filterSheet = false
    /// The filter before the last change, for "Remove last filter" at zero hits.
    @State private var previous: [Kind?: Filtering] = [:]
    @State private var loaded = false
    /// The grid from the catalog, page by page.
    @State private var list = CatalogList()
    @Environment(\.profileSettings) private var settings

    private var sorting: Sorting { sortings[kind] ?? preset(kind) }
    private var filtering: Binding<Filtering> {
        Binding(get: { filterings[kind] ?? Filtering() }, set: { filterings[kind] = $0 })
    }

    /// From the catalog, except for an ordered reading list, whose order only it knows.
    private var fromCatalog: Bool { inventory.catalog != nil && !collectionOrdered }

    private var catalogKey: CatalogList.EntryKey {
        CatalogList.EntryKey(
            query: catalogQuery(filtering.wrappedValue), unfiltered: catalogQuery(Filtering()),
            bundled: inventory.bookSeriesList, catalog: inventory.catalogState,
            readingState: inventory.readingStateState)
    }

    var body: some View {
        let filter = filtering.wrappedValue
        let parts =
            fromCatalog
            ? list.parts(sorting)
            : inventory.parts(
                kind: kind, genre: genre, author: author, publisher: publisher, collection: collection,
                sorting: sorting,
                filtering: filter)
        let mixed = kind == nil
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                    if let title {
                        PageHeader {
                            PageTitle(text: title)
                        } trailing: {
                            if viewMode != nil { menu.glassCircle() }
                            AccountCircle().glassCircle()
                        }
                    }
                    header
                        .environment(
                            \.filterRequest,
                            acceptFilterRequest ? FilterRequestAcceptance { w in take(w, reader) } : nil)
                    Color.clear.frame(height: 0).id(ShelfView.gridAnchor)
                    if inventory.shelf.empty && !inventory.ready {
                        // Persistence is still reading: show nothing instead of briefly "empty".
                        EmptyView()
                    } else if inventory.shelf.empty {
                        // Nothing there yet: the worm on the empty board, three ways forward.
                        EmptyShelf()
                    } else {
                        // The grid header sticks to the top while scrolling; the section
                        // headers (A, B, author) sit below it in the flow.
                        Section {
                            if fromCatalog && !list.ready {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                            } else if parts.isEmpty, !filter.empty {
                                noHits
                            } else if parts.isEmpty {
                                EmptyState(
                                    glyph: "line.3.horizontal.decrease.circle",
                                    title: Text(app: genre != nil ? "filter.empty.genre" : "filter.empty"))
                            } else {
                                ForEach(parts) { part in
                                    VStack(alignment: .leading, spacing: 12) {
                                        if let header = part.header {
                                            SectionHeader(header: header)
                                        }
                                        raster(part, mixed: mixed)
                                    }
                                }
                            }
                        } header: {
                            GridHeader(
                                title: filter.empty
                                    ? gridTitle
                                    : gridTitle.map { _ in Text(appKey: LibraryView.shortHeader(kind)) },
                                counter: counter(hit: parts, filter: filter),
                                sorting: Binding(get: { sorting }, set: { sortings[kind] = $0 }),
                                sortings: Sorting.allCases,
                                sortingLocked: collectionOrdered,
                                filtering: filtering,
                                names: filterNames(filter),
                                showFilters: { filterSheet = true })
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .scrubHandle()
        // Paper here too: without it the library stood on system black and the detail on
        // paper, and the theme showed on only half the app.
        .paper()
        // The soft edge under the bar, otherwise covers scroll sharply under the title.
        .softEdge()
        .refreshable { await inventory.refresh() }
        // `AKARI_PROBE=filter` opens the sheet, `filterchips` sets two criteria,
        // `reihenluecken` sets the filter "Series with gaps", for a screenshot in the
        // headless simulator.
        .onAppear {
            switch ProcessInfo.processInfo.environment["AKARI_PROBE"] {
            case "filter": filterSheet = true
            case "filterchips":
                var f = Filtering()
                f.formats = ["EPUB"]
                f.years = 2012...2013
                filtering.wrappedValue = f
            case "keinetreffer":
                var f = Filtering()
                f.genres = ["Krimi & Thriller"]
                filtering.wrappedValue = f
                f.formats = ["Keins"]
                filtering.wrappedValue = f
            case "reihenluecken":
                var f = Filtering()
                f.gaps = true
                filtering.wrappedValue = f
            default: break
            }
        }
        .withoutBar(title != nil)
        .sheet(isPresented: $filterSheet) {
            if let catalog = inventory.catalog {
                FilterSheet(
                    filtering: filtering,
                    source: FilterSource(
                        catalog: catalog, bundled: inventory.bookSeriesList, shelves: shelfChoice,
                        query: { f in catalogQuery(f) }))
            }
        }
        // Remembered per kind and profile: read on open, written on every change.
        .task(id: kind) { readSaved() }
        .task(id: fromCatalog ? catalogKey : nil) {
            guard fromCatalog else { return }
            await list.question(catalogKey, catalog: inventory.catalog)
        }
        .onChange(of: filterings) { old, _ in
            previous[kind] = old[kind] ?? Filtering()
            writeSaved()
        }
        .onChange(of: sortings) { writeSaved() }
    }

    /// The grid of a section: tiles, rows from the accessibility sizes on.
    @ViewBuilder
    private func raster(_ part: Shelf.Part, mixed: Bool) -> some View {
        if fontSize.isAccessibilitySize {
            VStack(spacing: 12) {
                ForEach(part.entries) { e in
                    EntryRow(
                        entry: e,
                        secondaryLine: sorting == .bookSeries ? ShelfView.bookSeriesRow(e) : nil,
                        withKind: mixed
                    )
                    .onAppear { if fromCatalog { list.appears(e.id) } }
                }
            }
            .padding(.horizontal)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: TileMetrics.raster(width), maximum: TileMetrics.gridCap(width)),
                        spacing: 12, alignment: .top)
                ],
                alignment: .leading, spacing: 20
            ) {
                ForEach(part.entries) { e in
                    EntryTile(
                        entry: e, width: TileMetrics.raster(width), withKind: mixed,
                        secondaryLine: sorting == .bookSeries ? ShelfView.bookSeriesRow(e) : nil
                    )
                    .onAppear { if fromCatalog { list.appears(e.id) } }
                }
            }
            .padding(.horizontal)
        }
    }

    /// The query to the catalog for a filter state; on a shelf's page narrowed to that
    /// shelf's titles.
    private func catalogQuery(_ f: Filtering) -> CatalogQuery {
        var a = inventory.catalogQuery(
            kind: kind, genre: genre, author: author, publisher: publisher, sorting: sorting, filtering: f)
        if let collection, let s = inventory.shelf.collection(collection) {
            var selection = CatalogQuery.Selection()
            for target in s.entries {
                switch target {
                case .title(let k): selection.title.insert(k.description)
                case .series(let k): selection.seriesList.insert(k.description)
                }
            }
            a.selection.append(selection)
        }
        return a
    }

    /// The shelves to choose from in the filter sheet; none on a shelf's page.
    private var shelfChoice: [ShelfChoice] {
        guard collection == nil else { return [] }
        return inventory.shelf.collections.map {
            ShelfChoice(identifier: $0.identifier.description, name: $0.name, automatic: $0.automatic)
        }
    }

    private func filterNames(_ f: Filtering) -> FilterNames {
        var n = FilterNames()
        for r in shelfChoice where f.shelves.contains(r.identifier) { n.shelves[r.identifier] = r }
        if !f.seriesList.isEmpty, let catalog = inventory.catalog {
            n.seriesList = (try? catalog.seriesNames(Array(f.seriesList))) ?? [:]
        }
        return n
    }

    /// Without a filter "37,214 books", with one "418 of 37,214".
    private func counter(hit: [Shelf.Part], filter: Filtering) -> String {
        if fromCatalog {
            return Filtering.counter(hit: list.hit, total: list.withoutFilter) {
                ShelfView.unitLabel(kind, $0)
            }
        }
        let count = hit.reduce(0) { $0 + $1.entries.count }
        let total =
            filter.empty
            ? count
            : inventory.parts(
                kind: kind, genre: genre, author: author, publisher: publisher, collection: collection,
                sorting: sorting
            ).reduce(0) { $0 + $1.entries.count }
        return Filtering.counter(hit: count, total: total) { ShelfView.unitLabel(kind, $0) }
    }

    /// An ordered reading list keeps its order, so no sort pill.
    private var collectionOrdered: Bool {
        guard let collection else { return false }
        return inventory.shelf.collection(collection)?.ordered == true
    }

    static var gridAnchor: String { "raster" }

    /// Zero hits: the searching worm and two ways back, undo the last step or clear
    /// everything. The former exists only if the previous state itself filtered;
    /// otherwise both buttons would do the same.
    private var noHits: some View {
        let previously = previous[kind]
        return EmptyState(
            worm: Text(app: "filter.noHits"), text: Text(app: "filter.noHits.text"), pose: .seek
        ) {
            VStack(spacing: 10) {
                if let previously, !previously.empty, previously != filtering.wrappedValue {
                    Button {
                        withAnimation { filtering.wrappedValue = previously }
                    } label: {
                        Text(app: "filter.removeLast")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    withAnimation { filtering.wrappedValue = Filtering() }
                } label: {
                    Text(app: "filter.removeAll")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Whether cards above the grid offer their genre or shelf as a filter; only in the
    /// library's own catalog grid, not on a genre or shelf page.
    private var acceptFilterRequest: Bool {
        fromCatalog && collection == nil && genre == nil && author == nil
    }

    /// "Apply as filter": genre or shelf into the filter, then scroll to the grid.
    private func take(_ request: FilterRequest, _ reader: ScrollViewProxy) {
        var f = filtering.wrappedValue
        switch request {
        case .genre(let name): f.genres.insert(name)
        case .shelf(let identifier): f.shelves.insert(identifier)
        }
        filtering.wrappedValue = f
        withAnimation { reader.scrollTo(ShelfView.gridAnchor, anchor: .top) }
    }

    private var persistenceKind: String { kind?.rawValue ?? "alle" }

    private func readSaved() {
        guard save, !loaded || filterings[kind] == nil else { return }
        loaded = true
        let decoder = JSONDecoder()
        if let data = settings.data(forKey: "library.filter." + persistenceKind),
            let f = try? decoder.decode(Filtering.self, from: data)
        {
            filterings[kind] = f
        }
        if let value = settings.string(forKey: "library.sort." + persistenceKind),
            let s = Sorting(rawValue: value)
        {
            sortings[kind] = s
        }
    }

    private func writeSaved() {
        guard save else { return }
        if let f = filterings[kind], let data = try? JSONEncoder().encode(f) {
            settings.set(data, forKey: "library.filter." + persistenceKind)
        }
        if let s = sortings[kind] { settings.set(s.rawValue, forKey: "library.sort." + persistenceKind) }
    }

    /// The menu at the top right, now only the view. Sorting and filtering are the pills
    /// in the ``GridHeader`` (one place to filter).
    private var menu: some View {
        Menu {
            if let viewMode { ViewModePicker(viewMode: viewMode) }
        } label: {
            Label(app: "view.menu", systemImage: viewMode?.wrappedValue.glyph ?? "square.grid.3x3")
        }
        .labelStyle(.iconOnly)
    }
}

extension ShelfView {
    /// "37,214 books", "21 series": the unit of the counter per kind.
    static func unitLabel(_ kind: Kind?, _ n: Int) -> String {
        switch kind {
        case .manga: Phrase.from("counter.seriesList", n)
        case .book: Phrase.from("counter.books", n)
        case .audiobook: Phrase.from("counter.audiobooks", n)
        case .podcast: Phrase.from("counter.podcasts", n)
        case nil: Phrase.from("counter.title", n)
        }
    }
}

/// The page behind the publisher link: everything from the publisher, from all sources.
struct PublisherView: View {

    let name: String

    var body: some View {
        ShelfView(kind: nil, genre: nil, publisher: name, preset: Sorting.defaultInGenre(for:)) {
            EmptyView()
        }
        .navigationTitle(Text(verbatim: name))
        .toolbarTitleDisplayMode(.inline)
    }
}

extension ShelfView {
    /// "Volume 2, 2011" under a tile when bundled by series; the reading order then
    /// shows on the entry, not only in its position.
    static func bookSeriesRow(_ entry: Shelf.Item) -> Text? {
        guard case .title(let t) = entry else { return nil }
        var share: [String] = []
        if let volume = t.series?.volume { share.append(Formats.volume(volume, kind: t.kind)) }
        if let date = t.released { share.append(Formats.year(date)) }
        if share.isEmpty, let author = t.authors.first { share.append(author) }
        return share.isEmpty ? nil : Text(verbatim: share.joined(separator: " · "))
    }
}

/// The header of a section in the grid ("A", "A. C. Doyle"), on paper so it stays above
/// the tiles while scrolling.
struct SectionHeader: View {

    let header: Shelf.Part.Header
    @Environment(\.theme) private var theme

    var body: some View {
        text
            .font(Typography.name(.subheadline))
            .foregroundStyle(ColorTheme.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(theme.paper.color)
    }

    private var text: Text {
        switch header {
        case .text(let s): Text(verbatim: s)
        case .withoutBookSeries: Text(app: "shelf.withoutBookSeries")
        case .withoutAuthor: Text(app: "shelf.withoutAuthor")
        }
    }
}

/// The genre row: cards with three fanned covers, "All genres" on the right. Missing
/// below two genres.
struct GenreRow: View {

    let kind: Kind?
    @Environment(LibraryService.self) private var inventory
    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        let genres = inventory.genres(kind)
        if genres.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                RowHeader(title: Text(app: "library.genres"), all: .allGenres(kind))
                if fontSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(genres) { g in
                            NavigationLink(value: Target.genre(kind, g.lookupKey)) {
                                Row(
                                    name: GenreRow.name(g),
                                    secondaryLine: Text(verbatim: Formats.integer(g.count))
                                ) {
                                    Image(systemName: "tag")
                                        .foregroundStyle(ColorTheme.muted.color)
                                        .frame(width: 30)
                                }
                            }
                            .buttonStyle(.plain)
                            .asFilterMenu(g.name.map { .genre($0) })
                        }
                    }
                    .padding(.horizontal)
                } else {
                    TileRow {
                        ForEach(genres) { g in
                            NavigationLink(value: Target.genre(kind, g.lookupKey)) {
                                GenreCard(
                                    name: GenreRow.name(g), count: Text(verbatim: GenreRow.counter(g)),
                                    cover: g.cover.map {
                                        Cover($0.address, source: $0.source, kind: $0.kind, width: 34)
                                    })
                            }
                            .buttonStyle(.plain)
                            .asFilterMenu(g.name.map { .genre($0) })
                        }
                    }
                }
            }
            .swipeLocked()
        }
    }

    /// "3 books", "8 series", under "All" "2 books, 1 audiobook": a number without a
    /// unit raised "3 what?".
    static func counter(_ genre: Shelf.Genre) -> String {
        let share: [String] = Kind.allCases.compactMap { kind in
            guard let n = genre.countPerKind[kind], n > 0 else { return nil }
            switch kind {
            case .manga: return Phrase.from("counter.seriesList", n)
            case .book: return Phrase.from("counter.books", n)
            case .audiobook: return Phrase.from("counter.audiobooks", n)
            case .podcast: return Phrase.from("counter.episodes", n)
            }
        }
        return share.isEmpty ? Formats.integer(genre.count) : share.joined(separator: " · ")
    }

    static func name(_ genre: Shelf.Genre) -> Text {
        name(genre.lookupKey)
    }

    static func name(_ lookupKey: Shelf.Genre.EntryKey) -> Text {
        if case .name(let n) = lookupKey { return Text(verbatim: n) }
        return Text(app: "genre.without")
    }
}

/// The genre page: the same grid, narrowed to one genre.
struct GenreView: View {

    let kind: Kind?
    let genre: Shelf.Genre.EntryKey

    var body: some View {
        ShelfView(kind: kind, genre: genre, preset: Sorting.defaultInGenre(for:)) {
            EmptyView()
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
    }

    private var title: Text { GenreRow.name(genre) }
}

/// Everything by one author, bundled by series like the genre page; the way from the
/// author hit in search.
/// "All genres" as a list, with counter, tappable to the genre page.
struct AllGenresView: View {

    let kind: Kind?

    var body: some View {
        GenreList(kind: kind)
            .navigationTitle(Text(app: "library.genres"))
            .toolbarTitleDisplayMode(.inline)
    }
}

/// The genre list behind "All genres"; it leads to the genre page. It used to double as
/// the iPad split view's sidebar, with an "All" that never counted as selected
/// (`tag(.none)`); the sidebar is now the system's, where "All" is called "Library".
struct GenreList: View {

    let kind: Kind?
    @Environment(LibraryService.self) private var inventory

    var body: some View {
        List(inventory.genres(kind)) { g in
            NavigationLink(value: Target.genre(kind, g.lookupKey)) { line(g) }
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .paper()
    }

    private func line(_ g: Shelf.Genre) -> some View {
        LabeledContent {
            Text(verbatim: Formats.integer(g.count)).monospacedDigit()
        } label: {
            GenreRow.name(g)
        }
    }
}

/// The three views of the library: titles (each book on its own), series (books and
/// audiobooks bundled like manga) and collections (the shelves, reading lists and
/// playlists of the servers as a grid).
enum ViewMode: String, CaseIterable {
    /// `shelf`: the library as a shelf of book spines.
    case title = "titel", bookSeriesList = "reihen", shelf = "regal", collections = "sammlungen", authors =
        "autoren"

    static let storeKey = "library.ansicht"

    var lookupKey: String {
        switch self {
        case .title: "view.title"
        case .bookSeriesList: "view.bookSeriesList"
        case .shelf: "view.shelf"
        case .collections: "view.collections"
        case .authors: "view.authors"
        }
    }

    var glyph: String {
        switch self {
        case .title: "square.grid.3x3"
        case .bookSeriesList: "books.vertical"
        case .shelf: "books.vertical.fill"
        case .collections: "square.stack"
        case .authors: "person.2"
        }
    }
}

/// The "View" section in the library menu.
struct ViewModePicker: View {

    let viewMode: Binding<ViewMode>

    var body: some View {
        Picker(selection: viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { a in
                Label(app: LocalizedStringKey(a.lookupKey), systemImage: a.glyph).tag(a)
            }
        } label: {
            Text(app: "view.title.menu")
        }
        .pickerStyle(.inline)
    }
}

/// The collection view: all collections of the kind as cards in a grid, and a sentence
/// if there are none, because then the way leads through "To collection ...".
struct CollectionGrid<Header: View>: View {

    let kind: Kind?
    let viewMode: Binding<ViewMode>
    @ViewBuilder let header: Header

    @Environment(LibraryService.self) private var inventory
    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        let collections = CollectionRow.matching(inventory, kind: kind)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                RowHeader(title: Text(app: "collection.title"))
                if collections.isEmpty {
                    EmptyState(
                        worm: Text(app: "collection.empty.title"), text: Text(app: "collection.empty.text"))
                } else if fontSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(collections) { s in
                            NavigationLink(value: Target.collection(s.identifier)) {
                                Row(
                                    name: Text(verbatim: s.name),
                                    secondaryLine: Text(verbatim: CollectionRow.line(s, inventory))
                                ) {
                                    Image(systemName: CollectionRow.glyph(s))
                                        .foregroundStyle(ColorTheme.muted.color)
                                        .frame(width: 30)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 118, maximum: 160), spacing: 12, alignment: .top)
                        ],
                        alignment: .leading, spacing: 16
                    ) {
                        ForEach(collections) { s in
                            NavigationLink(value: Target.collection(s.identifier)) {
                                GenreCard(
                                    name: Text(verbatim: s.name),
                                    count: Text(verbatim: CollectionRow.line(s, inventory)),
                                    cover: inventory.cover(for: s).map {
                                        Cover($0.address, source: $0.source, kind: $0.kind, width: 34)
                                    })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
        .paper()
        .refreshable { await inventory.refresh() }
    }
}

extension View {
    /// The scroll edge under the bar (iOS 26); it does not exist on the Mac (test runs).
    /// **Hard** instead of soft: the soft edge blurs what scrolls under the bar, and the
    /// header row (title, sort and profile circle) sits at the height of the tab pill on
    /// iPad; after "Back" it sat a little lower and was blurred.
    ///
    /// Plus paper behind the status bar: the sticky ``GridHeader`` ends at the safe area,
    /// above it the covers kept scrolling and appeared blurred behind the clock. A
    /// background in the header itself does not reach up, because a ScrollView's content
    /// does not ignore the safe area, so the strip lies over the whole scroll area.
    func softEdge() -> some View {
        modifier(ScrollEdge())
    }
}

private struct ScrollEdge: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .scrollEdgeEffectStyle(.hard, for: .top)
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(height: 0)
                        .background(theme.paper.color.ignoresSafeArea(edges: .top))
                        .allowsHitTesting(false)
                }
        #else
            content
        #endif
    }
}
