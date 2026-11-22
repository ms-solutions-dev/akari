import Foundation
import Network
import Synchronization

/// **A finished network request**, as `URLSessionTaskMetrics` describes it — without
/// address, query or headers: only host name and kind of path ("komga.example · Page").
///
/// **Why per request**: whether a page took 8 s because it sat 7.9 s in the session's
/// queue, because the connection was set up anew, or because the server stayed silent
/// for 8 s until the first byte are three different faults with three different fixes.
/// The session's metrics separate them.
public struct NetworkRequest: Sendable, Equatable {
    /// When the request ended.
    public var time: Date
    public var host: String
    public var kind: String
    public var method: String
    /// From the task to the start of the first transfer — the session's queue.
    public var waitMs: Double
    /// DNS, TCP and TLS together; `nil` if the connection was reused.
    public var connectionMs: Double?
    /// From the end of the request to the first byte of the response.
    public var firstByteMs: Double
    /// From the first to the last byte of the response.
    public var transferMs: Double
    public var totalMs: Double
    public var bytes: Int
    /// "h2", "http/1.1", "h3" — or "?".
    public var log: String
    public var reused: Bool
    public var status: Int?
    public var failure: String?
    public var cancelled: Bool

    public init(
        time: Date, host: String, kind: String, method: String, waitMs: Double, connectionMs: Double?,
        firstByteMs: Double, transferMs: Double, totalMs: Double, bytes: Int, log: String,
        reused: Bool, status: Int?, failure: String?, cancelled: Bool
    ) {
        self.time = time
        self.host = host
        self.kind = kind
        self.method = method
        self.waitMs = waitMs
        self.connectionMs = connectionMs
        self.firstByteMs = firstByteMs
        self.transferMs = transferMs
        self.totalMs = totalMs
        self.bytes = bytes
        self.log = log
        self.reused = reused
        self.status = status
        self.failure = failure
        self.cancelled = cancelled
    }

    /// From a finished task of the session. Without metrics (cancelled before the first byte)
    /// the times stay 0; error and bytes are kept anyway.
    public init(task: URLSessionTask, metrics: URLSessionTaskMetrics?, failure: Error?) {
        let address = task.originalRequest?.url
        let last = metrics?.transactionMetrics.last
        let first = metrics?.transactionMetrics.first
        func ms(_ from: Date?, _ until: Date?) -> Double? {
            guard let from, let until else { return nil }
            return until.timeIntervalSince(from) * 1000
        }
        let startTime = metrics?.taskInterval.start
        let reused = last?.isReusedConnection ?? false
        let urlError = failure as? URLError
        self.init(
            time: metrics?.taskInterval.end ?? Date(),
            host: address?.host() ?? "?",
            kind: NetworkRequest.kind(path: address?.path() ?? ""),
            method: task.originalRequest?.httpMethod ?? "GET",
            waitMs: ms(startTime, first?.fetchStartDate) ?? 0,
            connectionMs: reused
                ? nil : ms(last?.domainLookupStartDate ?? last?.connectStartDate, last?.connectEndDate),
            firstByteMs: ms(last?.requestEndDate ?? last?.fetchStartDate, last?.responseStartDate) ?? 0,
            transferMs: ms(last?.responseStartDate, last?.responseEndDate) ?? 0,
            totalMs: (metrics?.taskInterval.duration ?? 0) * 1000,
            bytes: Int(task.countOfBytesReceived),
            log: last?.networkProtocolName ?? "?",
            reused: reused,
            status: (task.response as? HTTPURLResponse)?.statusCode,
            failure: failure.map { NetworkRequest.short($0) },
            cancelled: urlError?.code == .cancelled)
    }

    /// The kind of path, without identifiers: "Page", "Cover", "File", "API", "other".
    public static func kind(path: String) -> String {
        let p = path.lowercased()
        if p.contains("/pages/") || p.hasSuffix("/pages") || p.contains("/page/") { return "Page" }
        if p.contains("thumbnail") || p.contains("cover") || p.contains("/image") { return "Cover" }
        for fileExtension in [".epub", ".cbz", ".cbr", ".pdf", ".m4b", ".mp3", ".m4a", ".zip"]
        where p.hasSuffix(fileExtension) {
            return "File"
        }
        if p.contains("/file") || p.contains("/download") || p.contains("/stream") { return "File" }
        if p.contains("/api/") || p.contains("/opds") { return "API" }
        return "other"
    }

    static func short(_ failure: Error) -> String {
        guard let u = failure as? URLError else { return String(describing: Swift.type(of: failure)) }
        switch u.code {
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "no network"
        case .networkConnectionLost: return "connection lost"
        case .cannotConnectToHost: return "server unreachable"
        case .cannotFindHost: return "name not resolved"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS"
        default: return "URLError \(u.code.rawValue)"
        }
    }

    /// "komga.example · Page 200 h2 112 KB: Wait 5 ms, New connection 38 ms, 1st byte 180 ms,
    /// Transfer 40 ms, total 230 ms" (example output).
    public var text: String {
        var share = [String(format: "Wait %.0f ms", waitMs)]
        if let connectionMs { share.append(String(format: "New connection %.0f ms", connectionMs)) }
        share.append(String(format: "1st byte %.0f ms", firstByteMs))
        share.append(String(format: "Transfer %.0f ms", transferMs))
        share.append(String(format: "total %.0f ms", totalMs))
        let header =
            "\(host) · \(kind) \(status.map(String.init) ?? "–") \(log) \(bytes / 1024) KB"
            + (failure.map { " · \($0)" } ?? "")
        return header + ": " + share.joined(separator: ", ")
    }

    public static let csvHeader =
        "time;host;kind;method;wait_ms;connection_ms;first_byte_ms;transfer_ms;total_ms;bytes;"
        + "protocol;reused;status;error;cancelled"

    public var csvRow: String {
        [
            time.formatted(
                Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true)), host,
            kind, method,
            String(format: "%.1f", waitMs), connectionMs.map { String(format: "%.1f", $0) } ?? "",
            String(format: "%.1f", firstByteMs), String(format: "%.1f", transferMs),
            String(format: "%.1f", totalMs), "\(bytes)", log, reused ? "1" : "0",
            status.map(String.init) ?? "", failure ?? "", cancelled ? "1" : "0",
        ].joined(separator: ";")
    }

    public static func csv(_ requests: [NetworkRequest]) -> String {
        ([csvHeader] + requests.map(\.csvRow)).joined(separator: "\n") + "\n"
    }
}

/// **What went over the wire in the interval** — collected from the requests, emptied at
/// each measurement point. The median time to first byte says whether the server dawdles,
/// the number of running requests whether the queue is full.
struct NetworkLoad: Sendable, Equatable {
    var done = 0
    var bytes = 0
    var firstByte: [Double] = []
    var aborts = 0
    var failure = 0

    mutating func save(_ a: NetworkRequest) {
        done += 1
        bytes += a.bytes
        if a.cancelled {
            aborts += 1
        } else if a.failure != nil {
            failure += 1
        } else {
            firstByte.append(a.firstByteMs)
        }
    }

    var firstByteMedian: Double {
        guard !firstByte.isEmpty else { return 0 }
        let s = firstByte.sorted()
        return s[s.count / 2]
    }

    var firstByteMax: Double { firstByte.max() ?? 0 }
}

/// **The network path** from `NWPathMonitor`, as a word: "WLAN", "WLAN + Tunnel", "Mobil (teuer)",
/// "kein Netz". Runs only while recording — a small watcher of its own so that the
/// diagnostics need no app package.
///
/// The tunnel is recognized via the `utun` interface; whatever carries it underneath (Wi-Fi,
/// cellular, cable) determines the path — a tunnel without a carrier is "kein Netz"
/// (WireGuard keeps its route in airplane mode).
final class NetworkPathWatch: Sendable {
    private let watch = Mutex<NWPathMonitor?>(nil)
    private let route = Mutex("unknown")
    private let report: @Sendable (String) -> Void

    init(report: @escaping @Sendable (String) -> Void) {
        self.report = report
    }

    var current: String { route.withLock { $0 } }

    func launch() {
        let new = NWPathMonitor()
        let old = watch.withLock { w -> NWPathMonitor? in
            defer { w = new }
            return w
        }
        old?.cancel()
        new.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let text = NetworkPathWatch.text(
                status: path.status, interfaces: path.availableInterfaces.map(\.type),
                names: path.availableInterfaces.map(\.name), expensive: path.isExpensive,
                sparing: path.isConstrained)
            let changed = self.route.withLock { w -> Bool in
                defer { w = text }
                return w != text
            }
            if changed { self.report(text) }
        }
        new.start(queue: DispatchQueue(label: "akari" + ".diagnose.netzpfad", qos: .utility))
    }

    func stop() {
        watch.withLock { w in
            w?.cancel()
            w = nil
        }
    }

    /// The translation as a rule, without `NWPath`, so that it can be tested.
    static func text(
        status: NWPath.Status, interfaces: [NWInterface.InterfaceType], names: [String], expensive: Bool,
        sparing: Bool
    ) -> String {
        let tunnel = names.contains { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") }
        let carrier: String? =
            interfaces.contains(.wifi)
            ? "Wi-Fi"
            : interfaces.contains(.cellular)
                ? "Cellular" : interfaces.contains(.wiredEthernet) ? "Wired" : nil
        guard status == .satisfied, let carrier else { return "no network" }
        var text = carrier
        if tunnel { text += " + Tunnel" }
        var extra: [String] = []
        if expensive { extra.append("expensive") }
        if sparing { extra.append("constrained") }
        if !extra.isEmpty { text += " (" + extra.joined(separator: ", ") + ")" }
        return text
    }
}
