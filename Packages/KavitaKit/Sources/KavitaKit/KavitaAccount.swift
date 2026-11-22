import Foundation
import SourcesKit

/// A signed-in Kavita account: server, key, roles.
///
/// **Key, not password and not JWT** — as with Komga: since
/// 0.9 Kavita has auth keys per user that apply as the `x-api-key` header on every
/// endpoint (measured on `/api/Library/libraries`). The
/// password is needed once for signing in and then forgotten; the JWT
/// from the sign-in lives only until the key is created. No
/// refreshing, no token pair that migrates.
public struct KavitaAccount: Sendable, Codable, Hashable {
    public let server: URL
    public let userId: Int
    public let username: String
    public let apiKey: String
    /// The id of the own auth key on the server — for deleting it when signing out.
    /// `nil` if the kit could not create one and uses the account key (`apiKey`,
    /// the same as for OPDS); signing out does not delete that.
    public let keyId: Int?
    public let roles: [String]

    public init(
        server: URL, userId: Int, username: String, apiKey: String, keyId: Int?,
        roles: [String]
    ) {
        self.server = server
        self.userId = userId
        self.username = username
        self.apiKey = apiKey
        self.keyId = keyId
        self.roles = roles
    }

    public var identifier: SourceID {
        SourceID(provider: .kavita, server: server.host() ?? server.absoluteString)
    }

    /// What this account may do — from the roles.
    ///
    /// Anyone who may read may fetch pages individually at Kavita; series and volume
    /// are the server's structure; the age rating is on every chapter.
    /// Fetching files is only for `Download` — or `Admin`, which Kavita allows everything
    /// (`HasDownloadPermission`). Without the permission the EPUB stays closed
    /// at Kavita too: the book reader needs the file, Kavita's own reader renders on the
    /// server (`/api/Book/{id}/book-page`), and Akari does not read that.
    ///
    /// The saved list is Kavita's "Want to Read" (per user, per series), collections
    /// are collections (series) and reading lists (chapters); any account may create and fill
    /// its own — editable per collection is only what belongs to the account.
    /// The rating is the average of this server's accounts.
    public var capabilities: Capabilities {
        var f: Capabilities = [
            .pageStream, .seriesList, .ageRating, .rating, .savedList, .collections,
            .editCollections,
        ]
        if mayFetch { f.insert(.keep) }
        return f
    }

    /// `Download` or `Admin` — the role names as `UserDto.roles` names them.
    public var mayFetch: Bool { roles.contains("Download") || roles.contains("Admin") }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case server
        case userId = "nutzerId"
        case username = "benutzername"
        case apiKey = "schluessel"
        case keyId = "schluesselId"
        case roles = "rollen"
    }
}
