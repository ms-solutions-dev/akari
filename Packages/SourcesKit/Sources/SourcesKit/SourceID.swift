/// Which server type is behind a source.
///
/// There were three at the start; every further one is a new case — and a new package
/// that fulfils ``Source`` (Kavita via `KavitaKit`; Calibre-Web is pending). The UI asks the
/// provider only for the badge in the account and the origin of a rating; everything else
/// goes through ``Capabilities``.
public enum Provider: String, Sendable, Codable, CaseIterable, Hashable {
    case komga
    case grimmory
    case audiobookshelf
    /// Kavita (`KavitaKit`) — books, manga and comics with reading state in both
    /// directions. Via OPDS it still works too, then without state written back.
    case kavita
    /// Files on the device — no server, no account, no sign-in.
    case device = "geraet"
    /// An OPDS catalog — Calibre-Web, Ubooquity, or Komga, Grimmory and
    /// Kavita via the standard route. No server reading state.
    case opds
    /// A WebDAV folder — Nextcloud, ownCloud, any server with `PROPFIND`.
    /// Metadata from path and file, no server reading state.
    case webdav

    /// The providers with a server and an account — account sheet, setup code, sign-in.
    public static let server: [Provider] = [.komga, .grimmory, .audiobookshelf, .kavita, .opds, .webdav]
}

/// A signed-in account: provider plus server.
///
/// Two Komga servers are two sources — which is why the provider is not enough as a
/// key. `server` is the host as it appears in the account view
/// (`manga.example`), not the full address: scheme and path belong to the kit.
public struct SourceID: Sendable, Codable, Hashable, CustomStringConvertible {
    public let provider: Provider
    public let server: String

    public init(provider: Provider, server: String) {
        self.provider = provider
        self.server = server
    }

    public var description: String { "\(provider.rawValue)@\(server)" }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case provider = "anbieter"
        case server
    }
}

/// A title, unique across all sources.
///
/// The `id` is the server's (Komga UUID, Grimmory number, ABS item), and only with
/// the source in front of it is it unique — two servers may hand out the same
/// number.
public struct TitleID: Sendable, Codable, Hashable, CustomStringConvertible {
    public let source: SourceID
    public let id: String

    public init(source: SourceID, id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source)/\(id)" }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source = "quelle"
        case id
    }
}

/// A series, unique across all sources — following the same pattern as
/// ``TitleID``.
public struct SeriesID: Sendable, Codable, Hashable, CustomStringConvertible {
    public let source: SourceID
    public let id: String

    public init(source: SourceID, id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source)/serie/\(id)" }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source = "quelle"
        case id
    }
}
