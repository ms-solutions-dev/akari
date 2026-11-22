import Bedrock
import Foundation
import SourcesKit
import Testing

@testable import AccountsKit

@Suite("Sign-in errors and account state")
struct SignInErrorTests {
    let source = SourceID(provider: .komga, server: "comics.example")

    @Test("Wrong address, wrong password, foreign server, disruption — four sentences")
    func interpretation() {
        let f = CertificateQuestion()
        #expect(
            SignInError.from(SourceError.unreachable(source), host: "comics.example", questions: f)
                == .unreachable)
        #expect(
            SignInError.from(SourceError.signedOut(source), host: "comics.example", questions: f) == .access)
        #expect(
            SignInError.from(SourceError.denied(source), host: "comics.example", questions: f) == .access)
        #expect(
            SignInError.from(SourceError.unreadable(source, "HTML"), host: "comics.example", questions: f)
                == .foreignServer)
        #expect(
            SignInError.from(
                SourceError.serverDisruption(source, status: 502), host: "comics.example", questions: f)
                == .serverDisruption(502))
        #expect(
            SignInError.from(URLError(.cancelled), host: "comics.example", questions: f) == .unreachable)
        #expect(SignInError.address.messageKey == "account.error.address")
    }

    @Test("If a certificate question exists for the host, it is the reason — not “unreachable”")
    func certificate() {
        let question = CertificateQuestion.Unresolved(
            host: "comics.example",
            fingerprint: CertificateFingerprint(value: String(repeating: "AB", count: 32)))
        let f = CertificateQuestion()
        f.spot(question)
        #expect(
            SignInError.from(SourceError.unreachable(source), host: "Comics.example", questions: f)
                == .certificate(question))
        // The question of another host does not count.
        #expect(
            SignInError.from(SourceError.unreachable(source), host: "buecher.example", questions: f)
                == .unreachable)
    }

    @Test("Account state: only “expired” is the red dot, everything broken is a banner")
    func phase() {
        #expect(AccountState.from(SourceError.signedOut(source)) == .expired)
        #expect(AccountState.from(SourceError.unreachable(source)) == .unreachable)
        #expect(AccountState.from(SourceError.serverDisruption(source, status: 503)) == .disrupted)
        #expect(AccountState.from(URLError(.timedOut)) == .unreachable)
        #expect(AccountState.expired.needsAttention)
        #expect(!AccountState.unreachable.needsAttention)
        #expect(AccountState.unreachable.disrupted)
        #expect(!AccountState.signedIn.disrupted)
        #expect(!AccountState.notConfigured.disrupted)
        #expect(!AccountState.unchecked.disrupted)
    }
}
