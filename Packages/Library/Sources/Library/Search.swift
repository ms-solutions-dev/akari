import Foundation
import SourcesKit

/// The search across the shelf — one title, three servers, no network.
///
/// **Local, not on the server**: the shelf already lies entirely in memory;
/// asking three servers would mean waiting for three response times through the
/// tunnel only to show the same titles. And offline, only this works.
///
/// **What counts is the name** — and the author and the series, because one
/// types "Doyle" when "Sherlock" does not come to mind. Umlauts and accents are folded,
/// case does not matter; every word of the input must occur, in any
/// order.
extension Shelf {

    public struct SearchResult: Sendable, Hashable {
        /// A hit: a title, or a series with the volumes that themselves
        /// matched — "Bokraisik Branbros" shows the series, not 111 volumes.
        public enum Hit: Sendable, Hashable, Identifiable {
            case title(Title)
            case series(Series, volumes: [Title])

            public var id: String {
                switch self {
                case .title(let t): t.identifier.description
                case .series(let s, _): s.identifier.description
                }
            }
        }

        public struct Cluster: Sendable, Hashable, Identifiable {
            public let kind: Kind
            public let hit: [Hit]
            public var id: Kind { kind }
        }

        /// An author as a hit of its own — leads to everything by them.
        public struct Author: Sendable, Hashable, Identifiable {
            public let name: String
            public let count: Int
            public var id: String { name }
        }

        public let clusters: [Cluster]
        public let authors: [Author]

        public var empty: Bool { clusters.isEmpty && authors.isEmpty }
        public static let empty = SearchResult(clusters: [], authors: [])
    }

    /// How many volumes stand under a series — more leads to the series detail.
    public static let volumesPerHit = 5

    public func search(_ text: String, kind: Kind? = nil) -> SearchResult {
        let words = Shelf.searchWords(text)
        guard !words.isEmpty else { return .empty }
        var hit: [Kind: [(rang: Int, hit: SearchResult.Hit)]] = [:]
        var authors: [String: Int] = [:]
        for entry in entries(kind) {
            for author in entry.authors where Shelf.matches(words, on: [author]) {
                authors[author, default: 0] += 1
            }
            switch entry {
            case .title(let t):
                if let rang = Shelf.rang(words, name: t.name, others: t.authors + [t.series?.name ?? ""]) {
                    hit[t.kind, default: []].append((rang, .title(t)))
                }
            case .series(let s):
                let all = volumes(s.identifier)
                let own = all.filter { Shelf.rang(words, name: $0.name, others: []) != nil }
                if let rang = Shelf.rang(words, name: s.name, others: s.authors) {
                    // The series itself matches: volumes only if some of them
                    // match on their own — if all match (because they carry the series
                    // name), the series is the hit.
                    let volumes = own.count == all.count ? [] : own
                    hit[s.kind, default: []].append((rang, .series(s, volumes: volumes)))
                } else if !own.isEmpty {
                    hit[s.kind, default: []].append((3, .series(s, volumes: own)))
                }
            }
        }
        let clusters = Kind.allCases.compactMap { kind -> SearchResult.Cluster? in
            guard let list = hit[kind], !list.isEmpty else { return nil }
            let ordered = list.sorted { a, b in
                if a.rang != b.rang { return a.rang < b.rang }
                return Shelf.name(a.hit).localizedStandardCompare(Shelf.name(b.hit))
                    == .orderedAscending
            }
            return SearchResult.Cluster(kind: kind, hit: ordered.map(\.hit))
        }
        let authorList = authors.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { SearchResult.Author(name: $0, count: authors[$0]!) }
        return SearchResult(clusters: clusters, authors: authorList)
    }

    // MARK: - Helpers

    /// The words of the input, folded — empty for whitespace alone.
    static func searchWords(_ text: String) -> [String] {
        Shelf.folded(text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Whether every word occurs in one of the fields.
    static func matches(_ words: [String], on fields: [String]) -> Bool {
        let haystack = fields.map(Shelf.folded)
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }

    /// The rank of a hit: 0 the name begins with the input, 1 a word of the
    /// name begins with it, 2 the name contains it, 3 only author or series match —
    /// `nil` means no hit.
    static func rang(_ words: [String], name: String, others: [String]) -> Int? {
        let folded = Shelf.folded(name)
        if Shelf.matches(words, on: [name]) {
            if folded.hasPrefix(words.joined(separator: " ")) { return 0 }
            let nameWords = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return 1 }
            return 2
        }
        return Shelf.matches(words, on: [name] + others) ? 3 : nil
    }

    private static func name(_ hit: SearchResult.Hit) -> String {
        switch hit {
        case .title(let t): t.name
        case .series(let s, _): s.name
        }
    }
}
