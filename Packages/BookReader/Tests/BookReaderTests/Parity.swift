import Foundation
import ReadiumZIPFoundation
import Testing

@testable import BookReader

/// Parity of Swift and the Python reference on the 716 gold-standard books.
///
/// Reads every EPUB like the reference (ZIP, container, OPF, spine, nav/ncx, UTF-8 otherwise
/// cp1252), calls ``Glossary/find(in:title:)`` and ``CardFinder/findings(in:title:)`` and
/// compares with `soll.jsonl`, what the reference rules find on
/// the same inputs. Plus the recall of both versions against the gold parts.
///
/// **Runs on request only**: `AKARI_GOLD=<folder>` (via xcodebuild as
/// `TEST_RUNNER_AKARI_GOLD`). The folder holds `soll.jsonl` and `epubs/` - protected
/// books, local only, never in the repo. Written are `abgleich.jsonl` (per book the
/// deviations, only terms and numbers) and `zusammenfassung.json`.
@Suite("Parity of Swift and Python")
struct Parity {

    static let folder = ProcessInfo.processInfo.environment["AKARI_GOLD"].map { URL(filePath: $0) }

    @Test(.enabled(if: Parity.folder != nil), .timeLimit(.minutes(60)))
    func measure() async throws {
        let root = try #require(Parity.folder)
        let target = try String(contentsOf: root.appending(path: "soll" + ".jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        let only = Int(ProcessInfo.processInfo.environment["AKARI_GOLD_NUR"] ?? "") ?? target.count
        // Magnifier: `AKARI_GOLD_BUCH=<id>` writes paragraphs and entries of a book to
        // `lupe.json` - for comparison with the reference's paragraphs/entry on the same chapter.
        if let lupe = ProcessInfo.processInfo.environment["AKARI_GOLD_BUCH"],
            let book = target.first(where: { $0["id"] as? String == lupe })
        {
            let epub = try await Epub.load(
                root.appending(path: "epubs").appending(path: book["ordner"] as? String ?? "")
                    .appending(path: book["datei"] as? String ?? ""))
            var chapter: [[String: Any]] = []
            for (pos, (href, html)) in epub.chapter.enumerated() {
                let atBack = Glossary.inSearchWindow(pos, from: epub.chapter.count)
                guard let g = Glossary.parse(html: html, title: epub.title[href], atBack: atBack) else {
                    continue
                }
                let u = Glossary.heading(html, title: epub.title[href])
                chapter.append([
                    "pos": pos, "href": href, "ueberschrift": g.heading,
                    "absaetze": Glossary.paragraphs(html).filter { $0.text != u }.map {
                        [
                            $0.text, $0.emphasized ?? "",
                            Glossary.entry($0, people: true, matches: true)?.term ?? "—",
                        ]
                    },
                    "eintraege": g.entries.prefix(60).map {
                        [$0.term, $0.explanation.prefix(40).description]
                    },
                ])
            }
            let json = try JSONSerialization.data(withJSONObject: chapter, options: [.prettyPrinted])
            try json.write(to: root.appending(path: "lupe.json"))
            return
        }
        var figures = Counter()
        var lines: [String] = []
        for book in target.prefix(only) {
            let path = root.appending(path: "epubs").appending(path: book["ordner"] as? String ?? "")
                .appending(path: book["datei"] as? String ?? "")
            let result: [String: Any]
            do {
                let epub = try await Epub.load(path)
                result = await Comparison.book(target: book, epub: epub, figures: &figures)
            } catch {
                figures.failure += 1
                result = ["id": book["id"] ?? "", "fehler": String(describing: error)]
            }
            let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            lines.append(String(decoding: json, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: root.appending(path: "abgleich" + ".jsonl"), atomically: true, encoding: .utf8)
        let summary = try JSONSerialization.data(
            withJSONObject: figures.summary(), options: [.prettyPrinted, .sortedKeys])
        try summary.write(to: root.appending(path: "zusammenfassung.json"))
        print(String(decoding: summary, as: UTF8.self))
    }
}

// MARK: - EPUB like the reference

/// A book as the reference sees it: chapters in reading order (raw HTML) and
/// the first TOC title per resource (anchor cut off).
struct Epub: @unchecked Sendable {
    let chapter: [(href: String, html: String)]
    let title: [String: String]
    /// An entry of the ZIP, case-insensitive - for the images of the map rule `margin`.
    let read: @Sendable (String) async -> Data?

    static func load(_ url: URL) async throws -> Epub {
        let archive = try await Archive(url: url, accessMode: .read)
        var small: [String: Entry] = [:]
        for e in try await archive.entries() { small[e.path.lowercased()] = small[e.path.lowercased()] ?? e }
        let entries = small
        @Sendable func read(_ name: String) async throws -> Data? {
            guard let e = entries[name.lowercased()] else { return nil }
            let buffer = Puffer()
            _ = try await archive.extract(e, skipCRC32: true) { await buffer.append($0) }
            return await buffer.data
        }
        guard let container = try await read("META-INF/container.xml"),
            let opfPath = firstCapture(
                #"full-path\s*=\s*"([^"]+)""#, String(decoding: container, as: UTF8.self)),
            let opfData = try await read(opfPath)
        else { throw Failure.withoutOPF }
        let opf = decode(opfData)
        let baseDirectory = (opfPath as NSString).deletingLastPathComponent

        var items: [String: (href: String, type: String, prop: String)] = [:]
        for tag in all(#"(?i)<item\b[^>]*>"#, opf) {
            guard let id = firstCapture(#"\bid="([^"]+)""#, tag),
                let h = firstCapture(#"\bhref="([^"]+)""#, tag)
            else {
                continue
            }
            items[id] = (
                resolve(baseDirectory, h), firstCapture(#"media-type="([^"]+)""#, tag) ?? "",
                firstCapture(#"properties="([^"]+)""#, tag) ?? ""
            )
        }
        let spine = allGroups(#"<itemref\b[^>]*idref="([^"]+)""#, opf).compactMap { items[$0]?.href }

        // Table of contents: nav first, otherwise ncx
        var toc: [(label: String, href: String)] = []
        if let nav = items.values.first(where: { $0.prop.split(separator: " ").contains("nav") })?.href,
            let raw = try await read(nav).map(decode)
        {
            let part = firstHit(#"(?is)<nav[^>]*epub:type="toc".*?</nav>"#, raw) ?? raw
            let navBase = (nav as NSString).deletingLastPathComponent
            for m in pairs(#"(?is)<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, part) {
                toc.append((text(m.1), resolve(navBase, m.0)))
            }
        }
        if toc.isEmpty, let ncx = items.values.first(where: { $0.type.contains("ncx") })?.href,
            let raw = try await read(ncx).map(decode)
        {
            let ncxBase = (ncx as NSString).deletingLastPathComponent
            for m in pairs(#"(?is)<navLabel>\s*<text>(.*?)</text>.*?<content[^>]*src="([^"]+)""#, raw) {
                toc.append((text(m.0), resolve(ncxBase, m.1)))
            }
        }
        var title: [String: String] = [:]
        for (label, href) in toc where !label.isEmpty {
            let withoutAnchor = String(
                href.split(separator: "#", omittingEmptySubsequences: false).first ?? "")
            if title[withoutAnchor] == nil { title[withoutAnchor] = label }
        }

        var chapter: [(href: String, html: String)] = []
        for href in spine {
            guard let data = try await read(href) else { continue }
            chapter.append((href, decode(data)))
        }
        return Epub(chapter: chapter, title: title, read: { try? await read($0) })
    }

    enum Failure: Error { case withoutOPF }

    actor Puffer {
        var data = Data()
        func append(_ d: Data) { data.append(d) }
    }

    /// UTF-8, otherwise cp1252, otherwise UTF-8 with replacement characters.
    static func decode(_ d: Data) -> String {
        String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252)
            ?? String(decoding: d, as: UTF8.self)
    }

    /// href relative to `base` -> ZIP name: decoded, without anchor, `../` resolved.
    static func resolve(_ baseDirectory: String, _ href: String) -> String {
        let withoutAnchor = String(
            entities(href).split(separator: "#", omittingEmptySubsequences: false).first ?? "")
        let h = withoutAnchor.removingPercentEncoding ?? withoutAnchor
        let full = baseDirectory.isEmpty || baseDirectory == "." ? h : baseDirectory + "/" + h
        var share: [String] = []
        for t in full.split(separator: "/", omittingEmptySubsequences: true) {
            if t == "." { continue }
            if t == "..", !share.isEmpty, share.last != ".." {
                share.removeLast()
            } else {
                share.append(String(t))
            }
        }
        var result = share.joined(separator: "/")
        while result.hasPrefix(".") || result.hasPrefix("/") { result.removeFirst() }
        return result
    }

    /// Visible text of an HTML snippet.
    static func text(_ raw: String) -> String {
        var h = replace(#"(?is)<(script|style|head)\b.*?</\1>"#, raw, " ")
        h = replace(#"(?i)<br\s*/?>|</(p|div|h\d|li|dt|dd|tr)>"#, h, "\n")
        h = replace(#"<[^>]+>"#, h, " ")
        h = entities(h)
        h = replace(#"[ \t\u00A0]+"#, h, " ")
        return replace(#"\n\s*\n+"#, h, "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `html.unescape` - the same function as in the app.
    static func entities(_ s: String) -> String { Glossary.entities(s) }

    // MARK: Regex helpers

    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static func firstCapture(_ p: String, _ s: String) -> String? {
        guard let m = rx(p).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
    static func firstHit(_ p: String, _ s: String) -> String? {
        guard let m = rx(p).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range, in: s)
        else { return nil }
        return String(s[r])
    }
    static func all(_ p: String, _ s: String) -> [String] {
        rx(p).matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s) }
            .map { String(s[$0]) }
    }
    static func allGroups(_ p: String, _ s: String) -> [String] {
        rx(p).matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s)
        }
        .map { String(s[$0]) }
    }
    static func pairs(_ p: String, _ s: String) -> [(String, String)] {
        rx(p).matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else {
                return nil
            }
            return (String(s[a]), String(s[b]))
        }
    }
    static func replace(_ p: String, _ s: String, _ replacement: String) -> String {
        rx(p).stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

// MARK: - Comparison

/// Normalized terms: lowercase, whitespace collapsed, arrows and stars removed.
func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "→", with: "").replacingOccurrences(of: "*", with: "")
        .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

enum Comparison {

    static let goldKinds: Set<String> = ["glossar", "personen", "orte", "sprache", "gemischt"]

    static func book(target: [String: Any], epub: Epub, figures: inout Counter) async -> [String: Any] {
        let py = target["glossar"] as? [String: Any] ?? [:]
        let pyFinds = py["findet"] as? Bool ?? false
        let pyChapters = Set((py["kapitel"] as? [[String: Any]] ?? []).compactMap { $0["pos"] as? Int })
        var pyKind: [String: String] = [:]
        for e in py["eintraege"] as? [[String: Any]] ?? [] {
            let b = norm(e["begriff"] as? String ?? "")
            if pyKind[b] == nil { pyKind[b] = e["typ"] as? String ?? "" }
        }

        let glossary = Glossary.find(in: epub.chapter, title: epub.title)
        let swFinds = glossary != nil
        let position = Dictionary(
            epub.chapter.enumerated().map { ($1.href, $0) }, uniquingKeysWith: { a, _ in a })
        let swChapters = Set((glossary?.chapter ?? []).compactMap { position[$0] })
        var swKind: [String: String] = [:]
        for e in glossary?.entries ?? [] where swKind[norm(e.term)] == nil {
            swKind[norm(e.term)] = e.type.rawValue
        }

        let spineSame = (target["spine"] as? [String] ?? []) == epub.chapter.map(\.href)
        let pyB = Set(pyKind.keys), swB = Set(swKind.keys)
        let common = pyB.intersection(swB)
        let kindDiffers = common.filter { pyKind[$0] != swKind[$0] }.sorted()

        // Maps: Python lists all; Swift certain first, without duplicates, at most four.
        let pyAll = (target["karten"] as? [[String: Any]] ?? []).map {
            (image: $0["bild"] as? String ?? "", certain: ($0["stufe"] as? String) == "sicher")
        }
        var seen: Set<String> = []
        let pyCards = (pyAll.filter(\.certain) + pyAll.filter { !$0.certain })
            .filter { seen.insert($0.image).inserted }.prefix(4)
            .map { "\($0.image)|\($0.certain ? "sicher" : "kandidat")" }
        let swCards = await CardFinder.selection(CardFinder.findings(in: epub.chapter, title: epub.title)) {
            await epub.read($0).flatMap(CardFinder.edge)
        }.map { "\($0.path)|\($0.certain ? "sicher" : "kandidat")" }

        // Gold: terms from parts with an index kind
        var gold: [String: String] = [:]
        var goldHas = false
        for t in (target["gold"] as? [String: Any])?["teile"] as? [[String: Any]] ?? [] {
            guard goldKinds.contains(t["art"] as? String ?? "") else { continue }
            goldHas = true
            for e in t["eintraege"] as? [[String: Any]] ?? [] {
                let b = norm(e["begriff"] as? String ?? "")
                if !b.isEmpty, gold[b] == nil { gold[b] = e["typ"] as? String ?? "" }
            }
        }

        figures.books += 1
        figures.spineSame += spineSame ? 1 : 0
        figures.findsSame += pyFinds == swFinds ? 1 : 0
        figures.bothFind += pyFinds && swFinds ? 1 : 0
        figures.chapterSame += (pyFinds && swFinds && pyChapters == swChapters) ? 1 : 0
        figures.termsPython += pyB.count
        figures.termsSwift += swB.count
        figures.termsShared += common.count
        figures.kindSame += common.count - kindDiffers.count
        figures.cardBooks += (pyCards.isEmpty && swCards.isEmpty) ? 0 : 1
        figures.cardsSame +=
            (!(pyCards.isEmpty && swCards.isEmpty) && Set(pyCards) == Set(swCards)) ? 1 : 0
        figures.goldBooks += goldHas ? 1 : 0
        figures.goldFindsPython += goldHas && pyFinds ? 1 : 0
        figures.goldFindsSwift += goldHas && swFinds ? 1 : 0
        figures.goldTerms += gold.count
        figures.goldHitsPython += Set(gold.keys).intersection(pyB).count
        figures.goldHitsSwift += Set(gold.keys).intersection(swB).count
        let goldKindShared = Set(gold.keys).intersection(swB).filter { !(gold[$0] ?? "").isEmpty }
        figures.goldKindCompared += goldKindShared.count
        figures.goldKindSwift += goldKindShared.filter { gold[$0] == swKind[$0] }.count
        let goldKindPy = Set(gold.keys).intersection(pyB).filter { !(gold[$0] ?? "").isEmpty }
        figures.goldKindComparedPython += goldKindPy.count
        figures.goldKindPython += goldKindPy.filter { gold[$0] == pyKind[$0] }.count

        let missing = pyB.subtracting(swB).sorted(), excess = swB.subtracting(pyB).sorted()
        // Kind per term against gold: where Swift does better or worse than Python.
        let both = goldKindShared.intersection(goldKindPy)
        let kindBetter = both.filter { gold[$0] == swKind[$0] && gold[$0] != pyKind[$0] }.sorted()
        let kindWorse = both.filter { gold[$0] == pyKind[$0] && gold[$0] != swKind[$0] }.sorted()
        return [
            "typ_besser": kindBetter.map {
                "\($0): \(pyKind[$0] ?? "") → \(swKind[$0] ?? "") (Gold \(gold[$0] ?? ""))"
            },
            "typ_schlechter": kindWorse.map {
                "\($0): \(pyKind[$0] ?? "") → \(swKind[$0] ?? "") (Gold \(gold[$0] ?? ""))"
            },
            "id": target["id"] ?? "", "kapitel": epub.chapter.count, "spine_gleich": spineSame,
            "findet": ["python": pyFinds, "swift": swFinds],
            "glossar_kapitel": ["python": pyChapters.sorted(), "swift": swChapters.sorted()],
            "begriffe": ["python": pyB.count, "swift": swB.count, "gemeinsam": common.count],
            "fehlt_in_swift": Array(missing.prefix(40)), "nur_in_swift": Array(excess.prefix(40)),
            "typ_anders": kindDiffers.prefix(40).map { [$0, pyKind[$0] ?? "", swKind[$0] ?? ""] },
            "karten": ["python": pyCards, "swift": swCards],
            "gold": [
                "begriffe": gold.count, "python": Set(gold.keys).intersection(pyB).count,
                "swift": Set(gold.keys).intersection(swB).count,
            ],
            "abweichungen": missing.count + excess.count + kindDiffers.count
                + (pyFinds == swFinds ? 0 : 1) + (Set(pyCards) == Set(swCards) ? 0 : 1),
        ]
    }
}

struct Counter {
    var books = 0, failure = 0, spineSame = 0
    var findsSame = 0, bothFind = 0, chapterSame = 0
    var termsPython = 0, termsSwift = 0, termsShared = 0, kindSame = 0
    var cardBooks = 0, cardsSame = 0
    var goldBooks = 0, goldFindsPython = 0, goldFindsSwift = 0
    var goldTerms = 0, goldHitsPython = 0, goldHitsSwift = 0
    var goldKindCompared = 0, goldKindSwift = 0, goldKindComparedPython = 0, goldKindPython = 0

    func summary() -> [String: Any] {
        func p(_ a: Int, _ b: Int) -> Double { b == 0 ? 100 : (Double(a) / Double(b) * 1000).rounded() / 10 }
        let union = termsPython + termsSwift - termsShared
        return [
            "buecher": books, "fehler": failure,
            "spine_gleich_pct": p(spineSame, books),
            "findet_gleich_pct": p(findsSame, books),
            "kapitel_gleich_pct": p(chapterSame, bothFind),
            "begriffe_gleich_pct": p(termsShared, union),
            "begriffe": ["python": termsPython, "swift": termsSwift, "gemeinsam": termsShared],
            "typ_gleich_pct": p(kindSame, termsShared),
            "karten_gleich_pct": p(cardsSame, cardBooks), "karten_buecher": cardBooks,
            "gold": [
                "buecher": goldBooks,
                "findet_python_pct": p(goldFindsPython, goldBooks),
                "findet_swift_pct": p(goldFindsSwift, goldBooks),
                "recall_python_pct": p(goldHitsPython, goldTerms),
                "recall_swift_pct": p(goldHitsSwift, goldTerms),
                "typ_python_pct": p(goldKindPython, goldKindComparedPython),
                "typ_swift_pct": p(goldKindSwift, goldKindCompared),
            ],
        ]
    }
}
