import Foundation

/// A position in the book as an EPUB CFI - the language spoken by Grimmory's web reader
/// (foliate-js) and KOReader: `epubcfi(/6/12!/4/2[ch2]/10)`.
///
/// Readium has no CFIs; its locator carries file, progress and a
/// CSS selector. The way in between is the element path: before the `!` stands
/// the spine entry, after it the path from `<html>` to the first visible
/// element - even numbers are elements, odd ones text nodes, `[id]` an
/// assertion. Text nodes and character offsets are dropped here: an element as a
/// position is as precise as a page, and both web readers jump there.
public struct BookLocation: Hashable, Sendable {

    /// The spine entry, zero-based - counted over all `itemref`s, including those with
    /// `linear="no"`, which Readium removes from the reading order.
    public let entry: Int
    /// The path in the document, from `<html>`.
    public let steps: [Step]

    public struct Step: Hashable, Sendable, Codable {
        /// Which of the element children, one-based.
        public let index: Int
        public let id: String?

        public init(index: Int, id: String? = nil) {
            self.index = index
            self.id = id
        }
    }

    public init(entry: Int, steps: [Step]) {
        self.entry = max(entry, 0)
        self.steps = steps
    }

    /// Reads a CFI. A range (`...,/2/1:0,/3:5`) is cut to the common
    /// parent path, a second indirection (`!` within `!`) is dropped.
    public init?(cfi: String) {
        var text = cfi.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("epubcfi(") { text.removeFirst("epubcfi(".count) }
        if text.hasSuffix(")") { text.removeLast() }
        let share = BookLocation.share(text)
        guard let package = share.first, let latest = BookLocation.steps(from: package).last else {
            return nil
        }
        entry = latest.index - 1
        steps = share.count > 1 ? BookLocation.steps(from: share[1]) : []
    }

    /// Writes the CFI. `spine` is the step of the `<spine>` in the package - 6
    /// when metadata and manifest come before it, as almost always.
    public func cfi(spine: Int = 6) -> String {
        var s = "epubcfi(/\(spine)/\(2 * (entry + 1))!"
        for step in steps {
            s += "/\(2 * step.index)"
            if let id = step.id, !id.isEmpty { s += "[\(BookLocation.escaped(id))]" }
        }
        return s + ")"
    }

    // MARK: - Reading

    /// Splits at `!` and `,` at the top level - not inside assertions.
    private static func share(_ text: String) -> [String] {
        var share: [String] = []
        var current = ""
        var inBracket = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "^":
                escaped = true
                current.append(character)
            case "[":
                inBracket = true
                current.append(character)
            case "]":
                inBracket = false
                current.append(character)
            case "!" where !inBracket:
                share.append(current)
                current = ""
            case "," where !inBracket:
                share.append(current)
                return share
            default:
                current.append(character)
            }
        }
        share.append(current)
        return share
    }

    /// Reads `/4/2[ch2]/10/1:0` - up to the first text node.
    static func steps(from path: String) -> [Step] {
        var steps: [Step] = []
        var remainder = Substring(path)
        while let slash = remainder.firstIndex(of: "/") {
            remainder = remainder[remainder.index(after: slash)...]
            let digits = remainder.prefix { $0.isNumber }
            guard let integer = Int(digits) else { break }
            remainder = remainder.dropFirst(digits.count)
            var id: String?
            if remainder.first == "[" {
                var content = ""
                var escaped = false
                var index = remainder.index(after: remainder.startIndex)
                while index < remainder.endIndex {
                    let z = remainder[index]
                    index = remainder.index(after: index)
                    if escaped {
                        content.append(z)
                        escaped = false
                    } else if z == "^" {
                        escaped = true
                    } else if z == "]" {
                        break
                    } else {
                        content.append(z)
                    }
                }
                remainder = remainder[index...]
                // Only a plain identifier is an `id`; text assertions carry commas.
                if !content.isEmpty, !content.contains(","), !content.contains(";") { id = content }
            }
            // A character offset or a text node ends the element path.
            if integer % 2 == 1 { break }
            steps.append(Step(index: integer / 2, id: id))
            if remainder.first == ":" { break }
        }
        return steps
    }

    static func escaped(_ id: String) -> String {
        var s = ""
        for z in id {
            if "^[](),;=".contains(z) { s.append("^") }
            s.append(z)
        }
        return s
    }
}

// MARK: - The bridge into the document

extension BookLocation {

    /// Determines in the visible document the path to the first visible element -
    /// result like `/4/2[ch2]/10`, or `null`.
    static let jsDetermine = """
        (function(){
          var esc=function(s){return s.replace(/[\\^\\[\\]\\(\\),;=]/g,function(c){return '^'+c;});};
          var loc=(window.readium&&readium.findFirstVisibleLocator)?readium.findFirstVisibleLocator():null;
          var el=null;
          try{if(loc&&loc.locations&&loc.locations.cssSelector){el=document.querySelector(loc.locations.cssSelector);}}catch(e){}
          if(!el){return null;}
          var pfad='';var n=el;
          while(n&&n!==document.documentElement&&n.parentElement){
            var p=n.parentElement,c=p.children,i=-1;
            for(var j=0;j<c.length;j++){if(c[j]===n){i=j;break;}}
            if(i<0){return null;}
            pfad='/'+(2*(i+1))+(n.id?'['+esc(n.id)+']':'')+pfad;
            n=p;
          }
          return pfad;
        })()
        """

    /// Resolves the path in the visible document and scrolls there - `true` if
    /// the element was found. Readium's `scrollToLocator` takes a
    /// CSS selector; a short-lived attribute makes the element unique.
    static func jsJump(to steps: [Step]) -> String {
        let list =
            (try? JSONEncoder().encode(steps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
            (function(steps){
              var n=document.documentElement;
              for(var i=0;i<steps.length;i++){
                var s=steps[i],byId=s.id?document.getElementById(s.id):null;
                if(byId){n=byId;continue;}
                var c=n.children;if(!c||s.index<1||s.index>c.length){return 'fehlt bei Schritt '+i+': index '+s.index+' von '+(c?c.length:0)+' unter '+n.tagName+(n.id?'#'+n.id:'');}
                n=c[s.index-1];
              }
              if(!n||n===document.documentElement){return false;}
              n.setAttribute('data-akari-ziel','1');
              var ok=false;
              try{ok=readium.scrollToLocator({href:'#',type:'application/xhtml+xml',locations:{cssSelector:'[data-akari-ziel]'}},false);}catch(e){}
              n.removeAttribute('data-akari-ziel');
              return ok?true:('scrollToLocator false, Element '+n.tagName);
            })(\(list))
            """
    }
}

/// What the package document (OPF) says about the spine: the step of the
/// `<spine>` and the files of the `itemref`s in order - paths relative to the
/// root of the container, like Readium's `href`s.
///
/// Readium removes `linear="no"` from the reading order; foliate-js counts all.
/// Without this map the spine entry would be wrong in every book with a
/// non-linear front matter.
public struct SpineCard: Sendable, Hashable {

    public let spineStep: Int
    public let entries: [String]

    public init(spineStep: Int, entries: [String]) {
        self.spineStep = spineStep
        self.entries = entries
    }

    /// Reads `META-INF/container.xml` and returns the path of the OPF.
    public static func opfPath(container: Data) -> String? {
        let reader = ContainerReader()
        let parser = XMLParser(data: container)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        return reader.path
    }

    /// Reads the OPF at `path` (e.g. `OEBPS/content.opf`).
    public init?(opf: Data, path: String) {
        let reader = OPFReader()
        let parser = XMLParser(data: opf)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        guard let step = reader.spineStep, !reader.idrefs.isEmpty else { return nil }
        let folder = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        spineStep = step
        entries = reader.idrefs.compactMap { idref in
            reader.manifest[idref].map { SpineCard.resolved($0, in: folder) }
        }
    }

    /// The spine entry for a Readium `href` (e.g. `OEBPS/ch2.xhtml`, also
    /// percent-encoded or with a leading slash).
    public func entry(for href: String) -> Int? {
        entries.firstIndex(of: SpineCard.plain(href))
    }

    public func href(for entry: Int) -> String? {
        entries.indices.contains(entry) ? entries[entry] : nil
    }

    static func resolved(_ href: String, in folder: String) -> String {
        let raw = href.removingPercentEncoding ?? href
        var share = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        for part in raw.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !share.isEmpty { share.removeLast() }
            default: share.append(String(part))
            }
        }
        return share.joined(separator: "/")
    }
}

private final class ContainerReader: NSObject, XMLParserDelegate {
    var path: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        if elementName == "rootfile", path == nil { path = attributes["full-path"] }
    }
}

private final class OPFReader: NSObject, XMLParserDelegate {
    var spineStep: Int?
    var manifest: [String: String] = [:]
    var idrefs: [String] = []
    private var depth = 0
    private var packageChildren = 0
    private var imManifest = false
    private var imSpine = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        depth += 1
        if depth == 2 {
            packageChildren += 1
            if elementName == "spine" {
                spineStep = 2 * packageChildren
                imSpine = true
            }
            imManifest = elementName == "manifest"
        } else if depth == 3 {
            if imManifest, elementName == "item", let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
            } else if imSpine, elementName == "itemref", let idref = attributes["idref"] {
                idrefs.append(idref)
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if depth == 2 {
            imManifest = false
            imSpine = false
        }
        depth -= 1
    }
}
