import Foundation
import Synchronization

/// **One measurement point of the time series** — one every ``TimeSeries/beat`` seconds while
/// recording: CPU of the process and of the main thread (difference of thread times),
/// frames in the interval including missed frame changes and the longest frame, memory, heat,
/// place, spot, scroll phase, rebuilds and the levels of the areas (page loader queue).
///
/// **Why continuous**: thresholds show *that* something happened — curves show what was
/// *before*. Whether CPU already rose before the jolt, whether memory climbed, whether the
/// loader's queue was full when frames stopped coming: that is read off the series, not
/// off events.
public struct Sample: Sendable, Equatable {
    public var time: Date
    /// CPU of the process in percent of one core.
    public var cpu: Double
    /// CPU of the main thread in percent of one core.
    public var main: Double
    /// Frames delivered in the interval.
    public var images: Int
    /// Missed frame changes in the interval — the delay counted in frame lengths.
    public var missed: Int
    public var longestMs: Double
    /// Sum of the delays in the interval.
    public var jankMs: Double
    public var storageMB: Double
    public var freeMB: Double?
    public var thermal: String
    public var place: String
    public var spot: String
    public var scroll: String
    /// Rebuilds of all counted views in the interval.
    public var builds: Int
    public var level: [String: Int]
    /// Network requests still running at the end of the interval.
    public var networkRunning: Int
    /// Network requests that finished in the interval.
    public var networkDone: Int
    public var networkBytes: Int
    /// Median and maximum of the time to first byte in the interval, ms.
    public var networkFirstByteMs: Double
    public var networkFirstByteMaxMs: Double
    public var networkAborts: Int
    public var networkError: Int
    public var networkPath: String
    /// What the measurement point itself cost.
    public var tickMicros: Int

    public init(
        time: Date, cpu: Double, main: Double, images: Int, missed: Int, longestMs: Double,
        jankMs: Double, storageMB: Double, freeMB: Double?, thermal: String, place: String, spot: String,
        scroll: String, builds: Int, level: [String: Int], networkRunning: Int = 0, networkDone: Int = 0,
        networkBytes: Int = 0, networkFirstByteMs: Double = 0, networkFirstByteMaxMs: Double = 0,
        networkAborts: Int = 0,
        networkError: Int = 0, networkPath: String = "", tickMicros: Int
    ) {
        self.time = time
        self.cpu = cpu
        self.main = main
        self.images = images
        self.missed = missed
        self.longestMs = longestMs
        self.jankMs = jankMs
        self.storageMB = storageMB
        self.freeMB = freeMB
        self.thermal = thermal
        self.place = place
        self.spot = spot
        self.scroll = scroll
        self.builds = builds
        self.level = level
        self.networkRunning = networkRunning
        self.networkDone = networkDone
        self.networkBytes = networkBytes
        self.networkFirstByteMs = networkFirstByteMs
        self.networkFirstByteMaxMs = networkFirstByteMaxMs
        self.networkAborts = networkAborts
        self.networkError = networkError
        self.networkPath = networkPath
        self.tickMicros = tickMicros
    }
}

/// **The time series**: a ring buffer of the last ``edition`` points (15 minutes at
/// 250 ms) and a CSV file that is appended in blocks of eight — one file access every
/// two seconds, not four per second.
///
/// The report uses the ring buffer; the file survives a crash and starts over above
/// ``fileLimit``, like the event book.
public final class TimeSeries: Sendable {

    public static let beat: TimeInterval = 0.25
    public static let edition = 3_600
    public static let fileLimit = 4 * 1024 * 1024
    static let block = 8

    private struct Phase {
        var points: [Sample] = []
        var header = 0
        var pending: [String] = []
    }

    private let phase = Mutex(Phase())
    private let file: URL?
    private let writer = DispatchQueue(label: "akari" + ".diagnose.zeitreihe", qos: .utility)

    public init(file: URL?) {
        self.file = file
        if let file {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    public func save(_ point: Sample) {
        let block = phase.withLock { z -> [String]? in
            if z.points.count < Self.edition {
                z.points.append(point)
            } else {
                z.points[z.header] = point
                z.header = (z.header + 1) % Self.edition
            }
            guard file != nil else { return nil }
            z.pending.append(Self.csvRow(point))
            guard z.pending.count >= Self.block else { return nil }
            defer { z.pending.removeAll(keepingCapacity: true) }
            return z.pending
        }
        if let block, let file {
            writer.async { Self.append(block, to: file) }
        }
    }

    /// All points, oldest first.
    public var all: [Sample] {
        phase.withLock { z in Array(z.points[z.header...] + z.points[..<z.header]) }
    }

    public func clearOut() {
        phase.withLock { $0 = Phase() }
        if let file { writer.async { try? FileManager.default.removeItem(at: file) } }
    }

    // MARK: - CSV

    public static let csvHeader =
        "time;cpu_percent;main_percent;frames;missed;longest_ms;jank_ms;memory_mb;free_mb;"
        + "thermal;place;spot;scroll;rebuilds;level;net_running;net_done;net_bytes;net_first_byte_ms;"
        + "net_first_byte_max_ms;net_aborts;net_errors;net_path;tick_us"

    public static func csvRow(_ p: Sample) -> String {
        let level = p.level.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        return [
            p.time.formatted(
                Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true)),
            String(format: "%.1f", p.cpu), String(format: "%.1f", p.main), "\(p.images)", "\(p.missed)",
            String(format: "%.1f", p.longestMs), String(format: "%.1f", p.jankMs),
            String(format: "%.1f", p.storageMB), p.freeMB.map { String(format: "%.0f", $0) } ?? "",
            p.thermal, field(p.place), field(p.spot), p.scroll, "\(p.builds)", level, "\(p.networkRunning)",
            "\(p.networkDone)", "\(p.networkBytes)", String(format: "%.0f", p.networkFirstByteMs),
            String(format: "%.0f", p.networkFirstByteMaxMs), "\(p.networkAborts)", "\(p.networkError)",
            p.networkPath,
            "\(p.tickMicros)",
        ].joined(separator: ";")
    }

    /// The whole buffer as CSV — the report's attachment.
    public static func csv(_ points: [Sample]) -> String {
        ([csvHeader] + points.map(csvRow)).joined(separator: "\n") + "\n"
    }

    private static func field(_ text: String) -> String {
        text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ")
    }

    private static func append(_ lines: [String], to file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > fileLimit { try? FileManager.default.removeItem(at: file) }
        let new = !FileManager.default.fileExists(atPath: file.path)
        let text = (new ? [csvHeader] : []) + lines
        let data = Data((text.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: - Condensing

    /// One point per second: CPU averaged, frames summed, longest and memory as
    /// maximum, place and spot from the last point — the line for the timeline in the report.
    public static func perSecond(_ points: [Sample]) -> [Sample] {
        var result: [Sample] = []
        var cluster: [Sample] = []
        func close() {
            guard let last = cluster.last else { return }
            let n = Double(cluster.count)
            var p = last
            p.time = Date(timeIntervalSince1970: cluster[0].time.timeIntervalSince1970.rounded(.down))
            p.cpu = cluster.reduce(0) { $0 + $1.cpu } / n
            p.main = cluster.reduce(0) { $0 + $1.main } / n
            p.images = cluster.reduce(0) { $0 + $1.images }
            p.missed = cluster.reduce(0) { $0 + $1.missed }
            p.longestMs = cluster.map(\.longestMs).max() ?? 0
            p.jankMs = cluster.reduce(0) { $0 + $1.jankMs }
            p.storageMB = cluster.map(\.storageMB).max() ?? 0
            p.builds = cluster.reduce(0) { $0 + $1.builds }
            p.networkRunning = cluster.map(\.networkRunning).max() ?? 0
            p.networkDone = cluster.reduce(0) { $0 + $1.networkDone }
            p.networkBytes = cluster.reduce(0) { $0 + $1.networkBytes }
            p.networkFirstByteMs = cluster.filter { $0.networkDone > 0 }.map(\.networkFirstByteMs).max() ?? 0
            p.networkFirstByteMaxMs = cluster.map(\.networkFirstByteMaxMs).max() ?? 0
            p.networkAborts = cluster.reduce(0) { $0 + $1.networkAborts }
            p.networkError = cluster.reduce(0) { $0 + $1.networkError }
            p.tickMicros = cluster.map(\.tickMicros).max() ?? 0
            result.append(p)
            cluster.removeAll(keepingCapacity: true)
        }
        for p in points {
            if let first = cluster.first,
                first.time.timeIntervalSince1970.rounded(.down)
                    != p.time.timeIntervalSince1970.rounded(.down)
            {
                close()
            }
            cluster.append(p)
        }
        close()
        return result
    }

    /// "CPU  85 % · Main  71 % · Frames  31 (missed 12, longest 140 ms) · 194 MB · normal ·
    /// finger · Loader 12 · p. 255/1170" (example output).
    public static func line(_ p: Sample) -> String {
        var share = [
            String(format: "CPU %3.0f %%", p.cpu), String(format: "Main %3.0f %%", p.main),
            String(
                format: "Frames %3d (missed %2d, longest %3.0f ms)", p.images, p.missed, p.longestMs),
            String(format: "%.0f MB", p.storageMB), p.thermal,
        ]
        if !p.scroll.isEmpty { share.append(p.scroll) }
        if p.builds > 0 { share.append("\(p.builds) rebuilds") }
        for (name, value) in p.level.sorted(by: { $0.key < $1.key }) { share.append("\(name) \(value)") }
        if p.networkRunning > 0 || p.networkDone > 0 {
            var network =
                "Network \(p.networkRunning) running, \(p.networkDone) done, \(p.networkBytes / 1024) KB"
            if p.networkDone > 0 {
                network += String(
                    format: ", 1st byte %.0f ms (max %.0f)", p.networkFirstByteMs, p.networkFirstByteMaxMs)
            }
            if p.networkAborts > 0 { network += ", \(p.networkAborts) cancelled" }
            if p.networkError > 0 { network += ", \(p.networkError) errors" }
            share.append(network)
        }
        if !p.networkPath.isEmpty { share.append(p.networkPath) }
        if !p.spot.isEmpty { share.append(p.spot) }
        return share.joined(separator: " · ")
    }
}
