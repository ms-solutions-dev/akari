import Foundation
import Testing

@testable import Bedrock

/// These tests exist because of a concrete incident: signing in with an address
/// like `jellyfin.example` failed although server and network were fine. The
/// cause was a combination of two entries in the project configuration that
/// cancel each other out. The error looked like a network problem and cost time
/// accordingly.
///
/// The last test case reads the **real** project file, so it is noticed
/// immediately if the entries are ever combined unhappily again.
@Suite("Transport security")
struct TransportSecurityRuleTests {

    @Test("The broad permission alone allows name addresses")
    func arbitraryAlone() {
        let verdict = TransportSecurityRule.evaluate(["NSAllowsArbitraryLoads": true])

        #expect(verdict == .allowsAnyPlainHTTP)
        #expect(verdict.permitsCustomDomainNames)
    }

    @Test("Together with the local-network permission it becomes ineffective")
    func arbitraryCancelledOut() {
        // Exactly this combination was the bug. It looks more generous than the broad
        // permission alone, but is narrower.
        let verdict = TransportSecurityRule.evaluate([
            "NSAllowsArbitraryLoads": true,
            "NSAllowsLocalNetworking": true,
        ])

        #expect(verdict == .allowsLocalOnly(ineffectiveArbitraryLoads: true))
        #expect(
            !verdict.permitsCustomDomainNames,
            "eine Adresse wie jellyfin.example wäre damit blockiert"
        )
    }

    @Test(
        "Jeder der feiner gefassten Schlüssel setzt die weite Erlaubnis außer Kraft",
        arguments: TransportSecurityRule.overridingKeys
    )
    func anyOverridingKeyCancels(key: String) {
        let verdict = TransportSecurityRule.evaluate([
            "NSAllowsArbitraryLoads": true,
            key: true,
        ])

        #expect(!verdict.permitsCustomDomainNames, "\(key) makes the broad permission ineffective")
    }

    @Test("The local-network permission alone does not cover name addresses either")
    func localOnly() {
        let verdict = TransportSecurityRule.evaluate(["NSAllowsLocalNetworking": true])

        #expect(verdict == .allowsLocalOnly(ineffectiveArbitraryLoads: false))
        #expect(!verdict.permitsCustomDomainNames)
    }

    @Test("Without entries only encrypted connections are allowed")
    func nothingSet() {
        #expect(TransportSecurityRule.evaluate([:]) == .requiresHTTPS)
    }
}
