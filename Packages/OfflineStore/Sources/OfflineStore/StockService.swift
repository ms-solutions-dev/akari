import Bedrock
import Foundation
import Observation
import SourcesKit

/// The stock on the main actor: what is kept, what is being fetched, and how much
/// all of it weighs.
///
/// **Keeping is an intention of the user**, not a cache: A volume that is kept lies
/// completely on the device and stays until it is released — the badge at the bottom
/// right says so. Fetching runs per title as its own task, one after another (one
/// connection through the tunnel is enough), and a cancellation leaves what is
/// already there.
///
/// The word "download" does not appear: there is keeping and releasing.
@MainActor
@Observable
public final class StockService {

    public private(set) var entries: [TitleID: KeptItem] = [:] {
        didSet {
            let new = Set(entries.values.filter(\.done).map(\.identifier))
            if new != completed { completed = new }
        }
    }

    /// How far a running fetch is — separate so only the progress rings listen to the
    /// four reports per second. If they lay in ``entries``, the shell and every visible
    /// tile would recompute four times per second while a download ran.
    public private(set) var progresses: [TitleID: Progress] = [:]

    public struct Progress: Sendable, Hashable {
        public let fraction: Double
        public let bytes: Int64
    }

    public func progress(_ identifier: TitleID) -> Progress? { progresses[identifier] }

    /// The entry with the current progress in it — for the storage sheet.
    public func withProgress(_ e: KeptItem) -> KeptItem {
        guard case .ongoing = e.state, let f = progresses[e.identifier] else { return e }
        return e.with(state: .ongoing(fraction: f.fraction, bytes: f.bytes), size: f.bytes)
    }
    private let persistence: KeepStore
    @ObservationIgnored private var tasks: [TitleID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastReported: [TitleID: ContinuousClock.Instant] = [:]
    /// Data packages being fetched right now — not twice.
    @ObservationIgnored private var packagesInFlight: Set<TitleID> = []

    public init(persistence: KeepStore = KeepStore()) {
        self.persistence = persistence
        var list: [TitleID: KeptItem] = [:]
        for b in persistence.restoreFromDisk() {
            // What stood mid-fetch last time is now failed — the next attempt resumes what
            // lies there.
            if case .ongoing = b.state {
                list[b.identifier] = b.with(
                    state: .disrupted("unterbrochen"), size: persistence.size(b.identifier))
            } else {
                list[b.identifier] = b
            }
        }
        entries = list
        completed = Set(list.values.filter(\.done).map(\.identifier))
    }

    /// The identifiers that lie completely on the device — the "Keep" filter and the
    /// badge. Stored, not computed: it only changes when a title finishes or goes.
    public private(set) var completed: Set<TitleID> = []

    public func entry(_ identifier: TitleID) -> KeptItem? { entries[identifier] }

    /// What was left interrupted — the app was quit while fetching, the network dropped.
    /// The shell resumes it as soon as the library and a capable network are there; the
    /// file fetcher continues via `Range` where it stopped.
    public var interrupted: [TitleID] {
        entries.values.compactMap { if case .disrupted = $0.state { $0.identifier } else { nil } }
    }

    /// Everything kept together, in bytes — the number in the storage sheet.
    public var sum: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    /// The files of a finished title, in reading order — for the readers.
    public func files(_ identifier: TitleID) -> [URL]? {
        guard let b = entries[identifier], b.done else { return nil }
        let folder = persistence.folder(for: identifier)
        return b.files.map { folder.appending(path: $0) }
    }

    /// The audio manifest of a completely kept audiobook with the tracks as files on
    /// the device — `nil` if it is not (entirely) there. Chapters and locations are the
    /// server's, saved as `tonband.json` next to the tracks so that the player needs no
    /// server.
    public func audioManifest(_ identifier: TitleID) -> AudioManifest? {
        guard let files = files(identifier), let volume = persistence.audioManifest(identifier) else {
            return nil
        }
        return AudiobookStock.local(volume, files: files)
    }

    // MARK: - Keeping and releasing

    /// Fetches the title completely onto the device — one file, all pages or all tracks.
    /// Runs in the background; ``entries`` shows the progress.
    ///
    /// - Parameter audioManifest: for audiobooks the manifest, if the caller already
    ///   fetched it (the button asks for tracks and size beforehand) — saves the second
    ///   request for the detail; otherwise the service fetches it itself.
    public func requestKeep(
        _ title: Title, source: any Source, transport: any Transport, audioManifest: AudioManifest? = nil
    ) {
        let identifier = title.identifier
        if let previous = entries[identifier], previous.done || tasks[identifier] != nil { return }
        var content = source.content(title)
        if let audioManifest, case .audioStream = content { content = .audioStream { audioManifest } }
        let headerLines = source.headerLines()
        entries[identifier] =
            entries[identifier]?.with(state: .ongoing(fraction: 0, bytes: 0))
            ?? KeptItem(
                identifier: identifier, name: title.name, kind: title.kind, since: Date(), size: 0,
                state: .ongoing(fraction: 0, bytes: 0), files: [], title: title)
        secure()
        fetchPackage(title, source: source, transport: transport)
        let folder = persistence.folder(for: identifier)
        let expected = title.size
        // `self` strongly: The service lives as long as the shell, the task as long as the
        // fetch — that is no cycle, and a main-actor object is `Sendable`.
        tasks[identifier] = Task {
            do {
                let (files, bytes) = try await StockService.fetch(
                    content, headerLines: headerLines, transport: transport, to: folder, expected: expected
                ) { bytes, fraction in
                    Task { @MainActor in self.report(identifier, bytes: bytes, fraction: fraction) }
                }
                finish(identifier, files: files, bytes: bytes)
            } catch is CancellationError {
                disruption(identifier, "abgebrochen")
            } catch {
                Diagnostics.network.error(
                    "Stock: \(identifier.description, privacy: .public) not fetched: \(String(describing: error), privacy: .public)"
                )
                disruption(identifier, String(describing: error))
            }
        }
    }

    /// The kept titles as they appear on the shelf without a catalog: from their data
    /// package, the cover as a file in the folder. Only finished ones — a started
    /// download is no book.
    public var snapshots: [Title] {
        entries.values.filter(\.done).compactMap { b -> Title? in
            guard let title = b.title else { return nil }
            guard let file = b.coverFile else { return title }
            return title.with(cover: persistence.folder(for: b.identifier).appending(path: file))
        }
        .sorted { $0.identifier.description < $1.identifier.description }
    }

    /// Adds the data package for kept items from before (entries without
    /// ``KeptItem/title``) as soon as the title appears in a catalog — once per program
    /// run and title.
    public func supplement(
        title: (TitleID) -> Title?, source: (SourceID) -> (any Source)?,
        transport: (Provider) -> any Transport
    ) {
        for b in entries.values where b.title == nil || b.coverFile == nil {
            guard let t = b.title ?? title(b.identifier), let q = source(b.identifier.source) else {
                continue
            }
            fetchPackage(t, source: q, transport: transport(b.identifier.source.provider))
        }
    }

    /// Fetches the data package: the title fresh from the server — with everything the
    /// catalog trims, blurb first — and the cover as `cover.jpg` into the folder. Runs
    /// alongside the download; if it fails, the title stays as the catalog knew it.
    private func fetchPackage(_ title: Title, source: any Source, transport: any Transport) {
        let identifier = title.identifier
        guard packagesInFlight.insert(identifier).inserted else { return }
        let folder = persistence.folder(for: identifier)
        let headerLines = source.headerLines()
        Task {
            defer { packagesInFlight.remove(identifier) }
            let full = (try? await source.title(identifier)) ?? title
            let done = full.summary == nil && title.summary != nil ? title : full
            var cover: String?
            if let address = title.cover ?? full.cover,
                let image = await ImageLoader.shared.image(
                    address, headerLines: headerLines, pixels: 1200, transport: transport),
                ImageLoader.writeJPEG(image, to: folder.appending(path: "cover.jpg"))
            {
                cover = "cover.jpg"
            }
            guard let b = entries[identifier] else { return }
            entries[identifier] = b.with(title: done, coverFile: cover)
            secure()
        }
    }

    /// Releases the title — the files are gone, the badge too. A running fetch is
    /// cancelled.
    public func release(_ identifier: TitleID) {
        tasks[identifier]?.cancel()
        tasks[identifier] = nil
        progresses[identifier] = nil
        entries[identifier] = nil
        persistence.remove(identifier)
        secure()
    }

    // MARK: - Internals

    /// At most four times per second: the file fetcher reports every 256 KB, on Wi-Fi
    /// dozens of times per second — and every report made the shell and every visible
    /// tile recompute. Four steps per second are enough for a progress ring.
    private func report(_ identifier: TitleID, bytes: Int64, fraction: Double) {
        guard let b = entries[identifier], case .ongoing = b.state else { return }
        let now = ContinuousClock.now
        if let recently = lastReported[identifier], now - recently < .milliseconds(250) { return }
        lastReported[identifier] = now
        progresses[identifier] = Progress(fraction: fraction, bytes: bytes)
    }

    private func finish(_ identifier: TitleID, files: [String], bytes: Int64) {
        tasks[identifier] = nil
        progresses[identifier] = nil
        lastReported[identifier] = nil
        guard let b = entries[identifier] else { return }
        entries[identifier] = b.with(state: .done, size: bytes, files: files)
        secure()
        Diagnostics.step(
            "Stock: \(b.name) kept (\(bytes / 1024) KB)", since: nil, area: "Stock")
    }

    private func disruption(_ identifier: TitleID, _ reason: String) {
        tasks[identifier] = nil
        progresses[identifier] = nil
        guard let b = entries[identifier] else { return }
        entries[identifier] = b.with(state: .disrupted(reason), size: persistence.size(identifier))
        secure()
    }

    private func secure() {
        do { try persistence.write(Array(entries.values)) } catch {
            Diagnostics.network.error("Stock: index not written")
        }
    }

    /// Fetches what the content source names: one file, page by page, or track by track
    /// — for audiobooks first the manifest, then every track in its order as
    /// `spur-0001.mp3`; a finished track is skipped, a started one (`.teil`) is continued
    /// via `Range`, the manifest lies next to it as `tonband.json`.
    nonisolated static func fetch(
        _ content: ContentSource, headerLines: [String: String], transport: any Transport, to folder: URL,
        expected: Int64?, progress: @escaping @Sendable (Int64, Double) -> Void
    ) async throws -> ([String], Int64) {
        switch content {
        case .file(let address, let size, let rangeCapable):
            let name = "inhalt" + StockService.fileExtension(address)
            let total = size ?? expected
            let bytes = try await FileFetcher.fetch(
                address, headerLines: headerLines, transport: transport, to: folder.appending(path: name),
                rangeCapable: rangeCapable
            ) { soFar in
                progress(soFar, total.map { min(Double(soFar) / Double(max($0, 1)), 0.99) } ?? 0)
            }
            return ([name], bytes)
        case .pageStream(let count, let page, let measures):
            var names: [String] = []
            var sum: Int64 = 0
            // The dimensions first: for OPDS 2.0 the page addresses are in the Divina manifest,
            // and `measures` fetches it — otherwise the page stream guesses the addresses (stopgap).
            _ = try? await measures?()
            for i in 1...max(count, 1) {
                let name = String(format: "seite-%04d", i)
                let target = folder.appending(path: name)
                if let present = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, present > 0 {
                    sum += Int64(present)
                } else {
                    sum += try await FileFetcher.fetch(
                        page(i), headerLines: headerLines, transport: transport, to: target,
                        rangeCapable: false
                    ) { _ in }
                }
                names.append(name)
                progress(sum, Double(i) / Double(max(count, 1)))
                try Task.checkCancellation()
            }
            return (names, sum)
        case .audioStream(let fetchVolume):
            let volume = try await fetchVolume()
            guard !volume.tracks.isEmpty else {
                throw SourceError.unreadable(
                    SourceID(provider: .audiobookshelf, server: ""), "no tracks")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(volume).write(
                to: folder.appending(path: AudiobookStock.volumeFile), options: .atomic)
            let total = volume.size ?? expected
            let names = AudiobookStock.filenames(volume)
            var sum: Int64 = 0
            for (i, track) in volume.tracks.enumerated() {
                let target = folder.appending(path: names[i])
                if let present = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, present > 0 {
                    sum += Int64(present)
                } else {
                    let teil = target.appendingPathExtension("teil")
                    let soFar = sum
                    let bytes = try await FileFetcher.fetch(
                        track.address, headerLines: headerLines, transport: transport, to: teil,
                        rangeCapable: true
                    ) { inSpur in
                        progress(
                            soFar + inSpur,
                            AudiobookStock.fraction(
                                bytes: soFar + inSpur, total: total, track: i, from: volume.tracks.count))
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: teil, to: target)
                    sum += bytes
                }
                progress(
                    sum,
                    AudiobookStock.fraction(bytes: sum, total: total, track: i + 1, from: volume.tracks.count)
                )
                try Task.checkCancellation()
            }
            return (names, sum)
        }
    }

    private nonisolated static func fileExtension(_ url: URL) -> String {
        let e = url.pathExtension
        return e.isEmpty ? "" : "." + e
    }
}
