import Foundation
import SourcesKit

/// An OPDS account: the catalog address and, if the catalog demands it, name and password for
/// Basic Auth.
///
/// **The password stays** — unlike the three other kits, OPDS has no key and no token; every
/// request carries name and password. It lives in the Keychain like the other kits' secrets,
/// never in a file.
///
/// **An OPDS account is an OPDS account:** whether the catalog speaks Atom (1.2) or JSON (2.0)
/// is detected by ``OpdsSource/signIn(catalog:username:password:transport:)`` from the response
/// and remembered here only for the record — the account sheet does not ask for it, and every
/// feed is recognized by its shape on reading anyway.
public struct OpdsAccount: Sendable, Codable, Hashable {

    /// The edition of the catalog — Atom (OPDS 1.2) or JSON (OPDS 2.0).
    public enum Edition: String, Sendable, Codable, Hashable {
        case atom
        case json
    }

    /// The address of the catalog (root feed), e.g. `https://comics.example/opds/v1.2/catalog`.
    public let catalog: URL
    public let username: String
    public let password: String
    /// The title of the catalog as the feed names it — for the account sheet.
    public let title: String
    /// The search template with `{searchTerms}` in it — from OpenSearch (Atom) or from the URI
    /// template of the `search` link (JSON), both brought into the same form.
    public let search: String?
    /// For the record; accounts from older builds lack the field and count as Atom.
    public let edition: Edition

    public init(
        catalog: URL, username: String, password: String, title: String, search: String? = nil,
        edition: Edition = .atom
    ) {
        self.catalog = catalog
        self.username = username
        self.password = password
        self.title = title
        self.search = search
        self.edition = edition
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalog = try container.decode(URL.self, forKey: .catalog)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        title = try container.decode(String.self, forKey: .title)
        search = try container.decodeIfPresent(String.self, forKey: .search)
        edition = try container.decodeIfPresent(Edition.self, forKey: .edition) ?? .atom
    }

    public var server: URL { catalog }

    public var identifier: SourceID {
        SourceID(provider: .opds, server: catalog.host() ?? catalog.absoluteString)
    }

    /// What OPDS can do: series (from the feeds), keeping (the file is the way), individual pages
    /// only where the catalog speaks OPDS-PSE or names a Divina manifest — the feed says that, not
    /// the account; therefore `pageStream` is always listed here and the title decides. The same
    /// goes for reading state: the capabilities have no switch for it, the library always asks the
    /// source — and the source sends it to the progression API where the title names one, otherwise
    /// to local storage. No saved list, no collections.
    public var capabilities: Capabilities { [.seriesList, .keep, .pageStream] }

    var headerLines: [String: String] {
        guard !username.isEmpty else { return [:] }
        return ["Authorization": "Basic " + Data((username + ":" + password).utf8).base64EncodedString()]
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case catalog = "katalog"
        case username = "benutzername"
        case password = "passwort"
        case title = "titel"
        case search = "suche"
        case edition = "fassung"
    }
}
