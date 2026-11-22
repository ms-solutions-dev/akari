import Foundation
import Testing

@testable import Bedrock

/// Trust on first use: the same procedure as with SSH.
///
/// The difference from "accept all certificates" is the whole point: whoever is
/// on the same network could otherwise slip in unnoticed. These cases therefore
/// mainly check that a **changed** certificate does not pass silently.
@Suite("Certificate trust")
struct CertificateTrustTests {

    static func store() -> CertificateTrustStore {
        // Volatile store: access to the real keychain makes the test run hang on the
        // computer, because it expects an authorization there.
        CertificateTrustStore(store: InMemoryStore())
    }

    static func fingerprint(_ seed: String) -> CertificateFingerprint {
        CertificateFingerprint(certificateData: Data(seed.utf8))
    }

    @Test("An unknown certificate is not accepted but asked about")
    func unknownAsksUser() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("zertifikat-a")

        #expect(trust.evaluate(fp, for: "neu.example") == .askUser(fp))
    }

    @Test("After confirmation the same certificate is accepted")
    func confirmedIsAccepted() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("zertifikat-b")

        try trust.trust(fp, for: "bekannt.example")

        #expect(trust.evaluate(fp, for: "bekannt.example") == .accept)
    }

    @Test("A changed certificate is reported, not accepted")
    func changedIsReported() throws {
        // The serious case: either it was renewed, or someone is intercepting. Both
        // must be noticed.
        let trust = Self.store()
        let original = Self.fingerprint("zertifikat-c")
        let impostor = Self.fingerprint("zertifikat-fremd")

        try trust.trust(original, for: "wechsel.example")
        let verdict = trust.evaluate(impostor, for: "wechsel.example")

        #expect(verdict == .changed(known: original, presented: impostor))
        #expect(verdict != .accept, "must never pass silently")
    }

    @Test("Trust applies per server, not across the board")
    func trustIsPerHost() throws {
        // Otherwise a one-time confirmation would cover every further server: exactly
        // the barn door that is to be avoided.
        let trust = Self.store()
        let fp = Self.fingerprint("zertifikat-d")

        try trust.trust(fp, for: "einer.example")

        #expect(trust.evaluate(fp, for: "anderer.example") == .askUser(fp))
    }

    @Test("The case of the server name does not matter")
    func hostIsCaseInsensitive() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("zertifikat-e")

        try trust.trust(fp, for: "Jellyfin.Example")

        #expect(trust.evaluate(fp, for: "jellyfin.example") == .accept)
    }

    @Test("Forgetting withdraws the trust again")
    func forgetting() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("zertifikat-f")

        try trust.trust(fp, for: "temp.example")
        #expect(trust.evaluate(fp, for: "temp.example") == .accept)

        try trust.forget("temp.example")
        #expect(trust.evaluate(fp, for: "temp.example") == .askUser(fp))
    }

    // MARK: - Presentation

    @Test("The fingerprint is made readable in groups of four")
    func readableGrouping() {
        // On the television it must be possible to compare it with what is on the
        // computer; as a single block that is hopeless.
        let fp = CertificateFingerprint(value: "ABCDEF0123456789")

        #expect(fp.readable == "ABCD EF01 2345 6789")
        #expect(fp.short == "ABCD EF01 2345 6789 …")
    }

    @Test("The same data yields the same fingerprint, other data a different one")
    func deterministic() {
        #expect(Self.fingerprint("gleich") == Self.fingerprint("gleich"))
        #expect(Self.fingerprint("gleich") != Self.fingerprint("anders"))
    }

    @Test("The fingerprint has the length of a SHA-256 checksum")
    func length() {
        // 32 bytes, so 64 characters in hexadecimal.
        #expect(Self.fingerprint("beliebig").value.count == 64)
    }

    @Test("Case is normalized")
    func normalizesCase() {
        #expect(CertificateFingerprint(value: "abcdef").value == "ABCDEF")
    }
}
