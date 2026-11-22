import Bedrock
import Foundation
import SourcesKit
import Synchronization

/// A WebDAV folder as a source: the tree is crawled with `PROPFIND`, every EPUB, PDF, CBZ or CBR
/// file in it is a title.
///
/// **The crawl:** first a `PROPFIND` with `Depth: infinity` — one call, the whole tree. Nextcloud
/// refuses that (403, `Sabre\DAV\Exception\Forbidden`), then it goes folder by folder with
/// `Depth: 1`, with caps (500 folders, depth 8, 5,000 titles) and a deficiency in the log if one
/// applies. Folders with a leading dot stay out.
///
/// **What the path says is on the shelf at once** (``PathMetadata``); what the file says comes
/// from the ``Backfill`` — with a time budget in the crawl (eight seconds, sixty files) and
/// afterwards in the background, so that a shelf with three hundred books does not need minutes
/// through the tunnel before it stands. On the next refresh the names from the OPF are there.
/// The ``WebdavSwitch`` fetches covers and pages only when a tile or the reader needs them.
///
/// **What WebDAV does not know stays local:** the reading state lives in a JSON file per source
/// (``StateStore``). No saved list and no collections.
public final class WebdavSource: Source, Sendable {
    public let account: WebdavAccount
    let fetch: ServerFetch
    let gate: WebdavSwitch
    let states: StateStore
    let backfill: BackfillStore
    private let background = Mutex<Task<Void, Never>?>(nil)

    static let maxFolders = 500
    static let maxDepth = 8
    static let maxTitles = 5_000
    /// How long the catalog crawl waits for the backfill, and how many files it reads at most —
    /// the rest continues in the background.
    static let backfillBudget: TimeInterval = 8
    static let backfillPerRun = 60

    static let propfindBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getcontenttype/><d:getlastmodified/><d:getetag/><d:displayname/></d:prop></d:propfind>
        """.utf8)

    /// - Parameters:
    ///   - transport: the session — or already the ``WebdavSwitch``; a bare session gets the switch
    ///     put in front so that covers and pages arrive even if nobody set it up from outside.
    ///   - persistence: the file of the reading states; `nil` takes the standard store
    ///   - backfill: the backfill findings; the tests pass their own
    public init(
        account: WebdavAccount, transport: any Transport = URLSession.forSource(), persistence: URL? = nil,
        backfill: BackfillStore = .standard
    ) {
        self.account = account
        self.backfill = backfill
        self.gate = transport as? WebdavSwitch ?? WebdavSwitch(network: transport, persistence: backfill)
        self.fetch = ServerFetch(baseURL: account.folder, source: account.identifier, transport: gate)
        self.states = StateStore(file: persistence ?? StateStore.standard(for: account.identifier))
    }

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }
    public func headerLines() -> [String: String] { account.headerLines }

    // MARK: - Sign in

    /// `PROPFIND` with `Depth: 0` on the folder — 207 (or 200) means: folder there, access correct.
    /// What comes back must be a folder; a file or an HTML page is a foreign server.
    public static func signIn(
        folder: URL, username: String, password: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> WebdavAccount {
        let account = WebdavAccount(folder: folder, username: username, password: password)
        let source = WebdavSource(
            account: account, transport: transport, persistence: nil, backfill: BackfillStore(file: nil))
        let entries = try await source.propfind(account.folder, depth: "0")
        guard let first = entries.first, first.isFolder else {
            throw SourceError.unreadable(account.identifier, "\(account.folder.path()) is not a folder")
        }
        Diagnostics.step("WebDAV: folder \(account.title) reachable", since: nil, area: "Source")
        return account
    }

    public func verify() async throws {
        _ = try await propfind(account.folder, depth: "0")
    }

    // MARK: - Catalog

    public func library() async throws -> LibraryExtract {
        let start = Date()
        let files = try await crawl()
        let unresolved = await runBackfill(files, budget: WebdavSource.backfillBudget)
        let title = files.map { title($0) }
        let seriesList = WebdavSource.seriesList(from: title)
        Diagnostics.step(
            "WebDAV \(account.title): \(files.count) files, \(title.count) titles, \(seriesList.count) series, backfill pending: \(unresolved.count)",
            since: start, area: "Source")
        if !unresolved.isEmpty { runBackfillInBackground(unresolved) }
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: title,
            readingStates: states.all(source: identifier),
            state: Date())
    }

    /// A file in the tree: the entry from the PROPFIND, its path relative to the account's folder
    /// and its address.
    struct FileEntry: Sendable {
        let entry: WebdavEntry
        let path: String
        let address: URL
        let type: FileType
    }

    /// All files with a known extension under the folder — with `Depth: infinity` if the server
    /// allows it, otherwise folder by folder.
    func crawl() async throws -> [FileEntry] {
        let root = account.folder.path(percentEncoded: false)
        var entries: [WebdavEntry]
        do {
            entries = try await propfind(account.folder, depth: "infinity")
        } catch SourceError.denied, SourceError.unreadable {
            Diagnostics.step(
                "WebDAV \(account.title): depth ∞ refused — folder by folder at depth 1", since: nil,
                area: "Source")
            entries = try await crawlFolderByFolder()
        }
        var files: [FileEntry] = []
        for e in entries where !e.isFolder {
            guard let type = FileType(name: e.name), let path = WebdavSource.relative(e.path, to: root),
                !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
            else { continue }
            files.append(
                FileEntry(entry: e, path: path, address: account.folder.appending(path: path), type: type))
            if files.count >= WebdavSource.maxTitles {
                Diagnostics.deficiency(
                    "WebDAV \(account.title): cap reached (\(files.count) titles) — the folder is incomplete",
                    since: nil, area: "Source")
                break
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// `Depth: 1`, folder by folder, breadth first — with caps for folders and depth.
    func crawlFolderByFolder() async throws -> [WebdavEntry] {
        let root = account.folder.path(percentEncoded: false)
        var seen: Set<String> = []
        var queue: [(URL, Int)] = [(account.folder, 0)]
        var all: [WebdavEntry] = []
        var folder = 0
        while !queue.isEmpty {
            let (address, depth) = queue.removeFirst()
            guard seen.insert(address.path(percentEncoded: false)).inserted else { continue }
            if folder >= WebdavSource.maxFolders {
                Diagnostics.deficiency(
                    "WebDAV \(account.title): cap reached (\(folder) folders) — the folder is incomplete",
                    since: nil, area: "Source")
                break
            }
            folder += 1
            let entries = try await propfind(address, depth: "1")
            for e in entries {
                let own =
                    e.path == address.path(percentEncoded: false)
                    || e.path == address.path(percentEncoded: false) + "/"
                guard !own else { continue }
                all.append(e)
                guard e.isFolder, !e.name.hasPrefix("."), let rel = WebdavSource.relative(e.path, to: root)
                else { continue }
                if depth + 1 > WebdavSource.maxDepth {
                    Diagnostics.deficiency(
                        "WebDAV \(account.title): depth \(WebdavSource.maxDepth) reached — \(rel) stays out",
                        since: nil, area: "Source")
                    continue
                }
                queue.append((account.folder.appending(path: rel, directoryHint: .isDirectory), depth + 1))
            }
        }
        return all
    }

    /// The path of a resource relative to the account's folder — `nil` if it is not below it.
    static func relative(_ path: String, to root: String) -> String? {
        let w = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(w) else { return nil }
        var rel = String(path.dropFirst(w.count))
        while rel.hasSuffix("/") { rel.removeLast() }
        return rel.isEmpty ? nil : rel
    }

    /// A `PROPFIND` with the body that names the six properties. The refusal at depth ∞ is the
    /// normal case with Nextcloud, not a deficiency — it bypasses the server fetch so that the trace
    /// carries no red entry per run.
    func propfind(_ address: URL, depth: String) async throws -> [WebdavEntry] {
        var request = URLRequest(url: address)
        request.httpMethod = "PROPFIND"
        request.httpBody = WebdavSource.propfindBody
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml, text/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        for (k, v) in account.headerLines { request.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        if depth == "infinity" {
            let (body, response): (Data, HTTPURLResponse)
            do {
                (body, response) = try await gate.send(request)
            } catch {
                throw SourceError.from(error, source: identifier)
            }
            if let failure = SourceError.from(status: response.statusCode, source: identifier) {
                throw failure
            }
            data = body
        } else {
            data = try await fetch.data(request).0
        }
        do {
            return try WebdavParser.parse(data)
        } catch {
            throw SourceError.unreadable(identifier, "\(address.path()): \(error.localizedDescription)")
        }
    }

    // MARK: - Title

    /// A title from path and — if present — backfill. The identifier is the path relative to the
    /// folder: readable, stable, and the local reading state hangs on it. A cover exists as long as
    /// the backfill has not said there is none — the switch fetches it when a tile shows it.
    func title(_ file: FileEntry) -> Title {
        let path = PathMetadata.extract(file.path, type: file.type)
        let finding = backfill.finding(file.address, etag: file.entry.etag, size: file.entry.size)
        let kind = file.type.kind
        var name = finding?.name ?? path.name
        if name.isEmpty { name = path.name }
        let authors = (finding?.authors.isEmpty == false ? finding?.authors : nil) ?? path.authors
        let bookSeries = finding?.bookSeries ?? path.bookSeries
        let volume = finding?.bookSeries != nil ? finding?.volume : path.volume
        let series: SeriesReference? = bookSeries.map {
            SeriesReference(
                identifier: SeriesID(source: identifier, id: "reihe:" + $0), name: $0, volume: volume)
        }
        let cover: URL? =
            (file.type == .epub || file.type == .cbz) && (finding == nil || finding?.cover != nil)
            ? WebdavSwitch.cover(file.address) : nil
        return Title(
            identifier: TitleID(source: identifier, id: file.path), kind: kind, name: name, authors: authors,
            series: series, cover: cover,
            summary: Title.blurb(finding?.summary),
            scope: finding?.pages.map { .pages($0.count) } ?? .unknown,
            language: Title.languageCode(finding?.language), publisher: finding?.publisher,
            added: file.entry.changed, size: file.entry.size,
            format: Title.format(file.type.rawValue))
    }

    static func seriesList(from title: [Title]) -> [Series] {
        var clusters: [SeriesID: [Title]] = [:]
        for t in title { if let s = t.series { clusters[s.identifier, default: []].append(t) } }
        return clusters.map { identifier, volumes in
            let sortedVolumes = volumes.sorted {
                ($0.series?.volume ?? .infinity) < ($1.series?.volume ?? .infinity)
            }
            let first = sortedVolumes[0]
            var authors: [String] = []
            for b in sortedVolumes { for a in b.authors where !authors.contains(a) { authors.append(a) } }
            return Series(
                identifier: identifier, kind: first.kind, name: first.series?.name ?? identifier.id,
                authors: authors,
                cover: sortedVolumes.first { $0.cover != nil }?.cover, volumeCount: volumes.count,
                language: first.language, added: volumes.compactMap(\.added).min())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        throw SourceError.notPossible(
            self.identifier, "WebDAV has no single-title detail — the folder is the list")
    }

    /// The address of the file for a title — from the identifier, which is the path.
    public func file(_ title: Title) -> URL? {
        account.folder.appending(path: title.identifier.id)
    }

    /// A manga with a read directory is a page stream (each page a range via the switch);
    /// everything else is the file. A CBZ whose backfill is still pending is a file until the next
    /// refresh — the shell then shows the notice sheet.
    public func content(_ title: Title) -> ContentSource {
        let address = account.folder.appending(path: title.identifier.id)
        if title.kind == .manga, case .pages(let count) = title.scope, count > 0,
            FileType(name: title.identifier.id) == .cbz
        {
            return .pageStream(count: count) { n in WebdavSwitch.page(n, from: address) }
        }
        return .file(address, size: title.size, rangeCapable: true)
    }

    // MARK: - Backfill

    /// Reads the files without a valid finding until budget or cap applies; returns what remained
    /// open. CBZ first — without the directory a volume cannot be paged through, a book without OPF
    /// can at least be read. A server without ranges answers every question with the whole file — the
    /// others then get the same finding without anybody asking. A transport error is not remembered
    /// (try again later) but ends this run.
    func runBackfill(_ files: [FileEntry], budget: TimeInterval) async -> [FileEntry] {
        let start = Date()
        var unresolved = files.filter { d in
            (d.type == .epub || d.type == .cbz)
                && backfill.finding(d.address, etag: d.entry.etag, size: d.entry.size) == nil
        }
        unresolved.sort { ($0.type == .cbz ? 0 : 1, $0.path) < ($1.type == .cbz ? 0 : 1, $1.path) }
        let reader = RangeReader(transport: gate.network, headerLines: account.headerLines)
        var read = 0
        while let d = unresolved.first, read < WebdavSource.backfillPerRun,
            Date().timeIntervalSince(start) < budget
        {
            do {
                let finding = try await Backfill.extract(
                    d.address, type: d.type, etag: d.entry.etag, size: d.entry.size, reader: reader)
                backfill.save(finding, for: d.address)
                unresolved.removeFirst()
                read += 1
                if finding.noAreas {
                    for remainder in unresolved {
                        var b = Backfill.Finding(etag: remainder.entry.etag, size: remainder.entry.size)
                        b.futile = true
                        b.noAreas = true
                        backfill.save(b, for: remainder.address)
                    }
                    unresolved.removeAll()
                }
            } catch {
                Diagnostics.deficiency(
                    "WebDAV backfill \(d.path) aborted: \(String(describing: error))", since: start,
                    area: "Source")
                break
            }
        }
        if read > 0 { backfill.secure() }
        return unresolved
    }

    /// The rest of the backfill, in the background — one run at a time, with a cap.
    func runBackfillInBackground(_ files: [FileEntry]) {
        background.withLock { ongoing in
            guard ongoing == nil || ongoing?.isCancelled == true else { return }
            ongoing = Task.detached(priority: .utility) { [self] in
                let remainder = await self.runBackfill(files, budget: 600)
                Diagnostics.step(
                    "WebDAV \(account.title): backfill in the background, \(remainder.count) pending",
                    since: nil,
                    area: "Source")
                self.background.withLock { $0 = nil }
            }
        }
    }

    // MARK: - Reading state, local

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        states.state(identifier)
    }

    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        try states.write(state, for: identifier)
    }

    public func forget(progressFor identifier: TitleID) async throws {
        try states.forget(identifier)
    }

    public func savedList() async throws -> Set<TitleID> {
        throw SourceError.notPossible(identifier, "WebDAV has no saved list")
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        throw SourceError.notPossible(self.identifier, "WebDAV has no saved list")
    }

    public func collections() async throws -> [TitleCollection] {
        throw SourceError.notPossible(identifier, "WebDAV has no collections")
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        throw SourceError.notPossible(identifier, "WebDAV has no collections")
    }

    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        throw SourceError.notPossible(identifier, "WebDAV has no collections")
    }
}
