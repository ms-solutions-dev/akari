import Foundation
import SourcesKit

/// A state the server does not have yet; a `nil` `state` means: forgotten.
public struct Pending: Sendable, Codable, Hashable {
    public let identifier: TitleID
    public let state: ReadingState?
    public let since: Date

    public init(identifier: TitleID, state: ReadingState?, since: Date = Date()) {
        self.identifier = identifier
        self.state = state
        self.since = since
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case state = "stand"
        case since = "seit"
    }
}

/// What was written offline and has to be supplied later: one entry per title (the last
/// wins), on disk so a restart loses nothing.
///
/// Plus the **device track:** per title, the state this device last wrote itself. None of
/// the three servers stores a device name, but the ``ConflictRule`` needs the difference
/// between "my state" and "somebody else's", and it lives here.
public final class Queue: @unchecked Sendable {

    private let folder: URL?
    private let lock = NSLock()
    private var entries: [TitleID: Pending] = [:]
    private var track: [TitleID: ReadingState] = [:]

    /// - Parameter folder: where the two files live; by default
    ///   `Application Support/fortschritt`, and `nil` keeps everything in memory only (tests).
    public init(folder: URL? = Queue.defaultFolder) {
        self.folder = folder
        restoreFromDisk()
    }

    public static var defaultFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "fortschritt", directoryHint: .isDirectory)
    }

    // MARK: - Queue

    public var all: [Pending] {
        lock.withLock { entries.values.sorted { $0.since < $1.since } }
    }

    public var empty: Bool { lock.withLock { entries.isEmpty } }

    public func pending(_ identifier: TitleID) -> Pending? {
        lock.withLock { entries[identifier] }
    }

    /// Queues a state (or a forgetting), replacing whatever was already there for the title.
    public func spot(_ state: ReadingState?, for identifier: TitleID) {
        lock.withLock {
            entries[identifier] = Pending(identifier: identifier, state: state)
            write()
        }
    }

    public func remove(_ identifier: TitleID) {
        lock.withLock {
            entries[identifier] = nil
            write()
        }
    }

    // MARK: - Device track

    public func own(_ identifier: TitleID) -> ReadingState? {
        lock.withLock { track[identifier] }
    }

    /// Remembers what this device wrote, even if it is still only in the queue.
    public func save(own state: ReadingState?, for identifier: TitleID) {
        lock.withLock {
            track[identifier] = state
            write()
        }
    }

    // MARK: - Disk

    private struct Snapshot: Codable {
        var entries: [Pending]
        var track: [TitleID: ReadingState]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case entries = "eintraege"
            case track = "spur"
        }
    }

    private func restoreFromDisk() {
        // Whatever is still being written goes to disk first, otherwise a new queue would
        // read the state from a moment ago.
        Queue.diskQueue.sync {}
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "warteschlange.json")),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.identifier, $0) })
        track = snapshot.track
    }

    /// Writes away from the caller, in order: every reading state used to write twice here
    /// on the main thread. The snapshot is built under the lock, encoded and written on a
    /// queue of its own; the order is kept and the last state wins.
    private func write() {
        guard let folder else { return }
        let snapshot = Snapshot(entries: Array(entries.values), track: track)
        Queue.diskQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appending(path: "warteschlange.json"), options: .atomic)
        }
    }

    private static let diskQueue = DispatchQueue(label: "Queue-Disk", qos: .utility)

    /// Waits until everything written is on disk, for tests and before quitting.
    public func secure() {
        Queue.diskQueue.sync {}
    }
}
