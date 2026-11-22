/// What a source can do — the answer from which the UI derives buttons, rows and
/// segments without ever knowing the provider.
///
/// **Why a set and not a provider switch:** Grimmory knows keeping, but the account `robin` may
/// not fetch files (403 after the tap). The same integration, two answers — the capability
/// depends on the account, and only the source itself knows.
public struct Capabilities: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Pages individually from the server, without a file — Komga.
    public static let pageStream = Capabilities(rawValue: 1 << 0)
    /// May fetch and keep whole files — not for every account.
    public static let keep = Capabilities(rawValue: 1 << 1)
    /// Series and volume as structure, not just as a field.
    public static let seriesList = Capabilities(rawValue: 1 << 2)
    /// Community stars with their origin.
    public static let rating = Capabilities(rawValue: 1 << 3)
    /// A per-user saved list on the server — Komga has none.
    public static let savedList = Capabilities(rawValue: 1 << 4)
    /// Age rating per title — Komga.
    public static let ageRating = Capabilities(rawValue: 1 << 5)
    /// Read collections — shelves, read lists, playlists.
    public static let collections = Capabilities(rawValue: 1 << 6)
    /// Create and fill collections — Komga only as ADMIN.
    public static let editCollections = Capabilities(rawValue: 1 << 7)

    /// All eight — for checks that need a source without restrictions.
    public static let all: Capabilities = [
        .pageStream, .keep, .seriesList, .rating, .savedList, .ageRating, .collections,
        .editCollections,
    ]
}
