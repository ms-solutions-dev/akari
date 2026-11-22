import AudiobookshelfKit
import Bedrock
import Foundation
import GrimmoryKit
import KavitaKit
import KomgaKit
import OpdsKit
import SourcesKit
import WebdavKit

/// Builds the source from an account and signs an account in — the one place that
/// knows the three kits by name.
///
/// The transport is a slot: in production a `URLSession` with the certificate guard,
/// in tests the mock transport with recorded responses. That way the registry is
/// checked against what the servers actually said, without asking one.
public struct SourceFactory: Sendable {

    /// The transport per provider — per provider so a test can make Komga fail and let
    /// Grimmory answer.
    public let transport: @Sendable (Provider) -> any Transport
    /// Where the local reading states of the sources without a server-side state live
    /// (OPDS, WebDAV) — the profile's folder; `nil` takes the old location.
    public let states: URL?
    /// A source that does not come from the kit — the mock of the preview, so the
    /// registry can work with accounts whose "server" is a mock source. `nil` means:
    /// the kit builds it.
    private let own: (@Sendable (Account) -> (any Source)?)?

    public init(
        states: URL? = nil, own: (@Sendable (Account) -> (any Source)?)? = nil,
        transport: @escaping @Sendable (Provider) -> any Transport
    ) {
        self.transport = transport
        self.states = states
        self.own = own
    }

    /// One session for all — they differ only in the headers, and those come from the
    /// kit. WebDAV gets the `WebdavSwitch` in front: covers and pages live in archives
    /// there, and the image loader fetches them through this transport.
    public static func standard(
        trusts: CertificateTrustStore = CertificateTrustStore(), states: URL? = nil
    ) -> SourceFactory {
        let session = URLSession.forSource(trusts: trusts)
        let webdavSwitch = WebdavSwitch(network: session)
        return SourceFactory(states: states) { provider -> any Transport in
            provider == .webdav ? webdavSwitch : session
        }
    }

    /// The file of an account's local reading states — in the profile folder, otherwise
    /// `nil` (then the source uses its old location).
    private func stateFile(_ identifier: SourceID) -> URL? {
        states.map { StateStore.standard(for: identifier, below: $0) }
    }

    /// The source for an account. `changed` fires when the account renews itself on the
    /// way — Grimmory's token pair moves on every refresh.
    public func source(_ account: Account, changed: @escaping @Sendable (Account) -> Void) -> any Source {
        if let own, let source = own(account) { return source }
        switch account {
        case .komga(let k):
            return KomgaSource(account: k, transport: transport(.komga))
        case .grimmory(let k):
            return GrimmorySource(
                account: k, transport: transport(.grimmory),
                magicStore: states.map {
                    $0.appending(path: "magisch-" + StateStore.filename(k.identifier))
                },
                syncStore: states.map {
                    $0.appending(path: "vollabgleich-" + StateStore.filename(k.identifier))
                },
                // The pages of an unfinished full sync (36 MB for 36,000 books) in the system cache,
                // not in the profile folder that is backed up — losing them only costs a refetch.
                pageStore: states.map { _ in
                    (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                        ?? FileManager.default.temporaryDirectory)
                        .appending(path: "grimmory-seiten-" + StateStore.filename(k.identifier))
                }
            ) { access in
                var new = k
                new.access = access
                changed(.grimmory(new))
            }
        case .audiobookshelf(let k):
            return AudiobookshelfSource(account: k, transport: transport(.audiobookshelf))
        case .kavita(let k):
            // The series markers next to the states in the profile folder — otherwise every cold
            // start would refetch all series one by one.
            return KavitaSource(
                account: k, transport: transport(.kavita),
                savedStore: states.map {
                    $0.appending(path: "kavita-marken-" + StateStore.filename(k.identifier))
                })
        case .opds(let k):
            return OpdsSource(account: k, transport: transport(.opds), persistence: stateFile(k.identifier))
        case .webdav(let k):
            return WebdavSource(
                account: k, transport: transport(.webdav), persistence: stateFile(k.identifier))
        }
    }

    /// Signs in — password in, account out. The password does not leave the function;
    /// what remains is a key or token.
    public func signIn(
        _ provider: Provider, server: URL, name: String, password: String, deviceName: String
    ) async throws -> Account {
        switch provider {
        case .komga:
            return .komga(
                try await KomgaSource.signIn(
                    server: server, email: name, password: password, deviceName: deviceName,
                    transport: transport(.komga)))
        case .grimmory:
            return .grimmory(
                try await GrimmorySource.signIn(
                    server: server, username: name, password: password, transport: transport(.grimmory)))
        case .audiobookshelf:
            return .audiobookshelf(
                try await AudiobookshelfSource.signIn(
                    server: server, username: name, password: password,
                    transport: transport(.audiobookshelf)))
        case .kavita:
            return .kavita(
                try await KavitaSource.signIn(
                    server: server, username: name, password: password, deviceName: deviceName,
                    transport: transport(.kavita)))
        case .opds:
            // The address is the catalog itself (with path); name and password may be empty.
            return .opds(
                try await OpdsSource.signIn(
                    catalog: server, username: name, password: password, transport: transport(.opds)))
        case .webdav:
            // The address is the folder itself (with path); PROPFIND depth 0 with 207 means access.
            return .webdav(
                try await WebdavSource.signIn(
                    folder: server, username: name, password: password, transport: transport(.webdav)))
        case .device:
            throw SourceError.notPossible(
                SourceID(provider: .device, server: server.host() ?? ""), "The device needs no account"
            )
        }
    }

    /// Signs out on the server where that means something: Komga and Kavita delete the
    /// key, the others have no sign-out — forgetting is enough there.
    public func signOut(_ account: Account) async throws {
        switch account {
        case .komga(let k):
            try await KomgaSource(account: k, transport: transport(.komga)).signOut()
        case .kavita(let k):
            try await KavitaSource(account: k, transport: transport(.kavita)).signOut()
        default:
            break
        }
    }
}
