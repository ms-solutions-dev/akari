import Foundation
import Synchronization

/// The reading state per title, local — one JSON file per source under "Application
/// Support", for sources that have no server-side reading state (OPDS, WebDAV).
/// Serialized through a mutex; the file is written in full on every write
/// (a few hundred entries, kilobytes).
///
/// Lives here rather than in `OpdsKit` because the second source without a server reading
/// state needs the same store. The file name stays `opds-<server>.json` — existing states
/// stay readable.
public final class StateStore: Sendable {
    private let file: URL?
    private let content: Mutex<[String: ReadingState]>

    /// The file of a source — formerly loose under "Application Support", now under
    /// `profile/<id>/states/` (``standard(for:below:)``); the file name is the
    /// same, so that the migration only moves it.
    public static func standard(for identifier: SourceID) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            standard(for: identifier, below: $0)
        }
    }

    public static func standard(for identifier: SourceID, below folder: URL) -> URL {
        folder.appending(path: filename(identifier))
    }

    /// `opds-comics.example.json` — provider and host, slashes as underscores.
    public static func filename(_ identifier: SourceID) -> String {
        "\(identifier.provider.rawValue)-\(identifier.server.replacingOccurrences(of: "/", with: "_")).json"
    }

    public init(file: URL?) {
        self.file = file
        var loaded: [String: ReadingState] = [:]
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([String: ReadingState].self, from: data)) ?? [:]
        }
        content = Mutex(loaded)
    }

    public func state(_ identifier: TitleID) -> ReadingState? {
        content.withLock { $0[identifier.id] }
    }

    public func all(source: SourceID) -> [TitleID: ReadingState] {
        content.withLock { states in
            Dictionary(
                uniqueKeysWithValues: states.map { (TitleID(source: source, id: $0.key), $0.value) })
        }
    }

    public func write(_ state: ReadingState, for identifier: TitleID) throws {
        try content.withLock { states in
            states[identifier.id] = state
            try secure(states)
        }
    }

    public func forget(_ identifier: TitleID) throws {
        try content.withLock { states in
            states[identifier.id] = nil
            try secure(states)
        }
    }

    private func secure(_ states: [String: ReadingState]) throws {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(states).write(to: file, options: .atomic)
    }
}
