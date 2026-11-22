import Bedrock
import Foundation
import SourcesKit

/// Fetches a file from the server to disk — piece by piece, with progress, and
/// resumes on servers capable of `Range` where it stopped.
///
/// Through the source's transport (certificate guard, session) and with its header
/// lines; if the transport is a `URLSession`, the bytes stream to disk, otherwise the
/// file arrives all at once — irrelevant for an EPUB of 0.8 MB, for a volume of 74 MB
/// the difference between "runs" and "hangs".
public enum FileFetcher {

    /// - Returns: the bytes on disk at the end.
    static func fetch(
        _ address: URL, headerLines: [String: String], transport: any Transport, to target: URL,
        rangeCapable: Bool, progress: @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: address)
        for (name, value) in headerLines { request.setValue(value, forHTTPHeaderField: name) }
        let present = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if rangeCapable, present > 0 {
            request.setValue("bytes=\(present)-", forHTTPHeaderField: "Range")
        }
        guard
            let session = transport as? URLSession
                ?? (transport as? SessionTransport)?.session(for: request)
        else {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else { throw Failure.status(response.statusCode) }
            try data.write(to: target, options: .atomic)
            progress(Int64(data.count))
            return Int64(data.count)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        let resuming = http.statusCode == 206
        guard resuming || (200..<300).contains(http.statusCode) else {
            throw Failure.status(http.statusCode)
        }
        if !resuming { FileManager.default.createFile(atPath: target.path, contents: nil) }
        let file = try FileHandle(forWritingTo: target)
        defer { try? file.close() }
        if resuming { try file.seekToEnd() } else { try file.truncate(atOffset: 0) }
        var sum: Int64 = resuming ? present : 0
        var puffer = Data()
        puffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            puffer.append(byte)
            if puffer.count >= 256 * 1024 {
                try file.write(contentsOf: puffer)
                sum += Int64(puffer.count)
                puffer.removeAll(keepingCapacity: true)
                progress(sum)
                try Task.checkCancellation()
            }
        }
        if !puffer.isEmpty {
            try file.write(contentsOf: puffer)
            sum += Int64(puffer.count)
        }
        progress(sum)
        return sum
    }

    public enum Failure: Error, Equatable {
        case status(Int)
    }
}
