import Device
import Foundation
import SourcesKit
import SourcesKitMocks
import Synchronization
import Testing

@testable import WebdavKit

/// A transport that answers `Range` fetches for stored files itself (206 with `Content-Range`,
/// 416 outside) and leaves everything else to the mock transport — the server the backfill needs.
/// A file may also exist only as a window (the recorded tail of a real EPUB): what lies outside
/// the window is 416, as behind the end of the file.
final class RangeMock: Transport, Sendable {
    struct Window: Sendable {
        let data: Data
        let offset: Int
        let total: Int
    }

    let inner = MockTransport()
    private let files = Mutex<[String: Window]>([:])
    private let counter = Mutex(0)
    /// Answers `Range` with 200 and the whole file — a server without ranges.
    let withoutRanges: Bool

    init(withoutRanges: Bool = false) { self.withoutRanges = withoutRanges }

    func create(_ data: Data, below path: String, from offset: Int = 0, total: Int? = nil) {
        files.withLock {
            $0[path] = Window(data: data, offset: offset, total: total ?? offset + data.count)
        }
    }

    var rangeFetches: Int { counter.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, request.httpMethod ?? "GET" == "GET",
            let window = files.withLock({ $0[url.path()] })
        else { return try await inner.send(request) }
        counter.withLock { $0 += 1 }
        guard !withoutRanges, let area = request.value(forHTTPHeaderField: "Range"),
            area.hasPrefix("bytes=")
        else {
            return (
                window.data,
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let share = area.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        let from: Int
        let until: Int
        if share[0].isEmpty {
            from = max(0, window.total - (Int(share[1]) ?? 0))
            until = window.total - 1
        } else {
            from = Int(share[0]) ?? 0
            until = min(
                window.total - 1,
                share.count > 1 && !share[1].isEmpty ? (Int(share[1]) ?? 0) : window.total - 1)
        }
        let end = window.offset + window.data.count
        guard from <= until, from >= window.offset, until < end else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 416, httpVersion: nil, headerFields: nil)!)
        }
        let piece = window.data.subdata(in: (from - window.offset)..<(until + 1 - window.offset))
        return (
            piece,
            HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(from)-\(until)/\(window.total)"])!
        )
    }
}

/// Against a recording of a Nextcloud 34 folder "Bücher" with three EPUB, one PDF and one CBZ —
/// and against a built tree for the path the recording does not show: the refusal at depth ∞,
/// which Nextcloud 34 no longer gives.
@Suite("WebdavKit")
struct WebdavKitTests {
    static let folder = URL(string: "https://nextcloud.example/remote.php/dav/files/leser/B%C3%BCcher/")!
    static let ourLife = folder.appending(path: "Jegeil Jauthern - Gutol Spespaifiar braprigla.epub")
    /// The files in the recorded folder, relative — the identifiers of the five titles.
    static let seto =
        "Maprekeit Siacou/Seto Gletroutzun (Blom Liwikia #1)/Seto Gletroutzun - Ceikailia Siacou.epub"
    static let plinpro = "Jegeil Jauthern/Plinpro (Plinpro #1)/Plinpro - Jegeil Jauthern.epub"
    static let kiastewou = "Manga/Miazul Kiastewou/Miazul Kiastewou 06.cbz"
    static let flitglu = "Plat Leinprepleind/Pliweik Flitglu bli drai trakrourn Wajou.pdf"

    private func probeAccount() -> WebdavAccount {
        WebdavAccount(folder: Self.folder, username: "leser", password: "app-passwort")
    }

    private func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The recorded tail of "Gutol Spespaifiar braprigla" with its position in the file.
    private func tail() throws -> (Data, offset: Int, total: Int) {
        let end = try MockTransport.recording("datei-ende.bin", from: .module)
        let area = try #require(end.headerLines["content-range"] ?? end.headerLines["Content-Range"])
        let total = try #require(RangeReader.totalLength(area))
        let from = try #require(Int(area.dropFirst("bytes ".count).split(separator: "-")[0]))
        return (end.data, from, total)
    }

    /// The SabreDAV refusal at depth ∞ — the rule up to Nextcloud 33, no longer recorded in 34; the
    /// format is that of the 401/404 recordings.
    static let denied = MockTransport.Answer(
        status: 403,
        data: Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
              <s:exception>Sabre\\DAV\\Exception\\Forbidden</s:exception>
              <s:message>PROPFIND requests with a Depth of "infinity" are not allowed for /remote.php/dav/files/leser/B%c3%bccher/.</s:message>
            </d:error>
            """.utf8), headerLines: ["Content-Type": "application/xml; charset=utf-8"])

    /// A multistatus in Nextcloud format for the built tree.
    static func multistatus(_ entries: [(path: String, folder: Bool, size: Int)]) -> Data {
        let responses = entries.map { e in
            let href = "/remote.php/dav/files/leser/B%c3%bccher/" + e.path
            let prop =
                e.folder
                ? "<d:resourcetype><d:collection/></d:resourcetype>"
                : "<d:resourcetype/><d:getcontentlength>\(e.size)</d:getcontentlength><d:getetag>&quot;\(e.path.hashValue.magnitude)&quot;</d:getetag>"
            return
                "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(prop)<d:getlastmodified>Tue, 16 Sep 2026 18:02:10 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }.joined()
        return Data(
            ("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:s=\"http://sabredav.org/ns\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">"
                + responses + "</d:multistatus>").utf8)
    }

    static func epub(name: String, bookSeries: String? = nil) -> Data {
        let seriesMeta =
            bookSeries.map {
                "<meta name=\"calibre:series\" content=\"\($0)\"/><meta name=\"calibre:series_index\" content=\"2\"/>"
            } ?? ""
        let opf = """
            <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(name)</dc:title>
            <dc:creator>Maprekeit Siacou</dc:creator><dc:language>de</dc:language><dc:publisher>Klufluve</dc:publisher>
            <dc:description>&lt;p&gt;Im Hafen von Lüttgrund wartet ein Kutter auf die nächste Springflut.&lt;/p&gt;</dc:description>
            <meta name="cover" content="cover"/>\(seriesMeta)</metadata>
            <manifest><item id="cover" href="images/cover.png" media-type="image/png"/><item id="k1" href="k1.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="k1"/></spine></package>
            """
        let text = (1...300).map { "<p>Absatz \($0) — \(UUID().uuidString)</p>" }.joined(separator: "\n")
        return Zip.archive([
            ("mimetype", Data("application/epub+zip".utf8)),
            (
                "META-INF/container.xml",
                Data(
                    "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
                        .utf8)
            ),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/k1.xhtml", Data("<html><body>\(text)</body></html>".utf8)),
            ("OEBPS/images/cover.png", Data("PNG-\(name)".utf8)),
        ])
    }

    static func cbz(pages: Int) -> Data {
        Zip.archive(
            (1...pages).map { n in
                ("Blawosfil Saga 001/\(String(format: "%03d", n)).jpg", Data("JPEG-\(n)".utf8))
            }
                + [("Blawosfil Saga 001/ComicInfo.xml", Data("<ComicInfo/>".utf8))])
    }

    // MARK: - Recording

    @Test(
        "The parser: depth 0, 1 and ∞ from Nextcloud 34 — folders and files, size, ETag, content type, date, decoded paths"
    )
    func parser() throws {
        let depth1 = try WebdavParser.parse(data("propfind-1.xml"))
        #expect(depth1.count == 6, "the root and five children")
        let root = try #require(depth1.first)
        #expect(root.isFolder && root.path == "/remote.php/dav/files/leser/Bücher/")
        #expect(root.displayName == "Bücher" && root.size == nil, "the 404 propstat sets nothing")
        #expect(
            depth1.filter(\.isFolder).map(\.name) == [
                "Bücher", "Maprekeit Siacou", "Jegeil Jauthern", "Manga", "Plat Leinprepleind",
            ])
        let life = try #require(depth1.first { !$0.isFolder })
        #expect(life.name == "Jegeil Jauthern - Gutol Spespaifiar braprigla.epub" && life.size == 453689)
        #expect(life.etag == "\"895b5955e752dcd080f83f8304f97bf1\"")
        #expect(life.contentType == "application/epub+zip")
        #expect(
            life.changed == WebdavParser.date("Sat, 19 Sep 2026 08:13:25 GMT") && life.changed != nil)
        let below = try WebdavParser.parse(data("propfind-unterordner.xml"))
        #expect(below.map(\.name) == ["Maprekeit Siacou", "Seto Gletroutzun (Blom Liwikia #1)"])
        #expect(below.allSatisfy { $0.isFolder })
        let everything = try WebdavParser.parse(data("propfind-unendlich.xml"))
        #expect(
            everything.count == 13 && everything.filter { !$0.isFolder }.count == 5,
            "depth ∞: the whole tree in one response")
        let kiastewou = try #require(everything.first { $0.name == "Miazul Kiastewou 06.cbz" })
        #expect(kiastewou.size == 36_619_233 && kiastewou.contentType == "application/comicbook+zip")
        #expect(
            everything.contains { $0.path.hasSuffix("/Seto Gletroutzun (Blom Liwikia #1)/") },
            "%23 and %c3%bc decoded")
        let without = try WebdavParser.parse(data("propfind-ohne-body.xml"))
        #expect(without.count == 6, "allprop reads the same way")
        let alone = try WebdavParser.parse(data("propfind-0.xml"))
        #expect(alone.count == 1 && alone[0].isFolder && alone[0].displayName == "Bücher")
    }

    @Test(
        "Refusals from SabreDAV: 401 and 404 recorded, the refusal at depth ∞ built — with a readable reason")
    func denials() throws {
        #expect(try WebdavParser.failure(data("401.xml"))?.contains("NotAuthenticated") == true)
        #expect(try WebdavParser.failure(data("404.xml"))?.contains("NotFound") == true)
        #expect(try MockTransport.recording("401.xml", from: .module).status == 401)
        #expect(try MockTransport.recording("404.xml", from: .module).status == 404)
        #expect(try MockTransport.recording("propfind-unendlich.xml", from: .module).status == 207)
        #expect(WebdavParser.failure(Self.denied.data)?.contains("Forbidden") == true)
        let options = String(decoding: try data("options.txt.headers"), as: UTF8.self).lowercased()
        #expect(options.contains("dav: 1, 3") && options.contains("propfind"))
    }

    @Test(
        "The tail of a real EPUB: 61 entries from the last 64 KB, Deflate entries from ranges, OPF and cover before it"
    )
    func tailOfRealEpub() throws {
        let (tail, offset, total) = try tail()
        #expect(total == 453689 && offset == total - tail.count)
        let remote = try Zip.Remote(tail: tail, size: total)
        #expect(remote.entries.count == 61)
        #expect(remote.entry("mimetype")?.size == 20)
        let container = try #require(remote.entry("META-INF/container.xml"))
        let opf = try #require(remote.entry("content.opf"))
        let cover = try #require(remote.entry("cover.jpeg"))
        #expect(remote.area(container).lowerBound < offset && remote.area(opf).lowerBound < offset)
        #expect(
            cover.size == 118_048 && remote.area(cover).lowerBound < offset,
            "the cover lies in front — a range of its own")
        // Entries that lie entirely in the tail are unpacked by the reader from the excerpt —
        // Deflate, with the local header, as Calibre writes it.
        for name in ["text/part0034.html", "titlepage.xhtml", "toc.ncx", "META-INF/encryption.xml"] {
            let e = try #require(remote.entry(name))
            let area = remote.area(e)
            #expect(area.lowerBound >= offset && area.upperBound <= total, Comment(rawValue: name))
            let content = try remote.content(
                e, from: tail.subdata(in: (area.lowerBound - offset)..<(area.upperBound - offset)))
            #expect(content.count == e.size, Comment(rawValue: name))
            #expect(String(decoding: content.prefix(200), as: UTF8.self).contains("<"), "\(name) is XML")
        }
        let start = try MockTransport.recording("datei-bereich.bin", from: .module)
        #expect(start.status == 206 && start.data.count == 1024)
        #expect(start.data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]), "a ZIP starts with PK")
        #expect(String(decoding: start.data.prefix(60), as: UTF8.self).contains("mimetype"))
        let startRange = start.headerLines["content-range"] ?? start.headerLines["Content-Range"]
        #expect(RangeReader.totalLength(startRange) == total)
        let header = String(decoding: try data("datei-kopf.headers"), as: UTF8.self).lowercased()
        #expect(
            !header.contains("accept-ranges"),
            "Nextcloud 34 names no Accept-Ranges — and still answers with 206; the kit does not ask for it"
        )
        #expect(
            header.contains("content-length: \(total)")
                && header.contains("etag: \"895b5955e752dcd080f83f8304f97bf1\""))
    }

    @Test(
        "The backfill on the tail: directory read, OPF outside → no finding with a name, but size and no error"
    )
    func backfillOnTail() async throws {
        let (tail, offset, total) = try tail()
        let t = RangeMock()
        t.create(tail, below: Self.ourLife.path(), from: offset, total: total)
        let reader = RangeReader(transport: t, headerLines: probeAccount().headerLines)
        let finding = try await Backfill.extract(
            Self.ourLife, type: .epub, etag: nil, size: nil, reader: reader)
        #expect(finding.size == Int64(total), "the length from Content-Range")
        #expect(
            finding.futile && !finding.noAreas,
            "container.xml lies before the window — 416, no crash")
        #expect(t.rangeFetches == 2, "tail and one attempt at container.xml")
    }

    @Test(
        "The crawl over the recorded tree: depth ∞ works — one PROPFIND, five titles, metadata from the paths"
    )
    func crawlRecording() async throws {
        let t = RangeMock()
        try t.inner.answer("PROPFIND", Self.folder.path(), file: "propfind-unendlich.xml", from: .module)
        let (tail, offset, total) = try tail()
        t.create(tail, below: Self.ourLife.path(), from: offset, total: total)
        for rel in [Self.seto, Self.plinpro, Self.kiastewou] {
            t.create(Data(), below: Self.folder.appending(path: rel).path(), from: 0, total: 1)
        }
        let backfill = BackfillStore(file: nil)
        let source = WebdavSource(account: probeAccount(), transport: t, persistence: nil, backfill: backfill)
        let extract = try await source.library()
        #expect(t.inner.paths == ["PROPFIND " + Self.folder.path()], "a single PROPFIND, no depth 1")
        #expect(t.inner.requests.first?.value(forHTTPHeaderField: "Depth") == "infinity")
        #expect(extract.title.count == 5, "three EPUB, one PDF, one CBZ")
        let title = Dictionary(uniqueKeysWithValues: extract.title.map { ($0.identifier.id, $0) })
        let seto = try #require(title[Self.seto])
        #expect(
            seto.name == "Seto Gletroutzun" && seto.authors == ["Ceikailia Siacou"],
            "the file name beats the folder \"Maprekeit Siacou\"")
        #expect(
            seto.series?.name == "Blom Liwikia" && seto.series?.volume == 1 && seto.kind == .book
        )
        #expect(seto.size == 813_279 && seto.format == "EPUB" && seto.added != nil)
        let plinpro = try #require(title[Self.plinpro])
        #expect(
            plinpro.name == "Plinpro" && plinpro.authors == ["Jegeil Jauthern"] && plinpro.series?.name == "Plinpro"
                && plinpro.series?.volume == 1)
        let life = try #require(title["Jegeil Jauthern - Gutol Spespaifiar braprigla.epub"])
        #expect(life.name == "Gutol Spespaifiar braprigla" && life.authors == ["Jegeil Jauthern"] && life.series == nil)
        let kiastewou = try #require(title[Self.kiastewou])
        #expect(kiastewou.kind == .manga && kiastewou.series?.name == "Miazul Kiastewou" && kiastewou.series?.volume == 6)
        #expect(kiastewou.format == "CBZ" && kiastewou.size == 36_619_233)
        let flitglu = try #require(title[Self.flitglu])
        #expect(
            flitglu.kind == .book && flitglu.name == "Pliweik Flitglu bli drai trakrourn Wajou"
                && flitglu.authors == ["Plat Leinprepleind"])
        #expect(flitglu.cover == nil && flitglu.format == "PDF")
        #expect(extract.seriesList.map(\.name) == ["Blom Liwikia", "Miazul Kiastewou", "Plinpro"])
        #expect(extract.seriesList.allSatisfy { $0.volumeCount == 1 })
        // The backfill touched all four archives; the range mock knows only the tail of "Gutol Spespaifiar
        // braprigla" — the findings are futile, no run breaks.
        #expect(backfill.count == 4 && backfill.finding(Self.ourLife)?.size == Int64(total))
        #expect(extract.title.allSatisfy { $0.cover == nil }, "no cover without a cover location")
        if case .file(let url, let size, let rangeCapable) = source.content(seto) {
            #expect(
                url.path(percentEncoded: false).hasSuffix(Self.seto) && size == 813_279
                    && rangeCapable)
        } else {
            Issue.record("no file")
        }
        if case .file = source.content(kiastewou) {
        } else {
            Issue.record("a CBZ without a directory is a file")
        }
        #expect(source.file(flitglu)?.lastPathComponent == "Pliweik Flitglu bli drai trakrourn Wajou.pdf")
    }

    // MARK: - Path and account

    @Test(
        "Metadata from the path: Calibre with series in the folder, author-dash-title, series patterns, manga folder"
    )
    func path() {
        let seto = PathMetadata.extract(Self.seto, type: .epub)
        #expect(seto.name == "Seto Gletroutzun" && seto.authors == ["Ceikailia Siacou"])
        #expect(seto.bookSeries == "Blom Liwikia" && seto.volume == 1)
        let miakus = PathMetadata.extract("Maprekeit Siacou/Miakus (12)/Miakus - Maprekeit Siacou.epub", type: .epub)
        #expect(miakus.name == "Miakus" && miakus.authors == ["Maprekeit Siacou"])
        let folderOnly = PathMetadata.extract(
            "Siacou, Maprekeit/Blom Liwikia (13)/Blom Liwikia.epub", type: .epub)
        #expect(
            folderOnly.name == "Blom Liwikia" && folderOnly.authors == ["Maprekeit Siacou"],
            "without an author in the file name the folder counts")
        let life = PathMetadata.extract("Jegeil Jauthern - Gutol Spespaifiar braprigla.epub", type: .epub)
        #expect(
            life.name == "Gutol Spespaifiar braprigla" && life.authors == ["Jegeil Jauthern"] && life.bookSeries == nil)
        let inAuthorFolder = PathMetadata.extract(
            "Plat Leinprepleind/Pliweik Flitglu bli drai trakrourn Wajou.pdf", type: .pdf)
        #expect(
            inAuthorFolder.name == "Pliweik Flitglu bli drai trakrourn Wajou"
                && inAuthorFolder.authors == ["Plat Leinprepleind"])
        let genre = PathMetadata.extract("Fantasy/Plinpro.epub", type: .epub)
        #expect(genre.name == "Plinpro" && genre.authors.isEmpty, "a genre is no author")
        let series1 = PathMetadata.extract("Ankerlicht - Gezeiten (Ankerlicht #2).epub", type: .epub)
        #expect(
            series1.authors == ["Ankerlicht"] && series1.name == "Gezeiten" && series1.bookSeries == "Ankerlicht"
                && series1.volume == 2
        )
        let series2 = PathMetadata.extract("Nasloslai Lindqvist - Ankerlicht 03 - Brandung.epub", type: .epub)
        #expect(
            series2.authors == ["Nasloslai Lindqvist"] && series2.name == "Brandung" && series2.bookSeries == "Ankerlicht"
                && series2.volume == 3)
        let series3 = PathMetadata.extract("Je Nitpol (Je Nitpol 1).epub", type: .epub)
        #expect(series3.name == "Je Nitpol" && series3.bookSeries == "Je Nitpol" && series3.volume == 1)
        let nameOnly = PathMetadata.extract("Vabriongom.pdf", type: .pdf)
        #expect(nameOnly.name == "Vabriongom" && nameOnly.authors.isEmpty && nameOnly.bookSeries == nil)
        let kiastewou = PathMetadata.extract(Self.kiastewou, type: .cbz)
        #expect(
            kiastewou.name == "Miazul Kiastewou 06" && kiastewou.bookSeries == "Miazul Kiastewou" && kiastewou.volume == 6)
        let number = PathMetadata.extract("Manga/Blawosfil Saga/002.cbz", type: .cbz)
        #expect(number.bookSeries == "Blawosfil Saga" && number.volume == 2)
        let flatManga = PathMetadata.extract("Comics/Brakka! v01.cbr", type: .cbr)
        #expect(flatManga.bookSeries == "Brakka!" && flatManga.volume == 1, "\"Comics\" is no series")
        #expect(
            PathMetadata.authors("Siacou, Maprekeit & Ceikailia Siacou") == ["Maprekeit Siacou", "Ceikailia Siacou"])
    }

    @Test(
        "The account: folder name as title, trailing slash, identifier with folder without Nextcloud prefix")
    func account() {
        let k = probeAccount()
        #expect(k.title == "Bücher")
        #expect(k.folder.absoluteString.hasSuffix("/"))
        #expect(k.identifier == SourceID(provider: .webdav, server: "nextcloud.example · Bücher"))
        let without = WebdavAccount(
            folder: URL(string: "https://nextcloud.example/remote.php/dav/files/leser/B%C3%BCcher")!,
            username: "",
            password: "")
        #expect(without.folder == k.folder && without.headerLines.isEmpty)
        #expect(k.headerLines["Authorization"]?.hasPrefix("Basic ") == true)
        let deep = WebdavAccount(
            folder: URL(string: "https://dav.example/webdav/Lesen/Neu/")!, username: "a", password: "b")
        #expect(deep.identifier.server == "dav.example · Lesen · Neu" && deep.title == "Neu")
    }

    // MARK: - The built tree: depth ∞ refused, backfill via ranges, switch

    static let miakus = epub(name: "Miakus")
    static let desert = epub(name: "Blom Liwikia", bookSeries: "Miakus-Stiwauzit")
    static let plinpro2 = epub(name: "Plinpro")
    static let volume1 = cbz(pages: 5)
    static let volume2 = cbz(pages: 3)
    static let miakusPath = "Maprekeit Siacou/Miakus (12)/Miakus - Maprekeit Siacou.epub"
    static let desertPath = "Maprekeit Siacou/Blom Liwikia (13)/Blom Liwikia - Maprekeit Siacou.epub"
    static let plinproPath = "Jegeil Jauthern - Plinpro.epub"
    static let volume1Path = "Manga/Blawosfil Saga/Blawosfil Saga 001.cbz"
    static let volume2Path = "Manga/Blawosfil Saga/Blawosfil Saga 002.cbz"

    /// A server that refuses depth ∞ (Nextcloud up to 33, ownCloud): first the refusal, then depth 1
    /// per folder — with built archives for the backfill whose sizes in the PROPFIND are the real ones
    /// (otherwise the range points into the void, 416).
    func tree(_ t: RangeMock) {
        let root = Self.folder.path()
        t.inner.answer("PROPFIND", root, with: Self.denied)
        func below(_ rel: String?, _ entries: [(path: String, folder: Bool, size: Int)]) {
            let address =
                rel.map { Self.folder.appending(path: $0, directoryHint: .isDirectory).path() } ?? root
            t.inner.answer("PROPFIND", address, with: .init(data: Self.multistatus(entries)))
        }
        below(
            nil,
            [
                ("", true, 0), ("Maprekeit%20Siacou/", true, 0), ("Manga/", true, 0), ("Comics/", true, 0),
                ("Jegeil%20Jauthern%20-%20Plinpro.epub", false, Self.plinpro2.count), ("Vabriongom.pdf", false, 4_210_776),
                ("Brodronwou.txt", false, 512),
            ])
        below(
            "Maprekeit Siacou",
            [
                ("Maprekeit%20Siacou/", true, 0), ("Maprekeit%20Siacou/Miakus%20(12)/", true, 0),
                ("Maprekeit%20Siacou/Blom%20Liwikia%20(13)/", true, 0),
            ])
        below(
            "Maprekeit Siacou/Miakus (12)",
            [
                ("Maprekeit%20Siacou/Miakus%20(12)/", true, 0),
                ("Maprekeit%20Siacou/Miakus%20(12)/Miakus%20-%20Maprekeit%20Siacou.epub", false, Self.miakus.count),
                ("Maprekeit%20Siacou/Miakus%20(12)/cover.jpg", false, 88_213),
                ("Maprekeit%20Siacou/Miakus%20(12)/metadata.opf", false, 3_412),
            ])
        below(
            "Maprekeit Siacou/Blom Liwikia (13)",
            [
                ("Maprekeit%20Siacou/Blom%20Liwikia%20(13)/", true, 0),
                (
                    "Maprekeit%20Siacou/Blom%20Liwikia%20(13)/Blom%20Liwikia%20-%20Maprekeit%20Siacou.epub",
                    false,
                    Self.desert.count
                ),
            ])
        below("Manga", [("Manga/", true, 0), ("Manga/Blawosfil%20Saga/", true, 0), ("Manga/.sync/", true, 0)])
        below(
            "Manga/Blawosfil Saga",
            [
                ("Manga/Blawosfil%20Saga/", true, 0),
                ("Manga/Blawosfil%20Saga/Blawosfil%20Saga%20001.cbz", false, Self.volume1.count),
                ("Manga/Blawosfil%20Saga/Blawosfil%20Saga%20002.cbz", false, Self.volume2.count),
            ])
        below("Comics", [("Comics/", true, 0), ("Comics/Brakka%21%20v01.cbr", false, 112_004_551)])
        for (data, rel) in [
            (Self.miakus, Self.miakusPath), (Self.desert, Self.desertPath), (Self.plinpro2, Self.plinproPath),
            (Self.volume1, Self.volume1Path), (Self.volume2, Self.volume2Path),
        ] {
            t.create(data, below: Self.folder.appending(path: rel).path())
        }
    }

    @Test(
        "Depth ∞ refused → depth 1 per folder; only EPUB/PDF/CBZ/CBR; series from path and OPF; backfill brings names, covers, pages"
    )
    func crawlDenied() async throws {
        let t = RangeMock()
        tree(t)
        let backfill = BackfillStore(file: nil)
        let source = WebdavSource(account: probeAccount(), transport: t, persistence: nil, backfill: backfill)
        let extract = try await source.library()
        let propfinds = t.inner.paths.filter { $0.hasPrefix("PROPFIND") }
        #expect(
            propfinds.count == 8,
            "∞ on the root, then depth 1 on root and six folders — .sync stays out")
        #expect(t.inner.requests.first?.value(forHTTPHeaderField: "Depth") == "infinity")
        #expect(t.inner.requests[1].value(forHTTPHeaderField: "Depth") == "1")
        #expect(
            t.inner.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true
            })
        #expect(
            extract.title.count == 7,
            "three EPUB, one PDF, two CBZ, one CBR — not cover.jpg, metadata.opf and Brodronwou.txt")
        let names = Dictionary(uniqueKeysWithValues: extract.title.map { ($0.identifier.id, $0) })
        let miakus = try #require(names[Self.miakusPath])
        #expect(
            miakus.kind == .book && miakus.name == "Miakus" && miakus.authors == ["Maprekeit Siacou"]
                && miakus.format == "EPUB")
        #expect(
            miakus.publisher == "Klufluve" && miakus.language == "de"
                && miakus.summary?.hasPrefix("Im Hafen von Lüttgrund") == true)
        #expect(
            miakus.cover?.fragment == "cover" && miakus.size == Int64(Self.miakus.count)
                && miakus.added != nil)
        let desert = try #require(names[Self.desertPath])
        #expect(desert.series?.name == "Miakus-Stiwauzit" && desert.series?.volume == 2, "the series from the OPF")
        let plinpro = try #require(names[Self.plinproPath])
        #expect(plinpro.name == "Plinpro" && plinpro.authors == ["Maprekeit Siacou"], "the OPF beats the file name")
        let pdf = try #require(names["Vabriongom.pdf"])
        #expect(pdf.kind == .book && pdf.name == "Vabriongom" && pdf.cover == nil && pdf.format == "PDF")
        let volume1 = try #require(names[Self.volume1Path])
        #expect(
            volume1.kind == .manga && volume1.series?.name == "Blawosfil Saga" && volume1.series?.volume == 1)
        #expect(volume1.scope == .pages(5) && volume1.cover?.fragment == "cover")
        let cbr = try #require(names["Comics/Brakka! v01.cbr"])
        #expect(
            cbr.kind == .manga && cbr.series?.name == "Brakka!" && cbr.scope == .unknown && cbr.cover == nil)
        // Content and order apart: the public export renames the series, which moves them in the list.
        let seriesNames = extract.seriesList.map(\.name)
        #expect(Set(seriesNames) == ["Brakka!", "Miakus-Stiwauzit", "Blawosfil Saga"] && seriesNames.count == 3)
        #expect(
            seriesNames == seriesNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "sorted by name")
        #expect(extract.seriesList.first { $0.name == "Blawosfil Saga" }?.volumeCount == 2)
        if case .pageStream(let count, let page, _) = source.content(volume1) {
            #expect(count == 5 && page(2).fragment == "seite=2")
            #expect(page(2).path(percentEncoded: false).hasSuffix("Blawosfil Saga 001.cbz"))
        } else {
            Issue.record("no page stream")
        }
        if case .file(let url, let size, let rangeCapable) = source.content(miakus) {
            #expect(
                url.path(percentEncoded: false).hasSuffix(Self.miakusPath) && size == Int64(Self.miakus.count)
                    && rangeCapable)
        } else {
            Issue.record("no file")
        }
        #expect(source.file(cbr)?.lastPathComponent == "Brakka! v01.cbr")
        #expect(backfill.count == 5 && t.rangeFetches > 0)
        // A fresh transport because the mock keeps its last response — the store stays.
        let t2 = RangeMock()
        tree(t2)
        let secondRun = try await WebdavSource(
            account: probeAccount(), transport: t2, persistence: nil, backfill: backfill
        ).library()
        #expect(t2.rangeFetches == 0, "everything from the store")
        #expect(
            secondRun.title.map(\.identifier) == extract.title.map(\.identifier),
            "same identifiers on the second run")
    }

    @Test("The switch: #cover and #seite=N come as ranges from the archive, everything else passes through")
    func gate() async throws {
        let t = RangeMock()
        tree(t)
        let backfill = BackfillStore(file: nil)
        let source = WebdavSource(account: probeAccount(), transport: t, persistence: nil, backfill: backfill)
        let miakus = Self.folder.appending(path: Self.miakusPath)
        var request = URLRequest(url: WebdavSwitch.cover(miakus))
        for (k, v) in source.headerLines() { request.setValue(v, forHTTPHeaderField: k) }
        let (cover, response) = try await source.gate.send(request)
        #expect(response.statusCode == 200 && cover == Data("PNG-Miakus".utf8))
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(
            backfill.finding(miakus)?.name == "Miakus",
            "without a catalog crawl the switch does the backfill itself")
        let volume = Self.folder.appending(path: Self.volume2Path)
        let (page, s) = try await source.gate.send(URLRequest(url: WebdavSwitch.page(2, from: volume)))
        #expect(s.statusCode == 200 && page == Data("JPEG-2".utf8))
        let (_, route) = try await source.gate.send(URLRequest(url: WebdavSwitch.page(9, from: volume)))
        #expect(route.statusCode == 404)
        var whole = URLRequest(url: volume)
        whole.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (start, a) = try await source.gate.send(whole)
        #expect(
            a.statusCode == 206 && start == Data([0x50, 0x4B, 0x03, 0x04]),
            "without fragment: the file itself"
        )
        #expect(source.gate.session(for: whole) == nil, "the mock is no session")
        #expect(source.gate.session(for: request) == nil)
        #expect(backfill.finding(Self.folder.appending(path: "Vabriongom.pdf")) == nil)
    }

    @Test(
        "A server without ranges (200 instead of 206): path names without cover, no error, no second attempt")
    func withoutRanges() async throws {
        let t = RangeMock(withoutRanges: true)
        tree(t)
        let backfill = BackfillStore(file: nil)
        let source = WebdavSource(account: probeAccount(), transport: t, persistence: nil, backfill: backfill)
        let extract = try await source.library()
        #expect(extract.title.count == 7)
        #expect(t.rangeFetches == 1, "after the first whole file nobody asks any more")
        #expect(extract.title.allSatisfy { $0.cover == nil })
        let miakus = try #require(extract.title.first { $0.identifier.id == Self.miakusPath })
        #expect(miakus.name == "Miakus" && miakus.authors == ["Maprekeit Siacou"], "from the path")
        #expect(backfill.count == 5 && backfill.finding(source.file(miakus)!)?.noAreas == true)
        _ = try await source.library()
        #expect(t.rangeFetches == 1)
    }

    @Test("The backfill store survives the restart and expires when the file changes")
    func persistence() async throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "webdav-nachlese-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let t = RangeMock()
        tree(t)
        _ = try await WebdavSource(
            account: probeAccount(), transport: t, persistence: nil, backfill: BackfillStore(file: file)
        )
        .library()
        let again = BackfillStore(file: file)
        #expect(again.count == 5)
        let plinpro = Self.folder.appending(path: Self.plinproPath)
        let finding = try #require(again.finding(plinpro))
        #expect(finding.name == "Plinpro" && finding.cover?.name == "OEBPS/images/cover.png")
        #expect(again.finding(plinpro, etag: finding.etag, size: finding.size) != nil)
        #expect(
            again.finding(plinpro, etag: "\"anders\"", size: finding.size) == nil,
            "a new ETag means a new file")
        #expect(again.finding(plinpro, etag: nil, size: 1) == nil, "without an ETag the size counts")
    }

    // MARK: - Sign-in, reading state

    @Test("Sign-in: PROPFIND depth 0 with 207 means access; 401 means signed out; 404 is no folder")
    func signIn() async throws {
        let t = MockTransport()
        try t.answer("PROPFIND", Self.folder.path(), file: "propfind-0.xml", from: .module)
        let account = try await WebdavSource.signIn(
            folder: Self.folder, username: "leser", password: "app-passwort", transport: t)
        #expect(account.title == "Bücher")
        #expect(t.requests.first?.value(forHTTPHeaderField: "Depth") == "0")
        #expect(t.requests.first?.httpMethod == "PROPFIND")
        let t2 = MockTransport()
        try t2.answer("PROPFIND", Self.folder.path(), file: "401.xml", from: .module)
        await #expect(throws: SourceError.signedOut(account.identifier)) {
            try await WebdavSource.signIn(
                folder: Self.folder, username: "x", password: "y", transport: t2)
        }
        let t3 = MockTransport()
        let route = Self.folder.appending(path: "gibt-es-nicht", directoryHint: .isDirectory)
        try t3.answer("PROPFIND", route.path(), file: "404.xml", from: .module)
        await #expect(throws: SourceError.self) {
            try await WebdavSource.signIn(folder: route, username: "x", password: "y", transport: t3)
        }
        let t4 = MockTransport()
        try t4.answer("PROPFIND", Self.folder.path(), file: "propfind-0.xml", from: .module)
        try await WebdavSource(
            account: account, transport: t4, persistence: nil, backfill: BackfillStore(file: nil)
        )
        .verify()
    }

    @Test("Reading state locally: write, read, forget, from disk")
    func readingState() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "webdav-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let backfill = BackfillStore(file: nil)
        let source = WebdavSource(
            account: probeAccount(), transport: MockTransport(), persistence: file, backfill: backfill)
        let identifier = TitleID(source: probeAccount().identifier, id: Self.plinpro)
        #expect(try await source.progress(identifier) == nil)
        let state = ReadingState(position: .position(cfi: "epubcfi(/6/4)", fraction: 0.3), timestamp: Date())
        try await source.write(state, for: identifier)
        #expect(try await source.progress(identifier)?.fraction == 0.3)
        let again = WebdavSource(
            account: probeAccount(), transport: MockTransport(), persistence: file, backfill: backfill)
        #expect(try await again.progress(identifier)?.fraction == 0.3)
        try await again.forget(progressFor: identifier)
        #expect(try await again.progress(identifier) == nil)
        await #expect(throws: SourceError.self) { try await again.savedList() }
        await #expect(throws: SourceError.self) { try await again.collections() }
        #expect(again.capabilities == [.keep, .seriesList])
    }
}
