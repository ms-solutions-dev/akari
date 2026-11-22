import Bedrock
import Foundation
import SourcesKit

/// The extracts on disk — so that Home comes up from the cache on the next launch,
/// before any server has answered, and offline at all.
///
/// One JSON file per source in the system cache (`caches`, which the system may
/// clear). A few hundred kilobytes per source; reading once on launch costs
/// milliseconds, and the home page has its two seconds for something else.
public struct LibraryStore: Sendable {

    public let folder: URL

    /// - Parameter folder: where the extracts live — by default under `caches/bestand`;
    ///   tests pass their own so they leave nothing behind.
    public init(folder: URL? = nil) {
        self.folder =
            folder
            ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "bestand", directoryHint: .isDirectory)
    }

    private func path(_ source: SourceID) -> URL {
        // The provider and the host form the name; a slash in it would be
        // a folder — host names contain none.
        folder.appending(path: "\(source.provider.rawValue)@\(source.server).json")
    }

    private func corePath(_ source: SourceID) -> URL {
        folder.appending(path: "\(source.provider.rawValue)@\(source.server).kern.json")
    }

    /// The reading states on their own: a new state used to rewrite the
    /// whole extract — for Grimmory 25 MB of JSON including the core, every time a
    /// book was closed, with memory peaks up to 450 MB and jank on Home. Now only this small
    /// file; it lies over the extract and the core when reading, until the next full extract
    /// replaces it.
    private func statesPath(_ source: SourceID) -> URL {
        folder.appending(path: "\(source.provider.rawValue)@\(source.server).staende.json")
    }

    public func loadExtract(_ source: SourceID) -> LibraryExtract? {
        guard let data = try? Data(contentsOf: path(source)) else { return nil }
        return withStates(try? JSONDecoder().decode(LibraryExtract.self, from: data))
    }

    /// Lays the separately written states over a read extract.
    private func withStates(_ extract: LibraryExtract?) -> LibraryExtract? {
        guard let extract, let data = try? Data(contentsOf: statesPath(extract.source)),
            let states = try? JSONDecoder().decode([TitleID: ReadingState].self, from: data)
        else { return extract }
        return LibraryExtract(
            source: extract.source, seriesList: extract.seriesList, title: extract.title,
            readingStates: states,
            collections: extract.collections, authors: extract.authors, state: extract.state,
            isSupplement: extract.isSupplement)
    }

    /// Writes only the reading states — for changes that touch nothing else in the extract.
    public func writeStates(_ extract: LibraryExtract) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(extract.readingStates).write(
            to: statesPath(extract.source), options: .atomic)
    }

    /// Writes the core and returns its titles — the writer remembers them to know
    /// whether a new state affects a title that is missing from the core.
    @discardableResult
    public func writeCore(_ extract: LibraryExtract) -> Set<TitleID> {
        let core = LibraryStore.core(extract)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(core).write(to: corePath(extract.source), options: .atomic)
        return Set(core.title.map(\.identifier))
    }

    /// The core of a large source — read in milliseconds so that Home stands
    /// while the whole extract (30 MB for 35,000 books, a good second on an iPhone) is
    /// still decoding. `nil` for small sources: those are read whole right away.
    public func readCore(_ source: SourceID) -> LibraryExtract? {
        guard let data = try? Data(contentsOf: corePath(source)) else { return nil }
        return withStates(try? JSONDecoder().decode(LibraryExtract.self, from: data))
    }

    /// Writes the whole extract; the separately written states are contained in it and drop out.
    /// - Returns: the titles of the core, `nil` for small sources without a core.
    @discardableResult
    public func write(_ extract: LibraryExtract) throws -> Set<TitleID>? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(extract).write(to: path(extract.source), options: .atomic)
        try? FileManager.default.removeItem(at: statesPath(extract.source))
        if extract.title.count > LibraryStore.kernAb {
            return writeCore(extract)
        }
        try? FileManager.default.removeItem(at: corePath(extract.source))
        return nil
    }

    /// Writes the core if it is missing — an unchanged extract is not rewritten,
    /// and without this the core would only come with the next change.
    ///
    /// The path unencoded: `path()` yields "Application%20Support", the file was never
    /// considered present, and the core was rebuilt and written on every launch.
    @discardableResult
    public func writeCoreIfMissing(_ extract: LibraryExtract) -> Set<TitleID>? {
        guard extract.title.count > LibraryStore.kernAb,
            !FileManager.default.fileExists(atPath: corePath(extract.source).path(percentEncoded: false))
        else { return nil }
        return writeCore(extract)
    }

    /// From how many titles on a source gets a core.
    static let kernAb = 3_000

    /// What Home needs: all titles with a reading state, the 200 youngest (new on shelf) and all
    /// volumes of the series in which any of that lies (up next, series state). Without the
    /// author list; the collections stay (the shelf row).
    static func core(_ extract: LibraryExtract) -> LibraryExtract {
        var keep = Set(extract.readingStates.keys)
        let youngest = extract.title.sorted {
            ($0.added ?? .distantPast) > ($1.added ?? .distantPast)
        }
        for t in youngest.prefix(200) { keep.insert(t.identifier) }
        let bookSeriesList = Set(
            extract.title.filter { keep.contains($0.identifier) }.compactMap { $0.series?.identifier })
        let title = extract.title.filter {
            keep.contains($0.identifier)
                || ($0.series.map { bookSeriesList.contains($0.identifier) } ?? false)
        }
        return LibraryExtract(
            source: extract.source,
            seriesList: extract.seriesList.filter { bookSeriesList.contains($0.identifier) }, title: title,
            readingStates: extract.readingStates, collections: extract.collections, authors: [],
            state: extract.state,
            isSupplement: extract.isSupplement)
    }

    public func remove(_ source: SourceID) {
        try? FileManager.default.removeItem(at: path(source))
        try? FileManager.default.removeItem(at: corePath(source))
        try? FileManager.default.removeItem(at: statesPath(source))
    }

    public func clearOut() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Writes the store off the main thread — bundled.
///
/// **Why**: every reading state used to rewrite its source's whole extract
/// on the main thread. For Grimmory that is 30 MB of JSON with 24,000 titles — on an iPhone
/// half a second to one and a half of standstill, every 15 s while listening, per page when
/// paging through a comic. Anything that wanted to animate in that time stood still.
///
/// After a refresh ``write(_:)`` writes immediately (but in the actor, not on the
/// main thread). A reading state only schedules with ``schedule(_:statesOnly:)``; it is written after
/// ``quiet`` seconds without a new state, or with ``secure()`` when the app
/// goes to the background. Nothing important is lost that way: the store is the cache for the
/// next launch, open states lie separately in the ``Queue``.
actor StoreWriter {

    private let persistence: LibraryStore
    private let quiet: Duration
    private var unresolved: [SourceID: (extract: LibraryExtract, statesOnly: Bool)] = [:]
    /// The titles in the core per source, as far as this writer wrote it.
    private var coreTitles: [SourceID: Set<TitleID>] = [:]
    /// Removed sources — a pending write that arrives afterwards does not write them back.
    private var removed: Set<SourceID> = []
    private var timer: Task<Void, Never>?

    init(persistence: LibraryStore, quiet: Duration = .seconds(3)) {
        self.persistence = persistence
        self.quiet = quiet
    }

    /// Write immediately — after a refresh, so the next launch has the new version.
    func write(_ extract: LibraryExtract) {
        unresolved[extract.source] = nil
        removed.remove(extract.source)
        do { coreTitles[extract.source] = try persistence.write(extract) } catch {
            Diagnostics.network.error(
                "Inventory: shelf \(extract.source.description, privacy: .public) not written")
        }
    }

    /// Write only the states — and the core, if a state concerns a title that
    /// is missing in it (otherwise a newly started book would only appear in
    /// "Continue reading" after the whole extract).
    func writeStates(_ extract: LibraryExtract) {
        unresolved[extract.source] = nil
        removed.remove(extract.source)
        do { try persistence.writeStates(extract) } catch {
            Diagnostics.network.error(
                "Inventory: states \(extract.source.description, privacy: .public) not written")
        }
        guard extract.title.count > LibraryStore.kernAb else { return }
        if let known = coreTitles[extract.source], Set(extract.readingStates.keys).isSubset(of: known) {
            return
        }
        coreTitles[extract.source] = persistence.writeCore(extract)
    }

    /// Schedule — the newest extract per source wins, writing is bundled. If only
    /// states changed (`statesOnly`): only the small states file is written then —
    /// as long as no other pending write for the same source has changed more.
    func schedule(_ extract: LibraryExtract, statesOnly: Bool = false) {
        guard !removed.contains(extract.source) else { return }
        unresolved[extract.source] = (extract, statesOnly && (unresolved[extract.source]?.statesOnly ?? true))
        timer?.cancel()
        timer = Task { [quiet] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            self.secure()
        }
    }

    /// Writes what is pending.
    func secure() {
        let list = unresolved.values
        unresolved.removeAll()
        for (extract, statesOnly) in list {
            if statesOnly { writeStates(extract) } else { write(extract) }
        }
    }

    func coreIfMissing(_ extract: LibraryExtract) {
        if let title = persistence.writeCoreIfMissing(extract) { coreTitles[extract.source] = title }
    }

    func remove(_ source: SourceID) {
        unresolved[source] = nil
        removed.insert(source)
        persistence.remove(source)
    }
}
