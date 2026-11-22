import Foundation
import Testing

@testable import BookReader

/// The forms found in real books (824 EPUBs, 101 with a glossary) - rebuilt,
/// not copied: colon, dash, bold, definition list,
/// capitals, bracket and arrow - and the two false ones the analysis showed.
@Suite("Glossary")
struct GlossaryTests {

    private func chapter(_ title: String?, _ lines: [String], tag: String = "p") -> String {
        let header = title.map { "<h1>\($0)</h1>" } ?? ""
        return "<html><head><title>Buch</title></head><body>\(header)"
            + lines.map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</body></html>"
    }

    /// Alphabetical terms with explanation - base material for all forms.
    private let terms = [
        "Abdrift", "Abtakelungsordnung", "Ahming", "Ankerwacht", "Austernbank", "Brasse Loddenhaus",
        "Bunnerts Werft",
        "Calmenring", "Dünungsglas", "Ebbmark", "Fennlinge", "Gerrin Dolle", "Heringszoll", "Kalmer Ostrand",
        "Moorlicht", "Schottwacht", "Tranlicht", "Zollkutter",
    ]

    @Test("Colon with heading 'Glossar', bracket and arrow in the forms")
    func colon() throws {
        var lines = terms.map { "\($0): Ein Begriff aus dem Hafenviertel, ausführlich erklärt." }
        lines.insert(
            "Ab’lun (Ebbmark): ein Gerät – es besteht aus einem Messingring und einer Glaslinse.", at: 1)
        lines.append("Hohe Kante, die: Die Klippe hinter dem →Leuchtfeuer.")
        let g = try #require(
            Glossary.find(in: [
                (
                    "k1.xhtml",
                    chapter(
                        nil,
                        ["Ein Kapitel voller Text."]
                            + Array(repeating: "Und noch ein Satz im Kapitel.", count: 20))
                ), ("glossar.xhtml", chapter("Glossar", lines)),
            ]))
        #expect(g.heading == "Glossar" && g.chapter == ["glossar.xhtml"])
        #expect(g.entries.count == terms.count + 2)
        let ablun = try #require(g.entry(for: "ebbmark"))
        #expect(ablun.term == "Ab’lun (Ebbmark)" && ablun.forms == ["Ab’lun", "Ebbmark"])
        let other = try #require(g.entry(for: "hohe kante"))
        #expect(other.explanation.hasPrefix("Die Klippe"))
        #expect(g.searchForms.first?.form == "Abtakelungsordnung", "lange Formen zuerst")
    }

    @Test("Dash without heading - the ordering decides")
    func stroke() throws {
        let lines =
            ["Glossar"] + terms.map { "\($0) – ein Ort, ein Name oder eine Sache aus der Welt des Buchs." }
        let g = try #require(Glossary.find(in: [("x.xhtml", chapter(nil, lines))]))
        #expect(g.heading == "Glossar", "die erste Zeile ist die Überschrift")
        #expect(g.entries.count == terms.count)
        #expect(g.entries[0].explanation.hasPrefix("ein Ort"))
    }

    @Test("Set in bold and as a definition list - without colon")
    func boldAndList() throws {
        let bold = terms.map { "<b>\($0)</b> alter Begriff in Lüttgrund, hier ausführlich erläutert." }
        let g = try #require(Glossary.find(in: [("g.xhtml", chapter("Glossar", bold))]))
        #expect(g.entries.count == terms.count && g.entries[0].term == "Abdrift")
        let dl =
            "<html><body><h2>Begriffe</h2><dl>"
            + terms.map { "<dt>\($0)</dt><dd>Erklärt in einem Satz, der lang genug ist.</dd>" }.joined()
            + "</dl></body></html>"
        let l = try #require(Glossary.find(in: [("d.xhtml", dl)]))
        #expect(l.entries.count == terms.count && l.entries.last?.term == "Zollkutter")
    }

    @Test("CAPITALIZED and several glossary chapters become one")
    func capitalAndMultiple() throws {
        let large = terms.map {
            "\($0.uppercased()): Ein Knoten, den nur die alten Fischer am Hafen binden."
        }
        let people = [
            "Achim: Hauptfigur, Wirt der Herberge am Fluss.", "Berta: Seine Schwester, Heilerin.",
            "Cäsar: Ein Hund, der zu viel weiß.", "Dora: Die Stimme aus dem Nebel, niemand kennt sie.",
            "Emil: Der Bote des Königs, stets zu spät.", "Fritz: Ein Schmied.", "Gunda: Die Wirtin.",
            "Hans: Ein Knecht.",
        ]
        let g = try #require(
            Glossary.find(in: [
                ("a.xhtml", chapter("GLOSSAR", large)),
                ("b.xhtml", chapter("Dramatis personae – Hauptfiguren", people)),
            ]))
        #expect(g.chapter == ["a.xhtml", "b.xhtml"])
        #expect(g.entries.count == terms.count + 8)
        #expect(g.entry(for: "schottwacht")?.term == "SCHOTTWACHT")
    }

    @Test(
        "No glossary: dialogue lines 'Name: sentence' without ordering, a table of contents, the acknowledgments"
    )
    func none() {
        let dialog =
            ["Kapitel 40", "Kein Ausweg"]
            + (0..<40).map { i in
                "\(["Paul", "Anna", "Zoe", "Ben", "Mara"][i % 5]): Der Abend war angebrochen, und draußen schwand das Tageslicht."
            }
        #expect(
            Glossary.find(in: [("k.xhtml", chapter(nil, dialog))]) == nil, "unsortierte Namen sind Dialog")
        let content =
            ["Table of Contents"] + (1..<30).map { "Kapitel \($0) – Folster, der Wirt, und die lange Nacht" }
        #expect(Glossary.find(in: [("t.xhtml", chapter(nil, content))]) == nil, "Kapitel n ist kein Begriff")
        let thanks = chapter(
            "Danksagung", terms.map { "\($0): Danke für alles, was du getan hast, wirklich." })
        #expect(Glossary.find(in: [("d.xhtml", thanks)]) == nil)
        #expect(
            Glossary.find(in: [("x.xhtml", chapter("Glossar", ["Abdrift: kurz.", "Brasse: auch kurz."]))])
                == nil, "zu wenige")
    }

    @Test(
        "Marking in HTML: terms in the text as span, long form first, not in tags, links, headings and head; style and marker in the head; off per class"
    )
    func marking() throws {
        let g = try #require(
            Glossary.find(in: [
                (
                    "g.xhtml",
                    chapter(
                        "Glossar",
                        [
                            "Brasse: Kurzform der Netzflickerinnen.", "Brasse Loddenhaus, die: Zunft der Netzflickerinnen.",
                            "Fennlinge: Leute aus der Marsch.", "Gerrin Dolle: Die Nadel der Lotsenprüfung.",
                            "Kalmer Ostrand: Der Wind, der aus allen Richtungen zugleich weht.",
                            "Riffgras: Das Seegras von Lüttgrund.", "Schottwacht: Wachleute des Hafenmeisters.",
                            "Sielhof: Siedlung der Fennlinge.",
                        ])
                )
            ]))
        let html = """
            <html><head><title>Fennlinge</title><style>.fennlinge{}</style></head><body>
            <h1>Die Fennlinge</h1>
            <p class="fennlinge">Die <i>Brasse Loddenhaus</i> und die Fennlinge; ein Sielhof der Fennlinge. <a href="#x">Riffgras</a> Riffgrashandel.</p>
            <p>SCHOTTWACHT!</p></body></html>
            """
        let from = Glossary.mark(html: html, glossary: g)
        #expect(
            from.contains(
                "<i><span class=\"ss-glossar ss-m\" data-ss-begriff=\"Brasse Loddenhaus, die\">Brasse Loddenhaus</span></i>"
            ),
            "die lange Form gewinnt; ohne Plan trägt die erste Nennung die Linie")
        #expect(from.contains("<p class=\"fennlinge\">"), "Attribute bleiben")
        #expect(from.contains("<h1>Die Fennlinge</h1>"), "Überschriften nicht")
        #expect(from.contains("<title>Fennlinge</title>"), "head nicht")
        #expect(from.contains("<a href=\"#x\">Riffgras</a>"), "Links nicht")
        #expect(from.contains("Riffgrashandel"), "kein Teilwort")
        #expect(
            from.contains("data-ss-begriff=\"Schottwacht\">SCHOTTWACHT</span>"), "ohne Groß/Klein, Wort bleibt")
        #expect(
            from.components(separatedBy: "data-ss-begriff=\"Fennlinge\"").count - 1 == 2,
            "zweimal im Absatz, nicht im Kopf — beide antippbar")
        #expect(
            from.components(separatedBy: "class=\"ss-glossar ss-m\" data-ss-begriff=\"Fennlinge\"").count - 1
                == 1,
            "markiert ≠ antippbar: nur die erste Nennung hat die Linie")
        let planned = Glossary.mark(html: html, glossary: g, marked: [])
        #expect(
            !planned.contains("class=\"ss-glossar ss-m\"") && planned.contains("data-ss-begriff=\"Fennlinge\""),
            "Plan ohne Linie: alles bleibt antippbar")
        #expect(
            from.contains("<style>:root{--ss-linie:32%}.ss-glossar{") && from.contains("<![CDATA[")
                && from.contains("</head>"))
        #expect(!from.contains("<html class="))
        let without = Glossary.mark(html: html, glossary: g, to: false)
        #expect(without.contains("<html class=\"ss-glossar-aus\">"))
        #expect(
            Glossary.mark(html: "<p>Nichts davon.</p>", glossary: g) == "<p>Nichts davon.</p>",
            "unverändert ohne Treffer")
    }

    @Test("The ordering: sorted 1.0, dialogue clearly below")
    func ordering() {
        #expect(Glossary.ordering(["Abdrift", "ätzwasser", "Brasse", "Zollkutter"]) == 1)
        #expect(Glossary.ordering(["Paul", "Anna", "Zoe", "Ben", "Mara", "Paul", "Anna"]) < 0.6)
    }

    // MARK: - Version 2

    @Test("Rule front: Dramatis Personae at the front of the book counts with a heading, not without")
    func frontText() throws {
        let people = [
            "Achim: Hauptfigur, Wirt der Herberge.", "Berta: Seine Schwester.", "Cäsar: Ein alter Freund.",
            "Dora: Die Stimme aus dem Nebel.", "Emil: Der Bote des Königs.", "Fritz: Ein Schmied.",
            "Gunda: Die Wirtin.", "Hans: Ein Knecht.",
        ]
        let filler = chapter(nil, Array(repeating: "Ein Satz im Kapitel, der nichts erklärt.", count: 30))
        var book: [(href: String, html: String)] = [("p.xhtml", chapter("Dramatis personae", people))]
        book += (1...30).map { ("k\($0).xhtml", filler) }
        let g = try #require(Glossary.find(in: book))
        #expect(g.chapter == ["p.xhtml"] && g.entries.count == 8)
        #expect(g.entries.allSatisfy { $0.type == .person }, "unter einer Personen-Überschrift")
        var without: [(href: String, html: String)] = [("p.xhtml", chapter(nil, people))]
        without += (1...30).map { ("k\($0).xhtml", filler) }
        #expect(Glossary.find(in: without) == nil, "vorne ohne Überschrift sucht die App nicht")
    }

    @Test("Forms: 'Surname, First name' is reversed; slash gives two forms")
    func formsV2() {
        #expect(Glossary.forms("Ambersley, Tobin") == ["Tobin Ambersley", "Ambersley"])
        #expect(Glossary.forms("Rethil/Rethmark") == ["Rethil", "Rethmark"])
        #expect(Glossary.forms("Andere Seite, die") == ["Andere Seite"])
    }

    @Test("Kind from the explanation: city is place, son is person, year is time")
    func types() {
        func e(_ b: String, _ x: String) -> Glossary.Item {
            Glossary.Item(term: b, explanation: x, forms: [b])
        }
        #expect(Glossary.type(e("Carrow", "Stadt an der Küste von Varn."), kind: .term) == .place)
        #expect(Glossary.type(e("Jorek", "Sohn des Leuchtturmwärters."), kind: .term) == .person)
        #expect(Glossary.type(e("1714", "Jahr der großen Sturmflut."), kind: .term) == .time)
        #expect(Glossary.type(e("Riffgras", "Seegras, das Netze haltbar macht."), kind: .term) == .term)
    }

    @Test("No index: literature list under appendix")
    func literature() {
        let list = (0..<12).map { i in
            "Autor\(Character(UnicodeScalar(65 + i)!)), Hans: Ein Buch. Verlag Tannhof, Lübbenau \(1990 + i)."
        }
        #expect(Glossary.find(in: [("l.xhtml", chapter("Anhang", list))]) == nil)
    }
}

/// The density rules as a pure function.
@Suite("Marking plan")
struct MarkingPlanTests {

    private func book(_ mentions: [(String, Int)], words: Int) -> TermIndex {
        TermIndex(chapter: [
            .init(
                href: "k.xhtml", words: words,
                mentions: mentions.map { .init(term: $0.0, word: $0.1) })
        ])
    }

    @Test("The very first mention of each term is marked, the second in the same section is not")
    func first() {
        let plan = MarkingPlan.compute(book([("A", 10), ("A", 500), ("B", 900)], words: 3_000))
        #expect(plan["k.xhtml"] == [0, 2])
    }

    @Test("R6: at most three lines per 1,000 words; R5: 40 words apart")
    func density() {
        // Long chapters (> 6,000 words) have sections of 3,000 words - there every
        // mention is a first in the section. Five already known terms in quick succession:
        var n: [(String, Int)] = ["A", "B", "C", "D", "E"].enumerated().map {
            ($0.element, $0.offset * 1_000)
        }
        n += ["A", "B", "C", "D", "E"].enumerated().map { ($0.element, 9_000 + $0.offset * 50) }
        let plan = MarkingPlan.compute(book(n, words: 12_000))
        let late = (plan["k.xhtml"] ?? []).filter { $0 >= 5 }
        #expect(late.count == 3, "im Fenster ab Wort 9.000 nur drei")
        let tight = MarkingPlan.compute(
            book([("A", 0), ("B", 3_000), ("A", 9_000), ("B", 9_010)], words: 12_000))
        #expect(tight["k.xhtml"] == [0, 1, 2], "zehn Wörter nach einer Linie keine zweite")
    }

    @Test("R2: the same term at the earliest after 2,500 words again")
    func markAgain() {
        let plan = MarkingPlan.compute(book([("A", 0), ("A", 3_100), ("A", 6_100)], words: 12_000))
        #expect(plan["k.xhtml"] == [0, 1, 2], "je 3.000 Wörter: neuer Abschnitt, genug Abstand")
        let near = MarkingPlan.compute(book([("A", 2_900), ("A", 3_100)], words: 12_000))
        #expect(near["k.xhtml"] == [0], "200 Wörter später, auch im neuen Abschnitt: keine Linie")
    }

    @Test(
        "Full window: the rare term wins, then the place; R4: opened rests 10,000 words")
    func priority() {
        // Four known terms in quick succession, only three fit in the window.
        var n: [(String, Int)] = [("A", 0), ("B", 100), ("C", 200), ("D", 300)]
        n += [("A", 9_000), ("B", 9_050), ("C", 9_100), ("D", 9_150)]
        n += [("A", 10_500), ("A", 10_600)]  // A is more frequent
        let plan = MarkingPlan.compute(book(n, words: 12_000), types: ["D": .place])
        let late = Set((plan["k.xhtml"] ?? []).filter { (4...7).contains($0) })
        #expect(late == [5, 6, 7], "A (häufiger) verliert gegen B, C, D")
        let on = MarkingPlan.compute(
            book([("A", 0), ("A", 9_000)], words: 12_000), opened: ["A": 1_000])
        #expect(on["k.xhtml"] == [0], "8.000 Wörter nach dem Öffnen: keine Linie")
        let later = MarkingPlan.compute(
            book([("A", 0), ("A", 9_000)], words: 12_000), opened: ["A": -2_000])
        #expect(later["k.xhtml"] == [0, 1])
    }

    @Test("Index: word position across chapters, state and spoiler protection")
    func chapterIndex() {
        let v = TermIndex(chapter: [
            .init(href: "a.xhtml", words: 1_000, mentions: [.init(term: "A", word: 100)]),
            .init(
                href: "b.xhtml", words: 1_000,
                mentions: [.init(term: "A", word: 10), .init(term: "B", word: 500)]),
        ])
        #expect(v.positions["A"] == [100, 1_010] && v.words == 2_000)
        #expect(v.word(href: "b.xhtml", fraction: 0.5) == 1_500)
        #expect(v.chapterIndex(word: 1_200) == 1)
        #expect(v.state("A", until: 1_200).count == 2 && v.state("A", until: 500).count == 1)
        #expect(!v.known("B", until: 1_200) && v.known("B", until: 1_600))
    }
}

/// The overall check across the whole library: printed registers and
/// poem openings are no glossary.
extension GlossaryTests {
    @Test(
        "No glossary: printed register with page numbers, poem openings under subheading"
    )
    func printRegister() {
        // Rebuilt, not copied: names with page references, like a printed register.
        let register = terms.enumerated().map { i, b in "\(b) I \(10 + i * 7), \(40 + i)f., \(90 + i)" }
        #expect(Glossary.find(in: [("reg.xhtml", chapter("Register", register))]) == nil)
        let withLinks = terms.map { "\($0) des Helden  [2] [3]" }
        #expect(Glossary.find(in: [("reg.xhtml", chapter("Register", withLinks))]) == nil)
        // Poem openings under "I. Songs and poems": sentence starts, not terms.
        let initials = [
            "Ahoi, wie die Möwen schreien", "Am Kai die Netze trocknen", "Bei Flut kam Jasper heim",
            "Das Beiboot liegt im Schlick", "Das Schilf steht hoch am Deich", "Die Taue knarren leise",
            "Ein Hering für den Zoll", "Im Hafen brennt ein Licht", "Kein Wind und keine Fahrt",
            "O Fischer auf dem Damm", "Vom Watt her ruft die Glocke", "Wenn der Kutter wiederkehrt",
        ]
        #expect(
            Glossary.find(in: [("reg.xhtml", chapter("Register", ["I. LIEDER VOM HAFEN"] + initials))])
                == nil)
    }

    @Test("Filler words drop out of a real glossary, the glossary stays")
    func fillerWordsRemoved() throws {
        var lines = terms.map { "\($0): Ein Begriff aus dem Hafenviertel, ausführlich erklärt." }
        lines.append("Und: kein Begriff, nur ein Satzanfang mit Doppelpunkt danach.")
        let g = try #require(Glossary.find(in: [("glossar.xhtml", chapter("Glossar", lines))]))
        #expect(g.entries.count == terms.count)
        #expect(!g.entries.contains { $0.term == "Und" })
    }

    @Test("A person list with ages stays an index - a number at the end is no page")
    func ageIsNotAPage() throws {
        let people = terms.enumerated().map { i, b in "\(b): Kommissar aus der Stadt, \(30 + i)" }
        let g = try #require(Glossary.find(in: [("p.xhtml", chapter("Die Hauptpersonen", people))]))
        #expect(g.entries.count == terms.count)
    }

    @Test("Persons in a play: a pure name list without explanation stays - empty is no page reference")
    func nameListStays() throws {
        let names = ["Martha", "Maria", "Die Mutter", "Jan", "Der alte Knecht"]
        let g = try #require(Glossary.find(in: [("p.xhtml", chapter("Personen", names))]))
        #expect(g.entries.map(\.term) == names)
    }

    @Test("Subheading 'Places' / 'Peoples' gives the kind and is itself no entry")
    func kindFromSection() throws {
        let lines =
            ["Orte"] + ["Altra", "Bremen", "Corin", "Dalen", "Esgar"].map { "\($0): weit im Norden gelegen" }
            + ["Völker"]
            + ["Fennlinge", "Gorin", "Hollen", "Ilvaner", "Jundar"].map { "\($0): leben draußen in der Marsch" }
        let g = try #require(Glossary.find(in: [("g.xhtml", chapter("Glossar", lines))]))
        #expect(g.entries.count == 10)
        #expect(!g.entries.contains { $0.term == "Orte" || $0.term == "Völker" })
        #expect(g.entries.prefix(5).allSatisfy { $0.type == .place })
        #expect(g.entries.suffix(5).allSatisfy { $0.type == .cluster })
    }

    @Test("Map names: only what stands capitalized at least twice in the text and is no dictionary word")
    func cardNamesFromText() {
        let r = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        let read = [
            ("BRAKMOOR", r), ("Wald", r), ("Xyzzq", r), ("Rethil", r), ("Hal Durrem", r), ("Osterfehn", r),
        ]
        let text =
            "Nach Brakmoor segelten sie. Brakmoor war fern. Im Wald, im Wald. Rethil einmal. "
            + "Hal Durrem und Hal Durrem. Osterfehn kennt der Leser schon."
        let names = CardFinder.names(
            read, text: text, known: [CardFinder.folded("Osterfehn")], dictionary: ["wald"])
        #expect(Set(names.keys) == ["Brakmoor", "Hal Durrem"])
    }

    @Test("VoiceOver: every mention is a button with a hint; the surface has a class of its own")
    func mentionIsKey() {
        let g = Glossary(
            heading: "Glossar",
            entries: [Glossary.Item(term: "Lüttgrund", explanation: "", forms: ["Lüttgrund"])],
            chapter: [])
        let html = Glossary.mark(
            html: "<html><head></head><body><p>Auf Lüttgrund.</p></body></html>", glossary: g,
            hint: "Erklärung öffnen")
        #expect(html.contains("role=\"button\" aria-description=\"Erklärung öffnen\""))
        #expect(html.contains(".ss-glossar.ss-aktiv{"))
        #expect(!Glossary.mark(html: "<p>Auf Lüttgrund.</p>", glossary: g).contains("role="))
    }

    @Test("Store: glossary, index and maps come back the same; a new version of the book does not")
    func storeRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ablage-\(UUID().uuidString).epub")
        try Data("eins".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let g = Glossary(
            heading: "Glossar",
            entries: [Glossary.Item(term: "Rethil", explanation: "", forms: ["Rethil"], type: .place)],
            chapter: ["g.xhtml"])
        let k = [
            TermIndex.Chapter(
                href: "a.xhtml", words: 10, mentions: [.init(term: "Rethil", word: 3)])
        ]
        let card = TermCache.Card(
            path: "OEBPS/karte.jpg", places: ["Rethil": CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)])
        TermCache(rules: TermCache.rules, glossary: g, chapterIndex: k, cards: [card]).write(
            for: file)
        let back = try #require(TermCache.load(for: file))
        #expect(back.glossary == g)
        #expect(back.chapterIndex == k)
        #expect(back.cards.first?.places["Rethil"] == card.places["Rethil"])
        // New version (other size): recompute.
        try Data("eins und zwei".utf8).write(to: file)
        #expect(TermCache.load(for: file) == nil)
        if let place = TermCache.place(for: file) { try? FileManager.default.removeItem(at: place) }
    }

    @Test("Prominent: class on html and accent color as variable; off and prominent possible together")
    func markingProminent() {
        let html = Glossary.extra(
            in: "<html><head></head><body></body></html>", to: false, pronounced: true, accent: 0x1F5C46)
        #expect(html.contains("<html class=\"ss-glossar-aus ss-deutlich\""))
        #expect(html.contains("--ss-akzent:#1F5C46"))
        #expect(!Glossary.extra(in: "<html><head></head></html>", to: true).contains("class="))
    }

    @Test(
        "Dictionary word only capitalized mid-sentence; multi-word term only in full; epigraph without line")
    func commonWordsAndEpigraph() {
        var g = Glossary(
            heading: "Glossar",
            entries: [
                Glossary.Item(term: "Gilde", explanation: "", forms: ["Gilde"]),
                Glossary.Item(term: "Kontor Brammsen", explanation: "", forms: ["Kontor Brammsen", "Kontor"]),
            ], chapter: [])
        g.general = ["gilde", "kontor"]
        let text = "<p>Gilde am Anfang. Sie sah die Gilde, die gilde und das Kontor. Das Kontor Brammsen kam.</p>"
        let n = Glossary.mentions(html: text, glossary: g).mentions
        #expect(
            n.map(\.term) == ["Gilde", "Kontor Brammsen"],
            "Satzanfang, klein und das kurze Kontor zählen nicht")
        let epigraph = Glossary.mentions(
            html: "<blockquote><p>Die Gilde sprach.</p></blockquote><p>Später sah sie die Gilde.</p>",
            glossary: g
        ).mentions
        #expect(epigraph.map(\.epigraph) == [true, nil])
        let v = TermIndex(chapter: [.init(href: "k.xhtml", words: 100, mentions: epigraph)])
        #expect(MarkingPlan.compute(v)["k.xhtml"] == [1], "die erste echte Nennung nach dem Motto")
    }

    @Test("Person card: only explicitly named relations; timeline in 40 bars up to here")
    func relationsAndTimeline() {
        let og = Glossary.Item(term: "Ubbo", explanation: "Vogt von Sielwarden", forms: ["Ubbo"], type: .person)
        let peor = Glossary.Item(term: "Treen", explanation: "Ort", forms: ["Treen"], type: .place)
        let lia = Glossary.Item(
            term: "Lia", explanation: "Tochter von Ubbo, reist →Treen; kennt Mara.", forms: ["Lia"],
            type: .person)
        let mara = Glossary.Item(term: "Mara", explanation: "Händlerin", forms: ["Mara"], type: .person)
        let g = Glossary(heading: "Personen", entries: [og, peor, lia, mara], chapter: [])
        let b = g.relations(lia)
        #expect(b.map(\.target.term) == ["Treen", "Ubbo"] || b.map(\.target.term) == ["Ubbo", "Treen"])
        #expect(b.first { $0.target.term == "Ubbo" }?.word == "Tochter")
        #expect(!b.contains { $0.target.term == "Mara" }, "bloß erwähnt ist keine Beziehung")
        let v = TermIndex(chapter: [
            .init(
                href: "a", words: 4_000,
                mentions: [.init(term: "Lia", word: 50), .init(term: "Lia", word: 3_950)])
        ])
        #expect(v.history("Lia").first == 1 && v.history("Lia").last == 1)
        #expect(v.history("Lia", until: 1_000).last == 0)
    }

    @Test("Only person and place are shown; what is on the map is a place")
    func displayOnlyPersonAndPlace() {
        func e(_ t: Glossary.Variant) -> Glossary.Item {
            Glossary.Item(term: "X", explanation: "", forms: ["X"], type: t)
        }
        #expect(e(.cluster).display(onCard: false) == .term)
        #expect(e(.thing).display(onCard: false) == .term)
        #expect(e(.place).display(onCard: false) == .place)
        #expect(e(.term).display(onCard: true) == .place)
        #expect(e(.person).display(onCard: true) == .person)
    }

    @Test("The kind often stands after a preamble: searching continues after the first punctuation mark")
    func kindAfterPreamble() {
        func kind(_ explanation: String) -> Glossary.Variant {
            Glossary.type(Glossary.Item(term: "X", explanation: explanation, forms: ["X"]), kind: .term)
        }
        #expect(kind("{OLE BRANDT VOM DEICH}, ältester Sohn von Reeder Habbe") == .person)
        #expect(kind("ein Watt-Nolde. Der Sohn eines Händlers") == .person)
        #expect(kind("(alte Sprache); Königreich im Norden") == .place)
        #expect(kind("Eine Form der Magie, die nur wenige beherrschen") == .term)
    }
}
