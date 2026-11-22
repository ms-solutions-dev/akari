import Bedrock
import Foundation
import KomgaKit
import SourcesKit
import SourcesKitMocks
import Testing

@testable import AccountsKit

/// The disruption pass: 401 is not 502, a changed certificate is not "unreachable",
/// and the registry carries the question to the shell.
@Suite("Account disruptions")
@MainActor
struct AccountDisruptionTests {

    /// A registry with a Komga account whose "server" is the mock — through its own
    /// factory, as in the preview.
    private func build() throws -> (AccountRegistry, MockSource, CertificateQuestion) {
        let store = InMemoryStore()
        let source = MockShelf.komga()
        let persistence = AccountStore(store: store)
        let account = Account.komga(
            KomgaAccount(
                server: URL(string: "https://comics.example")!, userId: "1", email: "m@home",
                apiKey: "k",
                keyId: "k1", roles: ["USER"]))
        try persistence.persist(AccountEntry(account: account, device: "Prüfstand"), on: .server(.komga))
        let questions = CertificateQuestion()
        let register = AccountRegistry(
            persistence: persistence, trusts: CertificateTrustStore(store: store),
            factory: SourceFactory(own: { $0.identifier == source.identifier ? source : nil }) { _ in
                MockTransport()
            }, questions: questions, deviceName: "Prüfstand")
        return (register, source, questions)
    }

    @Test("401 means expired with a red dot; 502 means disrupted without — and both are disruptions")
    func fourOhOneVersusFiveOhTwo() async throws {
        let (r, source, _) = try build()
        source.set(disruption: .signedOut(source.identifier))
        await r.verify()
        #expect(r.state(.komga).phase == .expired)
        #expect(r.needsAttention)
        #expect(r.disruptions.count == 1)

        source.set(disruption: .serverDisruption(source.identifier, status: 502))
        await r.verify()
        #expect(r.state(.komga).phase == .disrupted)
        #expect(!r.needsAttention)
        #expect(r.disruptions.count == 1)

        source.set(disruption: nil)
        source.set(network: .unreachable)
        await r.verify()
        #expect(r.state(.komga).phase == .unreachable)
        #expect(!r.needsAttention)
        #expect(r.certificateQuestion == nil)
    }

    @Test("If a certificate question sits in the mailbox for the host, “unreachable” is a certificate")
    func certificate() async throws {
        let (r, source, questions) = try build()
        let question = CertificateQuestion.Unresolved(
            host: "comics.example", fingerprint: CertificateFingerprint(certificateData: Data("neu".utf8)),
            known: CertificateFingerprint(certificateData: Data("alt".utf8)))
        questions.spot(question)
        source.set(network: .unreachable)
        await r.verify()
        #expect(r.state(.komga).phase == .certificate)
        #expect(r.needsAttention)
        #expect(r.certificateQuestion == question)
        #expect(r.slots(for: "COMICS.example") == [.server(.komga)])

        // Trusting stores the fingerprint and clears the question; the next check goes through.
        try r.trust(question)
        #expect(r.certificateQuestion == nil)
        #expect(questions.present == nil)
        source.set(network: .reachable)
        await r.verify(.komga)
        #expect(r.state(.komga).phase == .signedIn)
    }

    @Test("A question for another host changes nothing; declining clears it too")
    func otherHost() async throws {
        let (r, source, questions) = try build()
        let fremd = CertificateQuestion.Unresolved(
            host: "buecher.example", fingerprint: CertificateFingerprint(certificateData: Data("x".utf8)))
        questions.spot(fremd)
        source.set(network: .unreachable)
        await r.verify()
        #expect(r.state(.komga).phase == .unreachable)
        #expect(r.certificateQuestion == nil)

        let own = CertificateQuestion.Unresolved(
            host: "comics.example", fingerprint: CertificateFingerprint(certificateData: Data("y".utf8)))
        questions.spot(own)
        await r.verify()
        #expect(r.certificateQuestion == own)
        r.decline(own)
        #expect(r.certificateQuestion == nil)
        #expect(r.state(.komga).phase == .certificate, "the row stays until a check goes through")
    }

    @Test("AccountState.from interprets the source errors — and the mailbox only for unreachable")
    func interpretation() {
        let k = SourceID(provider: .komga, server: "comics.example")
        let questions = CertificateQuestion()
        questions.spot(
            CertificateQuestion.Unresolved(
                host: "comics.example", fingerprint: CertificateFingerprint(certificateData: Data("z".utf8))
            ))
        #expect(
            AccountState.from(SourceError.signedOut(k), host: "comics.example", questions: questions)
                == .expired)
        #expect(
            AccountState.from(
                SourceError.serverDisruption(k, status: 503), host: "comics.example", questions: questions)
                == .disrupted)
        #expect(
            AccountState.from(SourceError.unreachable(k), host: "comics.example", questions: questions)
                == .certificate)
        #expect(
            AccountState.from(URLError(.timedOut), host: "comics.example", questions: questions)
                == .certificate)
        #expect(AccountState.certificate.disrupted)
        #expect(AccountState.certificate.messageKey == "account.status.certificate")
    }
}
