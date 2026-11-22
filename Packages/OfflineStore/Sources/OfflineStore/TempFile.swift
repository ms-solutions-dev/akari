import Bedrock
import CryptoKit
import Foundation
import SourcesKit

/// A file in the cache — a book the reader needs right now, without it being kept.
/// Lies under `Zwischenspeicher/buecher/<digest>`, is fetched on opening and may be
/// evicted by the system.
///
/// A cancellation leaves `.teil` behind, and the next attempt resumes with `Range`
/// where it stopped (0.8 MB median, 22 seconds through the tunnel — a restart from
/// scratch would be double).
public enum TempFile {

    public static var folder: URL { Cache.folder.appending(path: "buecher") }

    /// Where the file for `address` lies or would lie.
    public static func path(for address: URL) -> URL {
        let digest = SHA256.hash(data: Data(address.absoluteString.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let fileExtension = address.pathExtension.isEmpty ? "" : "." + address.pathExtension
        return folder.appending(path: name + fileExtension)
    }

    /// The file lies there, complete.
    public static func present(_ address: URL) -> Bool {
        FileManager.default.fileExists(atPath: path(for: address).path)
    }

    /// Fetches the file if it is missing — `progress` in bytes and fraction (0…1, or 0
    /// if the size is unknown).
    public static func fetch(
        _ address: URL, size: Int64?, rangeCapable: Bool, headerLines: [String: String],
        transport: any Transport, progress: @escaping @Sendable (Int64, Double) -> Void = { _, _ in }
    ) async throws -> URL {
        let target = path(for: address)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let start = Date()
        let teil = target.appendingPathExtension("teil")
        let bytes = try await FileFetcher.fetch(
            address, headerLines: headerLines, transport: transport, to: teil, rangeCapable: rangeCapable
        ) { soFar in
            progress(soFar, size.map { min(Double(soFar) / Double(max($0, 1)), 0.99) } ?? 0)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: teil, to: target)
        progress(bytes, 1)
        Diagnostics.step("Book fetched: \(bytes / 1024) KB", since: start, area: "Stock")
        return target
    }
}
