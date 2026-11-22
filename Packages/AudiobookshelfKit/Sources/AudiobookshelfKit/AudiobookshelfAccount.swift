import Foundation
import SourcesKit

/// A signed-in Audiobookshelf account: server, user, permanent token.
///
/// The token does not expire and does not rotate — it is what `POST /login`
/// returns, and stays valid until the user is reassigned on the server.
public struct AudiobookshelfAccount: Sendable, Codable, Hashable {
    public let server: URL
    public let userId: String
    public let username: String
    public let token: String
    public let mayFetch: Bool

    public init(server: URL, userId: String, username: String, token: String, mayFetch: Bool) {
        self.server = server
        self.userId = userId
        self.username = username
        self.token = token
        self.mayFetch = mayFetch
    }

    public var identifier: SourceID {
        SourceID(provider: .audiobookshelf, server: server.host() ?? server.absoluteString)
    }

    /// Series for everyone; keeping needs the `download` permission; Audiobookshelf has no
    /// stars. The saved list (one playlist per user) comes in stage 2 — until the kit
    /// writes it, it does not declare it.
    public var capabilities: Capabilities {
        var f: Capabilities = [.seriesList, .collections, .editCollections]
        if mayFetch { f.insert(.keep) }
        return f
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case server
        case userId = "nutzerId"
        case username = "benutzername"
        case token
        case mayFetch = "darfHolen"
    }
}
