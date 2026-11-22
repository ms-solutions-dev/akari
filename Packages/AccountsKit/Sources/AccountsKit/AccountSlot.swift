import Foundation
import SourcesKit

/// A slot in the accounts sheet: provider plus number.
///
/// The three servers (Komga, Grimmory, Audiobookshelf) have exactly one slot,
/// number 0. OPDS catalogs and WebDAV folders count up — whoever keeps books, manga
/// and a Kavita separate has three catalogs one below the other ("add several OPDS,
/// all one below the other"), and two Nextcloud folders are two rows. The slot is
/// what the sheet opens and what the store keeps under the key
/// `konto.<provider>[.<number>]`.
public struct AccountSlot: Sendable, Hashable, Codable, CustomStringConvertible {
    public let provider: Provider
    public let number: Int

    public init(_ provider: Provider, number: Int = 0) {
        self.provider = provider
        self.number = number
    }

    /// The one slot of a server.
    public static func server(_ provider: Provider) -> AccountSlot { AccountSlot(provider) }

    /// Whether this provider may have several slots.
    public static func multiple(_ provider: Provider) -> Bool { provider == .opds || provider == .webdav }

    /// The key in the keychain — `konto.komga`, `konto.opds`, `konto.opds.2`; slot 0
    /// without number, so accounts written by earlier builds stay readable.
    var lookupKey: String {
        number == 0 ? "konto." + provider.rawValue : "konto.\(provider.rawValue).\(number)"
    }

    public var description: String { lookupKey }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case provider = "anbieter"
        case number = "nummer"
    }
}
