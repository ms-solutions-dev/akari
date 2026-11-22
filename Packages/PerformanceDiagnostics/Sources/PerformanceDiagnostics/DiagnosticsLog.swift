import Foundation
import Synchronization

/// What the diagnostics record: one line per event, with place and time.
public struct Event: Sendable, Codable, Equatable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// The main thread did not respond for longer than ``HangWatchdog/threshold``.
        case hang = "haenger"
        /// Frames arrived late — sum per place and window, in ms per second.
        case jank = "ruckeln"
        /// Single frames that were ≥ ``Performance/longImageFrom`` ms late — summarized as a storm
        /// as long as there was no second of quiet in between.
        case longImages = "langeBilder"
        /// The summary of a measurement series (``Performance/measure(_:_:)``) per window.
        case metering = "messung"
        /// Heat, low-power mode or network path changed.
        case phase = "zustand"
        /// A drag in the reader: where the finger started, how far it and the band went,
        /// with what momentum it was released and where it landed. Notable ones begin with "⚠".
        case breadcrumb = "zug"
        /// A network request that took long or failed — with the session's timings.
        case network = "netz"
        /// The app held a lot of CPU over a window.
        case sustainedLoad = "dauerlast"
        /// A view was rebuilt unusually often.
        case rebuilt = "neuaufbau"
        /// Where the user went.
        case place = "ort"
        /// What an area reports itself (page loaded in x ms …).
        case remark = "notiz"
        /// CPU and memory, summarized per minute.
        case last
        /// MetricKit delivered.
        case metrickit
    }

    public let time: Date
    public let kind: Kind
    public let place: String
    public let text: String

    public init(time: Date = Date(), kind: Kind, place: String, text: String) {
        self.time = time
        self.kind = kind
        self.place = place
        self.text = text
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case time = "zeit"
        case kind = "art"
        case place = "ort"
        case text
    }
}

/// The event book: a ring buffer in memory plus a file.
///
/// **Writable from any thread without waiting.** The hang watchdog writes from its own
/// thread while the main thread is stuck — an `await` on the main thread would be exactly
/// the hang it wants to report. Hence a `Mutex` instead of an actor.
///
/// **The file is only appended to** and cleared when ``fileLimit`` is exceeded; the
/// report uses the ring buffer, the file survives a crash.
public final class DiagnosticsLog: Sendable {

    /// This many events are kept in memory.
    public static let edition = 3_000
    /// From this size on, the file starts over.
    public static let fileLimit = 2 * 1024 * 1024

    private struct Phase {
        var entries: [Event] = []
        var header = 0
    }

    private let phase = Mutex(Phase())
    private let file: URL?
    private let writer = DispatchQueue(label: "akari" + ".diagnose.buch", qos: .utility)

    /// - Parameter file: where to append; `nil` keeps memory only (tests).
    public init(file: URL?) {
        self.file = file
        if let file {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    public func write(_ event: Event) {
        phase.withLock { z in
            if z.entries.count < Self.edition {
                z.entries.append(event)
            } else {
                z.entries[z.header] = event
                z.header = (z.header + 1) % Self.edition
            }
        }
        guard let file, let line = try? JSONEncoder().encode(event) else { return }
        writer.async {
            Self.append(line + Data("\n".utf8), to: file)
        }
    }

    /// All events, oldest first.
    public var all: [Event] {
        phase.withLock { z in
            Array(z.entries[z.header...] + z.entries[..<z.header])
        }
    }

    public func clearOut() {
        phase.withLock { $0 = Phase() }
        if let file { writer.async { try? FileManager.default.removeItem(at: file) } }
    }

    private static func append(_ data: Data, to file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > fileLimit { try? FileManager.default.removeItem(at: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
