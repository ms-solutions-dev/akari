import Foundation

/// The trace on disk: on by default, rolling and limited.
///
/// **Why a file when there is the ring buffer:** ``Diagnostics/Trace`` lives in
/// memory and dies with the app. The first real device failure showed exactly
/// this gap: what happened before the restart was already gone when the report
/// was submitted. Here it survives: every line that goes into the trace is also
/// appended, and the report reads the file instead of the buffer.
///
/// **Rolling, whichever takes effect first:** anything older than ``maxAge``
/// falls out silently, and if the file grows past ``maxBytes``, it is cut at the
/// front. Both without anyone doing anything: nobody keeps an operations journal
/// that needs care.
///
/// In the cache directory, not in documents: tvOS does not allow persistent
/// storage, and a trace cleared by the system is the same loss as a restart
/// before this file existed: annoying, but not a bug.
public actor TraceRecorder {

    /// The **recording**: every step, as long as the switch is on.
    public static let shared = TraceRecorder()

    /// The **error trace**: always runs, independent of the switch. A file of its
    /// own, so the errors of a normal day do not vanish among two hundred steps of a
    /// test evening, and so the recording can be deleted without losing the error
    /// history.
    public static let errors = TraceRecorder(filename: "\(ProgramID.shortName)-fehler.log")

    /// Three days: enough to still catch "it stuttered last night".
    public static let maxAge: TimeInterval = 3 * 24 * 3600

    /// The size cap. Two megabytes carry weeks of normal operation and also a
    /// verbosely recorded test evening.
    public static let maxBytes = 2_000_000

    private let fileURL: URL
    private var didTrim = false

    /// - Parameters:
    ///   - directory: For tests only: they need a directory of their own,
    ///     otherwise they would write into the computer's trace.
    ///   - filename: The name of the trace file; one per trace.
    public init(directory: URL? = nil, filename: String = "\(ProgramID.shortName)-spur.log") {
        let base =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appending(path: filename)
    }

    /// Appends a line, with the timestamp by which the trimming recognizes it
    /// later.
    public func append(_ line: String, at date: Date = Date()) {
        // Trim on first write, not on creation: that way app launch costs nothing,
        // and trimming still happens once per run.
        if !didTrim {
            didTrim = true
            trim(now: date)
        }

        let stamped = Self.stamp(date) + "\t" + line.replacingOccurrences(of: "\n", with: " ") + "\n"
        guard let data = stamped.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }

        // **Not via `URL.resourceValues`:** the values are cached per URL instance.
        // Asked on the stored `fileURL`, the size of the very first look came back
        // forever, and trimming never ran (proven in a test: 1031 bytes for a 2.3 MB
        // file). `attributesOfItem` reads fresh from the file system every time.
        let size =
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            trim(now: date)
        }
    }

    /// The whole retained trace, for the report.
    public func contents() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Throws out what is too old and then trims to the waterline.
    ///
    /// The order is intended: age first, because it usually suffices, and only when
    /// three days alone burst the cap does size additionally cut at the front. Cuts
    /// are made at line boundaries; half a line at the start would read like a
    /// transmission error.
    ///
    /// **To three quarters, not exactly to the cap:** whoever trims exactly to the
    /// limit is above it again with the next line and would then read and write the
    /// whole file on **every** append. With room below, the next trim comes only
    /// after another quarter.
    private func trim(now: Date) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let oldest = now.addingTimeInterval(-Self.maxAge)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        lines.removeAll { line in
            guard let at = Self.date(fromStamped: line) else { return true }
            return at < oldest
        }

        // One cut instead of line by line: first add up, then sacrifice as many lines
        // at the front as needed until the waterline holds. The line-by-line version
        // copied the megabyte-sized text once per line.
        let target = Self.maxBytes * 3 / 4
        var total = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var drop = 0
        while total > target, drop < lines.count {
            total -= lines[drop].utf8.count + 1
            drop += 1
        }
        lines.removeFirst(drop)

        var kept = lines.joined(separator: "\n")
        if !kept.isEmpty { kept += "\n" }
        try? kept.data(using: .utf8)?.write(to: fileURL)
    }

    /// The timestamp at the start of the line: fixed format, because the trimming
    /// must read it back. ISO 8601 without fractions: second precision suffices, and
    /// the line stays readable for humans. Via the `FormatStyle` instead of a shared
    /// `ISO8601DateFormatter`, which is not `Sendable`.
    static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func date(fromStamped line: Substring) -> Date? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        return try? Date.ISO8601FormatStyle().parse(String(line[..<tab]))
    }
}
