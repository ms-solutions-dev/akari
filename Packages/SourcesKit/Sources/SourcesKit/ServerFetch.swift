import Bedrock
import Foundation

/// The one verb through which a kit talks to its server.
///
/// In operation a `URLSession` stands behind it; in tests a
/// `MockTransport` that delivers the recorded responses from `Tests/Fixtures`.
/// The kits do not know the difference — which is why they can be checked on the
/// computer in seconds, against what the servers really said.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A transport that stands in front of a `URLSession` and hands it out — whoever fetches a
/// large file to disk then streams over the session, instead of taking it through
/// the switch into memory all at once (WebDAV).
public protocol SessionTransport: Transport {
    /// The session for this request — `nil` if the switch has to answer it itself
    /// (a cover from an archive), in which case it stays with ``Transport/send(_:)``.
    func session(for request: URLRequest) -> URLSession?
}

extension URLSession: Transport {
    /// With the ``NetworkObservation/Collector`` as delegate of the task, if anyone is listening — so
    /// the diagnostics get queue, connection and first byte of every request; the outcome
    /// is reported by this method, because the delegate does not learn it.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let collector = NetworkObservation.collector()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request, delegate: collector)
        } catch {
            collector?.complete(failure: error)
            throw error
        }
        collector?.complete(failure: nil)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The session for a source: with the certificate watch for `*.example`, without
    /// waiting for network, with an idle limit that the tunnel can bear.
    ///
    /// **30 s idle, not 30 s in total:** `timeoutIntervalForRequest` counts
    /// between two data packets. A 1.3 MB extract takes a good 30 s in the tunnel —
    /// but the bytes trickle in, and as long as they trickle, nothing expires.
    /// If the server stays silent for 30 s, it is unreachable, not slow.
    public static func forSource(trusts: CertificateTrustStore = CertificateTrustStore()) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration, delegate: CertificateWatch(trusts: trusts), delegateQueue: nil)
    }
}

/// Builds requests, sends them through the ``Transport`` and translates what
/// comes back into ``SourceError`` — the one place where three kits read
/// the same number the same way.
///
/// What a kit puts in: the base address, the identifier for the
/// error messages and the sign-in headers. What it gets out: data
/// or an error with a direction — never a `URLError`, never a `DecodingError`.
public struct ServerFetch: Sendable {
    public let baseURL: URL
    public let source: SourceID
    public let transport: any Transport

    public init(baseURL: URL, source: SourceID, transport: any Transport) {
        self.baseURL = baseURL
        self.source = source
        self.transport = transport
    }

    /// A request to a path below the base — `path` without a leading
    /// slash, query and body as needed.
    public func request(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
        headerLines: [String: String] = [:]
    ) -> URLRequest {
        var address = baseURL.appending(path: path)
        if !query.isEmpty { address.append(queryItems: query) }
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headerLines { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// A request with a JSON body from an `Encodable`.
    public func request<Body: Encodable>(
        _ path: String, method: String, json body: Body, query: [URLQueryItem] = [],
        headerLines: [String: String] = [:]
    ) throws -> URLRequest {
        let data = try JSONEncoder().encode(body)
        return request(path, method: method, query: query, body: data, headerLines: headerLines)
    }

    /// Sends the request and returns data — or throws a
    /// ``SourceError`` with a direction. `title` turns a 404 into "not
    /// found" instead of "unreadable".
    public func data(
        _ request: URLRequest, title: TitleID? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let start = Date()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            let failure = SourceError.from(error, source: source)
            Diagnostics.deficiency(
                "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "?") → \(failure.messageKey)",
                since: start,
                area: "Source")
            throw failure
        }
        if let failure = SourceError.from(status: response.statusCode, source: source, title: title) {
            Diagnostics.deficiency(
                "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "?") → \(response.statusCode)",
                since: start,
                area: "Source")
            throw failure
        }
        Diagnostics.verbose(
            "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "?") → \(response.statusCode), \(data.count) B",
            since: start, area: "Source")
        return (data, response)
    }

    /// Sends the request and reads JSON — a body that does not match the type
    /// is ``SourceError/unreadable(_:_:)``: a version question, not a network question.
    public func json<Answer: Decodable>(
        _ type: Answer.Type, _ request: URLRequest, decoder: JSONDecoder = ServerFetch.decoder,
        title: TitleID? = nil
    ) async throws -> Answer {
        let (data, _) = try await self.data(request, title: title)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SourceError.unreadable(source, Self.short(error))
        }
    }

    /// The decoder for all three: ISO 8601 with and without fractional seconds — Komga
    /// writes `…:09Z`, Grimmory `…:49Z`, ABS milliseconds as a number (the kit
    /// reads those itself).
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.withFractions.date(from: text) ?? Self.withoutFractions.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No date: \(text)")
            )
        }
        return decoder
    }()

    nonisolated(unsafe) private static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let withoutFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The decoding error in one line for the trace — path and reason, no
    /// addresses.
    static func short(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: Swift.type(of: error)) }
        switch decoding {
        case .keyNotFound(let key, let ctx):
            return "Field missing: \(path(ctx.codingPath))\(key.stringValue)"
        case .typeMismatch(_, let ctx):
            return "Type mismatch: \(path(ctx.codingPath))\(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            return "Value missing: \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):
            return "Not JSON: \(ctx.debugDescription)"
        @unknown default:
            return "Unreadable"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.isEmpty ? "" : codingPath.map(\.stringValue).joined(separator: ".") + "."
    }
}
