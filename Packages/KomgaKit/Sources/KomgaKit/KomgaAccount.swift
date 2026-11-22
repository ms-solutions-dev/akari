import Foundation
import SourcesKit

/// A signed-in Komga account: server, key, permissions.
///
/// **Key, not password:** the password is needed once for signing in and is then
/// forgotten. What stays is an API key with the comment "Akari on iPhone of …" — visible
/// in the account sheet, revocable on the server without changing the password. And
/// Komga's KOReader sync needs it anyway.
public struct KomgaAccount: Sendable, Codable, Hashable {
    public let server: URL
    public let userId: String
    public let email: String
    public let apiKey: String
    /// The id of the key on the server — for deleting it when signing out.
    public let keyId: String
    public let roles: [String]

    public init(
        server: URL, userId: String, email: String, apiKey: String, keyId: String,
        roles: [String]
    ) {
        self.server = server
        self.userId = userId
        self.email = email
        self.apiKey = apiKey
        self.keyId = keyId
        self.roles = roles
    }

    public var identifier: SourceID {
        SourceID(provider: .komga, server: server.host() ?? server.absoluteString)
    }

    /// What this account may do — from the roles, not from the provider.
    ///
    /// `PAGE_STREAMING` is reading itself, `FILE_DOWNLOAD` is keeping. Series
    /// and age rating are known to Komga for everyone; saved list and rating for
    /// no one.
    public var capabilities: Capabilities {
        var f: Capabilities = [.seriesList, .ageRating, .collections]
        if roles.contains("PAGE_STREAMING") { f.insert(.pageStream) }
        if roles.contains("FILE_DOWNLOAD") { f.insert(.keep) }
        // Collections and reading lists are library-wide — only ADMIN may create them,
        // and what it creates is seen by all accounts.
        if roles.contains("ADMIN") { f.insert(.editCollections) }
        return f
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case server
        case userId = "nutzerId"
        case email
        case apiKey = "schluessel"
        case keyId = "schluesselId"
        case roles = "rollen"
    }
}
