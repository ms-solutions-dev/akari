import Foundation

/// A book's glossary - found in the last chapters, read according to the
/// forms that actually occur in 824 EPUBs:
///
/// - `Term: explanation` - the most common form, also in CAPITALS
/// - `Term - explanation` with a dash
/// - `<b>Term</b> explanation` bold, with or without colon
/// - `<dt>Term</dt><dd>explanation</dd>` as a definition list
///
/// Whether a chapter is a glossary is told by its heading ("Glossary", "Index",
/// "Dramatis personae", "Terminology ...") - or, without it, by its form: at least
/// twelve entries, two fifths of the paragraphs, and **alphabetically ordered**. The
/// last criterion keeps out the wrong ones the analysis showed: a chapter
/// of dialogue lines "Name: sentence", a table of contents "Chapter 1 - Title".
public struct Glossary: Sendable, Hashable, Codable {

    /// What an entry is - for the sheet (person card, map) and the ranking when
    /// marking (places and people first). Computed from heading and explanation
    /// by the kind rules, without a language model.
    public enum Variant: String, Sendable, Hashable, CaseIterable, Codable {
        case person, place = "ort", cluster = "gruppe", thing = "sache", term = "begriff", language =
            "sprache", time = "zeit"
    }

    public struct Item: Sendable, Hashable, Identifiable, Codable {
        public let term: String
        public let explanation: String
        /// The forms under which the term appears in the text: "A'vel" and "Eilmark" for
        /// "A'vel (Eilmark)", "Andere Seite" for "Andere Seite, die", "Tobin Ambersley" and
        /// "Ambersley" for "Ambersley, Tobin".
        public let forms: [String]
        public var type: Variant = .term
        /// The subheading above the entry ("Places", "Kontor Brammsen") - rule `section`.
        var part: String? = nil

        /// What the sheet and "In the book" show: only person and place, the
        /// rest neutrally as term. A term that appears on a map of the book is
        /// practically certainly a place.
        public func display(onCard: Bool) -> Variant {
            type == .person ? .person : (type == .place || onCard) ? .place : .term
        }
        public var id: String { term }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case term = "begriff"
            case explanation = "erklaerung"
            case forms = "formen"
            case type = "typ"
            case part = "abschnitt"
        }
    }

    public let heading: String
    public let entries: [Item]
    /// The chapters (hrefs) the glossary comes from - nothing is marked in them.
    public let chapter: [String]
    /// Forms (lowercase) that also appear in the general dictionary ("Haus", "Gilde", "Sand") -
    /// checked once on opening. They only count capitalized in the middle of a
    /// sentence; if the term is a multi-word term, only the full form counts.
    public var general: Set<String> = []

    /// At least this many entries, otherwise it is not a glossary.
    static let atLeast = 8
    /// Without a matching heading more is needed - and the ordering.
    static let minimumWithoutTitle = 12
    static let atMost = 600
    /// For books without a glossary whose maps are shown anyway (a fantasy epic).
    static let empty = Glossary(heading: "", entries: [], chapter: [])

    static let headings = try! NSRegularExpression(
        pattern:
            #"(?i)(glossar|glossary|begriffe|begriffserkl|terminolog|wörterbuch|worterbuch|lexikon|"#
            + #"personenverzeichnis|personen und|dramatis personae|namen und|namenregister|erläuterung|"#
            + #"register|who's who|figuren|geisterkunde|orte und|götter|anhang|appendix)"#)
    static let notHeadings = try! NSRegularExpression(
        pattern:
            #"(?i)(danksagung|acknowledg|impressum|über den autor|about the author|leseprobe|"#
            + #"inhaltsverzeichnis|table of contents|copyright|newsletter)"#)

    // MARK: - Reading (the rules themselves are in `GlossaryRules.swift`)

    /// The heading: `h1`-`h3`, otherwise the chapter title from the table of contents,
    /// otherwise the first short line of text (Komga books often carry "GLOSSAR" only as a
    /// paragraph). The file's `<title>` is no good: it is usually the book title, and
    /// for one book even percent-encoded ("Die%20gl%C3%A4serne%20Stadt" showed up in the sheet).
    static func heading(_ html: String, title: String? = nil) -> String? {
        if let h = firstMatch(#"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>"#, in: html) { return h }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let lines = paragraphs(String(html.prefix(4_000)))
        if let first = lines.first?.text.trimmingCharacters(in: .whitespaces), first.count <= 60,
            !first.contains(":"), first.split(separator: " ").count <= 6
        {
            return first
        }
        return nil
    }

    private static func firstMatch(_ muster: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: muster),
            let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let r = Range(m.range(at: 1), in: html)
        else { return nil }
        let text = stripped(String(html[r]))
        return text.isEmpty ? nil : text
    }

    /// A paragraph with what was emphasized at the start (bold/italic) - the
    /// definition list becomes paragraphs "Term: explanation".
    struct Paragraph {
        let text: String
        /// The term, if it was bold or italic at the start.
        let emphasized: String?
    }

    private static let cell = try! NSRegularExpression(pattern: #"(?is)(<t[dh][^>]*>)(.*?)(</t[dh]>)"#)

    /// `<p>`/`<br>` inside a table cell become spaces.
    private static func cellsFlattened(_ html: String) -> String {
        let ns = html as NSString
        var from = ""
        var until = 0
        for m in cell.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let inner = m.range(at: 2)
            from += ns.substring(with: NSRange(location: until, length: inner.location - until))
            from += ns.substring(with: inner).replacingOccurrences(
                of: #"(?i)</?p[^>]*>|<br\s*/?>"#, with: " ", options: .regularExpression)
            until = inner.location + inner.length
        }
        return from + ns.substring(from: until)
    }

    static func paragraphs(_ html: String) -> [Paragraph] {
        var t = html
        t = t.replacingOccurrences(
            of: #"(?is)<(head|script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        // <dt>Term</dt><dd>explanation</dd> -> one line "Term: explanation"
        t = t.replacingOccurrences(
            of: #"(?is)<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>"#, with: "<p><b>$1</b>: ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)</dd>"#, with: "</p>", options: .regularExpression)
        // Tables (rule `table`): separate the cells of a row with "│", smooth paragraphs in
        // cells - otherwise "Vater Anselm" and "Wegführer" stick together.
        t = t.replacingOccurrences(
            of: #"(?is)</t[dh]>\s*(?=<t[dh][^>]*>)"#, with: " │ ", options: .regularExpression)
        t = cellsFlattened(t)
        var result: [Paragraph] = []
        t = t.replacingOccurrences(
            of: #"(?i)<br\s*/?>|</p>|</div>|</h[1-6]>|</li>|</tr>"#, with: "\u{1E}",
            options: .regularExpression)
        for raw in t.components(separatedBy: "\u{1E}") {
            var emphasized: String?
            if let regex = try? NSRegularExpression(
                pattern: #"(?is)^\s*(?:<p[^>]*>|<li[^>]*>|<div[^>]*>)?\s*<(b|strong|i|em)[^>]*>(.*?)</\1>"#),
                let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                let r = Range(m.range(at: 2), in: raw)
            {
                let h = stripped(String(raw[r]))
                if !h.isEmpty { emphasized = h }
            }
            let text = stripped(raw)
            if !text.isEmpty { result.append(Paragraph(text: text, emphasized: emphasized)) }
        }
        return result
    }

    static func stripped(_ html: String) -> String {
        let s = entities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let termPattern = try! NSRegularExpression(
        pattern:
            #"^([\p{L}\p{Nl}\p{No}][\p{L}\p{N}_'’.,\- ]{1,48}?(?:\s*\([^)]{1,30}\))?)\s*(?:[:：]\s*|\s+[–—-]\s+)(.{8,})$"#
    )

    /// How ordered the terms are - share of steps that do not go backwards
    /// (first letter, without accents, case-insensitive).
    static func ordering(_ terms: [String]) -> Double {
        guard terms.count > 1 else { return 1 }
        let initials = terms.map { fold($0).first ?? " " }
        var good = 0
        for i in 1..<initials.count where initials[i] >= initials[i - 1] { good += 1 }
        return Double(good) / Double(initials.count - 1)
    }

    /// Fold: NFKD, keep only ASCII, lowercase. What has no ASCII decomposition
    /// (CJK, "ł", "Œ") drops out - "龍 23. 01. 1928" then starts with the space, and a
    /// list of Chinese zodiac signs counts as ordered.
    static func fold(_ s: String) -> String {
        var result = String.UnicodeScalarView()
        for z in s.decomposedStringWithCompatibilityMapping.unicodeScalars where z.isASCII {
            result.append(z)
        }
        return String(result).lowercased()
    }

    /// The forms of a term in the text: without bracket, the bracket itself ("Eilmark"),
    /// "Andere Seite, die" reversed; arrows and stars removed.
    static func forms(_ term: String) -> [String] {
        var b = term.replacingOccurrences(of: "→", with: "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        var list: [String] = []
        if let on = b.firstIndex(of: "("), let to = b.firstIndex(of: ")"), on < to {
            let bracket = String(b[b.index(after: on)..<to]).trimmingCharacters(in: .whitespaces)
            b = String(b[..<on]).trimmingCharacters(in: .whitespaces)
            if bracket.count >= 3, !bracket.contains(" "), bracket.first?.isLetter == true {
                list.append(bracket)
            }
        }
        if let comma = b.range(of: ", ") {
            let article = String(b[comma.upperBound...])
            if ["der", "die", "das", "the"].contains(article.lowercased()) {
                b = String(b[..<comma.lowerBound])
            } else if let g = clusters(reverse, b) {
                // Rule `reverse`: "Ambersley, Tobin" appears in the text as "Tobin Ambersley"
                // or "Ambersley".
                return [g[2].trimmingCharacters(in: .whitespaces) + " " + g[1], g[1]] + list
            }
        }
        // Rule `separator`: "Rethil/Rethmark" are two forms.
        if b.contains("/") {
            let share = b.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                $0.count >= 3
            }
            if share.count > 1 { return share + list }
        }
        if b.count >= 3 { list.insert(b, at: 0) }
        return list
    }

    static let reverse = rx(
        #"^([A-ZÄÖÜ][\p{L}\p{N}_'’\-]+(?: [A-ZÄÖÜ][\p{L}\p{N}_'’\-]+)?), ((?:[A-ZÄÖÜ][\p{L}\p{N}_'’.\-]*\s?){1,3})$"#
    )

    // MARK: - From the book

    /// Searches the whole book - `chapter` are (href, HTML) in reading order; `title` are
    /// the chapter titles from the table of contents (href -> title). At the end of the book (the last
    /// eight chapters, for long books the last 10 %) the form suffices; before that a
    /// matching heading is needed (rule `front`; many indexes lay before the old
    /// search range, often the "Dramatis Personae" at the front). Several chapters
    /// (main characters, minor characters, terms) become one glossary.
    public static func find(
        in chapter: [(href: String, html: String)], title: [String: String] = [:]
    )
        -> Glossary?
    {
        var entries: [Item] = []
        var hrefs: [String] = []
        var heading: String?
        for (position, (href, html)) in chapter.enumerated() {
            let atBack = inSearchWindow(position, from: chapter.count)
            guard let read = parse(html: html, title: title[href], atBack: atBack) else { continue }
            entries += read.entries
            hrefs.append(href)
            if heading == nil || read.entries.count > entries.count / 2 {
                heading = read.heading
            }
        }
        guard !entries.isEmpty else { return nil }
        var seen: Set<String> = []
        let unambiguous = entries.filter { seen.insert($0.term.lowercased()).inserted }
        return Glossary(
            heading: heading ?? "Glossar", entries: Array(unambiguous.prefix(atMost)),
            chapter: hrefs)
    }

    /// The entry for a word from the text - via the forms, case-insensitive.
    public func entry(for word: String) -> Item? {
        let sought = word.lowercased()
        return entries.first { $0.forms.contains { $0.lowercased() == sought } }
    }

    /// The terms in a chapter's HTML as `<span class="ss-glossar" data-ss-begriff>`
    /// - set before the web view loads the file. Only in text, never in tags, not in
    /// `head`, `script`, `style`, headings and links; whole words, case-insensitive;
    /// long forms first (one regex pass with alternation, "Brune Halvaret" before "Brune").
    /// At most 400 per chapter.
    ///
    /// **Marked != tappable**: every mention gets the `span` and is tappable; only the mentions from
    /// `marked` get a line (`ss-m`) - the indices of the ``MarkingPlan`` for this chapter. Without a plan
    /// (it is still computing) the first mention of each term in the chapter gets the line.
    ///
    /// Why not Readium's decorations: their text anchors (Hypothesis `TextQuoteAnchor`)
    /// read the whole chapter text for every mark and search fuzzily - 400 of them
    /// in a long appendix held the web view for seconds, taps did not arrive,
    /// and a tap during paging became "book finished".
    /// `hint` is the VoiceOver hint of every mention ("Open explanation"): it
    /// is a button, the marking itself is not read aloud.
    public static func mark(
        html: String, glossary: Glossary, to: Bool = true, marked: Set<Int>? = nil, hint: String = "",
        hairline: Int = 32, pronounced: Bool = false, accent: UInt32? = nil
    ) -> String {
        var seen: Set<String> = []
        let spoken =
            hint.isEmpty ? "" : " role=\"button\" aria-description=\"" + attribute(hint) + "\""
        let run = walk(html: html, glossary: glossary) { index, entry, word in
            let hairline = marked.map { $0.contains(index) } ?? seen.insert(entry.id).inserted
            return "<span class=\"ss-glossar" + (hairline ? " ss-m" : "") + "\" data-ss-begriff=\""
                + attribute(entry.id) + "\"" + spoken + ">" + word + "</span>"
        }
        guard !run.mentions.isEmpty else { return html }
        return extra(in: run.html, to: to, hairline: hairline, pronounced: pronounced, accent: accent)
    }

    /// The mentions of a chapter with their word position - for the ``TermIndex``.
    /// The same pass as ``mark(html:glossary:marked:hint:)``, so the indices of the
    /// plan match the mentions at load time exactly.
    public static func mentions(
        html: String, glossary: Glossary
    ) -> (mentions: [TermIndex.Mention], words: Int) {
        let run = walk(html: html, glossary: glossary, set: nil)
        return (run.mentions, run.words)
    }

    static let tagRegex = rx("<[^>]*>")
    static let epigraphClass = rx(#"(?i)\bclass\s*=\s*"[^"]*(epigraph|motto|zitat|quote)"#)
    static func matchesEpigraph(_ tag: String) -> Bool {
        epigraphClass.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil
    }

    /// Is there already sentence content before `spot` in the same text piece, and no sentence end? At the start of a
    /// text piece (after a tag) it counts as a sentence start - better one mention fewer.
    static func midSentence(_ s: NSString, before spot: Int) -> Bool {
        var i = spot - 1
        while i >= 0, let z = UnicodeScalar(s.character(at: i)),
            CharacterSet.whitespacesAndNewlines.contains(z)
        {
            i -= 1
        }
        guard i >= 0, let z = UnicodeScalar(s.character(at: i)) else { return false }
        return !".!?:;«»\"„“”…".unicodeScalars.contains(z)
    }
    static let wordRegex = rx(#"[\p{L}\p{N}]+"#)
    /// No marking in there ...
    static let blockedTags: Set<String> = [
        "head", "script", "style", "a", "h1", "h2", "h3", "h4", "h5", "h6", "title",
    ]
    /// ... and no counting either - that is not reading text.
    static let silentTags: Set<String> = ["head", "script", "style", "title"]

    static func tally(_ s: String) -> Int {
        wordRegex.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// One pass through the HTML of a chapter: every mention in the text with its
    /// word position in the chapter. With `set` the new HTML is built at the same time - mention
    /// `index` is replaced by whatever `set` returns.
    static func walk(
        html: String, glossary: Glossary, set: ((_ index: Int, _ entry: Item, _ word: String) -> String)?
    ) -> (html: String, mentions: [TermIndex.Mention], words: Int) {
        let forms = glossary.searchForms
        let alternation = forms.map { NSRegularExpression.escapedPattern(for: $0.form) }.joined(
            separator: "|")
        let regex =
            forms.isEmpty
            ? nil
            : try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{M}])(?:" + alternation + ")(?![\\p{L}\\p{M}])",
                options: .caseInsensitive)
        var entries: [String: Item] = [:]
        for (form, entry) in forms where entries[form.lowercased()] == nil {
            entries[form.lowercased()] = entry
        }
        let ns = html as NSString
        var output = ""
        var mentions: [TermIndex.Mention] = []
        var words = 0
        var position = 0
        // Sections in which nothing is marked - up to the closing tag.
        var lockedUntil: String?
        // An epigraph at the start of a chapter stays tappable but gets no line.
        var epigraphUntil: String?
        let tags = tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        func text(_ r: NSRange) {
            let chunk = ns.substring(with: r)
            let counts = lockedUntil.map { !silentTags.contains($0) } ?? true
            guard lockedUntil == nil, mentions.count < 400, let regex else {
                if counts { words += tally(chunk) }
                if set != nil { output += chunk }
                return
            }
            var last = 0
            let sns = chunk as NSString
            for m in regex.matches(in: chunk, range: NSRange(location: 0, length: sns.length)) {
                guard mentions.count < 400 else { break }
                let word = sns.substring(with: m.range)
                guard let entry = entries[word.lowercased()] else { continue }
                // A dictionary word only counts capitalized in the middle of a sentence.
                if glossary.general.contains(word.lowercased()),
                    !(word.first?.isUppercase == true && midSentence(sns, before: m.range.location))
                {
                    continue
                }
                let before = sns.substring(with: NSRange(location: last, length: m.range.location - last))
                words += tally(before)
                mentions.append(
                    TermIndex.Mention(
                        term: entry.id, word: words, epigraph: epigraphUntil != nil ? true : nil))
                if let set { output += before + set(mentions.count - 1, entry, word) }
                words += tally(word)
                last = m.range.location + m.range.length
            }
            let remainder = sns.substring(from: last)
            words += tally(remainder)
            if set != nil { output += remainder }
        }
        for tag in tags {
            text(NSRange(location: position, length: tag.range.location - position))
            let raw = ns.substring(with: tag.range)
            if set != nil { output += raw }
            position = tag.range.location + tag.range.length
            let name = tagName(raw)
            if let until = epigraphUntil {
                if raw.hasPrefix("</"), name == until { epigraphUntil = nil }
            } else if !raw.hasPrefix("</"), !raw.hasSuffix("/>"), words < 150,
                name == "blockquote" || Glossary.matchesEpigraph(raw)
            {
                epigraphUntil = name
            }
            if let until = lockedUntil {
                if raw.hasPrefix("</"), name == until { lockedUntil = nil }
            } else if !raw.hasPrefix("</"), !raw.hasSuffix("/>"), blockedTags.contains(name) {
                lockedUntil = name
            }
        }
        text(NSRange(location: position, length: ns.length - position))
        return (output, mentions, words)
    }

    /// Style and tap marker into the `head`. The line is a restrained
    /// pencil underline in the text color (32 %), 0.06 em thick, 0.22 em below the
    /// baseline, descenders stay free - no blue, no dot, never animated. Only `ss-m`
    /// carries it; `html.ss-glossar-aus` removes it. The marker holds the most recently tapped
    /// term, which the app queries after the tap. XHTML is XML: the script sits in CDATA,
    /// otherwise the parser trips over `&&`.
    /// `line`: opacity of the line in percent of the text color, per reading theme.
    /// `prominent`: level "Prominent" in the profile's accent color (`accent`, else text color).
    static func extra(
        in html: String, to: Bool, hairline: Int = 32, pronounced: Bool = false, accent: UInt32? = nil
    ) -> String {
        let color = accent.map { ";--ss-akzent:#" + String(format: "%06X", $0) } ?? ""
        let header = """
            <style>:root{--ss-linie:\(hairline)%\(color)}.ss-glossar{-webkit-tap-highlight-color:transparent}\
            .ss-glossar.ss-m{text-decoration:underline;text-decoration-thickness:0.06em;text-underline-offset:0.22em;\
            text-decoration-skip-ink:auto;text-decoration-color:color-mix(in srgb,currentColor var(--ss-linie,32%),transparent)}\
            html.ss-deutlich .ss-glossar.ss-m{text-decoration-thickness:0.08em;\
            text-decoration-color:color-mix(in srgb,var(--ss-akzent,currentColor) 70%,transparent)}\
            html.ss-glossar-aus .ss-glossar.ss-m{text-decoration:none}\
            .ss-glossar.ss-aktiv{background:color-mix(in srgb,var(--ss-akzent,currentColor) 14%,transparent);border-radius:3px}</style>\
            <script>//<![CDATA[
            document.addEventListener('pointerdown',function(e){var t=e.target;t=(t&&t.closest)?t.closest('.ss-glossar'):null;\
            window.__ssBegriff=t?t.getAttribute('data-ss-begriff'):null;window.__ssEl=t;},true);
            //]]></script>
            """
        var s = html
        if let r = s.range(of: "</head>", options: .caseInsensitive) {
            s.replaceSubrange(r, with: header + "</head>")
        } else {
            s = header + s
        }
        let classes = [to ? nil : "ss-glossar-aus", pronounced ? "ss-deutlich" : nil].compactMap { $0 }
        if !classes.isEmpty, let r = s.range(of: "<html", options: .caseInsensitive) {
            s.replaceSubrange(r, with: "<html class=\"" + classes.joined(separator: " ") + "\"")
        }
        return s
    }

    static func tagName(_ tag: String) -> String {
        var t = tag.dropFirst()
        if t.hasPrefix("/") { t = t.dropFirst() }
        return String(t.prefix { $0.isLetter || $0.isNumber }).lowercased()
    }

    static func attribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// The forms searched for in the text - long first so "Brune Halvaret"
    /// beats "Bene"; only with three or more characters.
    public var searchForms: [(form: String, entry: Item)] {
        entries.flatMap { e in
            let multiWord = e.forms.contains { $0.contains(" ") }
            return e.forms.filter { f in
                f.count >= 3 && !(multiWord && !f.contains(" ") && general.contains(f.lowercased()))
            }.map { ($0, e) }
        }
        .sorted { $0.0.count > $1.0.count }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case heading = "ueberschrift"
        case entries = "eintraege"
        case chapter = "kapitel"
        case general = "allgemein"
    }
}

extension Glossary {

    /// An explicitly named relation: "daughter of X", "-> X" - X is itself in the glossary.
    /// `word` is the kinship word, empty for the arrow.
    public struct Relation: Hashable, Sendable {
        public let word: String
        public let target: Item
    }

    static let relationWord = try! NSRegularExpression(
        pattern:
            #"(?i)\b(sohn|tochter|vater|mutter|bruder|schwester|halbbruder|halbschwester|ehefrau|ehemann|frau|mann|gattin|gatte|witwe|witwer|onkel|tante|neffe|nichte|enkel|enkelin|cousin|cousine|freund|freundin|geliebte[rn]?|verlobte[rn]?|diener|dienerin|herr|herrin|lehrer|lehrerin|sch(ü|ue)ler|sch(ü|ue)lerin|son|daughter|father|mother|brother|sister|wife|husband|uncle|aunt)\s+(?:von|des|der|of)\s+(?:dem\s+|den\s+)?$"#
    )

    /// Only what is stated explicitly, nothing inferred: a kinship word with "von/des/der"
    /// directly before the name, or an arrow ("->Og"). Each target at most once.
    public func relations(_ e: Item) -> [Relation] {
        let text = e.explanation as NSString
        var found: [Relation] = []
        // All forms from two characters ("Og"), long first - the search forms of the body text start at three.
        let forms = entries.flatMap { z in z.forms.filter { $0.count >= 2 }.map { ($0, z) } }
            .sorted { $0.0.count > $1.0.count }
        for (form, target) in forms
        where target.id != e.id && !found.contains(where: { $0.target.id == target.id }) {
            let muster = "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: form) + "(?![\\p{L}])"
            guard let rx = try? NSRegularExpression(pattern: muster) else { continue }
            for m in rx.matches(in: e.explanation, range: NSRange(location: 0, length: text.length)) {
                let start = max(0, m.range.location - 40)
                let before = text.substring(with: NSRange(location: start, length: m.range.location - start))
                if before.hasSuffix("→") || before.hasSuffix("→ ") {
                    found.append(Relation(word: "", target: target))
                    break
                }
                let d = before as NSString
                if let w = Glossary.relationWord.firstMatch(
                    in: before, range: NSRange(location: 0, length: d.length))
                {
                    found.append(Relation(word: d.substring(with: w.range(at: 1)), target: target))
                    break
                }
            }
        }
        return found
    }
}
