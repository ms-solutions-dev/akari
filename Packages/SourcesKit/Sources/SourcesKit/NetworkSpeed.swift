import Foundation

/// Measures what the line really carries — from the requests that run anyway.
///
/// **No dedicated test transfer.** The tunnel carries 0.3 Mbit/s, and the app should say so
/// before the reader waits 19 s for a page. Fetching a probe file through exactly that tunnel
/// would be a waste; covers, pages and books are fetched anyway, and every response of at
/// least ``minimumBytes`` is a measurement. Small responses do not count: a 4 KB JSON
/// measures latency, not bandwidth.
///
/// **Six measurements, with hysteresis:** ``phase`` becomes ``NetworkStatus/slow(mbit:)`` as
/// soon as two measurements together fall below ``slowBelow``, and only returns to
/// ``NetworkStatus/reachable`` once they exceed ``fastFrom`` — a single sluggish request must
/// not make the banner flicker. When the network path changes, everything is forgotten
/// (``forget()``): what Wi-Fi carried says nothing about cellular.
public struct NetworkSpeed: Sendable, Equatable {

    /// A response: how much, and from when to when (system uptime in seconds).
    public struct Metering: Sendable, Equatable {
        public let bytes: Int
        public let startTime: TimeInterval
        public let end: TimeInterval

        public init(bytes: Int, startTime: TimeInterval, end: TimeInterval) {
            self.bytes = bytes
            self.startTime = startTime
            self.end = end
        }

        public var duration: TimeInterval { end - startTime }
    }

    /// From how many bytes a response counts as a measurement.
    public static let minimumBytes = 16 * 1024
    /// Below this rate the line is slow — the threshold at which a 700 kB manga
    /// page takes longer than six seconds.
    public static let slowBelow = 1.0
    /// From this rate on it is unremarkable again.
    public static let fastFrom = 1.5
    static let window = 6

    private var measurements: [Metering] = []
    private var slow = false

    public init() {}

    /// Records a response — ones that are too small or too short are dropped.
    public mutating func save(bytes: Int, startTime: TimeInterval, end: TimeInterval) {
        guard bytes >= NetworkSpeed.minimumBytes, end - startTime > 0.05 else { return }
        measurements.append(Metering(bytes: bytes, startTime: startTime, end: end))
        if measurements.count > NetworkSpeed.window { measurements.removeFirst() }
        guard let rate = mbit else { return }
        if slow, rate >= NetworkSpeed.fastFrom { slow = false }
        if !slow, rate < NetworkSpeed.slowBelow { slow = true }
    }

    /// A response without a timestamp — queued after the last one, as if loaded one by one.
    public mutating func save(bytes: Int, duration: TimeInterval) {
        let startTime = measurements.last?.end ?? 0
        save(bytes: bytes, startTime: startTime, end: startTime + duration)
    }

    /// A different path, a different line — start over.
    public mutating func forget() {
        measurements = []
        slow = false
    }

    /// The measured rate in megabits per second — `nil` below two measurements.
    ///
    /// **Bytes divided by the time in which anything ran at all** — not by the sum of the
    /// durations. Six covers at once, one second each, are six covers in one second; the sum
    /// would count six seconds and report a sixth of the real rate.
    public var mbit: Double? {
        guard measurements.count >= 2 else { return nil }
        let bytes = measurements.reduce(0) { $0 + $1.bytes }
        var duration = 0.0
        var until = -Double.infinity
        for m in measurements.sorted(by: { $0.startTime < $1.startTime }) {
            let from = max(m.startTime, until)
            if m.end > from { duration += m.end - from }
            until = max(until, m.end)
        }
        guard duration > 0 else { return nil }
        return Double(bytes) * 8 / duration / 1_000_000
    }

    /// What the UI says: slow with a number, otherwise reachable. Whether anything
    /// arrives at all is for the network watch to know — not the speed.
    public var phase: NetworkStatus {
        if slow, let mbit { return .slow(mbit: mbit) }
        return .reachable
    }
}

/// Measures what passes through it — **images and files only**. JSON and XML do not count:
/// for them the duration is the server's compute time, not the line (a page of 1,000 books
/// takes over a second to build, a 50-book request a quarter of a second for 30 kB — which
/// looked like 1 Mbit/s).
public struct MeteringTransport: Transport {

    private let inner: any Transport
    private let report: @Sendable (_ bytes: Int, _ startTime: TimeInterval, _ end: TimeInterval) -> Void

    public init(
        _ inner: any Transport,
        report: @escaping @Sendable (_ bytes: Int, _ startTime: TimeInterval, _ end: TimeInterval) -> Void
    ) {
        self.inner = inner
        self.report = report
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let startTime = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await inner.send(request)
        if MeteringTransport.counts(response) {
            report(data.count, startTime, ProcessInfo.processInfo.systemUptime)
        }
        return (data, response)
    }

    /// Whether a response says anything about the line: images, pages and files yes;
    /// responses of an API (JSON, XML, HTML) no.
    static func counts(_ response: HTTPURLResponse) -> Bool {
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return
            !(type.contains("json") || type.contains("xml") || type.contains("html")
            || type.hasPrefix("text/"))
    }
}

extension MeteringTransport: SessionTransport {
    /// Whoever can stream keeps streaming — the file fetcher and the audio bridge take
    /// the session behind it; those bytes stay unmeasured, while pages and covers
    /// go through ``send(_:)``.
    public func session(for request: URLRequest) -> URLSession? {
        (inner as? URLSession) ?? (inner as? SessionTransport)?.session(for: request)
    }
}
