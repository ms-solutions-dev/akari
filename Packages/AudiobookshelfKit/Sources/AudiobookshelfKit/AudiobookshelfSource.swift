import Bedrock
import Foundation
import SourcesKit

/// Audiobookshelf as a source — in stage 1 the library: title, duration, narrator,
/// series, cover, reading state. The player comes later. Podcast libraries are
/// included too: every episode is a title (`item:episode`), the podcast is the series.
///
/// Built against a real Audiobookshelf server. The reading state of all titles comes with
/// `GET /api/me` (`mediaProgress`) — one fetch for all nine audiobooks, and for 900 it
/// would be the same.
public final class AudiobookshelfSource: Source, Sendable {
    public let account: AudiobookshelfAccount
    let fetcher: ServerFetch

    static let pageSize = 500

    public init(account: AudiobookshelfAccount, transport: any Transport = URLSession.forSource()) {
        self.account = account
        self.fetcher = ServerFetch(baseURL: account.server, source: account.identifier, transport: transport)
    }

    public var identifier: SourceID { account.identifier }
    public var capabilities: Capabilities { account.capabilities }

    public func headerLines() -> [String: String] {
        ["Authorization": "Bearer " + account.token]
    }

    // MARK: - Sign in

    public static func signIn(
        server: URL, username: String, password: String,
        transport: any Transport = URLSession.forSource()
    ) async throws -> AudiobookshelfAccount {
        let identifier = SourceID(
            provider: .audiobookshelf, server: server.host() ?? server.absoluteString)
        let fetcher = ServerFetch(baseURL: server, source: identifier, transport: transport)
        let signInResult = try await fetcher.json(
            AudiobookshelfResponses.SignInResponse.self,
            try fetcher.request(
                "login", method: "POST",
                json: AudiobookshelfResponses.SignInBody(username: username, password: password)))
        guard let token = signInResult.user.token, !token.isEmpty else {
            throw SourceError.unreadable(identifier, "sign-in without token")
        }
        Diagnostics.step(
            "Audiobookshelf: signed in as \(signInResult.user.username)", since: nil, area: "Source")
        return AudiobookshelfAccount(
            server: server, userId: signInResult.user.id, username: signInResult.user.username, token: token,
            mayFetch: signInResult.user.permissions.download)
    }

    // MARK: - Source

    /// `GET /api/me` with the token — the same fetch the extract starts with.
    public func verify() async throws {
        _ = try await fetcher.json(
            AudiobookshelfResponses.User.self, fetcher.request("api/me", headerLines: headerLines()))
    }

    public func library() async throws -> LibraryExtract {
        let start = Date()
        let libraryList = try await fetcher.json(
            AudiobookshelfResponses.Libraries.self,
            fetcher.request("api/libraries", headerLines: headerLines()))
        var entries: [AudiobookshelfResponses.Item] = []
        var podcasts: [AudiobookshelfResponses.Item] = []
        for library in libraryList.libraries
        where library.mediaType == "book" || library.mediaType == "podcast" {
            var page = 0
            while true {
                let list = try await fetcher.json(
                    AudiobookshelfResponses.ItemList.self,
                    fetcher.request(
                        "api/libraries/\(library.id)/items",
                        query: [
                            URLQueryItem(name: "limit", value: String(Self.pageSize)),
                            URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "sort", value: "media.metadata.title"),
                        ], headerLines: headerLines()))
                if library.mediaType == "podcast" {
                    podcasts += list.results
                } else {
                    entries += list.results
                }
                if list.results.isEmpty || list.page != page
                    || (page + 1) * max(list.limit, 1) >= list.total
                {
                    break
                }
                page += 1
            }
        }
        // The episodes of a podcast are only known to the detail — one fetch per podcast, not per
        // episode; with two podcasts that is two, with twenty it is twenty.
        var episodeList: [Title] = []
        for podcast in podcasts {
            // A podcast whose detail does not arrive is missing on its own — before, the whole
            // extract with all audiobooks failed because of it.
            do {
                let detail = try await fetcher.json(
                    AudiobookshelfResponses.Item.self,
                    fetcher.request(
                        "api/items/\(podcast.id)", query: [URLQueryItem(name: "expanded", value: "1")],
                        headerLines: headerLines()))
                episodeList += AudiobookshelfMapping.episodeList(
                    detail, source: identifier, baseURL: fetcher.baseURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Diagnostics.network.error(
                    "Audiobookshelf: podcast \(podcast.id, privacy: .public) skipped: \(String(describing: error), privacy: .public)"
                )
            }
        }
        let me = try await fetcher.json(
            AudiobookshelfResponses.User.self, fetcher.request("api/me", headerLines: headerLines()))
        let title =
            entries.map { AudiobookshelfMapping.title($0, source: identifier, baseURL: fetcher.baseURL) }
            + episodeList
        let known = Set(title.map(\.identifier.id))
        var readingStates: [TitleID: ReadingState] = [:]
        for f in me.mediaProgress {
            // The state of an episode hangs on `episodeId`; the id is `item:episode`.
            let id =
                f.episodeId.map { AudiobookshelfMapping.episodeKey(f.libraryItemId, $0) }
                ?? f.libraryItemId
            guard known.contains(id) else { continue }
            readingStates[TitleID(source: identifier, id: id)] = AudiobookshelfMapping.readingState(f)
        }
        let seriesList = AudiobookshelfMapping.seriesList(from: title)
        Diagnostics.step(
            "Audiobookshelf: \(title.count) titles (\(episodeList.count) episodes), \(seriesList.count) series, \(readingStates.count) reading states",
            since: start,
            area: "Source")
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: title, readingStates: readingStates,
            state: Date())
    }

    /// How many episodes per library the episode watch looks at — enough for a day with
    /// many podcasts, and whoever was away longer gets the notification bundled anyway.
    static let recentLimit = 50

    /// One fetch per podcast library (`recent-episodes`), not per podcast: the list
    /// carries the podcast title on every episode. It is sorted by release, not
    /// by arrival — an episode that Podsync delivers late today with an old date falls
    /// off the end, and that is intended: delivered archive is not a new episode.
    public func latestEpisodes() async throws -> [NewAddition] {
        let libraryList = try await fetcher.json(
            AudiobookshelfResponses.Libraries.self,
            fetcher.request("api/libraries", headerLines: headerLines()))
        var episodeList: [NewAddition] = []
        for library in libraryList.libraries where library.mediaType == "podcast" {
            let list = try await fetcher.json(
                AudiobookshelfResponses.LatestEpisodes.self,
                fetcher.request(
                    "api/libraries/\(library.id)/recent-episodes",
                    query: [URLQueryItem(name: "limit", value: String(Self.recentLimit))],
                    headerLines: headerLines()))
            episodeList += list.episodes.compactMap { f in
                guard let arrived = f.addedAt ?? f.publishedAt else { return nil }
                return NewAddition(
                    identifier: TitleID(
                        source: identifier, id: AudiobookshelfMapping.episodeKey(f.libraryItemId, f.id)),
                    podcast: SeriesID(source: identifier, id: f.libraryItemId),
                    podcastName: f.podcast?.metadata.title ?? "",
                    name: f.title, arrived: Date(timeIntervalSince1970: arrived / 1000))
            }
        }
        return episodeList
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        if let share = AudiobookshelfMapping.episodeParts(identifier.id) {
            let podcast = try await entry(share.item, title: identifier)
            guard
                let episodeItem = AudiobookshelfMapping.episodeList(
                    podcast, source: self.identifier, baseURL: fetcher.baseURL
                )
                .first(where: { $0.identifier == identifier })
            else { throw SourceError.notFound(identifier) }
            return episodeItem
        }
        return AudiobookshelfMapping.title(
            try await entry(identifier.id, title: identifier), source: self.identifier,
            baseURL: fetcher.baseURL)
    }

    private func entry(_ id: String, title: TitleID) async throws -> AudiobookshelfResponses.Item {
        try await fetcher.json(
            AudiobookshelfResponses.Item.self,
            fetcher.request(
                "api/items/\(id)", query: [URLQueryItem(name: "expanded", value: "1")],
                headerLines: headerLines()),
            title: title)
    }

    /// The path of the reading state: audiobook `progress/{item}`, episode `progress/{item}/{episode}`.
    private func statePath(_ identifier: TitleID) -> String {
        if let share = AudiobookshelfMapping.episodeParts(identifier.id) {
            return "api/me/progress/\(share.item)/\(share.episodeItem)"
        }
        return "api/me/progress/\(identifier.id)"
    }

    /// Tracks and chapters are only known to the detail (`expanded=1`); the tracks are the
    /// files themselves (`/api/items/{id}/file/{ino}`, with the token in the header) — no
    /// `/play`, no session, no repacking: the player queues MP3s.
    public func content(_ title: Title) -> ContentSource {
        let identifier = title.identifier
        return .audioStream { [self] in try await audioManifest(identifier) }
    }

    public func audioManifest(_ identifier: TitleID) async throws -> AudioManifest {
        if let share = AudiobookshelfMapping.episodeParts(identifier.id) {
            let podcast = try await entry(share.item, title: identifier)
            guard let episodeItem = podcast.media.episodes?.first(where: { $0.id == share.episodeItem }),
                let volume = AudiobookshelfMapping.audioManifest(episodeItem, baseURL: fetcher.baseURL)
            else { throw SourceError.notFound(identifier) }
            return volume
        }
        let entry = try await entry(identifier.id, title: identifier)
        let tracks = (entry.media.tracks ?? []).sorted { $0.index < $1.index }.compactMap {
            track -> AudioTrack? in
            guard let address = URL(string: track.contentUrl, relativeTo: fetcher.baseURL)?.absoluteURL else {
                return nil
            }
            return AudioTrack(
                address: address, startTime: track.startOffset, duration: track.duration,
                size: track.metadata?.size,
                fileExtension: track.metadata?.ext.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 })
        }
        return AudioManifest(
            tracks: tracks, chapter: AudiobookshelfMapping.chapter(entry.media.chapters),
            duration: entry.media.duration)
    }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        do {
            let f = try await fetcher.json(
                AudiobookshelfResponses.Progress.self,
                fetcher.request(statePath(identifier), headerLines: headerLines()), title: identifier)
            return AudiobookshelfMapping.readingState(f)
        } catch SourceError.notFound {
            // No entry means: never started — not an error.
            return nil
        }
    }

    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        guard case .second(let second, let duration) = state.position else {
            throw SourceError.notPossible(self.identifier, "Audiobookshelf only knows seconds")
        }
        _ = try await fetcher.data(
            try fetcher.request(
                statePath(identifier), method: "PATCH",
                json: AudiobookshelfResponses.ProgressReport(
                    currentTime: second, duration: duration, progress: state.fraction,
                    isFinished: state.completed),
                headerLines: headerLines()),
            title: identifier)
    }

    /// Deleting does not go through ``statePath(_:)``: reading and writing take item and
    /// episode, but `DELETE /api/me/progress/{id}` takes the entry's own id —
    /// with the item id the server answers 404, and for episodes the route does not
    /// exist at all. So fetch the entry first; if it is missing, there is nothing to forget.
    public func forget(progressFor identifier: TitleID) async throws {
        let entry: AudiobookshelfResponses.Progress
        do {
            entry = try await fetcher.json(
                AudiobookshelfResponses.Progress.self,
                fetcher.request(statePath(identifier), headerLines: headerLines()), title: identifier)
        } catch SourceError.notFound {
            return
        }
        _ = try await fetcher.data(
            fetcher.request("api/me/progress/\(entry.id)", method: "DELETE", headerLines: headerLines()),
            title: identifier)
    }

    /// A playlist "Saved" on the server comes in stage 2; until then "Saved" lives
    /// in the app for audiobooks.
    // MARK: - Collections

    /// Collections (library-wide) and playlists (per user) — both take
    /// titles. Playlists that belong to someone else are not delivered by the server.
    public func collections() async throws -> [TitleCollection] {
        let collections = try await fetcher.json(
            AudiobookshelfResponses.CollectionList.self,
            fetcher.request("api/collections", headerLines: headerLines())
        )
        .collections.map { c in
            TitleCollection(
                identifier: CollectionID(source: identifier, id: c.id), name: c.name,
                collectionKind: .collection,
                entries: (c.books ?? []).map { .title(TitleID(source: identifier, id: $0.id)) },
                isPrivate: false, editable: true)
        }
        let lists = try await fetcher.json(
            AudiobookshelfResponses.PlaylistList.self,
            fetcher.request("api/playlists", headerLines: headerLines())
        )
        .playlists.map { l in
            TitleCollection(
                identifier: CollectionID(source: identifier, id: l.id), name: l.name,
                collectionKind: .readingList,
                entries: (l.items ?? []).map {
                    .title(TitleID(source: identifier, id: $0.libraryItemId))
                },
                ordered: true, isPrivate: true, editable: l.userId == nil || l.userId == account.userId)
        }
        return collections + lists
    }

    /// A playlist (private, ordered) or a collection — both need the
    /// library; the first book library of the server is used.
    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        let libraryList = try await fetcher.json(
            AudiobookshelfResponses.Libraries.self,
            fetcher.request("api/libraries", headerLines: headerLines()))
        guard let library = libraryList.libraries.first(where: { $0.mediaType == "book" }) else {
            throw SourceError.notPossible(identifier, "not a book library")
        }
        if collectionKind == .collection {
            let new = try await fetcher.json(
                AudiobookshelfResponses.TitleCollection.self,
                try fetcher.request(
                    "api/collections", method: "POST",
                    json: AudiobookshelfResponses.CreateCollection(libraryId: library.id, name: name),
                    headerLines: headerLines()))
            return TitleCollection(
                identifier: CollectionID(source: identifier, id: new.id), name: new.name,
                collectionKind: .collection,
                entries: [], isPrivate: false, editable: true)
        }
        let new = try await fetcher.json(
            AudiobookshelfResponses.Playlist.self,
            try fetcher.request(
                "api/playlists", method: "POST",
                json: AudiobookshelfResponses.CreatePlaylist(
                    libraryId: library.id, name: name, items: []),
                headerLines: headerLines()))
        return TitleCollection(
            identifier: CollectionID(source: identifier, id: new.id), name: new.name,
            collectionKind: .readingList,
            entries: [], ordered: true, isPrivate: true, editable: true)
    }

    /// One entry more or less — Audiobookshelf has one way for each;
    /// which one, the id says: collections begin with `col_`, playlists with
    /// `pl_`. The server deletes an empty playlist itself.
    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        guard case .title(let title) = target else {
            throw SourceError.notPossible(identifier, "Audiobookshelf collections take titles, not series")
        }
        let playlist = collection.id.hasPrefix("pl_")
        if into {
            let request =
                playlist
                ? try fetcher.request(
                    "api/playlists/\(collection.id)/item", method: "POST",
                    json: AudiobookshelfResponses.ItemReference(libraryItemId: title.id),
                    headerLines: headerLines())
                : try fetcher.request(
                    "api/collections/\(collection.id)/book", method: "POST",
                    json: AudiobookshelfResponses.BookReference(id: title.id), headerLines: headerLines())
            _ = try await fetcher.data(request, title: title)
        } else {
            let path =
                playlist
                ? "api/playlists/\(collection.id)/item/\(title.id)"
                : "api/collections/\(collection.id)/book/\(title.id)"
            _ = try await fetcher.data(
                fetcher.request(path, method: "DELETE", headerLines: headerLines()), title: title)
        }
    }

    public func savedList() async throws -> Set<TitleID> {
        throw SourceError.notPossible(identifier, "Audiobookshelf: saved list comes in tier 2")
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        throw SourceError.notPossible(self.identifier, "Audiobookshelf: saved list comes in tier 2")
    }
}
