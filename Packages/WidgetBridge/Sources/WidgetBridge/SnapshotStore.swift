import Foundation

/// Where the snapshots live and how they are read and written — the same lines for
/// both sides, so app and widget never drift apart over a file name.
///
/// One folder per widget in the container of the app group (`group.dev.ms-solutions.akari`):
/// `weiterlesen/` with `weiterlesen.json` and one cover per title, `weiterhoeren/`
/// with `weiterhoeren.json` and one cover, `lesezeit/` with `lesezeit.json`. Without an
/// app group (tests, a build without entitlement) there is no folder — then the
/// app writes nothing and the widget shows the placeholder.
public enum SnapshotStore {

    public static let cluster = "group.dev.ms-solutions.akari"

    /// The widget kinds for `WidgetCenter.reloadTimelines(ofKind:)` — the app
    /// calls it after every write, the widget registers under it.
    public static let widgetKind = "dev.ms-solutions.akari.weiterlesen"
    public static let continueListeningKind = "dev.ms-solutions.akari.weiterhoeren"
    public static let statisticsKind = "dev.ms-solutions.akari.lesestatistik"

    /// The link the empty widget carries: the app opens and does what Continue Reading does.
    public static let openLink = URL(string: "akari://weiterlesen")!
    /// The link of the reading-time widget: the app opens Account → Reading statistics.
    public static let statisticsLink = URL(string: "akari://statistik")!

    static let filename = "weiterlesen.json"
    static let continueListeningFile = "weiterhoeren.json"
    static let statisticsFile = "statistik.json"

    /// The folder of the "Continue reading" snapshot in the app group — `nil` if
    /// the group does not exist.
    public static func folder(cluster: String = cluster) -> URL? {
        root(cluster: cluster)?.appending(path: "weiterlesen")
    }

    public static func continueListeningFolder(cluster: String = cluster) -> URL? {
        root(cluster: cluster)?.appending(path: "weiterhoeren")
    }

    public static func statisticsFolder(cluster: String = cluster) -> URL? {
        root(cluster: cluster)?.appending(path: "statistik")
    }

    private static func root(cluster: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: cluster)
    }

    // MARK: - Continue reading

    /// Reads the snapshot — `nil` if none has been written yet or the
    /// file cannot be read (then the widget shows the placeholder, no rejection).
    public static func load(from folder: URL) -> ContinueReadingSnapshot? {
        load(file: filename, from: folder)
    }

    /// The path of a cover in the folder — for the widget when drawing.
    public static func cover(_ entry: ContinueReadingSnapshot.Item, in folder: URL) -> URL? {
        entry.cover.map { folder.appending(path: $0) }
    }

    /// Writes snapshot and covers. Images first, then the JSON file — the
    /// widget reads the JSON and then finds the images already there. Covers that no
    /// entry names any more are dropped; a cover that is already there is not rewritten
    /// (`cover` only carries what is missing or has changed).
    ///
    /// - Parameter cover: image data per file name (``ContinueReadingSnapshot/coverFilename(for:)``).
    public static func write(
        _ snapshot: ContinueReadingSnapshot, cover: [String: Data], in folder: URL
    ) throws {
        try write(
            snapshot, file: filename, cover: cover,
            keep: Set(snapshot.entries.compactMap(\.cover)), in: folder)
    }

    /// Which covers are already in the folder — the app only fetches what is missing.
    public static func existingCovers(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.filter { !$0.hasSuffix(".json") })
    }

    // MARK: - Continue listening

    public static func readContinueListening(from folder: URL) -> ContinueListeningSnapshot? {
        load(file: continueListeningFile, from: folder)
    }

    public static func cover(_ audiobook: ContinueListeningSnapshot.Audiobook, in folder: URL) -> URL? {
        audiobook.cover.map { folder.appending(path: $0) }
    }

    /// Writes the listening snapshot; the cover only if it comes along — what is there
    /// and still valid stays, everything else in the folder is dropped.
    public static func writeContinueListening(
        _ snapshot: ContinueListeningSnapshot, cover: [String: Data], in folder: URL
    ) throws {
        try write(
            snapshot, file: continueListeningFile, cover: cover,
            keep: Set([snapshot.audiobook?.cover].compactMap { $0 }), in: folder)
    }

    // MARK: - Reading statistics

    public static func readStatistics(from folder: URL) -> ReadingStatisticsSnapshot? {
        load(file: statisticsFile, from: folder)
    }

    public static func writeStatistics(_ snapshot: ReadingStatisticsSnapshot, in folder: URL) throws {
        try write(snapshot, file: statisticsFile, cover: [:], keep: [], in: folder)
    }

    // MARK: - Internals

    private static func load<Value: Decodable>(file: String, from folder: URL) -> Value? {
        guard let data = try? Data(contentsOf: folder.appending(path: file)) else { return nil }
        return try? snapshotDecoder.decode(Value.self, from: data)
    }

    private static func write<Value: Encodable>(
        _ value: Value, file: String, cover: [String: Data], keep: Set<String>, in folder: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in cover {
            try data.write(to: folder.appending(path: name), options: .atomic)
        }
        let remaining = keep.union([file])
        for entry in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where !remaining.contains(entry) {
            try? fm.removeItem(at: folder.appending(path: entry))
        }
        let data = try snapshotEncoder.encode(value)
        try data.write(to: folder.appending(path: file), options: .atomic)
    }

    private static let snapshotEncoder: JSONEncoder = {
        let k = JSONEncoder()
        k.dateEncodingStrategy = .iso8601
        k.outputFormatting = [.sortedKeys]
        return k
    }()

    private static let snapshotDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
