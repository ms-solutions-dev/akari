import Bedrock
import Foundation
import SourcesKit

/// Komga as a source: series and volumes, page stream, reading state per volume.
///
/// Built against Komga 1.26.3, checked against its real responses. `GET /api/v1/series`
/// and `GET /api/v1/books` are deprecated there; the way is `POST …/list` with an empty
/// filter. Both deliver 613 volumes in one 1.3 MB response — one fetch, no paging.
public final class KomgaSource: Source, Sendable {
    public let account: KomgaAccount
    let fetcher: ServerFetch

    /// How many entries are requested per page — 500 keeps the extract at one
    /// fetch, as long as the collection does not grow tenfold.
    static let pageSize = 500

    public init(account: KomgaAccount, transport: any Transport = URLSession.forSource()) {
        self.account = account
        self.fetcher = ServerFetch(baseURL: account.server, source: account.identifier, transport: transport)
    }

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }

    public func headerLines() -> [String: String] {
        ["X-API-Key": account.apiKey]
    }

    // MARK: - Sign in

    /// Signs in once with email and password and creates the key the account will
    /// use from then on. The password does not leave this function.
    public static func signIn(
        server: URL, email: String, password: String, deviceName: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> KomgaAccount {
        let identifier = SourceID(provider: .komga, server: server.host() ?? server.absoluteString)
        let fetcher = ServerFetch(baseURL: server, source: identifier, transport: transport)
        let basic = ["Authorization": "Basic " + Data((email + ":" + password).utf8).base64EncodedString()]
        let user = try await fetcher.json(
            KomgaResponses.User.self, fetcher.request("api/v2/users/me", headerLines: basic))
        let created = try await fetcher.json(
            KomgaResponses.ApiKey.self,
            try fetcher.request(
                "api/v2/users/me/api-keys", method: "POST",
                json: KomgaResponses.CreateAuthKey(comment: KomgaSource.keyComment(deviceName)),
                headerLines: basic))
        Diagnostics.step(
            "Komga: signed in as \(user.email), key \(created.id)", since: nil, area: "Source"
        )
        return KomgaAccount(
            server: server, userId: user.id, email: user.email, apiKey: created.key,
            keyId: created.id, roles: user.roles)
    }

    /// Deletes the key on the server — the account is signed out there afterwards,
    /// not just forgotten here.
    /// "Akari on iPad · 19.9.2026, 12:18" — Komga requires a unique comment per user
    /// (400 `ERR_1034`); without the time, every second sign-in of the same account on
    /// the same device failed as a "foreign server".
    static func keyComment(
        _ deviceName: String, now: Date = Date(), locale: Locale = .current
    ) -> String {
        let time = now.formatted(
            Date.FormatStyle(date: .numeric, time: .shortened, locale: locale))
        return String(
            format: String(localized: "server.keyComment", defaultValue: "Akari on %@ · %@", bundle: .main),
            deviceName, time)
    }

    public func signOut() async throws {
        _ = try await fetcher.data(
            fetcher.request(
                "api/v2/users/me/api-keys/\(account.keyId)", method: "DELETE", headerLines: headerLines())
        )
    }

    // MARK: - Source

    /// `GET /api/v2/users/me` with the key: 200 means signed in, 401 means
    /// key revoked.
    public func verify() async throws {
        _ = try await fetcher.json(
            KomgaResponses.User.self, fetcher.request("api/v2/users/me", headerLines: headerLines()))
    }

    public func library() async throws -> LibraryExtract {
        let start = Date()
        let seriesList = try await allPages(
            KomgaResponses.Series.self, path: "api/v1/series/list", sorting: ["metadata.titleSort,asc"])
        let books = try await allPages(
            KomgaResponses.Book.self, path: "api/v1/books/list",
            sorting: ["seriesId,asc", "metadata.numberSort,asc"])
        let seriesById = Dictionary(uniqueKeysWithValues: seriesList.map { ($0.id, $0) })
        var readingStates: [TitleID: ReadingState] = [:]
        let title = books.map { book in
            let t = KomgaMapping.title(
                book, series: seriesById[book.seriesId], source: identifier, baseURL: fetcher.baseURL)
            if let f = book.readProgress {
                readingStates[t.identifier] = KomgaMapping.readingState(f, pages: book.media.pagesCount)
            }
            return t
        }
        Diagnostics.step(
            "Komga: \(seriesList.count) series, \(books.count) volumes, \(readingStates.count) reading states",
            since: start,
            area: "Source")
        return LibraryExtract(
            source: identifier,
            seriesList: seriesList.map {
                KomgaMapping.series($0, source: identifier, baseURL: fetcher.baseURL)
            },
            title: title, readingStates: readingStates, state: Date())
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        let book = try await self.book(identifier)
        let series = try await fetcher.json(
            KomgaResponses.Series.self,
            fetcher.request("api/v1/series/\(book.seriesId)", headerLines: headerLines()))
        return KomgaMapping.title(book, series: series, source: self.identifier, baseURL: fetcher.baseURL)
    }

    /// Komga hands out every volume as a file — even the CBZ of a manga.
    public func file(_ title: Title) -> URL? {
        fetcher.baseURL.appending(path: "api/v1/books/\(title.identifier.id)/file")
    }

    public func content(_ title: Title) -> ContentSource {
        let baseURL = fetcher.baseURL
        let id = title.identifier.id
        if title.kind == .book {
            return .file(
                baseURL.appending(path: "api/v1/books/\(id)/file"), size: nil, rangeCapable: true)
        }
        let count = if case .pages(let n) = title.scope { n } else { 0 }
        let fetcher = fetcher
        let headerLines = headerLines()
        return .pageStream(
            count: count,
            page: { page in baseURL.appending(path: "api/v1/books/\(id)/pages/\(page)") },
            measures: {
                // The manifest: 213 entries, 31 kB — once per volume, before the first page.
                // Without dimensions (Komga never analyzed the image) a page counts as portrait.
                try await fetcher.json(
                    [KomgaResponses.PageDimensions].self,
                    fetcher.request("api/v1/books/\(id)/pages", headerLines: headerLines),
                    title: title.identifier
                )
                .sorted { $0.number < $1.number }
                .map { PageSize(width: $0.width ?? 0, height: $0.height ?? 1) }
            })
    }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        let book = try await self.book(identifier)
        return book.readProgress.map { KomgaMapping.readingState($0, pages: book.media.pagesCount) }
    }

    /// Writes page and "completed". Komga has no device name at this
    /// endpoint — that stays with the local progress.
    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        guard case .page(let page, _) = state.position else {
            throw SourceError.notPossible(self.identifier, "Komga only knows pages")
        }
        _ = try await fetcher.data(
            try fetcher.request(
                "api/v1/books/\(identifier.id)/read-progress", method: "PATCH",
                json: KomgaResponses.ProgressReport(page: page, completed: state.completed),
                headerLines: headerLines()),
            title: identifier)
    }

    public func forget(progressFor identifier: TitleID) async throws {
        _ = try await fetcher.data(
            fetcher.request(
                "api/v1/books/\(identifier.id)/read-progress", method: "DELETE", headerLines: headerLines()),
            title: identifier)
    }

    /// Komga has no per-user saved list — reading lists are visible to
    /// everyone, and that is exactly what an account with two users does not want. For manga
    /// "saved" lives only in the app.
    public func savedList() async throws -> Set<TitleID> {
        throw SourceError.notPossible(identifier, "Komga has no saved list")
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        throw SourceError.notPossible(self.identifier, "Komga has no saved list")
    }

    // MARK: - Collections

    /// Collections (series) and reading lists (volumes, ordered) — both library-wide,
    /// hence never private; editable only as ADMIN.
    public func collections() async throws -> [TitleCollection] {
        let mayEdit = capabilities.contains(.editCollections)
        let collections = try await fetcher.json(
            KomgaResponses.Page<KomgaResponses.TitleCollection>.self,
            fetcher.request(
                "api/v1/collections", query: [URLQueryItem(name: "size", value: "1000")],
                headerLines: headerLines())
        )
        .content.map { s in
            TitleCollection(
                identifier: CollectionID(source: identifier, id: s.id), name: s.name,
                collectionKind: .collection,
                entries: s.seriesIds.map { .series(SeriesID(source: identifier, id: $0)) },
                ordered: s.ordered,
                isPrivate: false, editable: mayEdit)
        }
        let readingLists = try await fetcher.json(
            KomgaResponses.Page<KomgaResponses.ReadingList>.self,
            fetcher.request(
                "api/v1/readlists", query: [URLQueryItem(name: "size", value: "1000")],
                headerLines: headerLines())
        )
        .content.map { l in
            TitleCollection(
                identifier: CollectionID(source: identifier, id: l.id), name: l.name,
                collectionKind: .readingList,
                entries: l.bookIds.map { .title(TitleID(source: identifier, id: $0)) },
                ordered: l.ordered,
                isPrivate: false, editable: mayEdit)
        }
        return collections + readingLists
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        guard capabilities.contains(.editCollections) else {
            throw SourceError.denied(identifier)
        }
        if collectionKind.takesSeries {
            let new = try await fetcher.json(
                KomgaResponses.TitleCollection.self,
                try fetcher.request(
                    "api/v1/collections", method: "POST",
                    json: KomgaResponses.CreateCollection(name: name, ordered: false, seriesIds: []),
                    headerLines: headerLines()))
            return TitleCollection(
                identifier: CollectionID(source: identifier, id: new.id), name: new.name,
                collectionKind: .collection,
                entries: [], ordered: new.ordered, isPrivate: false, editable: true)
        }
        let new = try await fetcher.json(
            KomgaResponses.ReadingList.self,
            try fetcher.request(
                "api/v1/readlists", method: "POST",
                json: KomgaResponses.CreateReadingList(name: name, summary: "", ordered: true, bookIds: []),
                headerLines: headerLines()))
        return TitleCollection(
            identifier: CollectionID(source: identifier, id: new.id), name: new.name,
            collectionKind: .readingList,
            entries: [], ordered: new.ordered, isPrivate: false, editable: true)
    }

    /// Komga has no "one more entry": the list is read and written back in
    /// full (`PATCH`) — so fetch it fresh first, then change it.
    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        guard capabilities.contains(.editCollections) else {
            throw SourceError.denied(identifier)
        }
        switch target {
        case .series(let series):
            let existing = try await fetcher.json(
                KomgaResponses.TitleCollection.self,
                fetcher.request("api/v1/collections/\(collection.id)", headerLines: headerLines()))
            var ids = existing.seriesIds.filter { $0 != series.id }
            if into { ids.append(series.id) }
            _ = try await fetcher.data(
                try fetcher.request(
                    "api/v1/collections/\(collection.id)", method: "PATCH",
                    json: KomgaResponses.ChangeCollection(seriesIds: ids), headerLines: headerLines()))
        case .title(let title):
            let existing = try await fetcher.json(
                KomgaResponses.ReadingList.self,
                fetcher.request("api/v1/readlists/\(collection.id)", headerLines: headerLines()))
            var ids = existing.bookIds.filter { $0 != title.id }
            if into { ids.append(title.id) }
            _ = try await fetcher.data(
                try fetcher.request(
                    "api/v1/readlists/\(collection.id)", method: "PATCH",
                    json: KomgaResponses.ChangeReadingList(bookIds: ids), headerLines: headerLines()),
                title: title)
        }
    }

    // MARK: - Helpers

    private func book(_ identifier: TitleID) async throws -> KomgaResponses.Book {
        try await fetcher.json(
            KomgaResponses.Book.self,
            fetcher.request("api/v1/books/\(identifier.id)", headerLines: headerLines()),
            title: identifier)
    }

    /// Pages through a `POST …/list` list to the last page.
    private func allPages<Element: Decodable & Sendable>(
        _ type: Element.Type, path: String, sorting: [String]
    ) async throws
        -> [Element]
    {
        var all: [Element] = []
        var page = 0
        while true {
            var query = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(Self.pageSize)),
            ]
            query += sorting.map { URLQueryItem(name: "sort", value: $0) }
            let response = try await fetcher.json(
                KomgaResponses.Page<Element>.self,
                fetcher.request(
                    path, method: "POST", query: query, body: Data("{}".utf8), headerLines: headerLines())
            )
            all += response.content
            if response.last || response.content.isEmpty || response.number != page { return all }
            page += 1
        }
    }
}
