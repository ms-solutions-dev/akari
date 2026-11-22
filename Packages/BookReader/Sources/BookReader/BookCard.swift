import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A map in the book with the places labelled on it. Without a language model:
///
/// 1. **Find** - a map word in the file name or alt text, a short page title with a map word
///    ("Map of Altra"), or a nearly textless image page at the edge of the book with a large
///    image (candidate only).
/// 2. **Read** - Apple's on-device text recognition (`VNRecognizeTextRequest`) yields the
///    labels with their frames. Fancy lettering and curved names are only partly legible.
/// 3. **Match** - against the forms of the book's terms: ignoring case, accents and
///    hyphens; names over five letters tolerate one typo.
///
/// Anything not labelled gets no pin - the app never guesses a position.
/// A candidate from the book edge only counts if text recognition finds at least two
/// terms of the book on it.
public struct BookCard: Sendable, Identifiable {
    /// The image, downscaled to at most 2,048 px (JPEG/PNG data - `Data` is `Sendable`).
    public let data: Data
    public let name: String
    /// Term (``Glossary/Item/id``) -> frame of the label, image coordinates 0 to 1,
    /// origin top left.
    public let places: [String: CGRect]
    public var id: String { name }
}

enum CardFinder {

    static func rx(_ muster: String) -> NSRegularExpression { try! NSRegularExpression(pattern: muster) }

    /// "karte/plan" also at the end of a word (Aegyptenkarte, Lageplan); "map/atlas" only as its
    /// own word (otherwise bitmap, plane, planet would match).
    static let cardWord = rx(
        #"(?i)(?:karten?|pl(?:an|äne|aene)|grundriss)(?![a-zäöüß])|(?<![a-zäöüß])(?:maps?|mapa|carte|atlas|kart)(?![a-zäöüß])"#
    )
    /// What opens a map section - narrower than ``cardWord``: "Der Plan" is a chapter,
    /// not a map.
    static let cardPartTitle = rx(
        #"(?i)(?<![a-zäöüß])(?:land|übersichts|uebersichts)?(?:karten?|maps?|atlas|lagepl(?:an|äne)|stadtpl(?:an|äne)|grundriss(?:e)?)(?![a-zäöüß])"#
    )
    static let notCard = rx(
        #"(?i)postkart|kartei|spielkart|visitenkart|eintrittskart|speisekart|fahrkart|auf eine karte|aus karten"#
    )
    static let coverName = rx(
        #"(?i)cover|titel|title|logo|autor|author|portrait|portr|verlag|newsletter|signet|vignette|ornament|deko|schmuck|banner|qr|barcode|ean"#
    )
    static let imageTag = rx(#"(?is)<(?:img|image)\b[^>]*>"#)
    static let source = rx(#"(?i)\b(?:src|xlink:href|href)\s*=\s*"([^"]+)""#)
    static let old = rx(#"(?i)\balt\s*=\s*"([^"]*)""#)

    static func matchesRegex(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func firstCapture(_ r: NSRegularExpression, _ s: String) -> String? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let g = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[g])
    }

    /// An image on a chapter page.
    struct Finding: Hashable {
        let path: String
        let old: String
        let chapter: Int
        let certain: Bool
        /// The image itself is named like a map (file name or alt text) - not just its page.
        var fromName = false
        /// A nearly textless image page up to three chapters after a title with a map word
        /// (a fantasy epic: "Maps", then "Midlands" and "Valmor"). Counts without a glossary
        /// if text recognition reads enough labels.
        var inCardPart = false
    }

    /// The images that may be maps - in reading order, each with its level:
    /// `certain` from name/alt text (rule `name`) or a short title with a map word
    /// (`title`: heading, TOC title, file name of the page, first text line), otherwise a candidate
    /// from the book edge (`margin`). Only ``selection(_:edge:)`` checks the image size of the
    /// candidates - it needs the image data.
    static func findings(in chapter: [(href: String, html: String)], title: [String: String]) -> [Finding] {
        let n = max(chapter.count, 1)
        var findings: [Finding] = []
        var cardPartUntil = -1
        for (pos, (href, html)) in chapter.enumerated() {
            if let t = title[href], words(t) <= 3, matchesRegex(cardPartTitle, t), !matchesRegex(notCard, t) {
                cardPartUntil = pos + 3
            }
            let ns = html as NSString
            let tags = imageTag.matches(in: html, range: NSRange(location: 0, length: ns.length))
            guard !tags.isEmpty else { continue }
            let base = ((href as NSString).lastPathComponent as NSString).deletingPathExtension
            let heading = [Glossary.heading(html, title: title[href]), title[href], base]
                .compactMap { $0 }.filter { !$0.isEmpty }
            let text = visibleText(html)
            let textWords = words(text)
            let first = text.components(separatedBy: "\n").first ?? ""
            let fraction = Double(pos) / Double(n)
            for t in tags {
                let tag = ns.substring(with: t.range)
                guard let src = firstCapture(source, tag), let path = resolved(src, against: href) else {
                    continue
                }
                let altText = firstCapture(old, tag) ?? ""
                let file = (path as NSString).lastPathComponent
                let fromName = [file, altText].contains {
                    matchesRegex(cardWord, $0) && !matchesRegex(notCard, $0)
                }
                let fromTitle = (heading + [first]).contains { s in
                    // A page file name with digits ("Feireiss-Karten-26") is not a title.
                    !s.isEmpty && !matchesRegex(filenameOnly, s) && words(s) <= 8 && matchesRegex(cardWord, s)
                        && !matchesRegex(notCard, s)
                }
                let margin = (fraction <= 0.15 && pos >= 2) || fraction >= 0.9
                let candidate =
                    margin && textWords <= 12
                    && !matchesRegex(coverName, file + " " + altText + " " + heading.joined(separator: " "))
                let inCardPart = pos <= cardPartUntil && textWords <= 12
                if fromName || fromTitle || candidate || inCardPart {
                    findings.append(
                        Finding(
                            path: path, old: altText, chapter: pos, certain: fromName || fromTitle,
                            fromName: fromName, inCardPart: inCardPart))
                }
            }
        }
        return findings
    }

    /// Which findings the app reads: margin candidates only with a long edge of at least 400 px (rule
    /// `margin`), certain ones first, no duplicates, at most four - text recognition costs about a second
    /// per image. `edge` yields the longer side in pixels, `nil` for an unreadable
    /// image (counts as 0).
    static func selection(_ findings: [Finding], edge: (String) async -> Int?) async -> [Finding] {
        var seen: Set<String> = []
        var result: [Finding] = []
        let bookSeries =
            findings.filter(\.certain) + findings.filter { !$0.certain && $0.inCardPart }
            + findings.filter { !$0.certain && !$0.inCardPart }
        for f in bookSeries where result.count < 4 {
            if !f.certain, (await edge(f.path) ?? 0) < 400 { continue }
            if seen.insert(f.path).inserted { result.append(f) }
        }
        return result
    }

    /// The longer side of an image in pixels, without decoding it.
    static func edge(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(w, h)
    }

    static let filenameOnly = rx(#"^\S*\d\S*\z"#)
    static let wordPart = rx(#"[\p{L}\p{N}_]+"#)

    /// Counts words (runs of letters and digits).
    static func words(_ s: String) -> Int {
        wordPart.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// Visible text of a page: without head/script/style, lines at paragraph and cell
    /// boundaries, entities as characters, whitespace collapsed.
    static func visibleText(_ raw: String) -> String {
        func replace(_ muster: String, _ s: String, _ replacement: String) -> String {
            s.replacingOccurrences(of: muster, with: replacement, options: .regularExpression)
        }
        var h = replace(#"(?is)<(script|style|head)\b.*?</\1>"#, raw, " ")
        h = replace(#"(?i)<br\s*/?>|</(p|div|h\d|li|dt|dd|tr)>"#, h, "\n")
        h = replace(#"<[^>]+>"#, h, " ")
        h = Glossary.entities(h)
        h = replace(#"[ \t\u00A0]+"#, h, " ")
        return replace(#"\n\s*\n+"#, h, "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `../Images/map.jpg` against `OEBPS/Text/ch1.xhtml` -> `OEBPS/Images/map.jpg`.
    /// Entities in `src` become characters first ("&amp;"), and
    /// unencoded characters (spaces) work too.
    static func resolved(_ src: String, against chapter: String) -> String? {
        let raw = Glossary.entities(src)
        guard !raw.hasPrefix("data:"),
            let baseURL =
                (URL(string: chapter, relativeTo: URL(string: "https://buch.invalid/"))
                    ?? chapter.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    .flatMap { URL(string: $0, relativeTo: URL(string: "https://buch.invalid/")) }),
            let target =
                (URL(string: raw, relativeTo: baseURL)
                ?? raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap { URL(string: $0, relativeTo: baseURL) })?.absoluteURL
        else { return nil }
        // `path` is already decoded - a second pass would turn "%2520" into a space.
        return String(target.path.drop { $0 == "/" })
    }

    // MARK: - Reading and matching

    /// Image data downscaled to at most 2,048 px, as a CGImage for text recognition.
    static func image(_ data: Data, edge: Int = 2_048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The labels of a map with frames (0 to 1, origin top left).
    /// Two passes: upright and rotated by 90 degrees - rivers
    /// and mountain ranges often run vertically. The rotated pass reads lettering in both directions;
    /// its frames are mapped back into the upright image.
    static func labels(_ image: CGImage) -> [(text: String, frame: CGRect)] {
        func detect(_ orientation: CGImagePropertyOrientation) -> [(String, CGRect)] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
            return (request.results ?? []).compactMap { o in
                guard let text = o.topCandidates(1).first?.string else { return nil }
                return (text, o.boundingBox)
            }
        }
        // Vision: origin bottom left; with orientation `.right` the image is rotated by 90 degrees.
        let rotated = detect(.right).map { t, r in
            (t, CGRect(x: 1 - (r.minY + r.height), y: r.minX, width: r.height, height: r.width))
        }
        let upright = detect(.up)
        let alreadyThere = Set(upright.map { folded($0.0) })
        return (upright + rotated.filter { !alreadyThere.contains(folded($0.0)) }).map { t, r in
            (t, CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height))
        }
    }

    /// Lowercase, without accents, letters and digits only.
    static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func spacing(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previously = Array(0...y.count)
        for i in 1...x.count {
            var now = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                now[j] = min(
                    previously[j] + 1, now[j - 1] + 1, previously[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previously = now
        }
        return previously[y.count]
    }

    /// Labels that appear as a name in the body text - making map names themselves
    /// tappable, even without a glossary entry ("Rethil" -> map). Never taken freely:
    /// the name must appear capitalized at least twice in the text and must not be a
    /// dictionary word (`dictionary`), so misread fancy lettering never becomes a term.
    /// Name as spelled in the text -> frame of the label.
    static func names(
        _ labels: [(text: String, frame: CGRect)], text: String, known: Set<String>,
        dictionary: Set<String>
    ) -> [String: CGRect] {
        var names: [String: CGRect] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for b in labels {
            let raw = b.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let words = raw.split(separator: " ").map { $0.lowercased() }
            guard raw.count >= 4, raw.count <= 30, words.count <= 3, !known.contains(folded(raw)),
                words.contains(where: { !dictionary.contains($0) })
            else { continue }
            let muster =
                "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: raw) + "(?![\\p{L}\\p{N}])"
            guard let search = try? NSRegularExpression(pattern: muster, options: .caseInsensitive) else {
                continue
            }
            // The most common capitalized spelling in the text: "VALMOR" on the map, "Valmor" in the book.
            var spellings: [String: Int] = [:]
            for m in search.matches(in: text, range: whole) {
                guard let r = Range(m.range, in: text), text[r].first?.isUppercase == true else { continue }
                spellings[String(text[r]), default: 0] += 1
            }
            guard let (form, n) = spellings.max(by: { $0.value < $1.value }), n >= 2, names[form] == nil
            else { continue }
            names[form] = b.frame
        }
        return names
    }

    /// The words of the labels, lowercase - for the dictionary check upfront.
    static func words(in labels: [(text: String, frame: CGRect)]) -> Set<String> {
        Set(
            labels.flatMap {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    .split(separator: " ").map { $0.lowercased() }
            })
    }

    /// Term -> frame of the label, for all terms of the book (not only places:
    /// groups and buildings appear on maps too).
    static func match(
        _ labels: [(text: String, frame: CGRect)], glossary: Glossary
    ) -> [String: CGRect] {
        let read = labels.map { (folded($0.text), $0.frame) }.filter { $0.0.count >= 3 }
        var places: [String: CGRect] = [:]
        for e in glossary.entries {
            for form in e.forms {
                let f = folded(form)
                guard f.count >= 3 else { continue }
                if let hit = read.first(where: { $0.0 == f || (f.count > 5 && spacing($0.0, f) <= 1) }) {
                    places[e.id] = hit.1
                    break
                }
            }
        }
        return places
    }
}
