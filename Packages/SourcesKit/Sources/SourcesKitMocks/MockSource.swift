import Foundation
import SourcesKit
import Synchronization

/// A source without a server: delivers what it is given and remembers what is
/// written to it.
///
/// With it everything above the slot — the library, reading progress, the screens — is tested
/// against a shelf that answers in milliseconds and can be made unreachable
/// on command. The responses are shaped after the real servers
/// (``MockShelf``), only the names are invented.
public final class MockSource: Source, Sendable {
    public let identifier: SourceID
    public let capabilities: Capabilities
    public let extract: LibraryExtract

    private let phase: Mutex<Phase>

    private struct Phase {
        var network: NetworkStatus
        var disruption: SourceError?
        var readingStates: [TitleID: ReadingState]
        var written: [(TitleID, ReadingState)] = []
        var saved: Set<TitleID> = []
        var collections: [TitleCollection] = []
        var newAdditions: [NewAddition]
        var fetches = 0
    }

    public init(
        identifier: SourceID, capabilities: Capabilities, extract: LibraryExtract,
        network: NetworkStatus = .reachable
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.extract = extract
        let episodes = extract.title.compactMap { t -> NewAddition? in
            guard t.kind == .podcast, let series = t.series else { return nil }
            return NewAddition(
                identifier: t.identifier, podcast: series.identifier, podcastName: series.name, name: t.name,
                arrived: t.added ?? .distantPast)
        }
        self.phase = Mutex(
            Phase(network: network, readingStates: extract.readingStates, newAdditions: episodes))
    }

    /// What ``latestEpisodes()`` delivers — at first the extract's podcast episodes;
    /// a test adds new ones as if they had just arrived.
    public var newAdditions: [NewAddition] {
        get { phase.withLock { $0.newAdditions } }
        set { phase.withLock { $0.newAdditions = newValue } }
    }

    /// Switches the network state — `unreachable` makes every request fail.
    public func set(network: NetworkStatus) {
        phase.withLock { $0.network = network }
    }

    /// Makes every request fail with this error — a 401 (``SourceError/signedOut(_:)``),
    /// a 502 (``SourceError/serverDisruption(_:status:)``) — until `nil` lifts it. This is how
    /// the disruption probe replays what Traefik without a backend and a revoked
    /// key answer to the account, without a server being shut down for it.
    public func set(disruption: SourceError?) {
        phase.withLock { $0.disruption = disruption }
    }

    /// What arrived via ``write(_:for:)``, in the order of arrival.
    public var written: [(TitleID, ReadingState)] {
        phase.withLock { $0.written }
    }

    /// How often ``library()`` was asked — for tests that separate cache
    /// from network.
    public var fetches: Int {
        phase.withLock { $0.fetches }
    }

    /// What is saved on the "server" — settable, so that a test replays the sync
    /// with the app's saved list.
    public var saved: Set<TitleID> {
        get { phase.withLock { $0.saved } }
        set { phase.withLock { $0.saved = newValue } }
    }

    /// The collections on the "server" — settable for tests.
    public var collectionList: [TitleCollection] {
        get { phase.withLock { $0.collections } }
        set { phase.withLock { $0.collections = newValue } }
    }

    private func checkNetwork() throws {
        let (network, disruption) = phase.withLock { ($0.network, $0.disruption) }
        if let disruption { throw disruption }
        guard network.usable else { throw SourceError.unreachable(identifier) }
    }

    public func verify() async throws {
        try checkNetwork()
    }

    public func latestEpisodes() async throws -> [NewAddition] {
        try checkNetwork()
        return newAdditions
    }

    public func library() async throws -> LibraryExtract {
        try checkNetwork()
        return phase.withLock { phase in
            phase.fetches += 1
            return LibraryExtract(
                source: extract.source, seriesList: extract.seriesList, title: extract.title,
                readingStates: phase.readingStates, state: extract.state)
        }
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        try checkNetwork()
        guard let title = extract.title.first(where: { $0.identifier == identifier }) else {
            throw SourceError.notFound(identifier)
        }
        return title
    }

    public func content(_ title: Title) -> ContentSource {
        let base = URL(string: "https://\(identifier.server)")!
        let id = title.identifier.id
        switch title.kind {
        case .manga:
            let count = if case .pages(let n) = title.scope { n } else { 0 }
            return .pageStream(count: count) { page in
                base.appending(path: "api/v1/books/\(id)/pages/\(page)")
            }
        case .audiobook, .podcast:
            // One minute of audio (the mock WAV), queued as often as the title is long —
            // including track changes; three chapters of a third each. Size and extension
            // are those of the mock WAV (44-byte header + 8 kHz · 60 s · 16 bit), so that
            // keeping knows its sum beforehand.
            let duration = if case .duration(let d) = title.scope { max(d, 60) } else { 60.0 }
            let tracks = (0..<Int((duration / 60).rounded(.up))).map { i in
                AudioTrack(
                    address: base.appending(path: "api/items/\(id)/file/\(i + 1)"),
                    startTime: Double(i) * 60,
                    duration: 60, size: 960_044, fileExtension: "wav")
            }
            let chapter = (0..<3).map {
                Chapter(
                    name: "Chapter \($0 + 1)", startTime: Double($0) * duration / 3,
                    end: Double($0 + 1) * duration / 3)
            }
            return .audioStream { AudioManifest(tracks: tracks, chapter: chapter, duration: duration) }
        case .book:
            return .file(
                base.appending(path: "api/v1/books/\(id)/content"), size: 800_000, rangeCapable: true)
        }
    }

    public func headerLines() -> [String: String] {
        ["X-Attrappe": identifier.description]
    }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        try checkNetwork()
        return phase.withLock { $0.readingStates[identifier] }
    }

    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        try checkNetwork()
        // Like Komga: a state for a book that does not exist is a 404 — final.
        guard extract.title.contains(where: { $0.identifier == identifier }) else {
            throw SourceError.notFound(identifier)
        }
        phase.withLock { phase in
            phase.readingStates[identifier] = state
            phase.written.append((identifier, state))
        }
    }

    public func forget(progressFor identifier: TitleID) async throws {
        try checkNetwork()
        phase.withLock { $0.readingStates[identifier] = nil }
    }

    public func savedList() async throws -> Set<TitleID> {
        guard capabilities.contains(.savedList) else {
            throw SourceError.notPossible(identifier, "Mock without saved list")
        }
        try checkNetwork()
        return phase.withLock { $0.saved }
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        guard capabilities.contains(.savedList) else {
            throw SourceError.notPossible(self.identifier, "Mock without saved list")
        }
        try checkNetwork()
        phase.withLock { if saved { $0.saved.insert(identifier) } else { $0.saved.remove(identifier) } }
    }

    public func collections() async throws -> [TitleCollection] {
        guard capabilities.contains(.collections) else {
            throw SourceError.notPossible(identifier, "Mock without collections")
        }
        try checkNetwork()
        return phase.withLock { $0.collections }
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        guard capabilities.contains(.editCollections) else {
            throw SourceError.notPossible(identifier, "Mock without collections")
        }
        try checkNetwork()
        return phase.withLock { phase in
            let new = TitleCollection(
                identifier: CollectionID(source: identifier, id: "s\(phase.collections.count + 1)"),
                name: name,
                collectionKind: collectionKind, entries: [], ordered: collectionKind == .readingList,
                isPrivate: collectionKind != .collection,
                editable: true)
            phase.collections.append(new)
            return new
        }
    }

    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        guard capabilities.contains(.editCollections) else {
            throw SourceError.notPossible(identifier, "Mock without collections")
        }
        try checkNetwork()
        try phase.withLock { phase in
            guard let i = phase.collections.firstIndex(where: { $0.identifier == collection }) else {
                throw SourceError.notPossible(identifier, "Collection unknown")
            }
            phase.collections[i] = phase.collections[i].with(target, into: into)
        }
    }
}
