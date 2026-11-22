import CoreGraphics
import Foundation
import ImageIO
import SourcesKit
import UniformTypeIdentifiers

/// What a bare file reveals about itself — title, author, cover — so that an EPUB
/// from a colleague does not sit in the shelf as "inhalt.epub".
///
/// EPUB: `META-INF/container.xml` → OPF → Dublin Core and the cover (`meta name="cover"`
/// or `properties="cover-image"`), plus Calibre's series. PDF: the info dictionary and
/// the first page as an image. CBZ: the images in name order, the first is the cover.
public enum FileMetadata {

    public struct Finding: Sendable {
        public var metadata: PackageMetadata
        public var cover: Data?
        public var coverExtension: String
    }

    /// - Parameter name: the file name without extension — the fallback for the title.
    public static func extract(_ url: URL, kind: FileKind, name: String) -> Finding {
        switch kind {
        case .epub: return epub(url, name: name)
        case .pdf: return pdf(url, name: name)
        case .cbz: return cbz(url, name: name)
        case .akari:
            return Finding(
                metadata: PackageMetadata(kind: .book, name: name, file: url.lastPathComponent), cover: nil,
                coverExtension: "jpg")
        }
    }

    // MARK: - EPUB

    static func epub(_ url: URL, name: String) -> Finding {
        var meta = PackageMetadata(kind: .book, name: name, file: "inhalt.epub")
        guard let zip = try? Zip(url: url),
            let container = try? zip.content("META-INF/container.xml"),
            let opfPath = Opf.rootfile(container),
            let opfData = try? zip.content(opfPath)
        else { return Finding(metadata: meta, cover: nil, coverExtension: "jpg") }
        let opf = Opf(opfData)
        if let title = opf.title, !title.isEmpty { meta.name = title }
        meta.authors = opf.authors
        meta.language = opf.language
        meta.publisher = opf.publisher
        meta.summary = opf.descriptionText.map(FileMetadata.withoutTags)
        if let bookSeries = opf.bookSeries {
            meta.bookSeries = PackageMetadata.BookSeries(name: bookSeries, volume: opf.volume)
        }
        var cover: Data?
        var fileExtension = "jpg"
        if let path = opf.coverPath(opfPath: opfPath) {
            cover = try? zip.content(path)
            fileExtension = (path as NSString).pathExtension.lowercased()
            if fileExtension.isEmpty { fileExtension = "jpg" }
        }
        return Finding(metadata: meta, cover: cover, coverExtension: fileExtension)
    }

    /// A blurb in the OPF often comes as HTML — tags out, paragraphs stay.
    public static func withoutTags(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        t = t.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PDF

    static func pdf(_ url: URL, name: String) -> Finding {
        var meta = PackageMetadata(kind: .book, name: name, file: "inhalt.pdf")
        guard let document = CGPDFDocument(url as CFURL) else {
            return Finding(metadata: meta, cover: nil, coverExtension: "jpg")
        }
        meta.pages = document.numberOfPages
        if let info = document.info {
            if let title = text(info, "Title"), !title.isEmpty { meta.name = title }
            if let author = text(info, "Author"), !author.isEmpty {
                meta.authors = author.split(whereSeparator: { $0 == ";" || $0 == "," }).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let cover = document.page(at: 1).flatMap { firstImage($0) }
        return Finding(metadata: meta, cover: cover, coverExtension: "jpg")
    }

    private static func text(_ info: CGPDFDictionaryRef, _ lookupKey: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, lookupKey, &value), let value,
            let cf = CGPDFStringCopyTextString(value)
        else { return nil }
        return cf as String
    }

    /// The first page, 600 pixels tall, as JPEG — the cover of a PDF.
    static func firstImage(_ page: CGPDFPage) -> Data? {
        let frame = page.getBoxRect(.mediaBox)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = 600 / frame.height
        let width = Int(frame.width * scale)
        let height = Int(frame.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(
            page.getDrawingTransform(
                .mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0,
                preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return jpeg(image)
    }

    public static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(
            target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }

    // MARK: - CBZ

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"]

    /// The image entries of a CBZ in reading order — digits sorted naturally so that
    /// "2" comes before "10".
    public static func pages(_ zip: Zip) -> [Zip.Item] {
        pages(zip.entries)
    }

    /// The same from a directory that is not stored here (``Zip/Remote``).
    public static func pages(_ entries: [Zip.Item]) -> [Zip.Item] {
        entries.filter { e in
            let name = (e.name as NSString).lastPathComponent
            return !name.hasPrefix(".") && !e.name.hasPrefix("__MACOSX")
                && imageExtensions.contains((e.name as NSString).pathExtension.lowercased())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func cbz(_ url: URL, name: String) -> Finding {
        var meta = PackageMetadata(kind: .manga, name: name, file: "inhalt.cbz")
        guard let zip = try? Zip(url: url) else {
            return Finding(metadata: meta, cover: nil, coverExtension: "jpg")
        }
        let pages = pages(zip)
        meta.pages = pages.count
        let cover = pages.first.flatMap { try? zip.content($0) }
        let fileExtension = pages.first.map { ($0.name as NSString).pathExtension.lowercased() } ?? "jpg"
        return Finding(metadata: meta, cover: cover, coverExtension: fileExtension)
    }
}

/// The OPF reader — only what the source needs.
public final class Opf: NSObject, XMLParserDelegate {

    public private(set) var title: String?
    public private(set) var authors: [String] = []
    public private(set) var language: String?
    public private(set) var publisher: String?
    public private(set) var descriptionText: String?
    public private(set) var bookSeries: String?
    public private(set) var volume: Double?
    public private(set) var coverHref: String?

    private var coverId: String?
    private var manifest: [String: (href: String, properties: String)] = [:]
    private var current: String?
    private var text = ""

    public init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let coverId, let item = manifest[coverId] {
            coverHref = item.href
        } else if let item = manifest.values.first(where: {
            $0.properties.split(separator: " ").contains("cover-image")
        }) {
            coverHref = item.href
        }
    }

    /// The path of the cover in the archive — the `href` from the manifest, resolved against the
    /// folder of the OPF, percent-encoded characters reversed.
    public func coverPath(opfPath: String) -> String? {
        guard let href = coverHref else { return nil }
        let base = (opfPath as NSString).deletingLastPathComponent
        let path = base.isEmpty ? href : base + "/" + href
        return path.removingPercentEncoding ?? path
    }

    /// `META-INF/container.xml` → the path of the OPF.
    public static func rootfile(_ container: Data) -> String? {
        let text = String(decoding: container, as: UTF8.self)
        guard let area = text.range(of: "full-path=\"") else { return nil }
        let remainder = text[area.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    public func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        current = name
        text = ""
        switch name {
        case "meta":
            let n = attributes["name"] ?? ""
            let content = attributes["content"] ?? ""
            if n == "cover" { coverId = content }
            if n == "calibre:series" { bookSeries = content }
            if n == "calibre:series_index" { volume = Double(content) }
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = (href, attributes["properties"] ?? "")
            }
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        let name = element.split(separator: ":").last.map(String.init) ?? element
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": if title == nil, !value.isEmpty { title = value }
        case "creator": if !value.isEmpty { authors.append(value) }
        case "language": if language == nil, !value.isEmpty { language = value }
        case "publisher": if publisher == nil, !value.isEmpty { publisher = value }
        case "description": if descriptionText == nil, !value.isEmpty { descriptionText = value }
        default: break
        }
        current = nil
    }
}
