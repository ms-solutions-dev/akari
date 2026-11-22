import Foundation
import SourcesKit

/// What an `.akari` package knows about its content — `metadaten.json` next to the
/// file. Version 1. Everything except `art`, `name` and `datei` is optional, so that a
/// package from a bare file (only the name from the file name) is just as valid as one
/// from the server library with series, volume and blurb.
public struct PackageMetadata: Codable, Sendable, Hashable {

    public struct BookSeries: Codable, Sendable, Hashable {
        public var name: String
        public var volume: Double?
        public init(name: String, volume: Double? = nil) {
            self.name = name
            self.volume = volume
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case volume = "band"
        }
    }

    /// Where the file came from — so that a recipient sees which shelf it came from.
    public struct Origin: Codable, Sendable, Hashable {
        public var provider: String
        public var server: String
        public var id: String
        public init(provider: String, server: String, id: String) {
            self.provider = provider
            self.server = server
            self.id = id
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case provider = "anbieter"
            case server
            case id
        }
    }

    public var version = 1
    public var kind: Kind
    public var name: String
    public var subtitle: String?
    public var authors: [String] = []
    public var bookSeries: BookSeries?
    public var language: String?
    public var publisher: String?
    public var summary: String?
    public var genres: [String] = []
    public var pages: Int?
    /// The name of the file in the package — `inhalt.epub`, `inhalt.pdf`, `inhalt.cbz`.
    public var file: String
    /// The name of the cover in the package, if one is included.
    public var cover: String?
    public var origin: Origin?
    public var createdAt: Date

    public init(
        kind: Kind, name: String, subtitle: String? = nil, authors: [String] = [],
        bookSeries: BookSeries? = nil,
        language: String? = nil, publisher: String? = nil, summary: String? = nil, genres: [String] = [],
        pages: Int? = nil, file: String, cover: String? = nil, origin: Origin? = nil,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.authors = authors
        self.bookSeries = bookSeries
        self.language = language
        self.publisher = publisher
        self.summary = summary
        self.genres = genres
        self.pages = pages
        self.file = file
        self.cover = cover
        self.origin = origin
        self.createdAt = createdAt
    }

    /// From a title of the library — for "share as Akari package".
    public init(_ title: Title, file: String, cover: String?) {
        self.init(
            kind: title.kind, name: title.name, subtitle: title.subtitle, authors: title.authors,
            bookSeries: title.series.map { BookSeries(name: $0.name, volume: $0.volume) },
            language: title.language,
            publisher: title.publisher, summary: title.summary, genres: title.genres,
            pages: { if case .pages(let n) = title.scope { n } else { nil } }(),
            file: file, cover: cover,
            origin: Origin(
                provider: title.identifier.source.provider.rawValue, server: title.identifier.source.server,
                id: title.identifier.id))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func json() throws -> Data { try PackageMetadata.encoder.encode(self) }

    public static func from(_ data: Data) throws -> PackageMetadata {
        try decoder.decode(PackageMetadata.self, from: data)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case kind = "art"
        case name
        case subtitle = "untertitel"
        case authors = "autoren"
        case bookSeries = "reihe"
        case language = "sprache"
        case publisher = "verlag"
        case summary = "zusammenfassung"
        case genres
        case pages = "seiten"
        case file = "datei"
        case cover
        case origin = "herkunft"
        case createdAt = "erstellt"
    }
}

/// The extensions the source knows, and what they mean.
public enum FileKind: String, Sendable, CaseIterable {
    case epub, pdf, cbz
    /// Akari's own package.
    case akari

    public var kind: Kind { self == .cbz ? .manga : .book }

    public init?(_ url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}
