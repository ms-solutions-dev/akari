import Foundation
import Library
import Observation
import SourcesKit

/// The entries of a grid from the `CatalogIndex`, loaded page by page.
///
/// The grid fetches the first page as soon as kind, filter, sorting or the catalog change,
/// and the next when the last tiles appear. Queries run off the main thread; a page is 120
/// entries and a few milliseconds, even with 35,000 books.
@MainActor
@Observable
final class CatalogList {

    /// What is loaded, in query order.
    private(set) var entries: [Shelf.Item] = []
    /// How many entries the query matches in total.
    private(set) var hit = 0
    /// How many there would be without the filter sheet's criteria, for "418 of 37,214".
    private(set) var withoutFilter = 0
    /// Whether the first page is in place; before that there is no empty state.
    private(set) var ready = false

    /// The query that `entries` answers.
    struct EntryKey: Hashable {
        let query: CatalogQuery
        let unfiltered: CatalogQuery
        let bundled: Set<Kind>
        let state: Int

        /// `state` from the catalog counter, plus the reading-state counter only if the query
        /// filters or sorts by reading state; otherwise every state change reloaded the grid.
        init(
            query: CatalogQuery, unfiltered: CatalogQuery, bundled: Set<Kind>, catalog: Int,
            readingState: Int
        ) {
            self.query = query
            self.unfiltered = unfiltered
            self.bundled = bundled
            let dependsOnState = query.phase != nil || query.sorting == .recentlyRead
            self.state = catalog &* 1_000_003 &+ (dependsOnState ? readingState : 0)
        }
    }

    @ObservationIgnored private var lookupKey: EntryKey?
    @ObservationIgnored private var catalog: CatalogIndex?
    @ObservationIgnored private var loadsMore = false
    @ObservationIgnored private var positions: [String: Int] = [:]
    /// The most recently folded sections; they change only with the entries.
    @ObservationIgnored private var folded: (sorting: Sorting, count: Int, parts: [Shelf.Part])?

    nonisolated static let page = 120

    /// Reloads when the query changed. For the same query against a changed catalog (a
    /// sync, a reading state) it loads as many entries as were already loaded; otherwise
    /// the grid would jump back to the first page on return.
    func question(_ new: EntryKey, catalog: CatalogIndex?) async {
        guard new != lookupKey || self.catalog !== catalog else { return }
        let sameKey =
            lookupKey?.query == new.query && lookupKey?.bundled == new.bundled
            && self.catalog === catalog
        let amount = sameKey ? max(entries.count, CatalogList.page) : CatalogList.page
        lookupKey = new
        self.catalog = catalog
        guard let catalog else {
            set([], hit: 0, withoutFilter: 0)
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            () -> ([Shelf.Item], Int, Int) in
            let list =
                (try? catalog.entries(new.query, bundled: new.bundled, atMost: amount)) ?? []
            let hit =
                (try? catalog.entryCount(new.query, bundled: new.bundled)) ?? list.count
            let without =
                new.unfiltered == new.query
                ? hit
                : ((try? catalog.entryCount(new.unfiltered, bundled: new.bundled)) ?? hit)
            return (list, hit, without)
        }.value
        // A newer query arrived in the meantime; its answer wins.
        guard lookupKey == new else { return }
        set(result.0, hit: result.1, withoutFilter: result.2)
    }

    /// A tile appears: if it lies in the last third of the page, the next page loads.
    func appears(_ id: String) {
        guard let i = positions[id], i >= entries.count - CatalogList.page / 3,
            entries.count < hit, !loadsMore, let lookupKey, let catalog
        else { return }
        loadsMore = true
        let from = entries.count
        Task {
            let more = await Task.detached(priority: .userInitiated) {
                (try? catalog.entries(
                    lookupKey.query, bundled: lookupKey.bundled, from: from,
                    atMost: CatalogList.page)) ?? []
            }.value
            loadsMore = false
            guard self.lookupKey == lookupKey, entries.count == from else { return }
            for (n, e) in more.enumerated() { positions[e.id] = from + n }
            folded = nil
            entries += more
        }
    }

    private func set(_ list: [Shelf.Item], hit: Int, withoutFilter: Int) {
        folded = nil
        entries = list
        positions = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.hit = hit
        self.withoutFilter = withoutFilter
        ready = true
    }

    /// The loaded entries in sections: by first letter for titles, by author for authors, by
    /// series for series; otherwise one section without header. The data arrives sorted, so
    /// merging consecutive equal headers is enough.
    ///
    /// Cached until new entries arrive: the grid asks on every pass, and with a few thousand
    /// loaded entries it folded anew each time.
    func parts(_ sorting: Sorting) -> [Shelf.Part] {
        if let folded, folded.sorting == sorting, folded.count == entries.count {
            return folded.parts
        }
        let new = fold(sorting)
        folded = (sorting, entries.count, new)
        return new
    }

    private func fold(_ sorting: Sorting) -> [Shelf.Part] {
        let header: (Shelf.Item) -> Shelf.Part.Header?
        switch sorting {
        case .title: header = { .text(CatalogList.start($0.name)) }
        case .author:
            header = { e in CatalogList.author(e).map { .text($0) } ?? .withoutAuthor }
        case .bookSeries:
            header = { e in CatalogList.bookSeries(e).map { .text($0) } ?? .withoutBookSeries }
        case .recentlyRead, .recentlyAdded, .rating:
            return entries.isEmpty ? [] : [Shelf.Part(header: nil, entries: entries)]
        }
        var result: [Shelf.Part] = []
        var current: Shelf.Part.Header?
        var collection: [Shelf.Item] = []
        for e in entries {
            let k = header(e)
            if k != current, !collection.isEmpty {
                result.append(Shelf.Part(header: current, entries: collection))
                collection = []
            }
            current = k
            collection.append(e)
        }
        if !collection.isEmpty { result.append(Shelf.Part(header: current, entries: collection)) }
        // A header that returns after a page boundary would have the same identity, and
        // its second part would attach to the first.
        var seen: [String: Int] = [:]
        var together: [Shelf.Part] = []
        for a in result {
            if let i = seen[a.id] {
                together[i] = Shelf.Part(
                    header: together[i].header, entries: together[i].entries + a.entries)
            } else {
                seen[a.id] = together.count
                together.append(a)
            }
        }
        return together
    }

    static func start(_ name: String) -> String {
        guard
            let firstChar = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .first
        else { return "#" }
        return firstChar.isLetter ? String(firstChar).uppercased() : "#"
    }

    static func author(_ e: Shelf.Item) -> String? {
        switch e {
        case .title(let t): t.authors.first
        case .series(let s): s.authors.first
        }
    }

    static func bookSeries(_ e: Shelf.Item) -> String? {
        switch e {
        case .title(let t): t.series?.name
        case .series(let s): s.name
        }
    }
}
