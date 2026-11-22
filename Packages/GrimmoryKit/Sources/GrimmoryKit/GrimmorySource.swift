import Bedrock
import Foundation
import SourcesKit
import Synchronization

/// Grimmory as a source: books (EPUB, PDF, CBX) with series, stars and reading state.
///
/// Built against Grimmory 3.4.1: the extract comes from the web list, detail and reading
/// state from the mobile API (`/api/v1/app/…`, contract: grimmory.org/api). Content is
/// fetched via `/api/v1/books/{id}/content` with `Range` — **not** `/download`, which an
/// account without `canDownload` may not use, and everybody should be allowed to read.
///
/// **The token moves, and nobody refreshes too early:** A refresh token may only be used
/// once the access expires (`nbf` claim since grimmory#2245) — otherwise 401 "Invalid
/// credentials". Therefore the kit refreshes only when the access no longer works, and only
/// once, no matter how many requests are waiting at the same time.
public final class GrimmorySource: Source, Sendable {
    public let account: GrimmoryAccount
    let fetch: ServerFetch
    private let accessGuard: AccessGuard
    private let mirror: Mutex<GrimmoryAccess>
    private let fileTypes = Mutex<[String: String]>([:])
    /// The last seen `readStatus` per book — so that ``write(_:for:)`` sets the status only
    /// when it changes.
    private let readStatus = Mutex<[String: String]>([:])

    /// - Parameter changed: Called with the new token pair as soon as there is one — whoever
    ///   stores the account updates it with it.
    public init(
        account: GrimmoryAccount, transport: any Transport = URLSession.forSource(),
        magicStore: URL? = nil, syncStore: URL? = nil, pageStore: URL? = nil,
        persistence: UserDefaults = .standard,
        changed: @escaping @Sendable (GrimmoryAccess) -> Void = { _ in }
    ) {
        self.account = account
        self.magicStore = magicStore
        self.syncStore = syncStore
        self.pageStore = pageStore
        self.persistence = persistence
        self.fetch = ServerFetch(baseURL: account.server, source: account.identifier, transport: transport)
        self.mirror = Mutex(account.access)
        self.accessGuard = AccessGuard(access: account.access, fetch: fetch, changed: changed)
        // Server and connection: all places in the app share one session per account; the tests
        // get their own per test — otherwise they would share fetches and authors.
        self.cacheKey =
            account.identifier.description + "|"
            + String(describing: ObjectIdentifier(transport as AnyObject))
    }

    /// Where the Magic Shelves live between two launches — otherwise every cold start would
    /// refetch their good 600 pages. `nil` in tests.
    private let magicStore: URL?
    /// When the last full sync was — between two launches. `nil` in tests.
    private let syncStore: URL?
    /// Folder for the catalog pages of a full sync that has not finished yet (``PageCheckpoint``).
    /// `nil` in tests that do not test it.
    private let pageStore: URL?
    /// Where the ``LibraryPicker`` lives — its own in tests. `UserDefaults` is thread-safe,
    /// just not declared `Sendable`.
    nonisolated(unsafe) private let persistence: UserDefaults

    private struct CachedMagic: Codable {
        let state: Date
        let list: [TitleCollection]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case state = "stand"
            case list = "liste"
        }
    }

    /// Key for coalescing the fetches and the remembered authors.
    let cacheKey: String

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }

    /// The last known access token — for covers and content. Whoever asks after expiry gets the
    /// old one; the next request through the kit exchanges it.
    public func headerLines() -> [String: String] {
        ["Authorization": "Bearer " + mirror.withLock { $0.token }]
    }

    // MARK: - Sign in

    public static func signIn(
        server: URL, username: String, password: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> GrimmoryAccount {
        let identifier = SourceID(provider: .grimmory, server: server.host() ?? server.absoluteString)
        let fetch = ServerFetch(baseURL: server, source: identifier, transport: transport)
        let login = try await fetch.json(
            GrimmoryResponses.Login.self,
            try fetch.request(
                "api/v1/auth/login", method: "POST",
                json: GrimmoryResponses.LoginBody(username: username, password: password)))
        let access = GrimmoryAccess(
            token: login.accessToken, refreshToken: login.refreshToken,
            flow: GrimmoryAccess.flow(from: login.expires))
        let user = try await fetch.json(
            GrimmoryResponses.User.self,
            fetch.request("api/v1/users/me", headerLines: ["Authorization": "Bearer " + access.token]))
        Diagnostics.step("Grimmory: signed in as \(user.username)", since: nil, area: "Source")
        return GrimmoryAccount(
            server: server, userId: user.id, username: user.username, displayName: user.name,
            mayFetch: user.permissions.canDownload, access: access)
    }

    // MARK: - Source

    /// The extract comes from the web list `GET /api/v1/books`: all 854 books in one response
    /// (0.9 MB), with series, categories and reading state. The mobile list caps at 50 per page
    /// and paginates without a fixed order — page 0 and 1 overlapped by one book, and what
    /// overlaps is missing elsewhere.
    /// `GET /api/v1/users/me` — refreshes the access if it no longer works; a refresh token the
    /// server no longer knows ends as ``SourceError/signedOut(_:)``.
    public func verify() async throws {
        _ = try await json(GrimmoryResponses.User.self, "api/v1/users/me")
    }

    /// What is currently being loaded, per server — a second caller attaches instead of fetching
    /// the catalog (35 MB) a second time (`/api/v1/authors` once arrived four times in two
    /// seconds).
    private static let ongoing = Mutex<[String: Task<LibraryExtract, any Error>]>([:])
    /// The author list per server, remembered for six hours: it rarely changes and is a good
    /// 300 KB for 25,000 authors.
    private static let cachedAuthors = Mutex<[String: (state: Date, list: [GrimmoryResponses.Author])]>([:])
    static let authorsFreshness: TimeInterval = 6 * 3600

    public func library() async throws -> LibraryExtract {
        try await library(progress: { _, _ in })
    }

    // MARK: - Libraries

    public func subLibraries() async throws -> [SubLibrary] {
        try await json([GrimmoryResponses.LibraryInfo].self, "api/v1/libraries").map {
            SubLibrary(id: String($0.id), name: $0.name)
        }
    }

    public func titleCount() async throws -> Int? {
        try await json(
            GrimmoryResponses.BookPage.self, "api/v1/books/page",
            query: [
                URLQueryItem(name: "size", value: "1"), URLQueryItem(name: "withDescription", value: "false"),
            ]
        ).page.totalElements
    }

    /// The books without the disabled libraries (``LibraryPicker``). The server does not filter
    /// by them (it ignores `libraryId` on `/books/page`), so the app does.
    private func withoutDisabled(_ books: [GrimmoryResponses.WebBook]) -> [GrimmoryResponses.WebBook] {
        let from = LibraryPicker.from(identifier, persistence)
        guard !from.isEmpty else { return books }
        return books.filter { b in b.libraryId.map { !from.contains(String($0)) } ?? true }
    }

    // MARK: - Changes only

    /// How long after a full sync only the changes are fetched. A full one also fetches changed
    /// metadata (blurb, series, genre) that `/books/ids` does not reveal.
    static let fullSyncFreshness: TimeInterval = 6 * 3600
    /// More new books than this, and the full sync is the shorter way.
    static let maxNew = 2_000
    private static let lastFullSync = Mutex<[String: Date]>([:])

    /// With a previous extract always only the changes (``incrementalSync(_:)``): `/books/ids` is
    /// 232 KB in 0.08 s (measured with 35,551 books) instead of 36 MB in 18 s. The full sync, which
    /// fetches changed metadata every six hours, then runs in the background
    /// (``fullSyncDue``) — no longer at launch: on the iPhone it took so long that people closed
    /// the app beforehand and it started over at the next launch. Only without a previous extract,
    /// or if the incremental sync fails, the full one runs here.
    public func library(
        previously: LibraryExtract?, progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws -> LibraryExtract {
        if let previously, !previously.title.isEmpty, !previously.isSupplement {
            // A whole extract is stored: the pages of an interrupted first sync are done with.
            pageStore.map(PageCheckpoint.init(folder:))?.clear()
            do {
                if let new = try await incrementalSync(previously) { return new }
            } catch {
                Diagnostics.network.error(
                    "Grimmory: incremental sync failed, full fetch — \(String(describing: error), privacy: .public)"
                )
            }
        }
        return try await library(progress: progress)
    }

    public var fullSyncDue: Bool {
        guard let full = lastFullSyncDate() else { return true }
        return Date().timeIntervalSince(full) >= GrimmorySource.fullSyncFreshness
    }

    private func lastFullSyncDate() -> Date? {
        let lookupKey = cacheKey
        if let saved = GrimmorySource.lastFullSync.withLock({ $0[lookupKey] }) { return saved }
        guard let syncStore, let data = try? Data(contentsOf: syncStore),
            let integer = Double(String(decoding: data, as: UTF8.self))
        else { return nil }
        let date = Date(timeIntervalSince1970: integer)
        GrimmorySource.lastFullSync.withLock { $0[lookupKey] = date }
        return date
    }

    private func rememberFullSync(_ date: Date) {
        let lookupKey = cacheKey
        GrimmorySource.lastFullSync.withLock { $0[lookupKey] = date }
        guard let syncStore else { return }
        try? FileManager.default.createDirectory(
            at: syncStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(date.timeIntervalSince1970).utf8).write(to: syncStore, options: .atomic)
    }

    /// The changes since `previously`: new books via `/books/batch`, vanished ones drop out, and
    /// the states of books read since the last extract (`/app/books` by `lastReadTime`, per book
    /// `/progress` — the list carries no position). `nil` if so much is new that the full sync
    /// would be shorter.
    func incrementalSync(_ previously: LibraryExtract) async throws -> LibraryExtract? {
        let start = Date()
        let ids = try await json([Int].self, "api/v1/books/ids")
        let present = Set(ids.map(String.init))
        let known = Set(previously.title.map(\.identifier.id))
        let new = ids.filter { !known.contains(String($0)) }
        guard new.count <= GrimmorySource.maxNew else {
            Diagnostics.network.info("Grimmory: \(new.count, privacy: .public) new — full fetch is shorter")
            return nil
        }
        var newBooks: [GrimmoryResponses.Book] = []
        for start in stride(from: 0, to: new.count, by: 100) {
            let chunk = new[start..<min(start + 100, new.count)]
            let list = try await json(
                Lenient<GrimmoryResponses.WebBook>.self, "api/v1/books/batch",
                query: [
                    URLQueryItem(name: "ids", value: chunk.map(String.init).joined(separator: ",")),
                    URLQueryItem(name: "withDescription", value: "false"),
                ])
            newBooks += withoutDisabled(list.wrappedValue).map(\.asBook)
        }
        fileTypes.withLock { types in for b in newBooks { types[String(b.id)] = b.primaryFileType } }

        var title = previously.title.filter { present.contains($0.identifier.id) }
        let kept = title.count
        title += newBooks.map { GrimmoryMapping.title($0, source: identifier, baseURL: fetch.baseURL) }
        var readingStates = previously.readingStates.filter { present.contains($0.key.id) }
        readStatus.withLock { status in
            for (k, s) in readingStates where status[k.id] == nil {
                status[k.id] = s.completed ? "READ" : "READING"
            }
        }

        // Read since the last extract — a minute of leeway for the clocks.
        let since = previously.state.addingTimeInterval(-60)
        let recent = try await json(
            GrimmoryResponses.ReadTimePage.self, "api/v1/app/books",
            query: [
                URLQueryItem(name: "sort", value: "lastReadTime"), URLQueryItem(name: "dir", value: "desc"),
                URLQueryItem(name: "size", value: "50"),
            ])
        var checked = 0
        for book in recent.content {
            guard let time = book.lastReadTime, time > since else { break }
            let k = TitleID(source: identifier, id: String(book.id))
            let f = try await json(
                GrimmoryResponses.Progress.self, "api/v1/app/books/\(book.id)/progress", title: k)
            readingStates[k] = GrimmoryMapping.readingState(f, pages: nil)
            readStatus.withLock { $0[k.id] = book.readStatus }
            checked += 1
        }

        var lengths: [SeriesID: Int] = [:]
        for s in previously.seriesList { if let total = s.total { lengths[s.identifier] = total } }
        for b in newBooks {
            if let total = b.seriesTotal, total > 0,
                let reference = GrimmoryMapping.seriesReference(b, source: identifier)
            {
                lengths[reference.identifier] = max(lengths[reference.identifier] ?? 0, total)
            }
        }
        title = GrimmoryMapping.unifySeries(title)
        let seriesList = GrimmoryMapping.seriesList(from: title, lengths: lengths)
        let authors = await authorList().map {
            GrimmoryMapping.author($0, source: identifier, baseURL: fetch.baseURL)
        }
        Diagnostics.step(
            "Grimmory incremental sync: \(new.count) new, \(known.count - kept) gone, "
                + "\(checked) states checked, \(title.count) books",
            since: start, area: "Source")
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: title, readingStates: readingStates,
            authors: authors.isEmpty ? previously.authors : authors, state: Date())
    }

    public func library(
        progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws
        -> LibraryExtract
    {
        let lookupKey = cacheKey
        let loadTask = GrimmorySource.ongoing.withLock { ongoing in
            if let existing = ongoing[lookupKey] { return existing }
            let new = Task { try await self.loadLibrary(progress: progress) }
            ongoing[lookupKey] = new
            return new
        }
        defer {
            GrimmorySource.ongoing.withLock { ongoing in
                if ongoing[lookupKey] == loadTask { ongoing[lookupKey] = nil }
            }
        }
        return try await loadTask.value
    }

    private func authorList() async -> [GrimmoryResponses.Author] {
        let lookupKey = cacheKey
        if let saved = GrimmorySource.cachedAuthors.withLock({ $0[lookupKey] }),
            Date().timeIntervalSince(saved.state) < GrimmorySource.authorsFreshness
        {
            return saved.list
        }
        let list = (try? await json([GrimmoryResponses.Author].self, "api/v1/authors")) ?? []
        if !list.isEmpty { GrimmorySource.cachedAuthors.withLock { $0[lookupKey] = (Date(), list) } }
        return list
    }

    /// Books per page: 1,000 are a good 1 MB and 1.4 s on the server (measured with 35,551
    /// books) — small enough for a page to arrive through the tunnel as well.
    static let pageSize = 1_000
    /// How many pages are in flight at the same time.
    static let pagesInParallel = 4

    /// The whole catalog page by page via `GET /api/v1/books/page?page=n&size=1000`: instead of a
    /// 35 MB response that took over 40 s to the first byte with 35,000 books and broke off in the
    /// tunnel, pages of 1,000 books arrive, four at a time; each is retried on its own. Not via the
    /// response's `cursor`: with it the server delivers only 100 per page and knows only "next".
    /// If the endpoint is missing (older Grimmory) or ignores `page`, the source loads everything
    /// at once as before.
    private func loadLibrary(
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws
        -> LibraryExtract
    {
        let start = Date()
        if capabilities.contains(.collections) { magicShelves() }
        var books: [GrimmoryResponses.Book]?
        do {
            books = try await paged(progress: progress)
        } catch let failure as SourceError where failure.endpointMissing {
            books = nil
        }
        if books == nil { books = try await allAtOnce() }
        let extract = try await extract(from: books ?? [], start: start)
        rememberFullSync(extract.state)
        return extract
    }

    /// One catalog page — from the ``PageCheckpoint`` if an interrupted sync left it there,
    /// otherwise from the server, and then straight onto the disk.
    private func page(
        _ number: Int, checkpoint: PageCheckpoint? = nil
    ) async throws
        -> GrimmoryResponses.BookPage
    {
        if let checkpoint, let saved = checkpoint.data(number),
            let page = try? ServerFetch.decoder.decode(GrimmoryResponses.BookPage.self, from: saved)
        {
            return page
        }
        let query = [
            URLQueryItem(name: "page", value: String(number)),
            URLQueryItem(name: "size", value: String(GrimmorySource.pageSize)),
            URLQueryItem(name: "withDescription", value: "false"),
        ]
        var attempt = 0
        while true {
            do {
                let data = try await withToken { token in
                    var request = fetch.request(
                        "api/v1/books/page", query: query, headerLines: ["Authorization": "Bearer " + token])
                    request.timeoutInterval = 60
                    return try await fetch.data(request).0
                }
                let page: GrimmoryResponses.BookPage
                do {
                    page = try ServerFetch.decoder.decode(GrimmoryResponses.BookPage.self, from: data)
                } catch {
                    throw SourceError.unreadable(identifier, String(describing: error))
                }
                checkpoint?.store(data, page: number)
                return page
            } catch let failure as SourceError where failure.temporary && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    /// The books of all pages in server order — `nil` if the server ignores `page` (the same
    /// books would then arrive repeatedly).
    private func paged(
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws
        -> [GrimmoryResponses.Book]?
    {
        // Page 0 always fresh: it carries the size the stored pages are checked against.
        let first = try await page(0)
        let total = first.page.totalElements
        let checkpoint = pageStore.map(PageCheckpoint.init(folder:))
        if let checkpoint, checkpoint.begin(total: total, pageSize: GrimmorySource.pageSize) {
            Diagnostics.step(
                "Grimmory: resuming the full sync, \(checkpoint.stored().count) pages from disk", since: nil,
                area: "Source")
        }
        var pages: [Int: GrimmoryResponses.BookPage] = [0: first]
        var loaded = first.content.wrappedValue.count
        progress(loaded, total)
        let count = (total + GrimmorySource.pageSize - 1) / GrimmorySource.pageSize
        if count > 1 {
            try await withThrowingTaskGroup(of: (Int, GrimmoryResponses.BookPage).self) { cluster in
                var next = 1
                func launch() {
                    guard next < count else { return }
                    let n = next
                    next += 1
                    cluster.addTask { (n, try await self.page(n, checkpoint: checkpoint)) }
                }
                for _ in 0..<GrimmorySource.pagesInParallel { launch() }
                for try await (n, s) in cluster {
                    pages[n] = s
                    loaded += s.content.wrappedValue.count
                    progress(loaded, total)
                    launch()
                }
            }
        }
        var collected: [GrimmoryResponses.WebBook] = []
        var discarded = 0
        for n in pages.keys.sorted() {
            collected += pages[n]!.content.wrappedValue
            discarded += pages[n]!.content.discarded
        }
        if discarded > 0 {
            Diagnostics.network.error(
                "Grimmory: \(discarded, privacy: .public) books unreadable, skipped")
        }
        // Duplicates (if the catalog shifted while loading) only once.
        var seen = Set<Int>()
        let unique = collected.filter { seen.insert($0.id).inserted }
        if count > 1, unique.count + discarded < total * 9 / 10 {
            Diagnostics.network.error(
                "Grimmory: pages overlap (\(unique.count, privacy: .public) of \(total, privacy: .public)), loading everything at once"
            )
            return nil
        }
        return withoutDisabled(unique).map(\.asBook)
    }

    /// The old way: everything in one response, abridged.
    private func allAtOnce() async throws -> [GrimmoryResponses.Book] {
        // Lean: without blurb and abridged (`stripForListView`, the server's default). With 35,000
        // books the unabridged response with blurbs was about 90 MB in one response — it no longer
        // arrived. Abridged it is 35 MB. The detail fetches the blurb on opening, a download puts it
        // in the data package. The length of a series (`seriesTotal`) is therefore missing; the gaps
        // of a Grimmory series count up to the last existing volume.
        // Lenient: a book without title or date goes missing on its own instead of toppling the
        // catalog.
        let list = try await json(
            Lenient<GrimmoryResponses.WebBook>.self, "api/v1/books",
            query: [
                URLQueryItem(name: "withDescription", value: "false"),
                URLQueryItem(name: "stripForListView", value: "true"),
            ],
            patience: 180
        )
        if list.discarded > 0 {
            Diagnostics.network.error(
                "Grimmory: \(list.discarded, privacy: .public) books unreadable, skipped")
        }
        return withoutDisabled(list.wrappedValue).map(\.asBook)
    }

    private func extract(from books: [GrimmoryResponses.Book], start: Date) async throws -> LibraryExtract {
        fileTypes.withLock { types in for b in books { types[String(b.id)] = b.primaryFileType } }
        readStatus.withLock { status in for b in books { status[String(b.id)] = b.readStatus } }
        var readingStates: [TitleID: ReadingState] = [:]
        let title = GrimmoryMapping.unifySeries(
            books.map { book in
                let t = GrimmoryMapping.title(book, source: identifier, baseURL: fetch.baseURL)
                if let state = GrimmoryMapping.readingState(list: book) {
                    readingStates[t.identifier] = state
                }
                return t
            })
        var lengths: [SeriesID: Int] = [:]
        for b in books {
            if let total = b.seriesTotal, total > 0,
                let reference = GrimmoryMapping.seriesReference(b, source: identifier)
            {
                lengths[reference.identifier] = max(lengths[reference.identifier] ?? 0, total)
            }
        }
        let seriesList = GrimmoryMapping.seriesList(from: title, lengths: lengths)
        // The authors as entries of their own, with image: one response for all 547. If the endpoint
        // is missing (older Grimmory), the list stays empty — the authors are on the books anyway.
        let authors = await authorList().map {
            GrimmoryMapping.author($0, source: identifier, baseURL: fetch.baseURL)
        }
        Diagnostics.step(
            "Grimmory: \(books.count) books, \(seriesList.count) series, \(readingStates.count) reading states, "
                + "\(authors.count) authors",
            since: start,
            area: "Source")
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: title, readingStates: readingStates,
            authors: authors,
            state: Date())
    }

    /// The description of an author — Grimmory has it from the Audible sync, as HTML; the UI
    /// strips the tags.
    public func author(_ reference: AuthorReference) async throws -> SourceAuthor? {
        let detail = try await json(GrimmoryResponses.Author.self, "api/v1/authors/\(reference.identifier)")
        return SourceAuthor(descriptionText: GrimmoryMapping.nilIfEmpty(detail.description))
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        let book = try await json(
            GrimmoryResponses.Book.self, "api/v1/app/books/\(identifier.id)", title: identifier)
        fileTypes.withLock { $0[identifier.id] = book.primaryFileType }
        return GrimmoryMapping.title(book, source: self.identifier, baseURL: fetch.baseURL)
    }

    public func content(_ title: Title) -> ContentSource {
        .file(
            fetch.baseURL.appending(path: "api/v1/books/\(title.identifier.id)/content"), size: nil,
            rangeCapable: true)
    }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        let f = try await json(
            GrimmoryResponses.Progress.self, "api/v1/app/books/\(identifier.id)/progress", title: identifier)
        return GrimmoryMapping.readingState(f, pages: nil)
    }

    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        var fileType = fileTypes.withLock { $0[identifier.id] }
        if fileType == nil, case .page = state.position {
            fileType = try await json(
                GrimmoryResponses.Book.self, "api/v1/app/books/\(identifier.id)", title: identifier
            )
            .primaryFileType
        }
        let report = GrimmoryMapping.report(state, fileType: fileType)
        try await withToken { token in
            _ = try await fetch.data(
                try fetch.request(
                    "api/v1/app/books/\(identifier.id)/progress", method: "PUT", json: report,
                    headerLines: ["Authorization": "Bearer " + token]),
                title: identifier)
        }
        // **Progress alone does not change the read status** (seen: 0.1 % and still UNREAD in the
        // web UI). The web reader sets READING on opening; here it happens at the first state above
        // zero — and READ when the state is completed.
        let previous = readStatus.withLock { $0[identifier.id] }
        if let new = GrimmoryMapping.readStatus(for: state, previous: previous) {
            try await withToken { token in
                _ = try await fetch.data(
                    try fetch.request(
                        "api/v1/app/books/\(identifier.id)/status", method: "PUT",
                        json: GrimmoryResponses.StatusReport(status: new),
                        headerLines: ["Authorization": "Bearer " + token]),
                    title: identifier)
            }
            readStatus.withLock { $0[identifier.id] = new }
        }
    }

    /// Grimmory has no delete for progress — it is set to zero and the status to `UNREAD`, in
    /// this order: a state above zero would otherwise set READING again right away.
    public func forget(progressFor identifier: TitleID) async throws {
        var fileType = fileTypes.withLock { $0[identifier.id] }
        if fileType == nil {
            fileType = try await json(
                GrimmoryResponses.Book.self, "api/v1/app/books/\(identifier.id)", title: identifier
            )
            .primaryFileType
        }
        let null: ReadingState.Position = fileType?.uppercased() == "EPUB" ? .fraction(0) : .page(0, from: 1)
        let report = GrimmoryMapping.report(
            ReadingState(position: null, timestamp: Date()), fileType: fileType)
        try await withToken { token in
            _ = try await fetch.data(
                try fetch.request(
                    "api/v1/app/books/\(identifier.id)/progress", method: "PUT", json: report,
                    headerLines: ["Authorization": "Bearer " + token]),
                title: identifier)
            _ = try await fetch.data(
                try fetch.request(
                    "api/v1/app/books/\(identifier.id)/status", method: "PUT",
                    json: GrimmoryResponses.StatusReport(status: "UNREAD"),
                    headerLines: ["Authorization": "Bearer " + token]),
                title: identifier)
        }
        readStatus.withLock { $0[identifier.id] = "UNREAD" }
    }

    // MARK: - Saved list

    /// The shelf "Favorites" is called that at Grimmory because the server creates it — in the
    /// app it is called Saved.
    static let favoritesShelf = "Favorites"

    /// The identifiers on the shelf "Favorites" — empty if the shelf does not exist.
    public func savedList() async throws -> Set<TitleID> {
        guard let shelf = try await favoritesShelfId(create: false) else { return [] }
        let books = try await json([GrimmoryResponses.ShelfBook].self, "api/v1/shelves/\(shelf)/books")
        return Set(books.map { TitleID(source: identifier, id: String($0.id)) })
    }

    /// Puts the book on the shelf or takes it off — the shelf is created on the first save in case
    /// the user deleted it in the web UI.
    public func save(_ identifier: TitleID, saved: Bool) async throws {
        guard let id = Int(identifier.id) else { throw SourceError.notFound(identifier) }
        guard let shelf = try await favoritesShelfId(create: saved) else { return }
        let assignment = GrimmoryResponses.ShelfAssignment(
            bookIds: [id], shelvesToAssign: saved ? [shelf] : [], shelvesToUnassign: saved ? [] : [shelf])
        try await withToken { token in
            _ = try await fetch.data(
                try fetch.request(
                    "api/v1/books/shelves", method: "POST", json: assignment,
                    headerLines: ["Authorization": "Bearer " + token]),
                title: identifier)
        }
    }

    // MARK: - Collections

    /// All shelves except "Favorites" (that is the saved list), with their books — one fetch per
    /// shelf. Other users' public shelves are readable, not editable.
    ///
    /// The Magic Shelves come from the cache here, even if it is older than six hours: they are
    /// refreshed only in the full sync (``loadLibrary(progress:)``), which waits until no reader is
    /// open. Previously every launch after six hours started about 500 fetches of over a second
    /// of server time each — in the middle of reading (device report: 16 MB, CPU in the comic
    /// reader 60–75 %).
    ///
    /// The first run waits at most ``magicWait``: on a fresh install it is a good 500 fetches and
    /// over a minute (device report 02.11.: catalog after 15 s, Magic Shelves still running after
    /// 30 s more). The library writes the catalog only after the collections — whoever left the app
    /// in that minute lost the whole catalog, and the next launch fetched the 36 MB again. Now the
    /// shelves come without the Magic Shelves, the run continues and the next sync carries them.
    public func collections() async throws -> [TitleCollection] {
        try await collections(magicWait: GrimmorySource.magicWait)
    }

    /// How long the collections wait for a running Magic Shelves run.
    static let magicWait: Duration = .seconds(3)

    func collections(magicWait: Duration) async throws -> [TitleCollection] {
        let magic = magicShelves(refresh: false)
        let shelves = try await json([GrimmoryResponses.Shelf].self, "api/v1/shelves")
        var result: [TitleCollection] = []
        for shelf in shelves
        where shelf.name.caseInsensitiveCompare(GrimmorySource.favoritesShelf) != .orderedSame {
            let books = try await json(
                [GrimmoryResponses.ShelfBook].self, "api/v1/shelves/\(shelf.id)/books")
            result.append(
                TitleCollection(
                    identifier: CollectionID(source: identifier, id: String(shelf.id)), name: shelf.name,
                    collectionKind: .shelf,
                    entries: books.map { .title(TitleID(source: identifier, id: String($0.id))) },
                    isPrivate: shelf.publicShelf != true,
                    editable: shelf.userId == nil || shelf.userId == account.userId,
                    symbol: shelf.icon))
        }
        return result + (await GrimmorySource.value(of: magic, within: magicWait))
    }

    /// The result of `run`, or empty if it takes longer than `limit` — the run itself goes on.
    /// Not via a task group: it would wait for the child awaiting `run.value`, cancelled or not.
    static func value(
        of run: Task<[TitleCollection], Never>, within limit: Duration
    ) async -> [TitleCollection] {
        let gate = Mutex<CheckedContinuation<[TitleCollection], Never>?>(nil)
        return await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
            Task {
                let list = await run.value
                gate.withLock {
                    $0?.resume(returning: list)
                    $0 = nil
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                gate.withLock {
                    if $0 != nil {
                        Diagnostics.step(
                            "Grimmory: Magic Shelves still loading, collections without them", since: nil,
                            area: "Source")
                    }
                    $0?.resume(returning: [])
                    $0 = nil
                }
            }
        }
    }

    // MARK: - Magic Shelves

    /// The Magic Shelves per server, remembered for six hours. The server hands out their books
    /// only 50 per page (eleven shelves, about 30,000 entries in total, so a good 600 fetches);
    /// recomputing the rules themselves (`/api/magic-shelves`) would mean rebuilding its rule
    /// language.
    static let cachedMagic = Mutex<[String: (state: Date, list: [TitleCollection])]>([:])
    private static let magicRunning = Mutex<[String: Task<[TitleCollection], Never>]>([:])
    static let magicFreshness: TimeInterval = 6 * 3600
    /// How many pages of the Magic Shelves are in flight at the same time.
    static let magicInParallel = 8

    /// The Magic Shelves: remembered ones at once (if they are older than six hours, a run
    /// refreshes them in the background for next time); the first time, the run itself. It starts
    /// with the catalog (``loadLibrary(progress:)``) so that it is finished when the collections are
    /// requested.
    /// - Parameter refresh: `false` returns remembered data of any age without starting a run;
    ///   only if nothing is remembered, it loads.
    @discardableResult
    func magicShelves(refresh: Bool = true) -> Task<[TitleCollection], Never> {
        let lookupKey = cacheKey
        if GrimmorySource.cachedMagic.withLock({ $0[lookupKey] }) == nil, let magicStore,
            let data = try? Data(contentsOf: magicStore),
            let old = try? JSONDecoder().decode(CachedMagic.self, from: data)
        {
            GrimmorySource.cachedMagic.withLock { $0[lookupKey] = (old.state, old.list) }
        }
        let saved = GrimmorySource.cachedMagic.withLock { $0[lookupKey] }
        if let saved, !refresh || Date().timeIntervalSince(saved.state) < GrimmorySource.magicFreshness {
            return Task { saved.list }
        }
        let run = GrimmorySource.magicRunning.withLock { ongoing in
            if let existing = ongoing[lookupKey] { return existing }
            let new = Task {
                // A good minute on a fresh install — leaving the app must not throw it away.
                let time = await MainActor.run { BackgroundTime("Magic Shelves") }
                defer { Task { @MainActor in time.end() } }
                let list = await self.loadMagicShelves()
                if let list {
                    let now = Date()
                    GrimmorySource.cachedMagic.withLock { $0[lookupKey] = (now, list) }
                    if let persistence = self.magicStore,
                        let data = try? JSONEncoder().encode(CachedMagic(state: now, list: list))
                    {
                        try? FileManager.default.createDirectory(
                            at: persistence.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: persistence, options: .atomic)
                    }
                }
                GrimmorySource.magicRunning.withLock { $0[lookupKey] = nil }
                return list ?? []
            }
            ongoing[lookupKey] = new
            return new
        }
        if let saved { return Task { saved.list } }
        return run
    }

    /// The shelves of a Magic Shelves run that are already complete — written after each shelf,
    /// so that an interrupted run resumes with the missing ones instead of all 500 fetches.
    private struct MagicPart: Codable {
        let started: Date
        var shelves: [Int: [Int]]
    }

    /// How long completed shelves of an interrupted run count.
    static let magicPartFreshness: TimeInterval = 24 * 3600

    private var magicPartStore: URL? {
        magicStore.map { $0.deletingLastPathComponent().appending(path: $0.lastPathComponent + ".teil") }
    }

    private func readMagicPart() -> MagicPart? {
        guard let magicPartStore, let data = try? Data(contentsOf: magicPartStore),
            let part = try? JSONDecoder().decode(MagicPart.self, from: data),
            Date().timeIntervalSince(part.started) < GrimmorySource.magicPartFreshness
        else { return nil }
        return part
    }

    private func writeMagicPart(_ part: MagicPart) {
        guard let magicPartStore, let data = try? JSONEncoder().encode(part) else { return }
        try? FileManager.default.createDirectory(
            at: magicPartStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: magicPartStore, options: .atomic)
    }

    /// The ids of a shelf's pages in page order, each only once.
    static func ids(_ pages: [Int: [Int]]) -> [Int] {
        var seen = Set<Int>()
        return pages.keys.sorted().flatMap { pages[$0]! }.filter { seen.insert($0).inserted }
    }

    /// `nil` if it did not work — then the remembered data stays.
    private func loadMagicShelves() async -> [TitleCollection]? {
        guard
            let shelves = try? await json([GrimmoryResponses.MagicShelf].self, "api/v1/app/shelves/magic")
        else { return nil }
        let start = Date()
        var part = readMagicPart() ?? MagicPart(started: start, shelves: [:])
        part.shelves = part.shelves.filter { id, _ in shelves.contains { $0.id == id } }
        if !part.shelves.isEmpty {
            Diagnostics.step(
                "Grimmory: resuming Magic Shelves, \(part.shelves.count) of \(shelves.count) from disk",
                since: nil, area: "Source")
        }
        var pages: [Int: [Int: [Int]]] = [:]
        var total: [Int: Int] = [:]
        var pageCount: [Int: Int] = [:]
        // Per shelf first page 0 (with the total), then all others together in one queue — so
        // never more than eight fetches run at once. Shelves complete from before are skipped.
        var jobs: [(shelf: Int, page: Int)] = shelves.filter { part.shelves[$0.id] == nil }.map { ($0.id, 0) }
        var failed = false
        await withTaskGroup(of: (Int, Int, GrimmoryResponses.MagicPage?).self) { cluster in
            var next = 0
            var onTheGo = 0
            func fill() {
                while !failed, onTheGo < GrimmorySource.magicInParallel, next < jobs.count {
                    launch()
                }
            }
            func launch() {
                let (shelf, page) = jobs[next]
                next += 1
                onTheGo += 1
                cluster.addTask {
                    let answer = try? await self.json(
                        GrimmoryResponses.MagicPage.self, "api/v1/app/shelves/magic/\(shelf)/books",
                        query: [
                            URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "size", value: "50"),
                        ])
                    return (shelf, page, answer)
                }
            }
            fill()
            for await (shelf, page, answer) in cluster {
                onTheGo -= 1
                guard let answer else {
                    failed = true
                    cluster.cancelAll()
                    continue
                }
                pages[shelf, default: [:]][page] = answer.content.map(\.id)
                if page == 0 {
                    total[shelf] = answer.totalElements
                    let count = (answer.totalElements + 49) / 50
                    pageCount[shelf] = max(count, 1)
                    if count > 1 { jobs += (1..<count).map { (shelf, $0) } }
                }
                // The shelf is complete: onto the disk at once.
                if let expected = pageCount[shelf], pages[shelf]?.count == expected {
                    part.shelves[shelf] = GrimmorySource.ids(pages[shelf] ?? [:])
                    writeMagicPart(part)
                }
                fill()
            }
        }
        guard !failed else { return nil }
        if let magicPartStore { try? FileManager.default.removeItem(at: magicPartStore) }
        let list = shelves.map { r in
            let ids = part.shelves[r.id] ?? GrimmorySource.ids(pages[r.id] ?? [:])
            return TitleCollection(
                identifier: CollectionID(
                    source: identifier, id: CollectionID.autoPrefix + String(r.id)),
                name: r.name, collectionKind: .shelf,
                entries: ids.map { .title(TitleID(source: identifier, id: String($0))) },
                isPrivate: r.publicShelf != true, editable: false, symbol: r.icon)
        }
        Diagnostics.step(
            "Grimmory: \(list.count) Magic Shelves, \(list.reduce(0) { $0 + $1.entries.count }) entries",
            since: start, area: "Source")
        return list
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        let new = try await withToken { token in
            try await fetch.json(
                GrimmoryResponses.Shelf.self,
                try fetch.request(
                    "api/v1/shelves", method: "POST",
                    json: GrimmoryResponses.CreateShelf(
                        name: name, icon: "library", iconType: "LUCIDE", publicShelf: false),
                    headerLines: ["Authorization": "Bearer " + token]))
        }
        return TitleCollection(
            identifier: CollectionID(source: identifier, id: String(new.id)), name: new.name,
            collectionKind: .shelf,
            entries: [], isPrivate: true, editable: true, symbol: new.icon)
    }

    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        guard case .title(let title) = target, let id = Int(title.id), let shelf = Int(collection.id) else {
            throw SourceError.notPossible(identifier, "Grimmory shelves take books, not series")
        }
        let assignment = GrimmoryResponses.ShelfAssignment(
            bookIds: [id], shelvesToAssign: into ? [shelf] : [], shelvesToUnassign: into ? [] : [shelf])
        try await withToken { token in
            _ = try await fetch.data(
                try fetch.request(
                    "api/v1/books/shelves", method: "POST", json: assignment,
                    headerLines: ["Authorization": "Bearer " + token]),
                title: title)
        }
    }

    private func favoritesShelfId(create: Bool) async throws -> Int? {
        let shelves = try await json([GrimmoryResponses.Shelf].self, "api/v1/app/shelves")
        if let shelf = shelves.first(where: {
            $0.name.caseInsensitiveCompare(GrimmorySource.favoritesShelf) == .orderedSame
        }) {
            return shelf.id
        }
        guard create else { return nil }
        let new = try await withToken { token in
            try await fetch.json(
                GrimmoryResponses.Shelf.self,
                try fetch.request(
                    "api/v1/shelves", method: "POST",
                    json: GrimmoryResponses.CreateShelf(
                        name: GrimmorySource.favoritesShelf, icon: "heart", iconType: "LUCIDE",
                        publicShelf: false),
                    headerLines: ["Authorization": "Bearer " + token]))
        }
        return new.id
    }

    // MARK: - Helpers

    /// Runs an action with a valid token; a 401 despite a valid token is retried once with a
    /// refreshed token, after which the account is signed out.
    private func withToken<Output: Sendable>(
        _ action: (String) async throws -> Output
    ) async throws -> Output {
        let token = try await accessGuard.token()
        mirror.withLock {
            $0 = GrimmoryAccess(token: token, refreshToken: $0.refreshToken, flow: $0.flow)
        }
        do {
            return try await action(token)
        } catch SourceError.signedOut {
            let new = try await accessGuard.token(force: true)
            mirror.withLock {
                $0 = GrimmoryAccess(token: new, refreshToken: $0.refreshToken, flow: $0.flow)
            }
            return try await action(new)
        }
    }

    /// - Parameter patience: how long the server may take to the first byte — the whole catalog
    ///   is built first and then sent (35,000 books: over 40 s).
    private func json<Answer: Decodable & Sendable>(
        _ type: Answer.Type, _ path: String, query: [URLQueryItem] = [], title: TitleID? = nil,
        patience: TimeInterval? = nil
    ) async throws -> Answer {
        try await withToken { token in
            var request = fetch.request(
                path, query: query, headerLines: ["Authorization": "Bearer " + token])
            if let patience { request.timeoutInterval = patience }
            return try await fetch.json(type, request, title: title)
        }
    }
}

/// Holds the token pair and refreshes it — once, even if many are waiting.
actor AccessGuard {
    private var access: GrimmoryAccess
    private var ongoing: Task<GrimmoryAccess, Error>?
    private let fetch: ServerFetch
    private let changed: @Sendable (GrimmoryAccess) -> Void

    init(access: GrimmoryAccess, fetch: ServerFetch, changed: @escaping @Sendable (GrimmoryAccess) -> Void) {
        self.access = access
        self.fetch = fetch
        self.changed = changed
    }

    func token(force: Bool = false) async throws -> String {
        if !force, access.usable() { return access.token }
        if let ongoing { return try await ongoing.value.token }
        let old = access
        let task = Task { [fetch] in
            let answer = try await fetch.json(
                GrimmoryResponses.Login.self,
                try fetch.request(
                    "api/v1/auth/refresh", method: "POST",
                    json: GrimmoryResponses.RefreshBody(refreshToken: old.refreshToken)))
            return GrimmoryAccess(
                token: answer.accessToken, refreshToken: answer.refreshToken,
                flow: GrimmoryAccess.flow(from: answer.expires))
        }
        ongoing = task
        defer { ongoing = nil }
        let new = try await task.value
        access = new
        changed(new)
        Diagnostics.step(
            "Grimmory: access refreshed, valid until \(new.flow)", since: nil, area: "Source")
        return new.token
    }
}

extension SourceError {
    /// The server does not know the page endpoint (older Grimmory).
    fileprivate var endpointMissing: Bool {
        switch self {
        case .unreadable(_, let reason): reason.hasPrefix("404")
        case .serverDisruption(_, let status): status == 404 || status == 405
        default: false
        }
    }

    /// Is a second attempt at the same page worthwhile?
    fileprivate var temporary: Bool {
        switch self {
        case .unreachable: true
        case .serverDisruption(_, let status): status >= 500
        default: false
        }
    }
}
