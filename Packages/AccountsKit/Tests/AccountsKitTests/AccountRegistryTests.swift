import AudiobookshelfKit
import Bedrock
import Foundation
import GrimmoryKit
import KomgaKit
import SourcesKit
import SourcesKitMocks
import Testing

@testable import AccountsKit

/// The registry against the recorded responses of the three servers — keychain and
/// trust in memory.
@Suite("Kontenregister")
@MainActor
struct AccountRegistryTests {

    /// The transports per provider, swappable: The mock transport keeps its last answer
    /// ("the last one stays"), and whoever wants a different one after signing in takes a
    /// fresh one — before the source's first request.
    final class Box: @unchecked Sendable {
        var transports: [Provider: MockTransport] = [
            .komga: MockTransport(), .grimmory: MockTransport(),
            .audiobookshelf: MockTransport(), .kavita: MockTransport(), .opds: MockTransport(),
            .webdav: MockTransport(),
        ]
    }

    @MainActor
    struct Setup {
        let store = InMemoryStore()
        let box = Box()
        let questions = CertificateQuestion()
        var transports: [Provider: MockTransport] { box.transports }
        var register: AccountRegistry {
            AccountRegistry(
                persistence: AccountStore(store: store), trusts: CertificateTrustStore(store: store),
                factory: SourceFactory { [box] in box.transports[$0]! }, questions: questions,
                deviceName: "Prüfstand")
        }
        @discardableResult
        func fresh(_ provider: Provider) -> MockTransport {
            let t = MockTransport()
            box.transports[provider] = t
            return t
        }
        func komgaSignIn() throws {
            try transports[.komga]!.answer("GET", "/api/v2/users/me", file: "komga-me.json", from: .module)
            try transports[.komga]!.answer(
                "POST", "/api/v2/users/me/api-keys", file: "komga-api-key-anlegen.json", from: .module)
        }
    }

    @Test("Empty: four rows (the servers; catalogs only once one is created), no attention")
    func empty() {
        let r = Setup().register
        #expect(r.states.map(\.provider) == [.komga, .grimmory, .audiobookshelf, .kavita])
        #expect(r.catalogs.isEmpty)
        #expect(r.newSlot(.opds) == AccountSlot(.opds, number: 0))
        #expect(r.states.allSatisfy { $0.phase == .notConfigured })
        #expect(!r.configured)
        #expect(!r.needsAttention)
        #expect(r.allSources.isEmpty)
    }

    @Test("Signing in to all four: account in the keychain, row signed in, source present")
    func signIn() async throws {
        let a = Setup()
        try a.komgaSignIn()
        try a.transports[.grimmory]!.answer(
            "POST", "/api/v1/auth/login", file: "grimmory-login.json", from: .module)
        try a.transports[.grimmory]!.answer(
            "GET", "/api/v1/users/me", file: "grimmory-me.json", from: .module)
        try a.transports[.audiobookshelf]!.answer("POST", "/login", file: "abs-login.json", from: .module)
        try a.transports[.kavita]!.answer(
            "POST", "/api/Account/login", file: "kavita-login.json", from: .module)
        let r = a.register
        try await r.signIn(.komga, address: "comics.example", name: "leser@example.test", password: "pw")
        try await r.signIn(.grimmory, address: "https://buecher.example/", name: "leser", password: "pw")
        try await r.signIn(.audiobookshelf, address: "hoerbuch.example", name: "leser", password: "pw")
        try await r.signIn(.kavita, address: "lesen.example", name: "leser", password: "pw")
        #expect(r.configured)
        #expect(r.states.allSatisfy { $0.phase == .signedIn })
        #expect(r.state(.komga).account?.username == "leser@example.test")
        #expect(r.state(.komga).entry?.device == "Prüfstand")
        #expect(r.state(.grimmory).account?.server.absoluteString == "https://buecher.example")
        #expect(r.state(.audiobookshelf).account?.mayKeep == true)
        #expect(r.state(.kavita).account?.username == "leser")
        #expect(r.allSources.count == 4)
        // A second registry from the same keychain knows the four — as unchecked.
        let r2 = a.register
        #expect(r2.states.allSatisfy { $0.phase == .unchecked })
        #expect(r2.state(.komga).account == r.state(.komga).account)
    }

    @Test("Several OPDS catalogs: two slots, one is removed, the other survives a restart")
    func catalogs() async throws {
        let a = Setup()
        let feed = """
            <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Katalog</title></feed>
            """
        a.transports[.opds]!.answer("GET", "/opds/v1.2/catalog", with: .init(data: Data(feed.utf8)))
        a.transports[.opds]!.answer("GET", "/api/v1/opds", with: .init(data: Data(feed.utf8)))
        let r = a.register
        try await r.signIn(.opds, address: "comics.example/opds/v1.2/catalog", name: "a", password: "pw")
        try await r.signIn(.opds, address: "buecher.example/api/v1/opds", name: "", password: "")
        #expect(r.catalogs.map(\.slot.number) == [0, 1])
        #expect(r.states.count == 6, "four servers, two catalogs")
        #expect(r.allSources.count == 2)
        #expect(r.catalogs[1].account?.server.host() == "buecher.example")
        #expect(r.newSlot(.opds) == AccountSlot(.opds, number: 2))
        await r.signOut(AccountSlot(.opds, number: 0))
        #expect(r.catalogs.map(\.slot.number) == [1])
        let r2 = a.register
        #expect(r2.catalogs.map(\.slot.number) == [1], "the list in the keychain only knows slot 1")
        #expect(r2.catalogs[0].account?.server.host() == "buecher.example")
        #expect(r2.newSlot(.opds) == AccountSlot(.opds, number: 2))
    }

    @Test(
        "WebDAV folders: PROPFIND depth 0 signs in, umlaut in the path, two folders are two rows, title is the folder name"
    )
    func folder() async throws {
        let a = Setup()
        let response = """
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response>
            <d:href>/remote.php/dav/files/leser/B%c3%bccher/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            </d:response></d:multistatus>
            """
        a.transports[.webdav]!.answer(
            "PROPFIND", "/remote.php/dav/files/leser/*", with: .init(status: 207, data: Data(response.utf8))
        )
        let r = a.register
        try await r.signIn(
            .webdav, address: "nextcloud.example/remote.php/dav/files/leser/Bücher", name: "leser",
            password: "app")
        try await r.signIn(
            .webdav, address: "https://nextcloud.example/remote.php/dav/files/leser/Manga/", name: "leser",
            password: "app")
        #expect(r.folder.map(\.slot.number) == [0, 1])
        #expect(r.folder[0].account?.displayName == "Bücher" && r.folder[1].account?.displayName == "Manga")
        #expect(
            r.folder[0].account?.server.absoluteString
                == "https://nextcloud.example/remote.php/dav/files/leser/B%C3%BCcher/")
        #expect(r.folder[0].account?.identifier.server == "nextcloud.example · Bücher")
        #expect(r.states.count == 6 && r.allSources.count == 2)
        #expect(a.transports[.webdav]!.requests.first?.value(forHTTPHeaderField: "Depth") == "0")
        let r2 = a.register
        #expect(r2.folder.count == 2, "both folders from the keychain")
        await r2.signOut(AccountSlot(.webdav, number: 0))
        #expect(
            r2.folder.map(\.slot.number) == [1] && r2.newSlot(.webdav) == AccountSlot(.webdav, number: 2))
    }

    @Test("Four refusals, four sentences")
    func refusals() async throws {
        let a = Setup()
        let r = a.register
        await #expect(throws: SignInError.address) {
            try await r.signIn(.komga, address: " ", name: "x", password: "y")
        }
        a.fresh(.komga).fail("GET", "/api/v2/users/me", with: .cannotFindHost)
        await #expect(throws: SignInError.unreachable) {
            try await r.signIn(.komga, address: "comics2.example", name: "x", password: "y")
        }
        try a.fresh(.komga).answer("GET", "/api/v2/users/me", file: "komga-401.json", from: .module)
        await #expect(throws: SignInError.access) {
            try await r.signIn(.komga, address: "comics.example", name: "x", password: "y")
        }
        try a.transports[.grimmory]!.answer(
            "POST", "/api/v1/auth/login", file: "grimmory-401-login.json", from: .module)
        await #expect(throws: SignInError.access) {
            try await r.signIn(.grimmory, address: "buecher.example", name: "x", password: "y")
        }
        a.transports[.audiobookshelf]!.answer(
            "POST", "/login", with: .init(status: 200, data: Data("<html>Grimmory</html>".utf8)))
        await #expect(throws: SignInError.foreignServer) {
            try await r.signIn(.audiobookshelf, address: "buecher.example", name: "x", password: "y")
        }
        a.fresh(.audiobookshelf).answer("POST", "/login", with: .init(status: 503))
        await #expect(throws: SignInError.serverDisruption(503)) {
            try await r.signIn(.audiobookshelf, address: "hoerbuch.example", name: "x", password: "y")
        }
        #expect(!r.configured)
    }

    /// Does what the certificate guard does: put the question into the mailbox, abort the connection.
    struct CertificateGuardTransport: Transport {
        let question: CertificateQuestion.Unresolved
        let questions: CertificateQuestion
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            questions.spot(question)
            throw URLError(.cancelled)
        }
    }

    @Test("Certificate: the question arrives as an error, trusting stores the fingerprint")
    func certificate() async throws {
        let store = InMemoryStore()
        let snapshot = CertificateFingerprint(value: String(repeating: "CD", count: 32))
        let question = CertificateQuestion.Unresolved(host: "comics.example", fingerprint: snapshot)
        let questions = CertificateQuestion()
        let r = AccountRegistry(
            persistence: AccountStore(store: store), trusts: CertificateTrustStore(store: store),
            factory: SourceFactory { _ in CertificateGuardTransport(question: question, questions: questions)
            },
            questions: questions,
            deviceName: "Prüfstand")
        await #expect(throws: SignInError.certificate(question)) {
            try await r.signIn(.komga, address: "comics.example", name: "x", password: "y")
        }
        #expect(questions.present == question)
        try r.trust(question)
        #expect(CertificateTrustStore(store: store).fingerprint(for: "comics.example") == snapshot)
        #expect(questions.present == nil)
        // Declining clears the question without storing anything.
        questions.spot(question)
        r.decline(question)
        #expect(questions.present == nil)
    }

    @Test("Verifying: signed in, expired, unreachable — per row, and the red dot")
    func verify() async throws {
        let a = Setup()
        try a.komgaSignIn()
        try a.transports[.grimmory]!.answer(
            "POST", "/api/v1/auth/login", file: "grimmory-login.json", from: .module)
        try a.transports[.grimmory]!.answer(
            "GET", "/api/v1/users/me", file: "grimmory-me.json", from: .module)
        try a.transports[.audiobookshelf]!.answer("POST", "/login", file: "abs-login.json", from: .module)
        let r = a.register
        try await r.signIn(.komga, address: "comics.example", name: "leser@example.test", password: "pw")
        try await r.signIn(.grimmory, address: "buecher.example", name: "leser", password: "pw")
        try await r.signIn(.audiobookshelf, address: "hoerbuch.example", name: "leser", password: "pw")

        try a.fresh(.komga).answer("GET", "/api/v2/users/me", file: "komga-401.json", from: .module)
        try a.fresh(.grimmory).answer("GET", "/api/v1/users/me", file: "grimmory-me.json", from: .module)
        a.fresh(.audiobookshelf).fail("GET", "/api/me", with: .timedOut)
        await r.verify()
        #expect(r.state(.komga).phase == .expired)
        #expect(r.state(.grimmory).phase == .signedIn)
        #expect(r.state(.audiobookshelf).phase == .unreachable)
        #expect(r.needsAttention)
        #expect(r.disruptions.map(\.provider) == [.komga, .audiobookshelf])
    }

    @Test("Signing out: Komga deletes the key on the server, the row becomes empty")
    func signOut() async throws {
        let a = Setup()
        try a.komgaSignIn()
        try a.transports[.komga]!.answer(
            "DELETE", "/api/v2/users/me/api-keys/*", file: "komga-api-key-loeschen.json", from: .module)
        let r = a.register
        try await r.signIn(.komga, address: "comics.example", name: "leser@example.test", password: "pw")
        await r.signOut(.komga)
        #expect(a.transports[.komga]!.paths.last?.hasPrefix("DELETE /api/v2/users/me/api-keys/") == true)
        #expect(r.state(.komga).phase == .notConfigured)
        #expect(r.state(.komga).account == nil)
        #expect(AccountStore(store: a.store).entry(.komga) == nil)
        #expect(!r.configured)
    }

    @Test("Setup code: fingerprint for every host, addresses as suggestions — except for signed-in accounts")
    func code() async throws {
        let a = Setup()
        try a.komgaSignIn()
        let r = a.register
        try await r.signIn(.komga, address: "comics.example", name: "leser@example.test", password: "pw")
        let snapshot = CertificateFingerprint(value: String(repeating: "4911402F", count: 8))
        r.adopt(
            SetupCode(
                server: [
                    .komga: URL(string: "https://comics.example")!,
                    .grimmory: URL(string: "https://buecher.example")!,
                    .audiobookshelf: URL(string: "https://hoerbuch.example")!,
                ], fingerprint: snapshot))
        let trusts = CertificateTrustStore(store: a.store)
        #expect(trusts.fingerprint(for: "comics.example") == snapshot)
        #expect(trusts.fingerprint(for: "buecher.example") == snapshot)
        #expect(trusts.fingerprint(for: "hoerbuch.example") == snapshot)
        #expect(
            r.suggested.mapValues(\.address) == [
                .grimmory: URL(string: "https://buecher.example")!,
                .audiobookshelf: URL(string: "https://hoerbuch.example")!,
            ])
        #expect(r.collectible.isEmpty)
    }

    @Test("Bulk sign-in: one password, three names — two go through, one stays open with its sentence")
    func bulkSignIn() async throws {
        let a = Setup()
        try a.komgaSignIn()
        try a.transports[.grimmory]!.answer(
            "POST", "/api/v1/auth/login", file: "grimmory-401-login.json", from: .module)
        try a.transports[.audiobookshelf]!.answer("POST", "/login", file: "abs-login.json", from: .module)
        let r = a.register
        r.adopt(
            SetupCode(
                server: [
                    .komga: URL(string: "https://comics.example")!,
                    .grimmory: URL(string: "https://buecher.example")!,
                    .audiobookshelf: URL(string: "https://hoerbuch.example")!,
                ],
                names: [.komga: "robin@example.test", .grimmory: "robin", .audiobookshelf: "robin"]))
        #expect(r.collectible == [.komga, .grimmory, .audiobookshelf])
        let succeeded = await r.signInAll(password: "pw")
        #expect(Set(succeeded) == [.komga, .audiobookshelf])
        #expect(r.state(.komga).phase == .signedIn)
        #expect(r.state(.audiobookshelf).phase == .signedIn)
        #expect(r.state(.grimmory).account == nil)
        #expect(r.lastError == [.grimmory: .access])
        #expect(r.collectible == [.grimmory])
        // The suggestion stays for the single sheet, the signed-in ones are rid of it.
        #expect(Array(r.suggested.keys) == [.grimmory])
        // The request carried the name from the code.
        let signInRequest = a.transports[.audiobookshelf]!.requests.first { $0.url?.path() == "/login" }
        let body = signInRequest?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(body.contains("\"robin\""))
    }

    @Test("Grimmory: a refreshed token pair lands in the keychain")
    func refresh() async throws {
        let a = Setup()
        let t = a.transports[.grimmory]!
        try t.answer("POST", "/api/v1/auth/login", file: "grimmory-login.json", from: .module)
        try t.answer("GET", "/api/v1/users/me", file: "grimmory-me.json", from: .module)
        let r = a.register
        try await r.signIn(.grimmory, address: "buecher.example", name: "leser", password: "pw")
        // An expired access forces the source to refresh.
        var entry = try #require(r.state(.grimmory).entry)
        guard case .grimmory(var account) = entry.account else { Issue.record("Grimmory expected"); return }
        account.access = GrimmoryAccess(token: "alt", refreshToken: "auffrischen", flow: .distantPast)
        entry.account = .grimmory(account)
        try AccountStore(store: a.store).persist(entry, on: .server(.grimmory))
        let r2 = a.register
        t.answer(
            "POST", "/api/v1/auth/refresh",
            with: .init(
                status: 200,
                data: Data(#"{"accessToken":"neu","refreshToken":"neu2","expires":7200}"#.utf8)))
        try t.answer("GET", "/api/v1/users/me", file: "grimmory-me.json", from: .module)
        await r2.verify(.grimmory)
        #expect(r2.state(.grimmory).phase == .signedIn)
        // The callback hops onto the main actor — wait one round.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        guard case .grimmory(let stored)? = AccountStore(store: a.store).entry(.grimmory)?.account else {
            Issue.record("Grimmory expected")
            return
        }
        #expect(stored.access.token == "neu")
        #expect(stored.access.refreshToken == "neu2")
    }
}
