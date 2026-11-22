import Foundation
import Testing

@testable import Bedrock

/// The sentence for the viewer.
///
/// **The finding:** on the television, `badRequest`, `badStatus(400)`,
/// `Network error -999` and `containerNotNativelySupported` stood in 25 pt red,
/// plus twice a roughly 700-character `NSError` dump with memory addresses,
/// under a caption promising "the cause in plain text".
@Suite("The error in the viewer's language")
struct ErrorImageTests {

    /// **The direction is the information,** not the code: their network, the server
    /// or the provider.
    @Test("Network errors are sorted by their direction")
    func directions() {
        #expect(ErrorImage.lookupKey(for: URLError(.notConnectedToInternet), status: nil) == "error.offline")
        #expect(ErrorImage.lookupKey(for: URLError(.timedOut), status: nil) == "error.slow")
        #expect(ErrorImage.lookupKey(for: URLError(.cannotFindHost), status: nil) == "error.unreachable")
        #expect(
            ErrorImage.lookupKey(for: URLError(.serverCertificateUntrusted), status: nil)
                == "error.certificate")
    }

    /// **And the developer instruction stays out.** For
    /// `appTransportSecurityRequiresSecureConnection`, ``Diagnostics/explain(_:)``
    /// prints "Check: is NSAllowsArbitraryLoads in the Info.plist …", a sentence for
    /// the developer that stood in the living room.
    @Test("The instruction to the developer does not stand in the living room")
    func noDeveloperInstruction() {
        let lookupKey = ErrorImage.lookupKey(
            for: URLError(.appTransportSecurityRequiresSecureConnection), status: nil)

        #expect(lookupKey == "error.certificate")
        // The trace still gets the whole sentence; the two readers are separated, not
        // one swapped for the other.
        #expect(
            Diagnostics.explain(URLError(.appTransportSecurityRequiresSecureConnection))
                .contains("NSAllowsArbitraryLoads"))
    }

    /// A rejection by the server is no network question; the status comes from outside.
    @Test("The server's rejection is called access")
    func denial() {
        struct Denial: Error {}
        #expect(ErrorImage.lookupKey(for: Denial(), status: 407) == "error.access")
        #expect(ErrorImage.lookupKey(for: Denial(), status: 503) == "error.serverDisruption")
        #expect(ErrorImage.lookupKey(for: Denial(), status: 404) == "error.general")
    }

    /// An unknown error gets a sentence and no dump.
    @Test("Unknown things get a sentence")
    func unknown() {
        struct Own: Error {}
        #expect(ErrorImage.lookupKey(for: Own(), status: nil) == "error.general")
    }

    /// **The 700-character dump is shortened.** Nobody reads anything longer on the
    /// television, and the whole line is in the trace anyway.
    @Test("The addition is shortened to 200 characters")
    func additionTruncated() {
        struct Lang: Error, CustomStringConvertible {
            var description: String { String(repeating: "x", count: 700) }
        }
        let extra = ErrorImage.extra(Lang())

        #expect(extra != nil)
        #expect((extra?.count ?? 0) <= ErrorImage.maxLength + 2)
    }

    /// And a short one stays whole.
    @Test("A short addition stays whole")
    func shortAddition() {
        struct Short: Error, CustomStringConvertible {
            var description: String { "Kurz und lesbar" }
        }
        #expect(ErrorImage.extra(Short()) == "Kurz und lesbar")
    }
}
