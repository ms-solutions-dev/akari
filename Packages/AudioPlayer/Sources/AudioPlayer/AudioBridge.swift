import Bedrock
import Foundation
import Network
import SourcesKit

/// The bridge between AVPlayer and the home server: an HTTP server only on
/// `127.0.0.1` that fetches every track via the source's transport - with its
/// certificate guard and header lines - and passes partial requests (`Range`) through.
///
/// **Why a bridge:** AVPlayer fetches audio itself and consults no
/// `URLSession` delegate - it does not trust the mkcert certificate of
/// the audiobook host, and cannot carry the token in the header.
/// Installing the root on every device would be a setup per phone;
/// the reverse proxy has no `http://`. The approach from CineLounge
/// (`LocalMediaServer`) works: for AVFoundation it is ordinary HTTP, and
/// the address never leaves the device.
public final class AudioBridge: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "akari.tonbruecke")
    private let lock = NSLock()
    private var tracks: [URL] = []
    private let headerLines: [String: String]
    private let transport: any Transport
    public private(set) var port: UInt16 = 0

    public enum Failure: Error {
        case noConnection
    }

    public init(headerLines: [String: String], transport: any Transport) throws {
        self.headerLines = headerLines
        self.transport = transport
        let parameter = NWParameters.tcp
        parameter.requiredInterfaceType = .loopback
        parameter.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameter, on: .any)
    }

    /// Starts and returns the port.
    public func launch() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let headerBuffer = HeaderBuffer()
            listener.stateUpdateHandler = { [weak self] phase in
                guard let self, !headerBuffer.done else { return }
                switch phase {
                case .ready:
                    headerBuffer.done = true
                    port = listener.port?.rawValue ?? 0
                    continuation.resume(returning: port)
                case .failed(let failure):
                    headerBuffer.done = true
                    continuation.resume(throwing: failure)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    /// The tracks the bridge knows - the address per track is `/spur/<index>`.
    public func set(tracks new: [URL]) {
        lock.withLock { tracks = new }
    }

    public func address(track index: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/spur/\(index)")!
    }

    // MARK: - One connection

    /// Everything a callback of the connection touches runs on `queue` - the
    /// header buffer makes that explicit to the compiler.
    private final class HeaderBuffer: @unchecked Sendable {
        var done = false
        var buffer = Data()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, HeaderBuffer())
    }

    private func readHeader(_ connection: NWConnection, _ headerBuffer: HeaderBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, end, failure in
            guard let self else { return }
            if let data { headerBuffer.buffer.append(data) }
            if let area = headerBuffer.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: headerBuffer.buffer[..<area.lowerBound], as: UTF8.self)
                Task { await self.answer(header, via: connection) }
            } else if end || failure != nil || headerBuffer.buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                readHeader(connection, headerBuffer)
            }
        }
    }

    /// Parses the request, fetches upstream, writes downstream.
    private func answer(_ header: String, via connection: NWConnection) async {
        let lines = header.split(separator: "\r\n").map(String.init)
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        guard request.count >= 2 else {
            connection.cancel()
            return
        }
        let method = request[0]
        let path = request[1]
        var area: String?
        for line in lines.dropFirst() {
            let share = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if share.count == 2, share[0].lowercased() == "range" { area = share[1] }
        }
        let index = Int(path.split(separator: "/").last ?? "") ?? -1
        let target: URL? = lock.withLock { tracks.indices.contains(index) ? tracks[index] : nil }
        guard let target, path.hasPrefix("/spur/") else {
            write(
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", via: connection)
            try? await close(connection)
            connection.cancel()
            return
        }
        var top = URLRequest(url: target)
        for (name, value) in headerLines { top.setValue(value, forHTTPHeaderField: name) }
        // HEAD: the size from a one-byte request, without fetching the body.
        top.setValue(method == "HEAD" ? "bytes=0-0" : area, forHTTPHeaderField: "Range")
        do {
            if let session = transport as? URLSession
                ?? (transport as? SessionTransport)?.session(for: top)
            {
                try await forward(top, session: session, method: method, via: connection)
            } else {
                try await forwardWhole(top, method: method, area: area, via: connection)
            }
        } catch {
            Diagnostics.network.error("Audio bridge: \(String(describing: error), privacy: .public)")
        }
        // End cleanly (FIN), do not abort - otherwise the player loses the
        // last bytes and reports "connection lost".
        try? await close(connection)
        connection.cancel()
    }

    /// Via a `URLSession`: pass the header through, forward bytes piece by piece.
    private func forward(
        _ top: URLRequest, session: URLSession, method: String, via connection: NWConnection
    )
        async throws
    {
        let (bytes, response) = try await session.bytes(for: top)
        guard let http = response as? HTTPURLResponse else { return }
        var status = http.statusCode
        var length = http.value(forHTTPHeaderField: "Content-Length")
        var area = http.value(forHTTPHeaderField: "Content-Range")
        if method == "HEAD", let total = area?.split(separator: "/").last {
            status = 200
            length = String(total)
            area = nil
        }
        write(
            AudioBridge.header(
                status: status, type: http.value(forHTTPHeaderField: "Content-Type"), length: length,
                area: area),
            via: connection)
        guard method != "HEAD" else { return }
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                try await send(chunk, via: connection)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await send(chunk, via: connection) }
    }

    /// Via another transport (mock): fetch everything, cut the range itself.
    private func forwardWhole(
        _ top: URLRequest, method: String, area: String?, via connection: NWConnection
    )
        async throws
    {
        var request = top
        request.setValue(nil, forHTTPHeaderField: "Range")
        let (data, http) = try await transport.send(request)
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let total = data.count
        if method == "HEAD" {
            write(
                AudioBridge.header(status: 200, type: type, length: String(total), area: nil),
                via: connection)
            return
        }
        if let (from, until) = AudioBridge.area(area, total: total) {
            write(
                AudioBridge.header(
                    status: 206, type: type, length: String(until - from + 1),
                    area: "bytes \(from)-\(until)/\(total)"),
                via: connection)
            try await send(data[from...until], via: connection)
        } else {
            write(
                AudioBridge.header(status: 200, type: type, length: String(total), area: nil),
                via: connection)
            try await send(data, via: connection)
        }
    }

    /// `bytes=a-b`, `bytes=a-`, `bytes=-n` -> (from, to) within the size.
    static func area(_ text: String?, total: Int) -> (Int, Int)? {
        guard let text, text.hasPrefix("bytes="), total > 0 else { return nil }
        let share = text.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard share.count == 2 else { return nil }
        let a = Int(share[0])
        let b = Int(share[1])
        switch (a, b) {
        case (let a?, let b?): return a <= b && a < total ? (a, min(b, total - 1)) : nil
        case (let a?, nil): return a < total ? (a, total - 1) : nil
        case (nil, let n?): return n > 0 ? (max(total - n, 0), total - 1) : nil
        default: return nil
        }
    }

    static func header(status: Int, type: String?, length: String?, area: String?) -> String {
        var lines = [
            "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : status == 200 ? "OK" : "Error")"
        ]
        lines.append("Content-Type: \(type ?? "application/octet-stream")")
        if let length { lines.append("Content-Length: \(length)") }
        if let area { lines.append("Content-Range: \(area)") }
        lines.append("Accept-Ranges: bytes")
        lines.append("Cache-Control: no-store")
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func write(_ text: String, via connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func close(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { failure in
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                })
        }
    }

    private func send(_ data: Data, via connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { failure in
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                })
        }
    }
}
