import Bedrock
import Foundation
import SourcesKit
import Synchronization

/// Kavita as a source: series, volumes and chapters, page stream for comics and manga,
/// EPUB as a file, reading state per chapter — read **and written**.
///
/// Built against Kavita 0.9.1.4; the contract is its
/// OpenAPI. Until then Kavita only ran via OPDS (`OpdsKit`): the reading state arrived there
/// as `pse:lastRead` and never went back. Here it goes via `/api/Reader/progress`.
///
/// **The extract costs one fetch per series:** Kavita has no list of all chapters;
/// `all-v2` delivers the series, `/api/Series/volumes` per series volumes, chapters and
/// states. A books library with 30,000 EPUBs is 30,000 fetches — hence
/// six at a time, with progress ("12,000 of 35,551"), and with a previous
/// extract only the series whose page count, read pages or last
/// chapter changed (``library(previously:progress:)``).
public final class KavitaSource: Source, Sendable {
    public let account: KavitaAccount
    let fetcher: ServerFetch
    /// Volume, series, library and page count per chapter — from the extract, for
    /// writing the state (Kavita wants all four) and the page stream.
    private let references = Mutex<[Int: KavitaMapping.ChapterReference]>([:])
    /// The first title per series (by volume and chapter) — the one the saved list
    /// shows when Kavita lists a series as "Want to Read".
    private let first = Mutex<[Int: TitleID]>([:])
    /// Where the series' markers lie between two launches (``MarkerNote``) — `nil` in
    /// the tests.
    private let savedStore: URL?
    private let markerNoteRead = Mutex<MarkerNote??>(nil)
    /// Where the ``LibraryPicker`` lives — its own in the tests. `UserDefaults` is
    /// thread-safe, just not declared `Sendable`.
    nonisolated(unsafe) private let persistence: UserDefaults

    /// Series per page of `all-v2` — Kavita accepts any size; 500 are a good 400 KB.
    static let pageSize = 500
    /// How many `/api/Series/volumes` run at once — enough for the tunnel, few
    /// enough that Kavita (SQLite) can still scan on the side.
    static let concurrency = 6

    public init(
        account: KavitaAccount, transport: any Transport = URLSession.forSource(), savedStore: URL? = nil,
        persistence: UserDefaults = .standard
    ) {
        self.account = account
        self.fetcher = ServerFetch(baseURL: account.server, source: account.identifier, transport: transport)
        self.savedStore = savedStore
        self.persistence = persistence
    }

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }

    /// The auth key applies as a header on every endpoint, covers included (200 on
    /// `/api/Image/series-cover` with it, 401 without). Only `/api/Reader/image` wants it
    /// in the query as well (``content(_:)``).
    public func headerLines() -> [String: String] {
        ["x-api-key": account.apiKey]
    }

    // MARK: - Sign in

    /// Signs in once with name and password and uses the JWT of the sign-in to create
    /// an auth key of its own ("Akari on iPhone · …") — visible and revocable
    /// in Kavita's account settings, without changing the password. If the server cannot do that
    /// (before 0.9, or it refuses), the kit takes the account key from the
    /// sign-in (`apiKey`, the same as for OPDS). The password does not leave this
    /// function.
    public static func signIn(
        server: URL, username: String, password: String, deviceName: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> KavitaAccount {
        let identifier = SourceID(provider: .kavita, server: server.host() ?? server.absoluteString)
        let fetcher = ServerFetch(baseURL: server, source: identifier, transport: transport)
        let user = try await fetcher.json(
            KavitaResponses.User.self,
            try fetcher.request(
                "api/Account/login", method: "POST",
                json: KavitaResponses.SignInBody(username: username, password: password)),
            decoder: KavitaResponses.decoder)
        guard let token = user.token, !token.isEmpty else {
            throw SourceError.unreadable(identifier, "sign-in without token")
        }
        var apiKey: String?
        var keyId: Int?
        do {
            let new = try await fetcher.json(
                KavitaResponses.EntryKey.self,
                try fetcher.request(
                    "api/Account/create-auth-key", method: "POST",
                    json: KavitaResponses.CreateAuthKey(
                        keyLength: 32, name: keyName(deviceName)),
                    headerLines: ["Authorization": "Bearer " + token]),
                decoder: KavitaResponses.decoder)
            if let key = new.key, !key.isEmpty {
                apiKey = key
                keyId = new.id
            }
        } catch let failure as SourceError {
            // Whoever was just signed in and still gets 401, or whose server
            // vanishes mid-sentence, has no account — everything else (404 before 0.9,
            // 400 for the name) leaves the account key.
            switch failure {
            case .signedOut, .unreachable: throw failure
            default:
                Diagnostics.step(
                    "Kavita: no dedicated auth key (\(failure.messageKey)), using the account key",
                    since: nil, area: "Source")
            }
        }
        guard let apiKey = apiKey ?? user.apiKey, !apiKey.isEmpty else {
            throw SourceError.unreadable(identifier, "sign-in without key")
        }
        Diagnostics.step(
            "Kavita \(user.kavitaVersion ?? "?"): signed in as \(user.username ?? "?"), key \(keyId.map(String.init) ?? "account")",
            since: nil, area: "Source")
        return KavitaAccount(
            server: server, userId: user.id, username: user.username ?? username,
            apiKey: apiKey, keyId: keyId, roles: user.roles ?? [])
    }

    /// "Akari on iPad · 24.10.2026, 22:18" — unique per sign-in, as with Komga,
    /// so two devices of the same account can be told apart in Kavita's list.
    static func keyName(
        _ deviceName: String, now: Date = Date(), locale: Locale = .current
    ) -> String {
        let time = now.formatted(
            Date.FormatStyle(date: .numeric, time: .shortened, locale: locale))
        return String(
            format: String(localized: "server.keyComment", defaultValue: "Akari on %@ · %@", bundle: .main),
            deviceName, time)
    }

    /// Deletes the own auth key on the server — the account is signed out there afterwards,
    /// not just forgotten here. It leaves the account key (OPDS) alone: another
    /// program may need it.
    public func signOut() async throws {
        guard let id = account.keyId else { return }
        _ = try await fetcher.data(
            fetcher.request(
                "api/Account/auth-key", method: "DELETE",
                query: [URLQueryItem(name: "authKeyId", value: String(id))], headerLines: headerLines()))
    }

    // MARK: - Source

    /// `GET /api/Account/refresh-account` with the key: 200 means signed in,
    /// 401 means key revoked.
    public func verify() async throws {
        _ = try await json(KavitaResponses.User.self, "api/Account/refresh-account")
    }

    public func subLibraries() async throws -> [SubLibrary] {
        try await json([KavitaResponses.Library].self, "api/Library/libraries").map {
            SubLibrary(id: String($0.id), name: $0.name ?? String($0.id))
        }
    }

    /// The number of series from the `Pagination` header — for books that is the number of
    /// titles, for manga fewer. For the question about the library choice that is enough.
    public func titleCount() async throws -> Int? {
        let (_, response) = try await seriesPage(1, size: 1)
        return sheet(response)?.totalItems
    }

    public func library() async throws -> LibraryExtract {
        try await library(previously: nil, progress: { _, _ in })
    }

    public func library(
        progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws -> LibraryExtract {
        try await library(previously: nil, progress: progress)
    }

    /// With a previous extract only the series whose marker changed: pages,
    /// read pages, last chapter and last reading day are on every series in
    /// `all-v2` — what is equal there has not moved in volumes and states.
    /// Changed metadata without a new chapter (a corrected blurb) only arrives
    /// with the next extract without a previous one.
    public func library(
        previously: LibraryExtract?, progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws -> LibraryExtract {
        let start = Date()
        let from = LibraryPicker.from(identifier, persistence)
        let seriesList = try await allSeries().filter { s in
            s.libraryId.map { !from.contains(String($0)) } ?? true
        }
        let reuse = reusable(previously)
        // Reading direction and webtoon are in the reading profile, not on the series — one fetch
        // for all. If it fails, the direction stays open and the reader uses its own.
        let profiles =
            (try? await json([KavitaResponses.ReadingProfile].self, "api/reading-profile/all")) ?? []
        var markers: [Int: SeriesMarker] = [:]
        var title: [Title] = []
        var readingStates: [TitleID: ReadingState] = [:]
        var resultSeries: [Series] = []
        var toFetch: [KavitaResponses.Series] = []
        for s in seriesList {
            let marker = Self.marker(s)
            if let saved = reuse.markers[s.id], saved.marker == marker, let part = reuse.share[String(s.id)] {
                title += part.title
                readingStates.merge(part.states) { new, _ in new }
                if let series = part.series { resultSeries.append(series) }
                markers[s.id] = saved
            } else {
                toFetch.append(s)
            }
        }
        var loaded = seriesList.count - toFetch.count
        progress(loaded, seriesList.count)

        var fetched: [Int: [KavitaResponses.Volume]] = [:]
        try await withThrowingTaskGroup(of: (Int, [KavitaResponses.Volume]?).self) { cluster in
            var next = 0
            func launch() {
                guard next < toFetch.count else { return }
                let id = toFetch[next].id
                next += 1
                cluster.addTask { (id, try await self.volumes(id)) }
            }
            for _ in 0..<Self.concurrency { launch() }
            for try await (id, volumes) in cluster {
                if let volumes { fetched[id] = volumes }
                loaded += 1
                progress(loaded, seriesList.count)
                launch()
            }
        }

        var newReferences: [Int: KavitaMapping.ChapterReference] = [:]
        for s in toFetch {
            guard let volumes = fetched[s.id] else { continue }
            let part = mapSeries(
                s, volumes: volumes,
                readingDirection: KavitaMapping.readingDirection(
                    KavitaMapping.readingProfile(profiles, series: s.id, library: s.libraryId)))
            title += part.title
            readingStates.merge(part.states) { new, _ in new }
            if let series = part.series { resultSeries.append(series) }
            newReferences.merge(part.references) { new, _ in new }
            markers[s.id] = SeriesMarker(marker: Self.marker(s), references: part.references)
        }
        references.withLock { $0.merge(newReferences) { new, _ in new } }
        var firstPerSeries: [Int: TitleID] = [:]
        for t in title {
            guard let s = t.series.flatMap({ Int($0.identifier.id) }), firstPerSeries[s] == nil else {
                continue
            }
            firstPerSeries[s] = t.identifier
        }
        first.withLock { $0 = firstPerSeries }

        let state = Date()
        save(MarkerNote(state: state, seriesList: markers))
        Diagnostics.step(
            "Kavita: \(resultSeries.count) series (\(toFetch.count) fetched), \(title.count) titles, \(readingStates.count) reading states",
            since: start, area: "Source")
        return LibraryExtract(
            source: identifier, seriesList: resultSeries, title: title, readingStates: readingStates,
            state: state)
    }

    /// The detail, with what the extract does not fetch per series: the stars of all accounts
    /// (`/api/Rating/overall-series` — one fetch per series would be 30,000 more
    /// for 30,000 books). If only the rating fails, the title stays without stars.
    public func title(_ identifier: TitleID) async throws -> Title {
        let chapter = try await json(
            KavitaResponses.Chapter.self, "api/Series/chapter", ["chapterId": identifier.id],
            title: identifier)
        let reference = try await reference(identifier, chapter: chapter)
        let volume = try await json(
            KavitaResponses.Volume.self, "api/Volume", ["volumeId": String(reference.volumeId)],
            title: identifier)
        let series = try await json(
            KavitaResponses.Series.self, "api/Series/\(reference.seriesId)", title: identifier)
        let rating = try? await json(
            KavitaResponses.Rating.self, "api/Rating/overall-series", ["seriesId": String(reference.seriesId)]
        )
        let profile = try? await json(
            KavitaResponses.ReadingProfile.self,
            "api/reading-profile/\(reference.libraryId)/\(reference.seriesId)")
        return KavitaMapping.title(
            chapter, volume: volume, series: series, seriesId: reference.seriesId, source: self.identifier,
            baseURL: fetcher.baseURL, rating: rating.flatMap(KavitaMapping.rating),
            readingDirection: KavitaMapping.readingDirection(profile))
    }

    /// Kavita hands out every chapter as a file, with `Download` or `Admin` —
    /// one file as it lies, several as a ZIP.
    public func file(_ title: Title) -> URL? {
        KavitaMapping.address(
            fetcher.baseURL, "api/Download/chapter", "chapterId", Int(title.identifier.id) ?? 0)
    }

    public func content(_ title: Title) -> ContentSource {
        let baseURL = fetcher.baseURL
        let id = title.identifier.id
        if title.kind == .book {
            return .file(
                KavitaMapping.address(baseURL, "api/Download/chapter", "chapterId", Int(id) ?? 0),
                size: title.size, rangeCapable: true)
        }
        let count = if case .pages(let n) = title.scope { n } else { 0 }
        // Kavita only hands out PDF pages as an image if you ask for it.
        let pdf = title.format == "PDF"
        var extra = [URLQueryItem(name: "chapterId", value: id)]
        if pdf { extra.append(URLQueryItem(name: "extractPdf", value: "true")) }
        let query = extra
        // `/api/Reader/image` demands `apiKey` in the query — with the header alone
        // 400 "The apiKey field is required". The image loader stores pages under
        // a hash, the diagnostics write only the path; the address therefore does not reveal the
        // key anywhere it is not already visible.
        let keyItem = URLQueryItem(name: "apiKey", value: account.apiKey)
        let fetcher = fetcher
        let headerLines = headerLines()
        return .pageStream(
            count: count,
            // Akari counts from 1, Kavita's `page` from 0.
            page: { page in
                baseURL.appending(path: "api/Reader/image").appending(
                    queryItems: query + [URLQueryItem(name: "page", value: String(page - 1)), keyItem])
            },
            measures: {
                // The dimensions of all pages in one fetch — Kavita unpacks the archive for it,
                // which the reader demands right away anyway.
                try await fetcher.json(
                    Lenient<KavitaResponses.PageDimensions>.self,
                    fetcher.request("api/Reader/file-dimensions", query: query, headerLines: headerLines),
                    decoder: KavitaResponses.decoder, title: title.identifier
                )
                .wrappedValue
                .sorted { $0.pageNumber < $1.pageNumber }
                .map { PageSize(width: $0.width ?? 0, height: $0.height ?? 1) }
            })
    }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        let reference = try await reference(identifier)
        let (data, _) = try await fetcher.data(
            fetcher.request(
                "api/Reader/get-progress", query: [URLQueryItem(name: "chapterId", value: identifier.id)],
                headerLines: headerLines()),
            title: identifier)
        // Without a state Kavita answers `pageNum: 0` and all zeros; an empty
        // body means the same.
        guard !data.isEmpty else { return nil }
        let f: KavitaResponses.Progress
        do {
            f = try KavitaResponses.decoder.decode(KavitaResponses.Progress.self, from: data)
        } catch {
            throw SourceError.unreadable(self.identifier, "get-progress: \(Swift.type(of: error))")
        }
        return KavitaMapping.readingState(
            page: f.pageNum, pages: reference.pages, epub: reference.epub,
            time: f.lastModifiedUtc.flatMap(KavitaResponses.time))
    }

    /// Writes the page — for an EPUB the section the fraction falls in. "Done"
    /// is the page count itself at Kavita; there is no field of its own. The
    /// endpoint does not know the device name.
    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        let reference = try await reference(identifier)
        try await report(KavitaMapping.pageNumber(state, pages: reference.pages), reference, identifier)
    }

    /// Kavita does not delete a state; `pageNum` 0 is "unread" there — the same as
    /// "Mark as unread" writes in the web UI.
    public func forget(progressFor identifier: TitleID) async throws {
        try await report(0, try await reference(identifier), identifier)
    }

    // MARK: - Saved list

    /// Kavita's "Want to Read" — series, per account. Akari's saved list holds titles, so
    /// for every saved series its first title is in it: for books the book
    /// itself (one series, one title), for manga volume 1. Series that the last extract
    /// does not know (a disabled library) are missing.
    public func savedList() async throws -> Set<TitleID> {
        var ids: [Int] = []
        var page = 1
        while true {
            let (data, response) = try await fetcher.data(
                try fetcher.request(
                    "api/want-to-read/v2", method: "POST", json: KavitaResponses.SeriesFilter(),
                    query: pagingQuery(page), headerLines: headerLines()))
            let list = try decodeLenient(Lenient<KavitaResponses.Series>.self, data, "want-to-read")
                .wrappedValue
            ids += list.map(\.id)
            if isLast(page, list.count, response) { break }
            page += 1
        }
        let firstTitles = self.first.withLock { $0 }
        return Set(ids.compactMap { firstTitles[$0] })
    }

    /// Saves the title's series — "Want to Read" knows nothing smaller. Whoever forgets a
    /// volume forgets the series.
    public func save(_ identifier: TitleID, saved: Bool) async throws {
        let reference = try await reference(identifier)
        _ = try await fetcher.data(
            try fetcher.request(
                saved ? "api/want-to-read/add-series" : "api/want-to-read/remove-series", method: "POST",
                json: KavitaResponses.WantToReadSeries(seriesIds: [reference.seriesId]),
                headerLines: headerLines()),
            title: identifier)
    }

    // MARK: - Collections

    /// Collections (series, kind ``TitleCollection/CollectionKind/collection``) and reading lists
    /// (chapters in order, ``TitleCollection/CollectionKind/readingList``). Both belong to an
    /// account; what an admin has promoted (`promoted`) is seen by all — private is what
    /// is not promoted, editable what belongs to this account.
    public func collections() async throws -> [TitleCollection] {
        let me = account.username
        var result: [TitleCollection] = []
        let collections = try await json(
            [KavitaResponses.TitleCollection].self, "api/Collection", ["ownedOnly": "false"])
        for s in collections {
            let seriesList = try await seriesOfCollection(s.id)
            result.append(
                TitleCollection(
                    identifier: CollectionID(source: identifier, id: Self.collectionPrefix + String(s.id)),
                    name: s.title ?? String(s.id), collectionKind: .collection,
                    entries: seriesList.map { .series(SeriesID(source: identifier, id: String($0))) },
                    isPrivate: s.promoted != true, editable: s.owner == nil || s.owner == me))
        }
        let (data, _) = try await fetcher.data(
            fetcher.request(
                "api/ReadingList/lists", method: "POST",
                query: pagingQuery(1, size: 1000) + [
                    URLQueryItem(name: "includePromoted", value: "true")
                ],
                headerLines: headerLines()))
        let lists = try decodeLenient(Lenient<KavitaResponses.ReadingList>.self, data, "ReadingList/lists")
            .wrappedValue
        for l in lists {
            let entries = try await json(
                Lenient<KavitaResponses.ListEntry>.self, "api/ReadingList/items",
                ["readingListId": String(l.id)]
            ).wrappedValue.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            result.append(
                TitleCollection(
                    identifier: CollectionID(source: identifier, id: Self.listPrefix + String(l.id)),
                    name: l.title ?? String(l.id), collectionKind: .readingList,
                    entries: entries.map {
                        .title(TitleID(source: identifier, id: String($0.chapterId)))
                    },
                    ordered: true, isPrivate: l.promoted != true,
                    editable: l.ownerUserName == nil || l.ownerUserName == me))
        }
        return result
    }

    /// A collection if series belong in it, otherwise a reading list. Kavita creates
    /// a collection via "fill with id 0" and does not name the new id
    /// — it is looked up afterwards by title in the own list.
    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        if collectionKind.takesSeries {
            _ = try await fetcher.data(
                try fetcher.request(
                    "api/Collection/update-for-series", method: "POST",
                    json: KavitaResponses.FillCollection(
                        collectionTagId: 0, collectionTagTitle: name, seriesIds: []),
                    headerLines: headerLines()))
            let own = try await json(
                [KavitaResponses.TitleCollection].self, "api/Collection", ["ownedOnly": "true"])
            guard let new = own.last(where: { $0.title == name }) else {
                throw SourceError.unreadable(identifier, "New collection not found")
            }
            return TitleCollection(
                identifier: CollectionID(source: identifier, id: Self.collectionPrefix + String(new.id)),
                name: name,
                collectionKind: .collection, entries: [], isPrivate: true, editable: true)
        }
        let new = try await fetcher.json(
            KavitaResponses.ReadingList.self,
            try fetcher.request(
                "api/ReadingList/create", method: "POST",
                json: KavitaResponses.CreateReadingList(title: name),
                headerLines: headerLines()),
            decoder: KavitaResponses.decoder)
        return TitleCollection(
            identifier: CollectionID(source: identifier, id: Self.listPrefix + String(new.id)),
            name: new.title ?? name, collectionKind: .readingList, entries: [], ordered: true,
            isPrivate: true,
            editable: true)
    }

    /// Series into a collection, title into a reading list — and out again. Kavita
    /// wants the whole collection as the body when taking out of a collection
    /// (`UpdateSeriesForTagDto.tag`); it is fetched fresh for that and passed
    /// through unchanged.
    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        switch target {
        case .series(let series):
            guard collection.id.hasPrefix(Self.collectionPrefix),
                let tag = Int(collection.id.dropFirst(Self.collectionPrefix.count)),
                let seriesId = Int(series.id)
            else { throw SourceError.notPossible(identifier, "Series belong in a collection") }
            let (raw, _) = try await fetcher.data(
                fetcher.request(
                    "api/Collection", query: [URLQueryItem(name: "ownedOnly", value: "true")],
                    headerLines: headerLines()))
            guard let list = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]],
                let entry = list.first(where: { ($0["id"] as? Int) == tag })
            else { throw SourceError.denied(identifier) }
            if into {
                _ = try await fetcher.data(
                    try fetcher.request(
                        "api/Collection/update-for-series", method: "POST",
                        json: KavitaResponses.FillCollection(
                            collectionTagId: tag, collectionTagTitle: entry["title"] as? String ?? "",
                            seriesIds: [seriesId]),
                        headerLines: headerLines()))
            } else {
                let body = try JSONSerialization.data(
                    withJSONObject: ["tag": entry, "seriesIdsToRemove": [seriesId]] as [String: Any])
                _ = try await fetcher.data(
                    fetcher.request(
                        "api/Collection/update-series", method: "POST", body: body,
                        headerLines: headerLines()))
            }
        case .title(let title):
            guard collection.id.hasPrefix(Self.listPrefix),
                let list = Int(collection.id.dropFirst(Self.listPrefix.count)),
                let chapterId = Int(title.id)
            else { throw SourceError.notPossible(identifier, "Titles belong in a reading list") }
            if into {
                let reference = try await reference(title)
                _ = try await fetcher.data(
                    try fetcher.request(
                        "api/ReadingList/update-by-chapter", method: "POST",
                        json: KavitaResponses.ReadingListChapter(
                            chapterId: chapterId, seriesId: reference.seriesId, readingListId: list),
                        headerLines: headerLines()),
                    title: title)
            } else {
                let entries = try await json(
                    Lenient<KavitaResponses.ListEntry>.self, "api/ReadingList/items",
                    ["readingListId": String(list)]
                ).wrappedValue
                for e in entries where e.chapterId == chapterId {
                    let spot = e.order ?? 0
                    _ = try await fetcher.data(
                        try fetcher.request(
                            "api/ReadingList/delete-item", method: "POST",
                            json: KavitaResponses.DeleteReadingListItem(
                                readingListId: list, readingListItemId: e.id, fromPosition: spot,
                                toPosition: spot),
                            headerLines: headerLines()),
                        title: title)
                }
            }
        }
    }

    /// Collections and reading lists count separately at Kavita — the same number can be both.
    /// The prefix keeps them apart in an id.
    static let collectionPrefix = "c"
    static let listPrefix = "l"

    /// The series of a collection, over all pages of `series-by-collection`.
    private func seriesOfCollection(_ id: Int) async throws -> [Int] {
        var ids: [Int] = []
        var page = 1
        while true {
            let (data, response) = try await fetcher.data(
                fetcher.request(
                    "api/Series/series-by-collection",
                    query: [URLQueryItem(name: "collectionId", value: String(id))] + pagingQuery(page),
                    headerLines: headerLines()))
            let list = try decodeLenient(Lenient<KavitaResponses.Series>.self, data, "series-by-collection")
                .wrappedValue
            ids += list.map(\.id)
            if isLast(page, list.count, response) { return ids }
            page += 1
        }
    }

    private func pagingQuery(_ page: Int, size: Int = KavitaSource.pageSize) -> [URLQueryItem] {
        [
            URLQueryItem(name: "PageNumber", value: String(page)),
            URLQueryItem(name: "PageSize", value: String(size)),
        ]
    }

    /// The last page: according to the `Pagination` header, without it by a short page.
    private func isLast(_ page: Int, _ count: Int, _ response: HTTPURLResponse) -> Bool {
        count == 0 || (sheet(response).map { page >= $0.totalPages } ?? (count < Self.pageSize))
    }

    // MARK: - Extract

    /// What ``mapSeries(_:volumes:)`` makes of a series — and what a later
    /// extract takes over from it as long as the marker stays the same.
    struct SeriesPart {
        var series: Series?
        var title: [Title] = []
        var states: [TitleID: ReadingState] = [:]
        var references: [Int: KavitaMapping.ChapterReference] = [:]
    }

    func mapSeries(
        _ s: KavitaResponses.Series, volumes: [KavitaResponses.Volume],
        readingDirection: ReadingDirection? = nil
    ) -> SeriesPart {
        var part = SeriesPart()
        var allChapters: [KavitaResponses.Chapter] = []
        for volume in volumes.sorted(by: { ($0.minNumber ?? 0) < ($1.minNumber ?? 0) }) {
            for k in volume.chapters.sorted(by: { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }) {
                allChapters.append(k)
                let t = KavitaMapping.title(
                    k, volume: volume, series: s, seriesId: s.id, source: identifier,
                    baseURL: fetcher.baseURL,
                    readingDirection: readingDirection)
                part.title.append(t)
                let epub = KavitaMapping.epub(k, series: s)
                let pages = k.pages ?? 0
                part.references[k.id] = KavitaMapping.ChapterReference(
                    volumeId: volume.id, seriesId: s.id, libraryId: s.libraryId ?? 0, pages: pages, epub: epub
                )
                if let state = KavitaMapping.readingState(
                    page: k.pagesRead, pages: pages, epub: epub, time: k.lastReadingProgressUtc)
                {
                    part.states[t.identifier] = state
                }
            }
        }
        if !allChapters.isEmpty {
            part.series = KavitaMapping.series(
                s, chapter: allChapters, source: identifier, baseURL: fetcher.baseURL,
                readingDirection: readingDirection)
        }
        return part
    }

    /// The volumes of a series — `nil` if the series vanished between list and fetch
    /// (a scan is running); then it is missing this time instead of tipping over the extract.
    private func volumes(_ seriesId: Int) async throws -> [KavitaResponses.Volume]? {
        do {
            return try await json(
                Lenient<KavitaResponses.Volume>.self, "api/Series/volumes", ["seriesId": String(seriesId)]
            ).wrappedValue
        } catch SourceError.notFound {
            return nil
        }
    }

    /// Pages through `all-v2` to the last page named by the `Pagination` header.
    private func allSeries() async throws -> [KavitaResponses.Series] {
        var all: [KavitaResponses.Series] = []
        var page = 1
        while true {
            let (data, response) = try await seriesPage(page, size: Self.pageSize)
            let list = try decodeLenient(Lenient<KavitaResponses.Series>.self, data, "all-v2").wrappedValue
            all += list
            let last = sheet(response).map { page >= $0.totalPages } ?? (list.count < Self.pageSize)
            if list.isEmpty || last { break }
            page += 1
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private func seriesPage(_ page: Int, size: Int) async throws -> (Data, HTTPURLResponse) {
        try await fetcher.data(
            try fetcher.request(
                "api/Series/all-v2", method: "POST", json: KavitaResponses.SeriesFilter(),
                query: [
                    URLQueryItem(name: "PageNumber", value: String(page)),
                    URLQueryItem(name: "PageSize", value: String(size)),
                ],
                headerLines: headerLines()))
    }

    private func sheet(_ response: HTTPURLResponse) -> KavitaResponses.Sheet? {
        guard let header = response.value(forHTTPHeaderField: "Pagination") else { return nil }
        return try? JSONDecoder().decode(KavitaResponses.Sheet.self, from: Data(header.utf8))
    }

    // MARK: - Markers

    /// What changes on a series when something changes on its chapters.
    static func marker(_ s: KavitaResponses.Series) -> String {
        [
            String(s.pages ?? -1), String(s.pagesRead ?? -1),
            String(s.lastChapterAddedUtc?.timeIntervalSince1970 ?? 0),
            String(s.latestReadDate?.timeIntervalSince1970 ?? 0),
        ].joined(separator: "|")
    }

    struct SeriesMarker: Codable, Sendable {
        let marker: String
        let references: [Int: KavitaMapping.ChapterReference]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case marker = "marke"
            case references = "bezuege"
        }
    }

    /// The markers of the last extract, with its timestamp: only a previous extract
    /// with exactly this state may contribute series — an older one does not know the states
    /// written since.
    struct MarkerNote: Codable, Sendable {
        let state: Date
        let seriesList: [Int: SeriesMarker]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case state = "stand"
            case seriesList = "serien"
        }
    }

    private struct Reusable {
        var markers: [Int: SeriesMarker] = [:]
        var share: [String: SeriesPart] = [:]
    }

    private func reusable(_ previously: LibraryExtract?) -> Reusable {
        guard let previously, !previously.isSupplement, !previously.title.isEmpty, let note = markerNote(),
            abs(previously.state.timeIntervalSince(note.state)) < 1
        else { return Reusable() }
        var share: [String: SeriesPart] = [:]
        let seriesList = Dictionary(previously.seriesList.map { ($0.identifier.id, $0) }) { a, _ in a }
        for t in previously.title {
            guard let id = t.series?.identifier.id else { continue }
            share[id, default: SeriesPart(series: seriesList[id])].title.append(t)
            if let state = previously.readingStates[t.identifier] { share[id]?.states[t.identifier] = state }
        }
        references.withLock { saved in
            for marker in note.seriesList.values { saved.merge(marker.references) { already, _ in already } }
        }
        return Reusable(markers: note.seriesList, share: share)
    }

    private func markerNote() -> MarkerNote? {
        if let read = markerNoteRead.withLock({ $0 }) { return read }
        let note = savedStore.flatMap { try? Data(contentsOf: $0) }.flatMap {
            try? JSONDecoder().decode(MarkerNote.self, from: $0)
        }
        markerNoteRead.withLock { $0 = .some(note) }
        return note
    }

    private func save(_ note: MarkerNote) {
        markerNoteRead.withLock { $0 = .some(note) }
        guard let savedStore, let data = try? JSONEncoder().encode(note) else { return }
        try? FileManager.default.createDirectory(
            at: savedStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: savedStore, options: .atomic)
    }

    // MARK: - Helpers

    /// Volume, series, library and page count of a chapter — from the extract, otherwise
    /// via three fetches without side effects (`/api/Reader/chapter-info` would have everything in
    /// one, but unpacks the archive).
    private func reference(
        _ identifier: TitleID, chapter: KavitaResponses.Chapter? = nil
    ) async throws -> KavitaMapping.ChapterReference {
        guard let id = Int(identifier.id) else { throw SourceError.notFound(identifier) }
        if let saved = references.withLock({ $0[id] }) { return saved }
        let k: KavitaResponses.Chapter
        if let chapter {
            k = chapter
        } else {
            k = try await json(
                KavitaResponses.Chapter.self, "api/Series/chapter", ["chapterId": identifier.id],
                title: identifier)
        }
        guard let volumeId = k.volumeId else {
            throw SourceError.unreadable(self.identifier, "Chapter without volume")
        }
        let volume = try await json(
            KavitaResponses.VolumeHead.self, "api/Volume", ["volumeId": String(volumeId)], title: identifier)
        let series = try await json(
            KavitaResponses.Series.self, "api/Series/\(volume.seriesId)", title: identifier)
        let reference = KavitaMapping.ChapterReference(
            volumeId: volumeId, seriesId: volume.seriesId, libraryId: series.libraryId ?? 0,
            pages: k.pages ?? 0,
            epub: KavitaMapping.epub(k, series: series))
        references.withLock { $0[id] = reference }
        return reference
    }

    private func report(
        _ page: Int, _ reference: KavitaMapping.ChapterReference, _ identifier: TitleID
    ) async throws {
        guard let id = Int(identifier.id) else { throw SourceError.notFound(identifier) }
        _ = try await fetcher.data(
            try fetcher.request(
                "api/Reader/progress", method: "POST",
                json: KavitaResponses.Progress(
                    volumeId: reference.volumeId, chapterId: id, pageNum: page, seriesId: reference.seriesId,
                    libraryId: reference.libraryId, bookScrollId: nil, lastModifiedUtc: nil),
                headerLines: headerLines()),
            title: identifier)
    }

    private func decodeLenient<Answer: Decodable>(
        _ type: Answer.Type, _ data: Data, _ label: String
    ) throws
        -> Answer
    {
        do {
            return try KavitaResponses.decoder.decode(type, from: data)
        } catch {
            throw SourceError.unreadable(identifier, "\(label): \(Swift.type(of: error))")
        }
    }

    private func json<Answer: Decodable>(
        _ type: Answer.Type, _ path: String, _ query: [String: String] = [:], title: TitleID? = nil
    ) async throws -> Answer {
        try await fetcher.json(
            type,
            fetcher.request(
                path,
                query: query.sorted { $0.key < $1.key }.map {
                    URLQueryItem(name: $0.key, value: $0.value)
                },
                headerLines: headerLines()),
            decoder: KavitaResponses.decoder, title: title)
    }
}
