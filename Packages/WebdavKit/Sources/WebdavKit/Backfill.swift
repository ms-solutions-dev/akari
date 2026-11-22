import Bedrock
import Device
import Foundation
import SourcesKit
import Synchronization

/// What a file says about itself without anybody fetching all of it — the backfill behind the
/// catalog crawl.
///
/// **Ranges instead of files:** An EPUB is a ZIP, and the directory of a ZIP is at the end. The
/// last 64 KB fetched via `Range`, the directory read, then `META-INF/container.xml`, the OPF
/// and the cover as one range each — for a 2 MB book about 80 KB instead of 2 MB, through a
/// tunnel at 0.3 Mbit/s two seconds instead of a minute. For a CBZ the directory suffices: it
/// names the pages, the first is the cover, and each page later is a range of its own.
///
/// **What does not work is no error:** If the server answers 200 instead of 206, it does not
/// understand ranges — then it stays with the path name without cover, and the finding
/// remembers that so the next round does not ask again. PDF and CBR stay without backfill: a
/// PDF does not reveal its cover in one range, the app does not read RAR.
public enum Backfill {

    /// The finding for a file, in the store under its address — with ETag and size as a seal: if the
    /// file changes, the finding no longer applies.
    public struct Finding: Sendable, Hashable, Codable {
        public var etag: String?
        public var size: Int64?
        public var name: String?
        public var authors: [String] = []
        public var bookSeries: String?
        public var volume: Double?
        public var language: String?
        public var publisher: String?
        public var summary: String?
        /// The cover as an entry in the archive — a range when it is needed.
        public var cover: Zip.Item?
        /// The pages of a CBZ in reading order — each a range for the page stream.
        public var pages: [Zip.Item]?
        /// The file is not a readable archive, or the server cannot do ranges — do not try again;
        /// after a week it may be asked again.
        public var futile = false
        /// The server ignored the range and sent the whole file — then this holds for all files there,
        /// and the backfill stops.
        public var noAreas = false
        public var state: Date

        static let retryAfter: TimeInterval = 7 * 24 * 3600

        public init(etag: String?, size: Int64?, state: Date = Date()) {
            self.etag = etag
            self.size = size
            self.state = state
        }

        /// Whether the finding still fits the file — ETag, otherwise size; a futile finding expires
        /// after a week.
        public func isValid(etag: String?, size: Int64?) -> Bool {
            if futile, Date().timeIntervalSince(state) > Finding.retryAfter { return false }
            if let etag, let own = self.etag { return etag == own }
            if let size, let own = self.size { return size == own }
            return true
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case etag
            case size = "groesse"
            case name
            case authors = "autoren"
            case bookSeries = "reihe"
            case volume = "band"
            case language = "sprache"
            case publisher = "verlag"
            case summary = "zusammenfassung"
            case cover
            case pages = "seiten"
            case futile = "vergeblich"
            case noAreas = "keineBereiche"
            case state = "stand"
        }
    }

    /// A server that answers `Range` with 200 and the whole file.
    public struct NoAreas: Error {}

    /// Reads what the file yields. Throws only on transport errors — a ``Finding/futile`` finding is
    /// an answer, not an error.
    public static func extract(
        _ address: URL, type: FileType, etag: String?, size: Int64?, reader: RangeReader
    ) async throws -> Finding {
        var finding = Finding(etag: etag, size: size)
        guard type == .epub || type == .cbz else {
            finding.futile = true
            return finding
        }
        let start = Date()
        do {
            let (tail, length) = try await reader.tail(address, size: size.map(Int.init))
            finding.size = Int64(length)
            var remote: Zip.Remote
            do {
                remote = try Zip.Remote(tail: tail, size: length)
            } catch Zip.Failure.tailTooShort(let needed)
                where needed <= RangeReader.atMostTail
            {
                let (more, _) = try await reader.tail(address, size: length, length: needed)
                remote = try Zip.Remote(tail: more, size: length)
            }
            switch type {
            case .epub: try await epub(remote, address: address, reader: reader, in: &finding)
            case .cbz: cbz(remote, in: &finding)
            default: break
            }
            Diagnostics.verbose(
                "WebDAV backfill \(address.lastPathComponent): \(finding.name ?? "—"), cover \(finding.cover != nil ? "yes" : "no")",
                since: start, area: "Source")
        } catch is NoAreas {
            Diagnostics.deficiency(
                "WebDAV: \(address.host() ?? "?") does not understand range fetches — cover and OPF stay off",
                since: start, area: "Source")
            finding.futile = true
            finding.noAreas = true
        } catch let failure as Zip.Failure {
            Diagnostics.deficiency(
                "WebDAV backfill \(address.lastPathComponent): not a readable archive (\(failure))",
                since: start,
                area: "Source")
            finding.futile = true
        }
        return finding
    }

    static func epub(
        _ remote: Zip.Remote, address: URL, reader: RangeReader, in finding: inout Finding
    ) async throws {
        guard let container = remote.entry("META-INF/container.xml") else {
            finding.futile = true
            return
        }
        let containerData = try await reader.content(container, from: address, remote: remote)
        guard let opfPath = Opf.rootfile(containerData), let opfEntry = remote.entry(opfPath) else {
            finding.futile = true
            return
        }
        let opf = Opf(try await reader.content(opfEntry, from: address, remote: remote))
        if let title = opf.title, !title.isEmpty { finding.name = title }
        finding.authors = opf.authors
        finding.language = opf.language
        finding.publisher = opf.publisher
        finding.summary = opf.descriptionText.map(FileMetadata.withoutTags)
        if let bookSeries = opf.bookSeries, !bookSeries.isEmpty {
            finding.bookSeries = bookSeries
            finding.volume = opf.volume
        }
        if let path = opf.coverPath(opfPath: opfPath) {
            finding.cover = remote.entry(path) ?? remote.entries.first { $0.name.hasSuffix(path) }
        }
    }

    static func cbz(_ remote: Zip.Remote, in finding: inout Finding) {
        let pages = FileMetadata.pages(remote.entries)
        guard !pages.isEmpty else {
            finding.futile = true
            return
        }
        finding.pages = pages
        finding.cover = pages.first
    }
}

/// The backfill findings, one JSON file for all WebDAV folders under the cache — keyed by the
/// address of the file, so that the source and the image transport (which knows only addresses)
/// read the same store.
///
/// It is written not on every finding but when the caller says ``secure()`` — the backfill
/// writes after every handful, not after every book.
public final class BackfillStore: Sendable {

    private let file: URL?
    private let content: Mutex<[String: Backfill.Finding]>

    /// The app's one store — source and image transport share it.
    public static let standard = BackfillStore(file: BackfillStore.defaultFile)

    public static var defaultFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "webdav/nachlese.json")
    }

    public init(file: URL?) {
        self.file = file
        var loaded: [String: Backfill.Finding] = [:]
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([String: Backfill.Finding].self, from: data)) ?? [:]
        }
        content = Mutex(loaded)
    }

    public func finding(_ address: URL) -> Backfill.Finding? {
        content.withLock { $0[BackfillStore.lookupKey(address)] }
    }

    /// The finding if it still fits the file.
    public func finding(_ address: URL, etag: String?, size: Int64?) -> Backfill.Finding? {
        guard let b = finding(address), b.isValid(etag: etag, size: size) else { return nil }
        return b
    }

    public func save(_ finding: Backfill.Finding, for address: URL) {
        content.withLock { $0[BackfillStore.lookupKey(address)] = finding }
    }

    public var count: Int { content.withLock { $0.count } }

    public func secure() {
        guard let file else { return }
        let state = content.withLock { $0 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: file, options: .atomic)
        } catch {
            Diagnostics.deficiency("WebDAV backfill not saved: \(error)", since: nil, area: "Source")
        }
    }

    /// The address without fragment — `#cover` and `#seite=3` mean the same file.
    static func lookupKey(_ address: URL) -> String {
        var share = URLComponents(url: address, resolvingAgainstBaseURL: true)
        share?.fragment = nil
        return share?.string ?? address.absoluteString
    }
}

/// Fetches ranges of a file via HTTP `Range` — the bytes that ``Zip/Remote`` asks for.
///
/// A server that answers 200 instead of 206 ignored the range and sent the whole file; that is
/// ``Backfill/NoAreas`` — the backfill then stops instead of fetching every file completely.
public struct RangeReader: Sendable {
    public let transport: any Transport
    public let headerLines: [String: String]

    /// Up to here the tail grows if the directory begins further forward (a CBZ with a thousand
    /// pages) — beyond that the file is no candidate any more.
    public static let atMostTail = 1_048_576

    public init(transport: any Transport, headerLines: [String: String]) {
        self.transport = transport
        self.headerLines = headerLines
    }

    /// The last bytes of the file and its total length — which comes from `Content-Range` if the
    /// caller does not know it.
    public func tail(
        _ address: URL, size: Int?, length: Int = Zip.Remote.tail
    ) async throws -> (Data, Int) {
        let area: String
        if let size {
            area = "bytes=\(max(0, size - length))-\(max(0, size - 1))"
        } else {
            area = "bytes=-\(length)"
        }
        let (data, response) = try await fetch(address, area: area)
        let total =
            RangeReader.totalLength(response.value(forHTTPHeaderField: "Content-Range")) ?? size
            ?? data.count
        return (data, total)
    }

    /// The bytes of a range `[from, to)`.
    public func area(_ address: URL, _ r: Range<Int>) async throws -> Data {
        guard !r.isEmpty else { return Data() }
        return try await fetch(address, area: "bytes=\(r.lowerBound)-\(r.upperBound - 1)").0
    }

    /// The unpacked content of an entry — one range, a second one for a longer local header.
    public func content(_ e: Zip.Item, from address: URL, remote: Zip.Remote) async throws -> Data {
        try await content(e, from: address, size: remote.size)
    }

    public func content(_ e: Zip.Item, from address: URL, size: Int) async throws -> Data {
        let first = Zip.Remote.area(e, size: size)
        let data = try await area(address, first)
        do {
            return try Zip.Remote.content(e, from: data)
        } catch Zip.Failure.rangeTooShort(let needed) {
            let more = try await area(
                address, first.lowerBound..<min(size, first.lowerBound + needed))
            return try Zip.Remote.content(e, from: more)
        }
    }

    private func fetch(_ address: URL, area: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: address)
        for (k, v) in headerLines { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(area, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 206: return (data, response)
        case 200: throw Backfill.NoAreas()
        case 416: throw Zip.Failure.corrupted
        default:
            let source = SourceID(provider: .webdav, server: address.host() ?? "")
            throw SourceError.from(status: response.statusCode, source: source)
                ?? .unreadable(source, "Response \(response.statusCode)")
        }
    }

    /// `bytes 1000-1999/54321` → 54321.
    static func totalLength(_ contentRange: String?) -> Int? {
        guard let text = contentRange, let slash = text.lastIndex(of: "/") else { return nil }
        return Int(text[text.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
