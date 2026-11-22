import Bedrock
import Device
import Foundation
import SourcesKit

/// The transport of the WebDAV sources — a switch in front of the session: addresses with the
/// fragment `#cover` or `#seite=N` do not mean the file but something **in** it, and the switch
/// fetches that as a range from the archive. Everything else (PROPFIND, the file for keeping or
/// the reader) passes through unchanged.
///
/// **Why a switch and not files in a cache:** The image loader and the page loader know only
/// address, header lines and transport — exactly the interface that is here. A cover is thus
/// fetched only when a tile shows it, and afterwards lives in the image loader like any other;
/// the pages of a CBZ arrive one by one, as with Komga, without the volume having to be there
/// completely beforehand.
///
/// What the range needs — the location of the cover, the list of pages — is in the
/// ``BackfillStore``; if the finding is missing, the switch does the backfill now. The fragment
/// part is never sent to the server.
public final class WebdavSwitch: Transport, SessionTransport, Sendable {

    public let network: any Transport
    let persistence: BackfillStore

    public init(network: any Transport, persistence: BackfillStore = .standard) {
        self.network = network
        self.persistence = persistence
    }

    /// The session behind it — the file fetcher streams whole files to disk with it; a cover or a
    /// page (fragment) is answered by the switch itself.
    public func session(for request: URLRequest) -> URLSession? {
        WebdavSwitch.fragment(request.url) == nil ? network as? URLSession : nil
    }

    /// The fragment the switch understands — otherwise `nil`.
    static func fragment(_ url: URL?) -> String? {
        guard let url, !url.isFileURL, let fragment = url.fragment,
            fragment == "cover" || fragment.hasPrefix("seite=")
        else { return nil }
        return fragment
    }

    /// `#cover` on a file address.
    public static func cover(_ file: URL) -> URL {
        URL(string: "#cover", relativeTo: file)?.absoluteURL ?? file
    }

    /// `#seite=N` on a file address, N 1-based.
    public static func page(_ n: Int, from file: URL) -> URL {
        URL(string: "#seite=\(n)", relativeTo: file)?.absoluteURL ?? file
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let address = request.url, let fragment = WebdavSwitch.fragment(address) else {
            return try await network.send(request)
        }
        var share = URLComponents(url: address, resolvingAgainstBaseURL: true)
        share?.fragment = nil
        guard let file = share?.url, let type = FileType(name: file.lastPathComponent) else {
            return (Data(), WebdavSwitch.response(address, status: 404))
        }
        let reader = RangeReader(
            transport: network,
            headerLines: (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "range" })
        var finding = persistence.finding(file)
        if finding == nil {
            let new = try await Backfill.extract(file, type: type, etag: nil, size: nil, reader: reader)
            persistence.save(new, for: file)
            persistence.secure()
            finding = new
        }
        guard let finding, let size = finding.size else {
            return (Data(), WebdavSwitch.response(address, status: 404))
        }
        let entry: Zip.Item?
        if fragment == "cover" {
            entry = finding.cover
        } else if let n = Int(fragment.dropFirst("seite=".count)), let pages = finding.pages,
            pages.indices.contains(n - 1)
        {
            entry = pages[n - 1]
        } else {
            entry = nil
        }
        guard let entry else { return (Data(), WebdavSwitch.response(address, status: 404)) }
        let content = try await reader.content(entry, from: file, size: Int(size))
        return (
            content,
            WebdavSwitch.response(
                address, status: 200,
                headerLines: [
                    "Content-Type": WebdavSwitch.contentType(entry.name),
                    "Content-Length": String(content.count),
                ])
        )
    }

    static func response(_ url: URL, status: Int, headerLines: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headerLines)!
    }

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "avif": "image/avif"
        case "heic": "image/heic"
        default: "application/octet-stream"
        }
    }
}
