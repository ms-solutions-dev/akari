import Foundation

/// Where each term appears in the book - in **words**, not pages:
/// pages depend on font size and device, the word position is fixed once the book has been counted.
///
/// Counted once per book in the background, together with the glossary search. From it come the
/// ``MarkingPlan``, the state in the sheet ("First in chapter 3 - up to here 19 times") and the
/// spoiler protection (only what appeared up to here).
///
/// Like a secondary index on a database table: built once, only
/// read while paging.
public struct TermIndex: Sendable, Hashable {

    /// A mention in the chapter: which term, at which word of the chapter.
    public struct Mention: Sendable, Hashable, Codable {
        public let term: String
        public let word: Int
        /// In an epigraph at the start of a chapter: tappable, never marked. `nil` means no.
        public var epigraph: Bool? = nil

        enum CodingKeys: String, CodingKey, CaseIterable {
            case term = "begriff"
            case word = "wort"
            case epigraph = "motto"
        }
    }

    /// A chapter of the reading order with its mentions in text order.
    public struct Chapter: Sendable, Hashable, Codable {
        public let href: String
        public let words: Int
        public let mentions: [Mention]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case href
            case words = "woerter"
            case mentions = "nennungen"
        }
    }

    public let chapter: [Chapter]
    /// Word position of the chapter start in the book, parallel to `chapter`.
    public let start: [Int]
    /// Term -> all word positions in the book, ascending.
    public let positions: [String: [Int]]

    public init(chapter: [Chapter]) {
        self.chapter = chapter
        var start: [Int] = []
        var sum = 0
        var positions: [String: [Int]] = [:]
        for k in chapter {
            start.append(sum)
            for n in k.mentions { positions[n.term, default: []].append(sum + n.word) }
            sum += k.words
        }
        self.start = start
        self.positions = positions
    }

    public var words: Int { (start.last ?? 0) + (chapter.last?.words ?? 0) }

    /// The word position of a spot - chapter and fraction within it (Readium's `progression`).
    public func word(href: String, fraction: Double) -> Int? {
        guard let i = chapter.firstIndex(where: { SpineCard.equal($0.href, href) }) else { return nil }
        return start[i] + Int(Double(chapter[i].words) * min(max(fraction, 0), 1))
    }

    /// The chapter (index in the reading order) for a word position.
    public func chapterIndex(word: Int) -> Int? {
        guard !start.isEmpty else { return nil }
        var lo = 0
        var hi = start.count - 1
        while lo < hi {
            let center = (lo + hi + 1) / 2
            if start[center] <= word { lo = center } else { hi = center - 1 }
        }
        return lo
    }

    /// "First in chapter 3 - up to here 19 times" - without `until` over the whole book.
    public func state(_ term: String, until: Int? = nil) -> (first: Int?, count: Int) {
        let all = positions[term] ?? []
        let untilHere = until.map { limit in all.filter { $0 <= limit } } ?? all
        return (all.first, untilHere.count)
    }

    /// Spoiler protection: did the term appear up to `word`?
    /// Only what first appears AFTER the spot is unknown - a
    /// term with no mention in the text at all reveals nothing and stays visible.
    public func known(_ term: String, until word: Int) -> Bool {
        (positions[term]?.first).map { $0 <= word } ?? true
    }

    /// Where in the book the term appears: mentions per bar, the book split into
    /// `bars` equal pieces. With `until` only what appeared up to there counts (spoiler protection).
    public func history(_ term: String, bars: Int = 40, until: Int? = nil) -> [Int] {
        var figures = Array(repeating: 0, count: bars)
        let total = max(words, 1)
        for w in positions[term] ?? [] where until.map({ w <= $0 }) ?? true {
            figures[min(bars - 1, w * bars / total)] += 1
        }
        return figures
    }
}

/// Which mentions get a line:
/// **Marked != tappable** - every mention stays tappable, marking happens only at the first
/// appearance and after a long pause. Before, it was 30-40 lines per 1,000 words;
/// the rule allows at most 3.
///
/// A pure function: input the ``TermIndex``, output per chapter the indices
/// of the marked mentions. Independent of font size and device, hence once per book.
///
/// Rules R1 to R6 and the precedence are implemented: the candidates (R1, R3, R4 do not
/// depend on what else is marked) are accepted by precedence - very first
/// mention, never opened, rare before frequent, place/person before group before thing/term before
/// language/time, then the earlier position. R2, R5 and R6 apply against the already accepted
/// marks in both directions. R4 ("opened") depends on the reader: `opened` carries per
/// term the word position at opening, the reader recomputes after every opening.
public enum MarkingPlan {

    public struct Rules: Sendable {
        /// Chapters over this many words are split into sections ...
        public var longChapter = 6_000
        /// ... of this length.
        public var part = 3_000
        /// R2: distance to the last *marked* mention of the same term.
        public var markAgain = 2_500
        /// R3: frequent terms (more than one mention per `oftenPer` words) only after such a
        /// long pause again.
        public var oftenPause = 20_000
        public var oftenPer = 300
        /// R5: distance to the previous mark of any term.
        public var spacing = 40
        /// R6: at most `perWindow` marks in a sliding window of `window` words.
        public var window = 1_000
        public var perWindow = 3
        /// After a forced first mention (beyond R6) at the earliest again after ...
        public var afterFirst = 300
        /// R4: an opened term at the earliest this many words after opening again.
        public var afterOpening = 10_000

        public init() {}
    }

    /// Chapter href -> indices (in ``TermIndex/Chapter/mentions``) of the marked mentions.
    public static func compute(
        _ v: TermIndex, rules r: Rules = Rules(), types: [String: Glossary.Variant] = [:],
        opened: [String: Int] = [:]
    ) -> [String: Set<Int>] {
        let total = max(v.words, 1)
        let frequent = Set(v.positions.filter { $0.value.count * r.oftenPer > total }.keys)

        // 1. Candidates in text order.
        struct Candidate {
            let chapter: Int, index: Int, term: String, word: Int, first: Bool
        }
        var candidates: [Candidate] = []
        var lastMentioned: [String: Int] = [:]
        var seenInSection: Set<String> = []
        var previousSection = -1
        for (ki, k) in v.chapter.enumerated() {
            for (ni, n) in k.mentions.enumerated() {
                let w = v.start[ki] + n.word
                // An epigraph does not count: the first real mention after it is the first.
                if n.epigraph == true { continue }
                // R1: section = chapter, long chapters in pieces of 3,000 words.
                let part =
                    k.words > r.longChapter ? ki * 100_000 + n.word / r.part : ki * 100_000
                if part != previousSection {
                    seenInSection = []
                    previousSection = part
                }
                let firstInSection = seenInSection.insert(n.term).inserted
                let previously = lastMentioned[n.term]
                lastMentioned[n.term] = w
                guard firstInSection else { continue }
                if let previously {
                    if frequent.contains(n.term), w - previously < r.oftenPause { continue }  // R3
                    if let on = opened[n.term], w >= on, w - on < r.afterOpening { continue }  // R4
                }
                candidates.append(
                    Candidate(chapter: ki, index: ni, term: n.term, word: w, first: previously == nil))
            }
        }

        // 2. Precedence.
        func rank(_ t: Glossary.Variant?) -> Int {
            switch t {
            case .person, .place: 0
            case .cluster: 1
            case .language, .time: 3
            default: 2
            }
        }
        let bookSeries = candidates.sorted { a, b in
            if a.first != b.first { return a.first }
            let aOpen = opened[a.term] != nil, bOpen = opened[b.term] != nil
            if aOpen != bOpen { return !aOpen }
            let aN = v.positions[a.term]?.count ?? 0, bN = v.positions[b.term]?.count ?? 0
            if aN != bN { return aN < bN }
            let aR = rank(types[a.term]), bR = rank(types[b.term])
            if aR != bR { return aR < bR }
            return a.word < b.word
        }

        // 3. Accept as long as R2, R5, R6 and the lock after a first mention hold.
        var marked: [Int] = []  // Word positions of all marks, ascending
        var perTerm: [String: [Int]] = [:]
        var locked: [Range<Int>] = []
        var result: [String: Set<Int>] = [:]
        for k in bookSeries {
            let w = k.word
            let i = marked.firstIndex { $0 >= w } ?? marked.count
            if !k.first {
                if (perTerm[k.term] ?? []).contains(where: { abs(w - $0) < r.markAgain }) {
                    continue
                }
                let neighbors = [i > 0 ? marked[i - 1] : nil, i < marked.count ? marked[i] : nil]
                if neighbors.contains(where: { $0.map { abs(w - $0) < r.spacing } ?? false }) { continue }
                if locked.contains(where: { $0.contains(w) }) { continue }
                // R6: every window of `window` words that contains w then has at most `perWindow`.
                let near = marked.filter { abs($0 - w) < r.window } + [w]
                let tooMany = near.contains { start in
                    start <= w && near.filter { $0 >= start && $0 < start + r.window }.count > r.perWindow
                }
                if tooMany { continue }
            }
            marked.insert(w, at: i)
            perTerm[k.term, default: []].append(w)
            if k.first { locked.append((w + 1)..<(w + r.afterFirst)) }
            result[v.chapter[k.chapter].href, default: []].insert(k.index)
        }
        return result
    }
}
