import Bedrock
import Foundation
import SourcesKit
import Synchronization

/// OPDS as a source — 1.2 (Atom) and 2.0 (JSON) through the same ``OpdsFeed``: the catalog is
/// crawled, every acquisition entry becomes a title, every feed full of acquisitions under a
/// series feed becomes a series (in OPDS 2.0 the entry names the series itself:
/// `belongsTo.series` with name and volume number).
///
/// **The crawl:** root → all navigation links (`subsection`), depth by depth; the crawl follows
/// `next` immediately (a list is read to the end before it goes on). It leaves out facets,
/// search, `self`, `alternate`; it sees a feed only once (address), a title only once (entry ID)
/// — Komga and Grimmory list every book under library, series, author and "New". A branch of the
/// root whose feeds bring nothing new five times in a row (no title, no unseen target) is not
/// read further. Caps: 1,000 feeds, depth 4, 5,000 titles — then a deficiency is logged.
///
/// **Reading state: the title decides.** If a comic names the progression API (OPDS 2.0, Komga
/// v2), `progress`, `write` and `forget` go there — the server is the truth, the ``StateStore``
/// only mirrors what this device last saw, so that the shelf shows a state without 700 single
/// fetches. Everything else (Atom catalogs, books from the file) lives in the store alone — as
/// on the device. No saved list and no collections.
///
/// **Individual pages:** via OPDS-PSE (Atom) or the Divina manifest (JSON) — the manifest names
/// the page addresses, so ``content(_:)`` fetches it on the first call in the background and
/// again via `measures`, and ``pageAddress(_:_:)`` reads from the cache.
public final class OpdsSource: Source, Sendable {
    public let account: OpdsAccount
    let fetch: ServerFetch
    let states: StateStore
    /// Divina manifests already fetched: manifest address → pages in reading order.
    let manifests = Mutex<[URL: [OpdsJsonReader.Page]]>([:])

    static let maxFeeds = 1_000
    static let maxDepth = 4
    static let maxTitles = 5_000
    static let maxEmpty = 5

    public init(
        account: OpdsAccount, transport: any Transport = URLSession.forSource(), persistence: URL? = nil
    ) {
        self.account = account
        self.fetch = ServerFetch(baseURL: account.catalog, source: account.identifier, transport: transport)
        self.states = StateStore(file: persistence ?? StateStore.standard(for: account.identifier))
    }

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }
    public func headerLines() -> [String: String] { account.headerLines }

    // MARK: - Sign in

    /// Fetches the root feed with name and password — 200 means: catalog there, access correct.
    /// The title of the feed becomes the name of the account.
    public static func signIn(
        catalog: URL, username: String, password: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> OpdsAccount {
        let probe = OpdsAccount(catalog: catalog, username: username, password: password, title: "")
        let source = OpdsSource(account: probe, transport: transport)
        let (feed, edition) = try await source.feedWithEdition(catalog)
        let search = await source.searchTemplate(feed)
        Diagnostics.step(
            "OPDS \(edition == .json ? "2.0" : "1.2"): catalog \(feed.title) with \(feed.entries.count) entries",
            since: nil, area: "Source")
        return OpdsAccount(
            catalog: catalog, username: username, password: password,
            title: feed.title.isEmpty ? (catalog.host() ?? "OPDS") : feed.title, search: search,
            edition: edition)
    }

    public func verify() async throws {
        _ = try await feed(account.catalog)
    }

    /// The search template: if it is in the link (`{searchTerms}` in the href), it applies; if the
    /// link is a URI template (OPDS 2.0, `templated`, `search{?query}`), it is brought into the same
    /// form; if the link points to an OpenSearch description (Komga, Grimmory), that is fetched.
    /// `{searchTerms}` survives `URL` only percent-encoded — turned back.
    func searchTemplate(_ feed: OpdsFeed) async -> String? {
        guard let link = feed.search else { return nil }
        let address = absolute(link.href, relativeTo: account.catalog)
        var template: String?
        if link.href.contains("{searchTerms}") {
            template = address.absoluteString
        } else if link.template || link.href.contains("{?"),
            let form = OpdsJsonReader.searchTemplate(link.href)
        {
            template = absolute(form, relativeTo: account.catalog).absoluteString
        } else if let data = try? await fetch.data(requestFor(address)).0,
            let t = OpdsParser.searchTemplate(data)
        {
            template = absolute(t, relativeTo: address).absoluteString
        }
        return template?.replacingOccurrences(of: "%7BsearchTerms%7D", with: "{searchTerms}")
    }

    // MARK: - Catalog

    public func library() async throws -> LibraryExtract {
        let start = Date()
        let run = try await crawl()
        let seriesList = OpdsMapping.seriesList(from: run.title, feeds: run.bookSeriesList)
        Diagnostics.step(
            "OPDS \(account.title): \(run.feeds) feeds, \(run.title.count) titles, \(seriesList.count) series",
            since: start, area: "Source")
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: run.title,
            readingStates: states.all(source: identifier),
            state: Date())
    }

    struct Run {
        var title: [Title] = []
        /// Feeds that are a series (acquisition feeds under "Serien" etc.): address → feed title.
        var bookSeriesList: [String: String] = [:]
        var feeds = 0
    }

    /// A feed in the queue: address, depth, title of the parent feed and the branch — the root
    /// entry it hangs under ("All books", "Authors" …).
    struct QueueItem {
        var address: URL
        var depth: Int
        var parent: String?
        var branch: String
    }

    func crawl() async throws -> Run {
        var run = Run()
        var seenFeeds: Set<String> = []
        // What is already in the queue or has been read — a target that a feed names counts as new
        // only if it is still missing here.
        var known: Set<String> = [account.catalog.absoluteString]
        // Entry ID → slot in `run.title`: a title that first came under "New" (without series) and
        // then in its series takes the series along.
        var slot: [String: Int] = [:]
        // Branches that bring nothing new any more: this many acquisition feeds in a row without a new
        // title and without a newly assigned series, and the rest of the branch drops. Grimmory lists
        // every book under "All", "New", the library, the author and the series — the same catalog five
        // times, 700 feeds for 850 books; the old cap of 400 feeds then silently cut off a third.
        var emptyInRow: [String: Int] = [:]
        var dead: Set<String> = []
        var queue: [QueueItem] = [QueueItem(address: account.catalog, depth: 0, parent: nil, branch: "")]
        while !queue.isEmpty, run.feeds < OpdsSource.maxFeeds,
            run.title.count < OpdsSource.maxTitles
        {
            let item = queue.removeFirst()
            let address = item.address
            guard !dead.contains(item.branch) else { continue }
            guard seenFeeds.insert(address.absoluteString).inserted else { continue }
            // A feed that does not exist (404) is a dead branch and is skipped. Everything else — timeout,
            // 5xx, unreadable — gets a second attempt and then aborts the whole crawl: half a catalog would
            // otherwise appear as a whole on the shelf (observed: a series with 20 instead of 74 volumes,
            // another without a series, because pages silently went missing). The old extract then stays.
            let feed: OpdsFeed
            do {
                feed = try await self.feedWithRetry(address)
            } catch SourceError.notFound {
                Diagnostics.deficiency("OPDS feed missing: \(address.path())", since: nil, area: "Source")
                continue
            }
            run.feeds += 1
            let acquisitions = feed.entries.filter {
                $0.acquisition != nil || $0.pageStream != nil || $0.manifest != nil
            }
            let bookSeries: String? =
                !acquisitions.isEmpty && OpdsMapping.isSeries(feed: feed, parent: item.parent)
                ? feed.title : nil
            if let bookSeries { run.bookSeriesList[address.absoluteString] = bookSeries }
            var fresh = 0
            for (spot, e) in acquisitions.enumerated() {
                let id = e.id.isEmpty ? (e.acquisition?.href ?? e.pageStream?.href ?? e.title) : e.id
                if let i = slot[id] {
                    if bookSeries != nil, run.title[i].series == nil,
                        let t = OpdsMapping.title(
                            e, feed: feed, feedAddress: address, bookSeries: bookSeries, slot: spot + 1,
                            source: identifier,
                            resolve: absolute)
                    {
                        run.title[i] = t
                        fresh += 1
                    }
                    continue
                }
                if let t = OpdsMapping.title(
                    e, feed: feed, feedAddress: address, bookSeries: bookSeries, slot: spot + 1,
                    source: identifier,
                    resolve: absolute)
                {
                    slot[id] = run.title.count
                    run.title.append(t)
                    fresh += 1
                }
            }
            // A navigation feed can be empty too: Komga v2 puts the publishers under "Browse" as a group —
            // 18 filter feeds per library, each naming the same series and the same publishers. Only a target
            // the crawl does not yet know counts as new — and only that goes into the queue.
            var children: [QueueItem] = []
            for e in feed.entries where e.acquisition == nil && e.manifest == nil {
                guard let nav = e.navigation else { continue }
                let target = absolute(nav.href, relativeTo: address)
                guard known.insert(target.absoluteString).inserted else { continue }
                fresh += 1
                // The parent name in OPDS 2.0 is the group ("Series"), not the feed.
                children.append(
                    QueueItem(
                        address: target, depth: item.depth + 1, parent: e.cluster ?? feed.title,
                        branch: item.depth == 0 ? (e.title.isEmpty ? target.path() : e.title) : item.branch)
                )
            }
            if !feed.entries.isEmpty {
                emptyInRow[item.branch] = fresh == 0 ? (emptyInRow[item.branch] ?? 0) + 1 : 0
                if (emptyInRow[item.branch] ?? 0) >= OpdsSource.maxEmpty {
                    dead.insert(item.branch)
                    Diagnostics.step(
                        "OPDS: branch \(item.branch) brings nothing new any more — skipped", since: nil,
                        area: "Source")
                    continue
                }
            }
            // The next page comes before everything else: a list is read to the end before the crawl
            // goes into the branches — otherwise "All books, page 6" ends up behind a hundred author feeds.
            if let next = feed.next, item.depth <= OpdsSource.maxDepth,
                known.insert(absolute(next.href, relativeTo: address).absoluteString).inserted
            {
                queue.insert(
                    QueueItem(
                        address: absolute(next.href, relativeTo: address), depth: item.depth,
                        parent: item.parent, branch: item.branch), at: 0)
            }
            guard item.depth < OpdsSource.maxDepth else { continue }
            queue.append(contentsOf: children)
        }
        if run.feeds >= OpdsSource.maxFeeds || run.title.count >= OpdsSource.maxTitles {
            Diagnostics.deficiency(
                "OPDS \(account.title): cap reached (\(run.feeds) feeds, \(run.title.count) titles) — the catalog is incomplete",
                since: nil, area: "Source")
        }
        return run
    }

    /// Twice, with a second in between — a tunnel dropout should not cost the catalog.
    func feedWithRetry(_ address: URL) async throws -> OpdsFeed {
        do {
            return try await feed(address)
        } catch SourceError.notFound(let t) {
            throw SourceError.notFound(t)
        } catch {
            try? await Task.sleep(for: .seconds(1))
            return try await feed(address)
        }
    }

    func requestFor(_ address: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.setValue(
            "application/opds+json, application/atom+xml, application/json;q=0.9, application/xml;q=0.9, */*;q=0.5",
            forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in account.headerLines { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    func feed(_ address: URL) async throws -> OpdsFeed {
        try await feedWithEdition(address).0
    }

    /// Fetches a feed and detects the edition from the response — from the content type
    /// (`application/opds+json`) or the first character of the body, never from the address.
    func feedWithEdition(_ address: URL) async throws -> (OpdsFeed, OpdsAccount.Edition) {
        // The feed address as "title", so that a 404 arrives as ``SourceError/notFound(_:)`` — the crawl
        // tells a dead branch from a disruption by it.
        let (data, response) = try await fetch.data(
            requestFor(address), title: TitleID(source: identifier, id: address.absoluteString))
        let json = OpdsJsonReader.isJson(
            data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        do {
            return json ? (try OpdsJsonReader.parse(data), .json) : (try OpdsParser.parse(data), .atom)
        } catch {
            throw SourceError.unreadable(identifier, "\(address.path()): \(error.localizedDescription)")
        }
    }

    /// A feed address resolved against the catalog — relative hrefs are the rule in OPDS.
    func absolute(_ href: String, relativeTo baseURL: URL) -> URL {
        if let url = URL(string: href), url.scheme != nil { return url }
        return URL(string: href, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    // MARK: - Title

    public func title(_ identifier: TitleID) async throws -> Title {
        throw SourceError.notPossible(
            self.identifier, "OPDS has no single-title detail — the catalog is the list")
    }

    /// The reader and the offline store count pages 1-based (page 1 is the cover) — the page
    /// stream receives this number and translates it into the address.
    public func content(_ title: Title) -> ContentSource {
        let entry = OpdsMapping.entry(from: title)
        if let stream = entry.pageStream, let count = entry.pages, count > 0 {
            return .pageStream(count: count) { page in
                // `{pageNumber}` — 0-based at Komga with `zero_based=true`, otherwise 1-based.
                let number = stream.contains("zero_based=true") ? page - 1 : page
                return URL(string: stream.replacingOccurrences(of: "{pageNumber}", with: String(number)))
                    ?? title.cover ?? self.account.catalog
            }
        }
        if let manifest = entry.manifest, let count = entry.pages, count > 0 {
            // Fetch the manifest now: the reader asks for `measures` and the first page side by side,
            // the offline store does not ask for `measures` at all.
            Task { _ = try? await self.manifest(manifest) }
            return .pageStream(
                count: count,
                page: { page in self.pageAddress(manifest, page) },
                measures: {
                    try await self.manifest(manifest).map {
                        PageSize(width: $0.width ?? 0, height: $0.height ?? 1)
                    }
                })
        }
        return .file(entry.file ?? account.catalog, size: title.size, rangeCapable: true)
    }

    /// The Divina manifest of a title — fetched once, then from the cache.
    func manifest(_ address: URL) async throws -> [OpdsJsonReader.Page] {
        if let pages = manifests.withLock({ $0[address] }) { return pages }
        let (data, _) = try await fetch.data(
            requestFor(address), title: TitleID(source: identifier, id: address.absoluteString))
        let pages: [OpdsJsonReader.Page]
        do {
            pages = try OpdsJsonReader.manifest(data)
        } catch {
            throw SourceError.unreadable(
                identifier, "Manifest \(address.path()): \(error.localizedDescription)")
        }
        manifests.withLock { $0[address] = pages }
        return pages
    }

    /// The address of a page (1-based) from the manifest's `readingOrder`. If the manifest is still
    /// on its way, the fallback applies: `…/manifest` → `…/pages/{n}` — Komga builds both addresses
    /// from the same template, another server would get a wrong page here until the manifest
    /// arrives.
    func pageAddress(_ manifest: URL, _ page: Int) -> URL {
        let pages = manifests.withLock { $0[manifest] }
        if let pages, pages.indices.contains(page - 1) {
            return absolute(pages[page - 1].href, relativeTo: manifest)
        }
        return manifest.deletingLastPathComponent().appending(path: "pages/\(page)")
    }

    public func file(_ title: Title) -> URL? {
        OpdsMapping.entry(from: title).file
    }

    // MARK: - Reading state: on the server where the title names a progression API, otherwise local

    /// From the server: 204 means never started (and the mirror is emptied); a state without a
    /// position (Komga web reader) leaves the mirror alone and returns it — better than starting at
    /// the front and overwriting the server's state.
    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        let entry = OpdsMapping.entry(from: identifier)
        guard let address = entry.progress else { return states.state(identifier) }
        let (data, response) = try await fetch.data(requestFor(address), title: identifier)
        guard response.statusCode != 204, !data.isEmpty else {
            try states.forget(identifier)
            return nil
        }
        let progression: OpdsProgression
        do {
            progression = try OpdsProgression.parse(data)
        } catch {
            throw SourceError.unreadable(self.identifier, "Progression: \(error.localizedDescription)")
        }
        guard let state = progression.readingState(pages: entry.pages ?? 0) else {
            Diagnostics.step(
                "OPDS: state on the server without a position (\(progression.device.name)) — the mirror stays",
                since: nil, area: "Source")
            return states.state(identifier)
        }
        try states.write(state, for: identifier)
        return state
    }

    /// To the server as progression (page, fraction, device) — 409 means: the server already holds a
    /// younger state, that is no disruption, the caller sees ``SourceError/unreadable(_:_:)`` and
    /// drops the entry. Then into the mirror, so that the shelf shows it.
    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        let entry = OpdsMapping.entry(from: identifier)
        guard let address = entry.progress else {
            try states.write(state, for: identifier)
            return
        }
        guard let progression = OpdsProgression(state, page: page(for: state, entry: entry)) else {
            throw SourceError.notPossible(self.identifier, "The progression API only knows pages")
        }
        _ = try await fetch.data(
            requestFor(address, method: "PUT", body: try progression.body()), title: identifier)
        try states.write(state, for: identifier)
    }

    /// Address and type of the page the state is on — from the manifest if it was already there;
    /// otherwise the address of the manifest (Komga does not check it for comics).
    private func page(
        for state: ReadingState, entry: OpdsMapping.EntryData
    ) -> (href: String, type: String?) {
        if case .page(let number, _) = state.position, let manifest = entry.manifest,
            let pages = manifests.withLock({ $0[manifest] }), pages.indices.contains(number - 1)
        {
            let s = pages[number - 1]
            return (absolute(s.href, relativeTo: manifest).absoluteString, s.type)
        }
        return (entry.manifest?.absoluteString ?? entry.progress?.absoluteString ?? "", nil)
    }

    /// The progression API has no delete (Komga: no `DELETE` under `/opds/v2`), and a state "page 1"
    /// would not be "never started" — hence honestly ``SourceError/notPossible(_:_:)``; resetting is
    /// done on the server itself.
    public func forget(progressFor identifier: TitleID) async throws {
        let entry = OpdsMapping.entry(from: identifier)
        guard entry.progress == nil else {
            throw SourceError.notPossible(
                self.identifier, "OPDS cannot forget on the server — reset in the catalog itself")
        }
        try states.forget(identifier)
    }

    public func savedList() async throws -> Set<TitleID> {
        throw SourceError.notPossible(identifier, "OPDS has no saved list")
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        throw SourceError.notPossible(self.identifier, "OPDS has no saved list")
    }

    public func collections() async throws -> [TitleCollection] {
        throw SourceError.notPossible(identifier, "OPDS has no collections")
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        throw SourceError.notPossible(identifier, "OPDS has no collections")
    }

    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        throw SourceError.notPossible(identifier, "OPDS has no collections")
    }

    // MARK: - Search

    /// The catalog's OpenSearch search — `{searchTerms}` in the template; `nil` without.
    public func search(_ text: String) async throws -> [Title] {
        guard let template = account.search else { return [] }
        let term = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        guard let address = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: term))
        else {
            return []
        }
        let feed = try await feed(address)
        var title = feed.entries.compactMap {
            OpdsMapping.title(
                $0, feed: feed, feedAddress: address, bookSeries: nil, source: identifier, resolve: absolute)
        }
        // Komga searches series: the hits are feeds — the first ten are fetched.
        for e in feed.entries.filter({ $0.acquisition == nil && $0.manifest == nil }).prefix(10) {
            guard let nav = e.navigation else { continue }
            let below = absolute(nav.href, relativeTo: address)
            guard let f = try? await self.feed(below) else { continue }
            for (spot, u) in f.entries.enumerated() {
                if let t = OpdsMapping.title(
                    u, feed: f, feedAddress: below, bookSeries: f.title, slot: spot + 1, source: identifier,
                    resolve: absolute)
                {
                    title.append(t)
                }
            }
        }
        return title
    }
}
