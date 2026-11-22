import Bedrock
import Foundation
import SourcesKit

/// The QR code from the server: addresses and the certificate fingerprint in one
/// link — `akari://einrichten?komga=…&grimmory=…&audiobookshelf=…&zertifikat=…`,
/// for a per-person code additionally the user names (`komga-name=…`) and the
/// person themselves (`person=Alice`) — from that comes the name of the profile.
///
/// **"Add device":** The same link then also carries `freigabe=` (the iCloud share
/// link of the profile zone) and `farbe=` (the circle's theme). One QR code, and the
/// new device accepts the share, creates the profile, enters the accounts and only
/// asks for the passwords. **The `akari://` link is the carrier, not the iCloud
/// link:** The system camera recognizes both and offers "Open in Akari" (the custom
/// scheme is registered), but an iCloud link with appended account data is, as far
/// as `shareMetadata(for:)` is concerned, no longer the link CloudKit issued —
/// whether Apple ignores the foreign parameters is not guaranteed. The other way
/// round it is safe.
///
/// **Names yes, passwords never:** A name is no secret, and with it the app only
/// needs one password field for all three servers. A password in the code would be
/// on the page for everyone on the network — and Komga and Grimmory issue no key
/// without a password, there is no admin shortcut there.
///
/// **One link, no format of its own:** The camera app recognizes it and offers "Open
/// in Akari", the camera sheet in the app reads it as well, and whoever has no
/// scanner pastes it as text. The keys are the provider names from `Provider`, so a
/// fourth provider needs no new case.
///
/// **One fingerprint for all addresses:** On a home setup one certificate covers
/// `*.example` (mkcert) — the same fingerprint is stored for every host in the code.
/// Whoever has their own per server issues one code per server.
public struct SetupCode: Sendable, Hashable {

    public static let schema = "akari"
    public static let path = "einrichten"
    static let certificateKey = "zertifikat"
    static let nameSuffix = "-name"
    static let personKey = "person"
    static let sharingKey = "freigabe"
    static let colorKey = "farbe"

    public var server: [Provider: URL]
    /// The user name per provider — for Komga the email.
    public var names: [Provider: String]
    /// Who this is — "Alice", "Bob": the name of the profile the code sets up.
    public var person: String?
    public var fingerprint: CertificateFingerprint?
    /// The iCloud share link of the profile zone — "Add device".
    public var sharing: URL?
    /// The theme of the profile circle (`tinte`, `indigo` …) — with the share.
    public var color: String?

    public init(
        server: [Provider: URL], names: [Provider: String] = [:], person: String? = nil,
        fingerprint: CertificateFingerprint? = nil, sharing: URL? = nil, color: String? = nil
    ) {
        self.server = server
        self.names = names
        self.person = person
        self.fingerprint = fingerprint
        self.sharing = sharing
        self.color = color
    }

    /// Reads a link; `nil` if it is no setup link or contains no usable address.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.schema,
            (url.host() ?? "").lowercased() == Self.path
                || url.path.trimmingCharacters(in: ["/"]) == Self.path,
            let share = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var server: [Provider: URL] = [:]
        var names: [Provider: String] = [:]
        var person: String?
        var snapshot: CertificateFingerprint?
        var sharing: URL?
        var color: String?
        for item in share.queryItems ?? [] {
            guard let value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                continue
            }
            let name = item.name.lowercased()
            if name == Self.certificateKey {
                let hex = value.filter(\.isHexDigit)
                if hex.count == 64 { snapshot = CertificateFingerprint(value: hex) }
            } else if name == Self.personKey {
                person = value
            } else if name == Self.sharingKey {
                sharing = URL(string: value)
            } else if name == Self.colorKey {
                color = value
            } else if name.hasSuffix(Self.nameSuffix),
                let provider = Provider(rawValue: String(name.dropLast(Self.nameSuffix.count)))
            {
                names[provider] = value
            } else if let provider = Provider(rawValue: name), let address = ServerAddress.url(from: value) {
                server[provider] = address
            }
        }
        // A code without servers is only worth something with a share — then the zone brings the profile.
        guard !server.isEmpty || sharing != nil else { return nil }
        // A name without an address leads nowhere.
        names = names.filter { server[$0.key] != nil }
        self.init(
            server: server, names: names, person: person, fingerprint: snapshot, sharing: sharing,
            color: color)
    }

    /// Reads the text of a QR code — the same link, just as a string.
    public init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url)
    }

    /// The link the way the server side writes it into the QR code — providers in a
    /// fixed order so the same content yields the same code.
    public var url: URL {
        var share = URLComponents()
        share.scheme = Self.schema
        share.host = Self.path
        var items: [URLQueryItem] = []
        for provider in Provider.server {
            guard let address = server[provider] else { continue }
            items.append(URLQueryItem(name: provider.rawValue, value: address.absoluteString))
            if let name = names[provider] {
                items.append(URLQueryItem(name: provider.rawValue + Self.nameSuffix, value: name))
            }
        }
        if let person {
            items.append(URLQueryItem(name: Self.personKey, value: person))
        }
        if let fingerprint {
            items.append(URLQueryItem(name: Self.certificateKey, value: fingerprint.value))
        }
        if let color { items.append(URLQueryItem(name: Self.colorKey, value: color)) }
        if let sharing {
            items.append(URLQueryItem(name: Self.sharingKey, value: sharing.absoluteString))
        }
        share.queryItems = items
        return share.url!
    }

    /// The host names the fingerprint applies to.
    public var computer: [String] {
        server.values.compactMap { $0.host()?.lowercased() }.sorted()
    }
}

extension SetupCode {

    /// The code of a profile for another device: the three servers with address and user
    /// name, the trusted fingerprint of the first host — never a password, never a
    /// token. OPDS catalogs and WebDAV folders do not come along (the code knows one slot
    /// per provider; they are created on the new device as usual).
    public static func from(
        accounts: [AccountSlot: AccountEntry], trusts: CertificateTrustStore, person: String, color: String?,
        sharing: URL?
    ) -> SetupCode {
        var server: [Provider: URL] = [:]
        var names: [Provider: String] = [:]
        for provider in Provider.server where !AccountSlot.multiple(provider) {
            guard let account = accounts[.server(provider)]?.account else { continue }
            server[provider] = account.server
            if !account.username.isEmpty { names[provider] = account.username }
        }
        let snapshot = server.values.compactMap { $0.host() }.sorted().lazy
            .compactMap { trusts.fingerprint(for: $0) }.first
        return SetupCode(
            server: server, names: names, person: person, fingerprint: snapshot, sharing: sharing,
            color: color)
    }
}
