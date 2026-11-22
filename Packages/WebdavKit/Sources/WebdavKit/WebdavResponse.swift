import Foundation

/// A resource from a `207 Multi-Status` response — folder or file with what `PROPFIND` says
/// about it.
public struct WebdavEntry: Sendable, Hashable {
    /// The `href` as the server writes it — percent-encoded and relative to the host for Nextcloud
    /// (`/remote.php/dav/files/…`), absolute also allowed by the RFC.
    public var href: String
    /// The path from the `href`, percent-encoded characters turned back; a folder ends in `/`.
    public var path: String
    public var isFolder = false
    public var size: Int64?
    public var changed: Date?
    public var etag: String?
    public var contentType: String?
    public var displayName: String?

    public init(href: String) {
        self.href = href
        self.path = WebdavEntry.path(from: href)
    }

    /// The last path part — the file name, for a folder its name.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// The path from an `href`: absolute addresses lose the host, the rest is decoded. A `+` stays
    /// a `+` — WebDAV encodes spaces as `%20`.
    static func path(from href: String) -> String {
        var raw = href
        if raw.contains("://"), let url = URL(string: raw) {
            raw = url.path(percentEncoded: true)
        }
        return raw.removingPercentEncoding ?? raw
    }
}

/// Reads a `207 Multi-Status` document with `XMLParser` — namespaces do not matter (only the
/// local name counts): `response`/`href`/`propstat`/`prop`, `resourcetype` with `collection`,
/// `getcontentlength`, `getlastmodified` (RFC 1123), `getetag`, `getcontenttype`, `displayname`.
/// A `propstat` with status 404 carries empty elements and sets nothing.
public final class WebdavParser: NSObject, XMLParserDelegate {

    private var entries: [WebdavEntry] = []
    private var entry: WebdavEntry?
    private var path: [String] = []
    private var text = ""
    private var propstatStatus = ""
    private var propstatValues: [String: String] = [:]
    private var propstatFolder = false
    private var errorMessage: String?
    private var exception: String?

    public static func parse(_ data: Data) throws -> [WebdavEntry] {
        let parser = XMLParser(data: data)
        let reader = WebdavParser()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "WebdavKit", code: 1)
        }
        return reader.entries
    }

    /// What a SabreDAV server (Nextcloud, ownCloud) says about an error — `<s:exception>` and
    /// `<s:message>` — for the trace, not for the UI.
    public static func failure(_ data: Data) -> String? {
        let parser = XMLParser(data: data)
        let reader = WebdavParser()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.parse()
        return [reader.exception, reader.errorMessage].compactMap { $0 }.joined(separator: ": ")
            .nonEmpty
    }

    public func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        path.append(element)
        text = ""
        switch element {
        case "response":
            entry = nil
        case "propstat":
            propstatStatus = ""
            propstatValues = [:]
            propstatFolder = false
        case "collection":
            if path.dropLast().last == "resourcetype" { propstatFolder = true }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        defer { path.removeLast(); text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inProp = path.dropLast().last == "prop"
        switch element {
        case "href":
            if path.dropLast().last == "response", entry == nil {
                entry = WebdavEntry(href: value)
            }
        case "status":
            if path.dropLast().last == "propstat" { propstatStatus = value }
        case "getcontentlength", "getlastmodified", "getetag", "getcontenttype", "displayname":
            if inProp, !value.isEmpty { propstatValues[element] = value }
        case "propstat":
            guard propstatStatus.isEmpty || propstatStatus.contains(" 200") else { break }
            if propstatFolder { entry?.isFolder = true }
            if let g = propstatValues["getcontentlength"].flatMap({ Int64($0) }) { entry?.size = g }
            if let d = propstatValues["getlastmodified"].flatMap(WebdavParser.date) { entry?.changed = d }
            if let e = propstatValues["getetag"] { entry?.etag = e }
            if let t = propstatValues["getcontenttype"] { entry?.contentType = t }
            if let n = propstatValues["displayname"] { entry?.displayName = n }
        case "response":
            if var e = entry {
                if e.isFolder, !e.path.hasSuffix("/") { e.path += "/" }
                entries.append(e)
            }
            entry = nil
        case "exception":
            exception = value.nonEmpty
        case "message":
            errorMessage = value.nonEmpty
        default:
            break
        }
    }

    /// RFC 1123 as `getlastmodified` writes it: `Sat, 13 Sep 2026 10:11:12 GMT`.
    nonisolated static func date(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: text) { return d }
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: text) { return d }
        return ISO8601DateFormatter().date(from: text)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
