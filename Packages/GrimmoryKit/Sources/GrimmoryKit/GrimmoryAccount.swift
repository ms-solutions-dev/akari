import Foundation
import SourcesKit

/// A signed-in Grimmory account: server, user, token pair.
///
/// **The token pair moves:** The access token lives two hours; the refresh token
/// exchanges it — and replaces itself in the process. Whoever stores the account must
/// notice the change; ``GrimmorySource`` reports every new pair through `changed`.
/// The password is never stored.
public struct GrimmoryAccount: Sendable, Codable, Hashable {
    public let server: URL
    public let userId: Int
    public let username: String
    public let displayName: String?
    public let mayFetch: Bool
    public var access: GrimmoryAccess

    public init(
        server: URL, userId: Int, username: String, displayName: String?, mayFetch: Bool,
        access: GrimmoryAccess
    ) {
        self.server = server
        self.userId = userId
        self.username = username
        self.displayName = displayName
        self.mayFetch = mayFetch
        self.access = access
    }

    public var identifier: SourceID {
        SourceID(provider: .grimmory, server: server.host() ?? server.absoluteString)
    }

    /// Grimmory offers series, ratings and the saved list to everyone; keeping (offline)
    /// only to accounts with `canDownload`.
    public var capabilities: Capabilities {
        var f: Capabilities = [.seriesList, .rating, .savedList, .collections, .editCollections]
        if mayFetch { f.insert(.keep) }
        return f
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case server
        case userId = "nutzerId"
        case username = "benutzername"
        case displayName = "anzeigename"
        case mayFetch = "darfHolen"
        case access = "zugang"
    }
}

/// Access token, refresh token and when the access expires.
public struct GrimmoryAccess: Sendable, Codable, Hashable {
    public let token: String
    public let refreshToken: String
    public let flow: Date

    public init(token: String, refreshToken: String, flow: Date) {
        self.token = token
        self.refreshToken = refreshToken
        self.flow = flow
    }

    /// Reads `expires` in its three forms: seconds from now (sign-in: 7200), timestamp
    /// in seconds, timestamp in milliseconds (refresh).
    public static func flow(from expires: Double, now: Date = Date()) -> Date {
        if expires > 1e12 { return Date(timeIntervalSince1970: expires / 1000) }
        if expires > 1e9 { return Date(timeIntervalSince1970: expires) }
        return now.addingTimeInterval(expires)
    }

    /// Whether the access still works now — with a minute to spare, because a request
    /// through the tunnel takes longer than a timestamp is accurate.
    public func usable(now: Date = Date()) -> Bool {
        now < flow.addingTimeInterval(-60)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case token
        case refreshToken = "auffrischtoken"
        case flow = "ablauf"
    }
}
