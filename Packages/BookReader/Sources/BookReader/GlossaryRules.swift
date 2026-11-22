import Foundation

/// The detection, version 2.
///
/// Every rule is named in the comments at the places where it applies, so it
/// can be looked up:
/// `front`, `heading`, `not`, `content`, `separator`, `lines`, `names`, `spaces`,
/// `small`, `head`, `short`, `period`, `number`, `table`, `reverse`, `star`, `content2`.
/// Everything stays regex, counting and comparing - no language model.
extension Glossary {

    // MARK: - Headings

    static func rx(_ muster: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: muster, options: options)
    }

    /// Rule `heading`: further headings that announce an index.
    static let newHeadings = rx(
        #"(?i)(personen|wer ist wer|charaktere|characters|namensverzeichnis|namensliste|"#
            + #"aussprache|pronunciation|vokabular|vokabeln|worterkl|w(?:ö|oe)rterverzeichnis|fremdw(?:ö|oe)rter|"#
            + #"abk(?:ü|ue)rzungen|^orte\b|schaupl(?:ä|ae)tze|^die familie|wichtige begriffe|kleines .*lexikon)"#
    )
    /// Rule `not`: further headings under which no index follows.
    static let notNew = rx(
        #"(?i)(^\s*inhalt\s*$|^\s*contents\s*$|inhalts(?:ü|ue)bersicht|literatur|bibliogra|^\s*quellen|"#
            + #"quellenverzeichnis|nachweis|abbildungsverzeichnis|bildquellen|weiterf(?:ü|ue)hrende|"#
            + #"zum weiterlesen|lesetipps|^\s*bücher von|^\s*vom selben autor|^\s*weitere titel|^\s*anzeige|"#
            // Registers without explanations: poem openings, songs, figures, maps (a fantasy
            // epic, new edition: "I Poems" became a glossary of "Ach", "Ich", "Im").
            + #"gedicht|lieder|liedanf|ges(?:ä|ae)nge|\bverse\b|songs\b|poems\b|abbildungen|illustrationen|"#
            + #"^\s*karten\b|kartenverzeichnis|"#
            // Cookbook and subject indexes, the imprint under "Persons and plot are fictitious".
            + #"rezeptregister|rezepte von a|kapitelregister|stichwortregister|"#
            + #"personen und handlung)"#
    )

    /// Words that are not glossary terms - whoever starts with one is a sentence or a verse line.
    static let fillerWords: Set<String> = [
        "ach", "ah", "oh", "o", "ich", "du", "er", "sie", "es", "wir", "ihr", "man", "mich", "mir", "dich",
        "dir",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einen", "einem", "und", "oder",
        "aber",
        "doch", "nicht", "nein", "ja", "im", "in", "am", "an", "auf", "aus", "bei", "mit", "nach", "vom",
        "von",
        "vor", "zu", "zum", "zur", "über", "unter", "wie", "wo", "was", "wer", "wenn", "als", "da", "dann",
        "so",
        "nun", "noch", "schon", "während", "weil", "dass", "daß", "einst", "seit", "schließlich", "genau",
        "weiß", "irgendwann", "auch", "später", "dabei", "mehr", "danach", "damals", "heute", "jetzt",
        "immer",
        "erst", "diese", "dieser", "dieses", "the", "a", "an", "and", "i", "you", "he", "she", "it", "we",
        "they",
        "of", "to",
    ]

    /// Words of an imprint - if two of them stand among the terms, the chapter is not one.
    static let imprint: Set<String> = [
        "alle rechte", "lektorat", "herstellung", "umschlaggestaltung", "umschlag", "originaltitel",
        "originalverlag", "published", "copyright", "isbn", "satz", "druck", "besuchen sie", "ähnlichkeiten",
        "redaktion", "korrektorat", "übersetzung", "printed in germany", "gesamtherstellung",
    ]

    /// A page reference at the end: "Valdor I 33, 36f., 50", "... II 457", "... 145ff." - the index
    /// of a printed book.
    static let pageReference = rx(
        // Unambiguous only: references in square brackets, a volume in Roman numerals with page, "f."/"ff."
        // or several numbers in a row. A single number at the end is usually an age or a year
        // ("Harm Tjaden, 57", "Okke, 1868") - otherwise real indexes were dropped.
        #"(?:(?:\s*\[\d{1,4}\])+|\s*(?:→|->|S\.)\s*\d{1,4}(?:\s*[,;]\s*\d{1,4})*|\b[IVX]{1,4}\s\d{1,4}(?:\s?ff?\.)?(?:\s*[,;]\s*\d{1,4}(?:\s?ff?\.)?)*|\d{1,4}\s?ff?\.|\d{1,4}(?:\s?ff?\.)?(?:\s*[,;]\s*\d{1,4}(?:\s?ff?\.)?)+)\.?\s*$"#
    )

    /// A subheading in the chapter: "I. SONGS AND POEMS", "II People", "PLACES".
    static let subheading = rx(#"^(?:[IVX]{1,4}[.:]\s+\p{L}.{0,45}|[\p{Lu}\s,\-–&]{3,45})$"#)

    /// An "explanation" made of page numbers (index of printed books) - worthless in an e-book.
    /// At least one digit: an empty explanation (pure name list, characters in a play) is
    /// not a page reference.
    static let pageNumbersOnly = rx(#"^[\s\d,;.\-–—fIVXLCivxlc]*\d[\s\d,;.\-–—fIVXLCivxlc]*$"#)
    /// Rule `head`: timelines, family trees, word lists, "The Old Language".
    static let headingsHead = rx(
        #"(?i)(zeittafel|zeitleiste|zeittabelle|chronologie|chronik\b|stammtafel|stammbaum|ahnentafel|"#
            + #"wortliste|w(?:ö|oe)rterliste|^\s*die (?:alte )?sprache\b|sprache der|redewendungen|"#
            + #"wichtigste[n]? (?:personen|figuren|begriffe)|handelnde)"#)
    static let timelineHeading = rx(
        #"(?i)(zeittafel|zeitleiste|zeittabelle|chronologie|chronik\b|daten|jahreszahlen|timeline|chronology)"#
    )
    static let peopleHeading = rx(
        #"(?i)(person|figur|charakter|character|dramatis|wer ist wer|who's who|namen|familie|cast)"#)
    static let placesHeading = rx(
        #"(?i)(^orte\b|orte und|schaupl(?:ä|ae)tze|geograph|geograf|^l(?:ä|ae)nder)"#)
    static let languageHeading = rx(
        #"(?i)(sprache|aussprache|pronunciation|vokabular|vokabeln|w(?:ö|oe)rterbuch|wortliste|redewendungen|fremdw)"#
    )

    static func matchesRegex(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// "D RAMATIS P ERSONAE" / "G L O S S A R" -> without spaces - only if the
    /// heading looks letter-spaced (at least a third single-letter words).
    static func withoutLetterSpacing(_ u: String) -> String {
        let w = u.split(separator: " ")
        guard w.count >= 2, w.filter({ $0.count == 1 }).count * 3 >= w.count else { return u }
        return u.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    static func matchesHeading(_ u: String?) -> Bool {
        guard let u, !u.isEmpty else { return false }
        if matchesRegex(headings, u) || matchesRegex(newHeadings, u) { return true }
        if matchesRegex(headingsHead, u), u.split(separator: " ").count <= 6 { return true }
        let z = withoutLetterSpacing(u)
        return z != u
            && (matchesRegex(headings, z) || matchesRegex(newHeadings, z) || matchesRegex(headingsHead, z))
    }

    static func excluded(_ u: String) -> Bool {
        matchesRegex(notHeadings, u) || matchesRegex(notNew, u)
    }

    // MARK: - Reading a chapter

    /// Reads a chapter; `nil` if it is not an index. `atBack`: the chapter lies
    /// in the search window at the end of the book - before that only with a matching heading (rule `front`).
    static func parse(
        html: String, title: String? = nil, atBack: Bool = true
    )
        -> (heading: String, entries: [Item])?
    {
        var u = heading(html, title: title)
        var matches = matchesHeading(u)
        if !matches {
            // Rule `head`/`content2`: the heading is often not in <h1-3> but in the
            // title of the table of contents or in the first short line.
            // Only the start of the chapter: at the front of the book every chapter is checked this way,
            // and a whole paragraph run per chapter slowed down opening.
            let first = paragraphs(String(html.prefix(4_000))).first.map(\.text).flatMap {
                $0.count <= 40 ? $0 : nil
            }
            for alternative in [title, first] {
                if let a = alternative, matchesHeading(a), !excluded(a) {
                    matches = true
                    u = a
                    break
                }
            }
        }
        if !atBack && !matches { return nil }
        if let u, excluded(u) { return nil }
        let people =
            matches
            && (matchesRegex(peopleHeading, u ?? "")
                || matchesRegex(peopleHeading, withoutLetterSpacing(u ?? "")))
        let time = matches && matchesRegex(timelineHeading, u ?? "")
        // Rule `section`: a subheading like "I. Poems and verse" hides its
        // section until the next one comes (a fantasy epic: the register starts with
        // the poem openings).
        // Rule `section` (kind): a short line like "Places", "Peoples" or
        // "Kontor Brammsen" is not an entry but gives the entries below it their kind.
        var hidden = false
        var current: String?
        var sectionOf: [String: String] = [:]
        let all = paragraphs(html).filter { $0.text != u }.filter { a in
            let t = a.text.trimmingCharacters(in: .whitespaces)
            if t.count <= 50, matchesRegex(subheading, t) {
                hidden = excluded(t)
                current = t
                return !hidden
            }
            if t.count <= 40, t.split(separator: " ").count <= 4, !matchesRegex(sectionSeparator, t),
                sectionKind(t) != nil
            {
                current = t
                return false
            }
            if !hidden, let current { sectionOf[a.text] = current }
            return !hidden
        }
        var items = all.compactMap { a -> Item? in
            guard var e = entry(a, people: people, matches: matches, time: time) else { return nil }
            e.part = sectionOf[a.text]
            return e
        }

        // Only under a matching heading: try other forms when the usual ones
        // yield too little - the form that explains the most paragraphs wins.
        if matches && Double(items.count) < max(Double(atLeast), 0.4 * Double(all.count)) {
            var candidates: [(list: [Item], weight: Int)] = [(items, 1)]
            candidates.append((linePairs(all, time: time), 2))  // Rule `lines`
            let lz = spacePairs(all)  // Rule `spaces`
            if Double(lz.count) >= 0.6 * Double(all.count), sortedLong(lz.map(\.term)) >= 0.8 {
                candidates.append((lz, 1))
            }
            if people {  // Rule `names`
                let nn = namesOnly(all)
                if Double(nn.count) >= 0.6 * Double(all.count) { candidates.append((nn, 1)) }
            }
            items =
                candidates.max { $0.list.count * $0.weight < $1.list.count * $1.weight }?.list ?? items
        }
        // Rule `content2`: terms that occur three times or more are speakers or
        // "Note:" - not entries.
        var repeated: [String: Int] = [:]
        for e in items { repeated[e.term.lowercased(), default: 0] += 1 }
        items = items.filter { (repeated[$0.term.lowercased()] ?? 0) < 3 }

        // Rule `filler`: if more than every eighth "term" is a
        // filler word, the chapter is prose, a question list or a poem register - not an
        // index. Otherwise the individual filler words drop out, as do entries whose
        // explanation is only page numbers.
        // Rule `register`: a printed index (page references on term or explanation in
        // more than three of ten entries) is not a glossary - the pages do not exist in the e-book
        // ("Valdor I 33, 36f., 50").
        let withPages = items.filter {
            matchesRegex(pageReference, $0.term) || matchesRegex(pageReference, $0.explanation)
        }
        if !items.isEmpty, Double(withPages.count) / Double(items.count) > 0.3 { return nil }
        if items.filter({ imprint.contains($0.term.lowercased()) }).count >= 2 { return nil }
        let filler = items.filter { fillerWords.contains($0.term.lowercased()) }.count
        // Under a persons heading ("Dramatis Personae") description lines often start with "He"
        // or "The merchant" - those drop out only individually, the chapter only from two fifths.
        if !items.isEmpty, Double(filler) / Double(items.count) > (people ? 0.4 : 0.125) { return nil }
        items = items.filter {
            !fillerWords.contains($0.term.lowercased()) && !matchesRegex(pageNumbersOnly, $0.explanation)
        }

        let fraction = Double(items.count) / Double(max(all.count, 1))
        var minimum = matches ? atLeast : minimumWithoutTitle
        if matches && fraction >= 0.8 { minimum = 4 }  // Rule `small`
        guard items.count >= minimum else { return nil }
        let orderScore = time ? 1.0 : ordering(items.map(\.term))
        guard matches ? (fraction >= 0.25 || orderScore >= 0.7) : (fraction >= 0.4 && orderScore >= 0.7)
        else { return nil }
        guard !noGlossary(items) else { return nil }  // Rule `content`

        // The kind per entry.
        let kind: Variant =
            time
            ? .time
            : people
                ? .person
                : matchesRegex(placesHeading, u ?? "")
                    ? .place
                    : matchesRegex(languageHeading, u ?? "") ? .language : .term
        var seen: Set<String> = []
        let unambiguous =
            items
            .filter { seen.insert($0.term.lowercased()).inserted }
            .map {
                Item(
                    term: $0.term, explanation: $0.explanation, forms: $0.forms,
                    type: Glossary.type($0, kind: kind), part: $0.part)
            }
        return (u ?? "Glossar", Array(unambiguous.prefix(atMost)))
    }

    // MARK: - One entry

    static let newTermPattern = rx(
        #"^([\p{L}\p{Nl}\p{No}][\p{L}\p{N}_'’.,\-/ ]{1,58}?(?:\s*\([^)]{1,40}\))?)"#
            + #"\s*(?:[:：]\s*|\s+[–—-]\s+|\s*=\s*|\s*;\s+|\s*[\t   ]+\s*|(?<=[\p{L}\p{N}_])[–—](?=[\p{L}\p{N}_]))(.{8,})$"#
    )
    static let listDash = rx(#"^\s*(?:[-–•·*▪►]|[a-z]\)|\(?\d{1,3}\))\s+"#)
    static let timePattern = rx(
        #"^((?:(?:um|ca\.|vor|nach|ab|seit|bis|anno|ende|anfang|mitte|fr(?:ü|ue)hjahr|sommer|herbst|winter)\s+)?"#
            + #"(?:\d{1,2}\.\s*(?:\d{1,2}\.\s*|[A-ZÄÖÜ][a-zäöü]+\.?\s+)?|[A-ZÄÖÜ][a-zäöü]+\.?\s+)?"#
            + #"\d{1,4}(?:\s*(?:[–—/\-]|bis)\s*\d{1,4})?(?:\s*(?:v\.|n\.)\s*Chr\.)?)"#
            + #"\s*(?:[:：]\s*|[–—\-]\s*|\s+)(.{3,})$"#)
    static let nameComma = rx(#"^((?:[A-ZÄÖÜ][\p{L}\p{N}_'’.\-]*\s?){1,4}),\s+(.{3,})$"#)
    static let nameLower = rx(
        #"^((?:[A-ZÄÖÜ][\p{L}\p{N}_'’.\-]*\s){1,4})(?=[a-zäöüß])"#
            + #"(?!(?:und|von|van|de|di|da|del|la|le|zu|aus|y|bin|ibn|al)\b)(.{3,})$"#)

    /// The groups of a match as strings (missing group -> empty).
    static func clusters(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    static func entry(
        _ paragraph: Paragraph, people: Bool = false, matches: Bool = false, time: Bool = false
    ) -> Item? {
        var text = paragraph.text
        var highlighted = paragraph.emphasized
        // Rule `separator`: strip the list dash at the front.
        text = text.replacingOccurrences(of: listDash.pattern, with: "", options: .regularExpression)
        // Rule `star`: "Name*:", "Name†" - remove the marker from the term (at the front of the paragraph).
        let frontText = String(text.prefix(70)).replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}_])[\*†]+"#, with: "", options: .regularExpression)
        text = frontText + text.dropFirst(70)
        highlighted = highlighted?.replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}_])[\*†]+"#, with: "", options: .regularExpression)

        var term: String?
        var explanation: String?
        // Rule `table`: dotted lines like table columns, cells separated by "│".
        text = text.replacingOccurrences(
            of: #"\s*(?:\.\s?){4,}\s*"#, with: " │ ", options: .regularExpression)
        if text.contains("│") {
            var cells = text.components(separatedBy: "│").map { $0.trimmingCharacters(in: .whitespaces) }
            while cells.count > 2, cells[0].rangeOfCharacter(from: .letters) == nil { cells.removeFirst() }
            if !cells[0].isEmpty, cells.dropFirst().contains(where: { !$0.isEmpty }) {
                term = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: " :–—-"))
                explanation = cells.dropFirst().filter { !$0.isEmpty }.joined(separator: " – ")
                highlighted = nil
                text = ""
            }
        }
        // Rule `number`: under a timeline the term is the date at the start of the line.
        if !text.isEmpty, time, let g = clusters(timePattern, text) {
            term = g[1].trimmingCharacters(in: .whitespaces)
            explanation = g[2]
            text = ""
        }
        if text.isEmpty {
            // already read
        } else if let h = highlighted, text.hasPrefix(h) {
            var remainder = String(text.dropFirst(h.count)).trimmingCharacters(in: .whitespaces)
            remainder = remainder.replacingOccurrences(
                of: #"^[:：–—-]\s*"#, with: "", options: .regularExpression)
            term = h.trimmingCharacters(in: CharacterSet(charactersIn: " :：–—-"))
            explanation = remainder
        } else if let g = clusters(termPattern, text) ?? clusters(newTermPattern, text) {
            term = g[1].trimmingCharacters(in: .whitespaces)
            explanation = g[2]
        } else if people, let g = clusters(nameComma, text) ?? clusters(nameLower, text) {
            // Rule `names`: "Wiebke, Ubbo's mother" - name up to the first comma.
            term = g[1].trimmingCharacters(in: .whitespaces)
            explanation = g[2]
        }
        term = term?.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        var minimum = people ? 3 : 8
        if matches { minimum = 2 }  // Rule `short`: "Tammo – Lotse"
        guard let b = term, let e = explanation, termOk(b, e, minimum: minimum, time: time) else {
            return nil
        }
        return Item(
            term: b, explanation: e.trimmingCharacters(in: .whitespaces), forms: forms(b))
    }

    static let periodEnd = rx(
        #"(?:\b[IVXLC]+|(?<![\p{L}\p{Nl}\p{No}])[\p{L}\p{Nl}\p{No}]{1,4}|\.[\p{L}\p{Nl}\p{No}])\.$"#)

    static func termOk(_ term: String, _ explanation: String, minimum: Int, time: Bool) -> Bool {
        guard !term.isEmpty, explanation.count >= minimum, let firstChar = term.first else { return false }
        let words = term.split(separator: " ", omittingEmptySubsequences: false)
        // Rule `period`: "Karl IV.", "Ltd." - abbreviation or Roman numeral, not a sentence end.
        let periodOk = words.count <= 4 && firstChar.isUppercase && matchesRegex(periodEnd, term)
        let startOk = firstChar.isLetter || (time && firstChar.isNumber)
        guard (2...60).contains(term.count), words.count <= 6, !term.hasSuffix(".") || periodOk,
            startOk
        else { return false }
        // A sentence with a colon is not a term: "The evening had fallen: ..."
        if words.count >= 4, term.contains(where: \.isLowercase),
            words.dropFirst().allSatisfy({ $0.first.map { $0.isLowercase } ?? true })
        {
            return false
        }
        return true
    }

    // MARK: - Other forms (only under a matching heading)

    /// A short paragraph that is only a keyword.
    static func termLike(_ text: String) -> Bool {
        let w = text.split(separator: " ")
        guard (1...5).contains(w.count), text.count <= 50, text.first?.isLetter == true else { return false }
        if let lastIndex = text.last, ".!?:;,".contains(lastIndex) { return false }
        return text.rangeOfCharacter(from: CharacterSet(charactersIn: "»«„“\"")) == nil
    }

    /// A follow-up line that is more explanation than a new keyword.
    static func explanationLike(_ text: String) -> Bool {
        guard text.count >= 3 else { return false }
        return !termLike(text) || text.contains(",") || text.first?.isNumber == true
            || text.range(of: #"(?:^|\s)[a-zäöüß]"#, options: .regularExpression) != nil
    }

    /// Rule `lines`: term alone in the paragraph, explanation in the next.
    static func linePairs(_ abs: [Paragraph], time: Bool) -> [Item] {
        var erg: [Item] = []
        var i = 0
        while i < abs.count - 1 {
            let a = abs[i].text
            let b = abs[i + 1].text
            if time,
                a.range(
                    of: #"^[\p{L}\p{N}_ .–—/\-]{0,25}\d{3,4}[\p{L}\p{N}_ .–—/\-]{0,12}$"#,
                    options: .regularExpression
                ) != nil,
                b.count >= 3
            {
                let term = a.trimmingCharacters(in: CharacterSet(charactersIn: " :–—-"))
                erg.append(Item(term: term, explanation: b, forms: [term]))
                i += 2
                continue
            }
            if termLike(a), a.count >= 2, explanationLike(b) {
                erg.append(Item(term: a, explanation: b, forms: forms(a)))
                i += 2
            } else {
                i += 1
            }
        }
        // Two-column word list (word / equivalent): almost only short lines.
        let short = abs.map(\.text).filter {
            termLike($0) && $0.split(separator: " ").count <= 3 && $0 != $0.uppercased()
        }
        if erg.count < atLeast, Double(short.count) >= 0.8 * Double(abs.count), short.count >= 2 * atLeast {
            erg = stride(from: 0, to: short.count - 1, by: 2).map {
                Item(term: short[$0], explanation: short[$0 + 1], forms: forms(short[$0]))
            }
        }
        return erg
    }

    static let spacePattern = rx(#"^([\p{L}\p{Nl}\p{No}][\p{L}\p{N}_'’\-]{1,30})[,.]?\s+(.{6,})$"#)

    /// Rule `spaces`: "word explanation" without separator.
    static func spacePairs(_ abs: [Paragraph]) -> [Item] {
        abs.compactMap { a in
            guard let g = clusters(spacePattern, a.text),
                let firstChar = g[2].first, !":–—-=".contains(firstChar)
            else { return nil }
            return Item(term: g[1], explanation: g[2], forms: forms(g[1]))
        }
    }

    /// Rule `names`: pure name lists under a persons heading.
    static func namesOnly(_ abs: [Paragraph]) -> [Item] {
        abs.compactMap { a in
            let t = a.text
            guard termLike(t), t.first?.isUppercase == true, t.count >= 2 else { return nil }
            let share = t.components(separatedBy: ", ")
            let name = share[0]
            return Item(
                term: name, explanation: share.dropFirst().joined(separator: ", "), forms: forms(name))
        }
    }

    // MARK: - Check content (rules `content`, `content2`)

    static let bibYear = rx(#"\b(1[5-9]\d\d|20\d\d)\b"#)
    static let bibWord = rx(
        #"(?i)verlag|hrsg|\bhg\.|\bS\.\s?\d|isbn|\bin:\s|edition\b|press\b|\bverl\.|auflage|\bbd\."#)
    static let tocTerm = rx(
        #"(?i)^(kapitel|teil|buch|chapter|part|abschnitt|folge|band|tag|szene|akt)\b\s*[\dIVXLC]*|^\d+\.?$|^[IVXLC]+\.?$|^(prolog|epilog)$|^[\p{L}\p{Nl}\p{No}]+\s+\d{1,3}$"#
    )

    /// Looks like an index but is literature, table of contents, register, picture credits,
    /// a quotation collection or dialogue.
    static func noGlossary(_ items: [Item]) -> Bool {
        let n = Double(items.count)
        guard n > 0 else { return false }
        func tally(_ condition: (Item) -> Bool) -> Double { Double(items.filter(condition).count) }
        let bib = tally {
            matchesRegex(bibYear, $0.term + " " + $0.explanation)
                && (matchesRegex(bibWord, $0.explanation)
                    || $0.term.range(of: #"\(\d{4}[a-z]?\)"#, options: .regularExpression) != nil
                    || $0.term.range(
                        of: #"^[A-ZÄÖÜ][\p{L}\p{N}_\-]+,\s[A-ZÄÖÜ]"#, options: .regularExpression)
                        != nil)
        }
        var toc = tally { matchesRegex(tocTerm, $0.term) }
        toc += tally { $0.term.range(of: #"(?i)^nr\.?\s*\d"#, options: .regularExpression) != nil }
        let pages = tally {
            $0.explanation.range(
                of: #"(?:^|[\s,])\d{1,4}(?:\s*[,;–-]\s*\d{1,4}){1,}\s*\.?$|^\d{1,4}\s*f*\.?$"#,
                options: .regularExpression)
                != nil
                || $0.explanation.range(
                    of: #"^(?:S\.|Seite|p\.)\s*\d{1,4}\s*f*\.?$"#, options: .regularExpression) != nil
        }
        let image = tally {
            $0.explanation.contains("©")
                || $0.term.range(of: #"(?i)^(seite|s\.)\s*\d|^abb"#, options: .regularExpression) != nil
        }
        let quote = tally {
            guard let e = $0.explanation.first, "»„\"«“".contains(e) else { return false }
            // A short translation at the start ("»Old friend«") is not a quotation.
            return $0.explanation.range(of: #"^[»„\"«“][^»«„“\"]{1,40}[«»“\"]"#, options: .regularExpression)
                == nil
        }
        let web = tally {
            $0.term.range(
                of: #"(?i)^(?:www\.|https?:)|\.(?:de|com|org|net|info|at|ch)$"#, options: .regularExpression)
                != nil
        }
        let unambiguous = Double(Set(items.map { $0.term.lowercased() }).count) / n
        let dialog = n >= 8 && unambiguous < 0.7
        return web >= 0.3 * n || bib >= 0.3 * n || toc >= 0.3 * n || pages >= 0.4 * n || image >= 0.3 * n
            || quote >= 0.3 * n || dialog
    }

    /// Share of the longest alphabetically ordered subsequence - robust against introductory paragraphs.
    static func sortedLong(_ terms: [String]) -> Double {
        let initials = terms.map { fold($0).first ?? " " }
        var ends: [Character] = []
        for a in initials {
            var lo = 0
            var hi = ends.count
            while lo < hi {  // bisect_right
                let center = (lo + hi) / 2
                if ends[center] <= a { lo = center + 1 } else { hi = center }
            }
            if lo == ends.count { ends.append(a) } else { ends[lo] = a }
        }
        return Double(ends.count) / Double(max(initials.count, 1))
    }

    /// Rule `front`: the window without a heading grows to the last 10 % for long books
    /// (appendices made of many individual files).
    static func inSearchWindow(_ position: Int, from total: Int) -> Bool {
        position >= total - max(lastChapters, total / 10)
    }

    static let lastChapters = 8

    // MARK: - Kind of an entry

    /// Rule `section`, in the same order: the first pattern wins.
    /// For persons capitalization counts ("Kontor Brammsen", "The Brammsens"), otherwise not.
    static let kindSection: [(Variant, NSRegularExpression)] = [
        (
            .place,
            rx(
                #"(?i)\b(orte?|schaupl(ä|ae)tze|l(ä|ae)nder|st(ä|ae)dte|geographie|geografie|landschaften|regionen|planeten|welten|reiche|provinzen|places|locations)\b"#
            )
        ),
        (
            .cluster,
            rx(
                #"(?i)\b(v(ö|oe)lker|rassen|orden|gilden|h(ä|ae)user|clans|st(ä|ae)mme|parteien|organisationen|gruppen|v(ö|oe)lkerschaften|institutionen|peoples|races)\b"#
            )
        ),
        (
            .person,
            rx(
                #"(person|figur|charakter|character|dramatis|familie|\bhaus\s+[A-ZÄÖÜ]|\bhof\b|g(ö|oe)tter|herrscher|k(ö|oe)nige|gefolge|besatzung|crew|mannschaft|die\s+[A-ZÄÖÜ]\w+s$)"#
            )
        ),
        (
            .thing,
            rx(
                #"(?i)\b(waffen|pflanzen|kr(ä|ae)uter|tiere|kreaturen|speisen|getr(ä|ae)nke|gerichte|kleidung|schiffe|fahrzeuge|ger(ä|ae)te|artefakte|w(ä|ae)hrung|m(ü|ue)nzen|edelsteine|drogen)\b"#
            )
        ),
        (.time, rx(#"(?i)\b(zeittafel|chronologie|chronik|zeitleiste|feste|feiertage|kalender|monate)\b"#)),
        (
            .language,
            rx(#"(?i)\b(sprache|w(ö|oe)rterbuch|vokabular|vokabeln|redewendungen|aussprache|übersetzung)\b"#)
        ),
        (.term, rx(#"(?i)\b(begriffe|glossar|abk(ü|ue)rzungen|fachbegriffe|r(ä|ae)nge|titel)\b"#)),
    ]
    /// A line with a separator ("Order: a league ...") is an entry, not a subheading.
    static let sectionSeparator = rx(#"[:–—=]|\s-\s|[.,;]\s|\d"#)

    static func sectionKind(_ s: String) -> Variant? {
        kindSection.first { matchesRegex($0.1, s) }?.0
    }

    static let kindNumber = rx(#"^\s*(?:um\s+|ca\.\s+|vor\s+|nach\s+|ab\s+)?(?:\d{1,4}|[IVXLC]+\.)\b"#)
    static let kindBefore =
        #"^(?:\(?[a-zäöü]+\.?\)?\s+)?(?:der|die|das|ein|eine|einer|eines|einem|den|dem)?\s*(?:[a-zäöüß\-]+(?:e|er|es|en|em)\s+){0,2}"#
    static let kindStart: [(Variant, NSRegularExpression)] =
        ([
            // Without "gut"/"hof": "gute Freundin" would otherwise be a place.
            (
                .place,
                #"(stadt|hauptstadt|dorf|d(ö|oe)rfchen|ort|ortschaft|siedlung|land|insel|fluss|strom|berg|gebirge|h(ü|ue)gel|tal|region|gegend|provinz|landschaft|k(ö|oe)nigreich|reich|herzogtum|grafschaft|festung|burg|schloss|palast|kloster|tempel|kirche|kathedrale|planet|mond|kontinent|see|meer|ozean|bucht|wald|w(ü|ue)ste|sumpf|hafen|hafenstadt|stadtteil|viertel|bezirk|stra(ß|ss)e|platz|gasthaus|schenke|taverne|wirtshaus|anwesen|turm|br(ü|ue)cke|pass|h(ö|oe)hle|quelle|zitadelle|stadtstaat|staat|halbinsel|archipel|bergwerk|mine|lager|gef(ä|ae)ngnis|garten|gebiet|bordell|kaffeehaus|saal|speisesaal|hospital|krankenhaus|refugium|unterwelt|freistadt|welt|nation|geb(ä|ae)ude|niederlassung|schlafsaal|ebene|heimat|heutige[snr]?\s+[A-ZÄÖÜ])"#
            ),
            (
                .person,
                #"(sohn|tochter|vater|mutter|bruder|schwester|ehefrau|ehemann|frau|mann|witwe|witwer|gattin|gatte|onkel|tante|neffe|nichte|enkel|enkelin|gro(ß|ss)vater|gro(ß|ss)mutter|cousin|cousine|freund|freundin|geliebte|geliebter|verlobte|diener|dienerin|magd|knecht|sklave|sklavin|k(ö|oe)nig|k(ö|oe)nigin|prinz|prinzessin|herzog|herzogin|graf|gr(ä|ae)fin|ritter|f(ü|ue)rst|f(ü|ue)rstin|kaiser|kaiserin|papst|bischof|abt|(ä|ae)btissin|m(ö|oe)nch|nonne|priester|priesterin|h(ä|ae)ndler|kaufmann|arzt|(ä|ae)rztin|soldat|hauptmann|kapit(ä|ae)n|kommissar|kommissarin|inspektor|anf(ü|ue)hrer|anf(ü|ue)hrerin|herrscher|herrscherin|zauberer|magier|magierin|hexe|krieger|kriegerin|schmied|wirt|wirtin|bauer|b(ä|ae)uerin|lehrer|lehrerin|sch(ü|ue)ler|sch(ü|ue)lerin|journalist|journalistin|politiker|politikerin|schriftsteller|dichter|maler|komponist|philosoph|gesandte|botschafter|minister|senator|general|admiral|leutnant|oberst|major|sergeant|offizier|kanzler|pr(ä|ae)sident|agent|agentin|waise|j(ü|ue)ngling|m(ä|ae)dchen|junge|kind|baby|mitglied|chef|chefin|leiter|leiterin|assistent|assistentin|sekret(ä|ae)r|sekret(ä|ae)rin|(ä|ae)ltester|vorsteher|gott|g(ö|oe)ttin|halbbruder|halbschwester|herrin|herr|lieutenant|captain|commander|midshipman|kommandant|kommandantin|premierminister|haush(ä|ae)lterin|meister|meisterin|"#
                    // Frequently missed in review:
                    + #"h(ü|ue)ter|h(ü|ue)terin|oberhaupt|pr(ä|ae)sident|pr(ä|ae)sidentin|vertraute[r]?|gef(ä|ae)hrte|gef(ä|ae)hrtin|"#
                    + #"spieler|spielerin|historiker|historikerin|assassine|clansherr|benediktiner|j(ä|ae)ger|j(ä|ae)gerin|pilot|pilotin|"#
                    + #"direktor|direktorin|polizist|polizistin|k(ö|oe)chin|koch|zauberin|knappe|erzbischof|gemahlin|gemahl|mensch|besitzer|besitzerin)"#
            ),
            (
                .cluster,
                #"(volk|stamm|orden|gilde|bund|geschlecht|clan|sippe|bruderschaft|schwesternschaft|partei|organisation|bewegung|armee|heer|einheit|regiment|truppe|bande|sekte|rasse|vereinigung|gesellschaft|firma|konzern|unternehmen|verband|beh(ö|oe)rde|ministerium|geheimdienst|polizei|dynastie|adelsgeschlecht|familie|bewohner|einwohner|anh(ä|ae)nger|krieger(?=\s+des)|angeh(ö|oe)rige[rn]?|br(ü|ue)der|soldaten|vampire|gremium|rat|department|volksstamm)"#
            ),
            (
                .thing,
                #"(schwert|waffe|dolch|messer|speer|lanze|bogen|axt|schild|r(ü|ue)stung|schiff|boot|fahrzeug|wagen|kutsche|pflanze|kraut|baum|blume|frucht|tier|vogel|pferd|hund|fisch|insekt|getr(ä|ae)nk|speise|gericht|suppe|kuchen|geb(ä|ae)ck|brot|eintopf|wein|bier|schnaps|lik(ö|oe)r|kleidung|gewand|mantel|tuch|kopfbedeckung|hut|m(ü|ue)tze|schuh|schmuck|ring|amulett|edelstein|stein|droge|gift|heilmittel|arznei|m(ü|ue)nze|w(ä|ae)hrung|instrument|musikinstrument|werkzeug|ger(ä|ae)t|maschine|apparat|artefakt|gef(ä|ae)(ß|ss)|beh(ä|ae)lter|m(ö|oe)bel|spiel|kartenspiel|geh(ä|ae)use|stange|stoff|euro)"#
            ),
            (
                .time,
                #"(fest|feiertag|festtag|feier|zeitalter|epoche|(ä|ae)ra|zeitrechnung|krieg|schlacht|monat|jahreszeit|wochentag|ritual)"#
            ),
        ] as [(Variant, String)]).map {
            ($0.0, rx(kindBefore + $0.1 + #"(?:e|en|n|s|es|er)?\b"#, .caseInsensitive))
        }
    /// The explanation itself and, if present, the rest after the first punctuation mark (`.`, `,`, `;`,
    /// `:`, `)`, `}`, `]`, `–`) within the first 80 characters.
    static func kindCues(_ explanation: String) -> [String] {
        var share = [explanation]
        let header = explanation.prefix(80)
        if let i = header.firstIndex(where: { ".,;:)}]–".contains($0) }) {
            let remainder = explanation[explanation.index(after: i)...].drop(while: {
                $0 == " " || ".,;:)}]–".contains($0)
            })
            if !remainder.isEmpty { share.append(String(remainder)) }
        }
        return share
    }

    static let lifeDates = rx(
        #"\(\s*(?:\*|geb\.|um|ca\.)?\s*\d{3,4}\s*[–—\-]\s*(?:†\s*)?\d{2,4}\s*\)|\bgeb(?:oren|\.)\s|\b\d{1,3}(?:-| )j(?:ä|ae)hrig|\b\d{1,3} jahre alt|\(\d{1,3}\)|†"#
    )

    /// Accuracy is highest for "person" and lower for "place".
    ///
    /// The keyword often stands after a preamble - "{OLE BRANDT VOM DEICH}, eldest son of ...",
    /// "a Watt-Nolde. The son ...", "(old tongue for ...); king of ...". Hence also after the first
    /// punctuation mark within the first 80 characters; most often a "term" where a reviewer saw
    /// a person, thing, group or place.
    static func type(_ e: Item, kind: Variant) -> Variant {
        if matchesRegex(kindNumber, e.term) { return .time }
        if kind != .language {
            for part in kindCues(e.explanation) {
                for (type, regex) in kindStart where matchesRegex(regex, part) { return type }
            }
        }
        if matchesRegex(lifeDates, String(e.explanation.prefix(80)) + " " + e.term) { return .person }
        // Under a persons heading, sections group persons ("Boats", "Kontore").
        if kind != .person, let a = e.part, let t = sectionKind(a) { return t }
        return kind
    }
}
