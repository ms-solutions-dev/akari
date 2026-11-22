import Foundation

/// The one slot: what every server must be able to do for the app to know it.
///
/// **Why a protocol and not three special cases:** the UI never asks "is there Grimmory?" but
/// the library — which is the sum of what the signed-in sources report. Segment, counter,
/// keep button, genre row: everything follows from ``capabilities`` and ``library()``,
/// without a view knowing the provider.
///
/// **What it costs:** quirks of one source do not come through. Whoever wants Komga's read
/// lists first turns them into a concept here — or leaves it.
///
/// Thirteen verbs and an identity, none of them "load": the source *verifies* its access,
/// *reads* its shelf, a title and a state, *names* the content, *writes* a state back,
/// *forgets* it on request, *reads* its saved list and *saves* a title, *reads*, *creates*
/// and *arranges* collections. Everything that fails throws ``SourceError`` — nothing
/// else.
public protocol Source: Sendable {
    var identifier: SourceID { get }
    var capabilities: Capabilities { get }

    /// A light request that proves the server is there and the account still
    /// valid — the status row in the account sheet ("signed in", "expired", "not
    /// reachable") is the answer to it. No extract, no shelf: one request for the
    /// user's own record, nothing more.
    func verify() async throws

    /// The whole shelf in one go, with the reading states the server
    /// sends along anyway.
    func library() async throws -> LibraryExtract

    /// Like ``library()``, but reports in between how many titles have arrived and how
    /// many there will be in total — for "Importing · 12,000 of 35,551". Default: no
    /// report; only sources that load page by page have anything to report.
    func library(
        progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws
        -> LibraryExtract

    /// Like ``library(progress:)``, with the last extract of this source: a source that can look
    /// up what changed fetches only that (Grimmory via `/books/ids`). Default: the whole
    /// extract.
    func library(
        previously: LibraryExtract?, progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws -> LibraryExtract

    /// A title fresh from the server — for the detail that wants more than the extract
    /// carries, and for a title missing from the extract.
    func title(_ identifier: TitleID) async throws -> Title

    /// How the title gets to the reader. No network: the addresses are built from the
    /// identifier and extent, and nothing is fetched until the reader turns a page. The whole
    /// title rather than the identifier, because the page stream must know its page count.
    func content(_ title: Title) -> ContentSource

    /// The whole file to pass on — "Share" in the context menu, via AirDrop to the
    /// computer or tablet. `nil` where there is no single file (an audiobook made of
    /// tracks). Default: the file from ``content(_:)``.
    func file(_ title: Title) -> URL?

    /// What every request for images and content of this source must carry —
    /// the key or the token. Covers and pages do not run through the kit but
    /// through the image loader, which takes the headers from here.
    func headerLines() -> [String: String]

    /// The state on the server, now — before opening a reader. `nil` means:
    /// never started.
    func progress(_ identifier: TitleID) async throws -> ReadingState?

    /// Writes a state back. The server is the truth; whoever writes here has
    /// already settled the conflict with the other state.
    func write(_ state: ReadingState, for identifier: TitleID) async throws

    /// Forgets the state on the server — "Unread" in the reading status menu and
    /// "Reset progress". Not a state with fraction zero: Komga and
    /// Audiobookshelf delete the entry, and a title without an entry is "never started"
    /// for all three, a title at page 0 is not.
    func forget(progressFor identifier: TitleID) async throws

    /// What the user has saved on the server — Grimmory's "Favorites" shelf.
    /// Only where ``Capabilities/savedList`` is declared; otherwise
    /// ``SourceError/notPossible``, and the library does not even ask.
    /// Komga has no per-user saved list — "Saved" lives only in the app there,
    /// and the app says so.
    func savedList() async throws -> Set<TitleID>

    /// Saves a title on the server or takes it out again.
    func save(_ identifier: TitleID, saved: Bool) async throws

    /// The server's collections, with their entries — only where
    /// ``Capabilities/collections`` is declared; otherwise ``SourceError/notPossible``.
    /// The shelf that mirrors the saved list (Grimmory "Favorites") is not one of
    /// them — it would otherwise appear twice.
    func collections() async throws -> [TitleCollection]

    /// Creates a collection — in the shape the server knows for this target.
    func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection

    /// Puts a target into a collection or takes it out.
    func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws

    /// The detail for an author from ``LibraryExtract/authors`` — `nil` where the source
    /// has none. Default: nothing.
    func author(_ reference: AuthorReference) async throws -> SourceAuthor?

    /// The latest podcast episodes of all libraries — a light request for the
    /// background episode watch, not the whole extract. Default: none; only
    /// Audiobookshelf has podcasts.
    func latestEpisodes() async throws -> [NewAddition]

    /// Whether a full sync is due — a source that only fetches changes (``library(previously:progress:)``)
    /// needs a complete one now and then so that changed metadata arrives. It runs in the
    /// background (``LibraryService``), not at launch. Default: never.
    var fullSyncDue: Bool { get }

    /// The server's libraries — empty where there is no choice. Default: none.
    func subLibraries() async throws -> [SubLibrary]

    /// How many titles the server holds, without loading the catalog — for the question
    /// about the library choice. Default: unknown.
    func titleCount() async throws -> Int?
}

extension Source {
    public func library(
        progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws
        -> LibraryExtract
    { try await library() }

    public func library(
        previously: LibraryExtract?, progress: @escaping @Sendable (_ loaded: Int, _ total: Int) -> Void
    ) async throws -> LibraryExtract {
        try await library(progress: progress)
    }

    public func author(_ reference: AuthorReference) async throws -> SourceAuthor? { nil }

    public func latestEpisodes() async throws -> [NewAddition] { [] }

    public var fullSyncDue: Bool { false }

    public func subLibraries() async throws -> [SubLibrary] { [] }

    public func titleCount() async throws -> Int? { nil }

    public func file(_ title: Title) -> URL? {
        if case .file(let address, _, _) = content(title) { return address }
        return nil
    }
}
