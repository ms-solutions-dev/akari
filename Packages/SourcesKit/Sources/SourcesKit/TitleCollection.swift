import Foundation

/// What a saved list or collection points at: a title or a whole series —
/// "I want to read Blawosfil Saga" is a wish about the series, not about volume 1.
public enum SaveTarget: Sendable, Hashable, Codable {
    case title(TitleID)
    case series(SeriesID)

    public var source: SourceID {
        switch self {
        case .title(let k): k.source
        case .series(let k): k.source
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case title = "titel"
        case series = "serie"
    }
    enum TitleCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum SeriesCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
}

public struct CollectionID: Sendable, Codable, Hashable, CustomStringConvertible {
    public let source: SourceID
    public let id: String

    public init(source: SourceID, id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source)/sammlung/\(id)" }

    /// The start of the identifier of an automatic shelf (``TitleCollection/automatic``).
    public static let autoPrefix = "auto-"

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source = "quelle"
        case id
    }
}

/// A set of titles or series maintained by the server — Grimmory's shelf, Komga's
/// collection (series) and read list (volumes, ordered), Audiobookshelf's collection
/// and playlist. One term for four things, so the library has one row and not four.
/// **In the UI this is called a shelf** (Grimmory's word): "collection" was understood as a
/// series — Miakus, Pibu Ratrund — and that is ``Series``. A shelf has a name of its own
/// ("Summer holiday"), a series tells a story; "saved" is the one list for what comes next.
///
/// **What the server cannot do is stated here:** ``editable`` says whether this account may
/// assign (Komga: ADMIN only, and then visible to everyone — ``isPrivate`` says so);
/// ``collectionKind`` says what fits in — series in a Komga collection, titles in everything
/// else. The app does not ask "is there Grimmory?" but "which collection takes this title?".
public struct TitleCollection: Sendable, Codable, Hashable, Identifiable {

    public enum CollectionKind: String, Sendable, Codable, Hashable {
        /// Grimmory shelf: books, unordered, per user.
        case shelf = "regal"
        /// Komga collection, Audiobookshelf collection: library-wide.
        case collection = "sammlung"
        /// Komga read list, Audiobookshelf playlist: titles in order.
        case readingList = "leseliste"

        /// Whether series belong in it (Komga collection) or titles (everything else).
        public var takesSeries: Bool { self == .collection }
    }

    public let identifier: CollectionID
    public let name: String
    public let collectionKind: CollectionKind
    /// In the server's order.
    public let entries: [SaveTarget]
    /// Whether the order carries meaning (read list) or is just a sort.
    public let ordered: Bool
    /// Only this account sees it — Grimmory shelf, Audiobookshelf playlist.
    public let isPrivate: Bool
    /// Whether this account may assign and remove.
    public let editable: Bool
    /// An icon name from the server, where there is one (Grimmory: Lucide).
    public let symbol: String?

    public var id: CollectionID { identifier }

    /// A shelf the server fills from rules (Grimmory "Magic Shelf") — nobody puts anything
    /// in or takes it out. Recognised by its identifier, so that older stored data without a
    /// field of its own stays readable.
    public var automatic: Bool { identifier.id.hasPrefix(CollectionID.autoPrefix) }

    public init(
        identifier: CollectionID, name: String, collectionKind: CollectionKind, entries: [SaveTarget],
        ordered: Bool = false,
        isPrivate: Bool = false, editable: Bool = false, symbol: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.collectionKind = collectionKind
        self.entries = entries
        self.ordered = ordered
        self.isPrivate = isPrivate
        self.editable = editable
        self.symbol = symbol
    }

    public func contains(_ target: SaveTarget) -> Bool { entries.contains(target) }

    /// The same collection with one target more or less — for optimistic writing in the
    /// library.
    public func with(_ target: SaveTarget, into: Bool) -> TitleCollection {
        var new = entries
        if into {
            if !new.contains(target) { new.append(target) }
        } else {
            new.removeAll { $0 == target }
        }
        return TitleCollection(
            identifier: identifier, name: name, collectionKind: collectionKind, entries: new,
            ordered: ordered,
            isPrivate: isPrivate,
            editable: editable, symbol: symbol)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case name
        case collectionKind = "gestalt"
        case entries = "eintraege"
        case ordered = "geordnet"
        case isPrivate = "privat"
        case editable = "bearbeitbar"
        case symbol
    }
}
