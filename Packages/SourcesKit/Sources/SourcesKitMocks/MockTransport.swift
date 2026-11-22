import Foundation
import SourcesKit
import Synchronization

/// A ``Transport`` that delivers the recorded responses instead of a server —
/// and remembers what was asked.
///
/// The kits talk to it as to `URLSession`. A response is registered per method
/// and path; several responses to the same path come in order
/// (the last one stays), so that an expired token and the fetch
/// after it can be replayed. A request without a registered response is a
/// test failure, not an empty response: a kit that calls a path nobody
/// expected should stand out.
///
/// ``answer(_:_:file:from:)`` reads the recording from `Tests/Fixtures`:
/// the body from the file, the status from the first line of the `.headers`
/// beside it — so the test carries the status the server really gave.
public final class MockTransport: Transport, Sendable {

    public struct Answer: Sendable {
        public var status: Int
        public var data: Data
        public var headerLines: [String: String]

        public init(status: Int = 200, data: Data = Data(), headerLines: [String: String] = [:]) {
            self.status = status
            self.data = data
            self.headerLines = headerLines
        }

        public static func json(_ text: String, status: Int = 200) -> Answer {
            Answer(status: status, data: Data(text.utf8), headerLines: ["Content-Type": "application/json"])
        }
    }

    /// A request for which no response was registered.
    public struct Unexpected: Error, CustomStringConvertible {
        public let method: String
        public let path: String
        public var description: String { "Unexpected request: \(method) \(path)" }
    }

    private struct EntryKey: Hashable {
        let method: String
        let path: String

        func matches(_ request: String) -> Bool {
            path.hasSuffix("*") ? request.hasPrefix(path.dropLast()) : request == path
        }
    }

    private struct Phase {
        var answers: [EntryKey: [Result<Answer, URLError>]] = [:]
        var requests: [URLRequest] = []
        var outage: URLError.Code?
        var delay: Duration = .zero
    }

    private let phase = Mutex(Phase())

    public init() {}

    /// Registers a response. `path` is the path without a query; if it ends in
    /// `*`, it counts as a prefix.
    public func answer(_ method: String = "GET", _ path: String, with response: Answer) {
        phase.withLock {
            $0.answers[EntryKey(method: method, path: path), default: []].append(.success(response))
        }
    }

    /// Registers the recording `file` (plus `file.headers`) from the
    /// `Fixtures` folder of the test bundle.
    public func answer(_ method: String = "GET", _ path: String, file: String, from bundle: Bundle) throws {
        answer(method, path, with: try Self.recording(file, from: bundle))
    }

    /// Makes the request fail with a transport error — timeout,
    /// no network.
    public func fail(_ method: String = "GET", _ path: String, with failure: URLError.Code) {
        phase.withLock {
            $0.answers[EntryKey(method: method, path: path), default: []].append(
                .failure(URLError(failure)))
        }
    }

    /// Makes **every** request fail with this transport error until `nil` lifts
    /// the outage — the network that drops in the middle of a volume and comes back later.
    /// The registered responses stay in place; afterwards the transport answers again.
    public func set(outage: URLError.Code?) {
        phase.withLock { $0.outage = outage }
    }

    /// Whether everything is currently failing.
    public var outage: URLError.Code? {
        phase.withLock { $0.outage }
    }

    /// Makes every response wait this long — the tunnel at 0.3 Mbit/s, where
    /// a manga page takes 19 s. The probe measures its network speed by it.
    public func set(delay: Duration) {
        phase.withLock { $0.delay = delay }
    }

    /// Everything that has been asked so far, in order.
    public var requests: [URLRequest] {
        phase.withLock { $0.requests }
    }

    /// The paths of the requests — for a `#expect` in one line.
    public var paths: [String] {
        requests.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path() ?? "") }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path() ?? ""
        let (outage, delay) = phase.withLock { ($0.outage, $0.delay) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let outage { throw URLError(outage) }
        let result: Result<Answer, URLError> = try phase.withLock { phase in
            phase.requests.append(request)
            // The longest matching path wins: `/api/v1/books/*` catches all pages,
            // `/api/v1/books/7/content` only that one book — dictionaries have no
            // order, otherwise chance would decide.
            guard
                let key = phase.answers.keys.filter({ $0.method == method && $0.matches(path) })
                    .max(by: { $0.path.count < $1.path.count })
            else { throw Unexpected(method: method, path: path) }
            var list = phase.answers[key]!
            let next = list.removeFirst()
            if list.isEmpty { list = [next] }
            phase.answers[key] = list
            return next
        }
        let response = try result.get()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/2",
            headerFields: response.headerLines)!
        return (response.data, http)
    }

    /// Reads body and status of a recording.
    public static func recording(_ file: String, from bundle: Bundle) throws -> Answer {
        guard let url = bundle.url(forResource: file, withExtension: nil, subdirectory: "Fixtures") else {
            throw Unexpected(method: "Fixture", path: file)
        }
        let data = try Data(contentsOf: url)
        var status = 200
        var headerLines: [String: String] = [:]
        if let header = try? String(contentsOf: url.appendingPathExtension("headers"), encoding: .utf8) {
            // curl writes `\r\n`, and Swift reads that as ONE character — a `split` at
            // `"\n"` would then find no line, and the header lines would stay empty (when
            // WebDAV needed the `Content-Range` from the recording).
            for line in header.components(separatedBy: .newlines).map({
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }) {
                if line.hasPrefix("HTTP/"),
                    let integer = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
                {
                    status = integer
                } else if let colon = line.firstIndex(of: ":") {
                    headerLines[String(line[..<colon])] = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return Answer(status: status, data: data, headerLines: headerLines)
    }
}
