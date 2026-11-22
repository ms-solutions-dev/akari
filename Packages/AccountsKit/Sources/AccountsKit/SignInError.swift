import Bedrock
import Foundation
import SourcesKit

/// Why a sign-in did not work — in the language of the form, not of the network.
///
/// **Wrong address ≠ wrong password ≠ certificate:** That is the difference to
/// Paperback's "Syncing 0 of 0". Every case carries its sentence and says what to
/// do. For the password the rule applies: no information on whether name or
/// password was wrong.
public enum SignInError: Error, Sendable, Equatable {
    /// The text is not a server address — no host name in it.
    case address
    /// Nothing answers at the address: typo, wrong network, server off.
    case unreachable
    /// The server presents a certificate the device does not know — the question with
    /// the fingerprint. Trust it, then sign in again.
    case certificate(CertificateQuestion.Unresolved)
    /// Name or password are wrong — or the account is not allowed.
    case access
    /// Something answers at the address, but not the expected server: Komga entered,
    /// Grimmory hit — or a version the kit cannot read.
    case foreignServer
    /// Server there, account right, and still 5xx.
    case serverDisruption(Int)
    /// Signed in, but the keychain did not accept the account.
    case persistence

    /// The localization key for the sentence under the form.
    public var messageKey: String {
        switch self {
        case .address: "account.error.address"
        case .unreachable: "account.error.unreachable"
        case .certificate: "account.error.certificate"
        case .access: "account.error.access"
        case .foreignServer: "account.error.foreignServer"
        case .serverDisruption: "account.error.serverDisruption"
        case .persistence: "account.error.store"
        }
    }

    /// Interprets what a kit threw while signing in.
    ///
    /// **The certificate does not arrive as an error** — the guard aborts the
    /// connection, and what the kit sees is "unreachable". Meanwhile the question sits
    /// in the mailbox (`CertificateQuestion`); whoever finds one there for this host has
    /// the true reason.
    public static func from(
        _ failure: Error, host: String, questions: CertificateQuestion = .shared
    ) -> SignInError {
        if let own = failure as? SignInError { return own }
        if let unresolved = questions.present, unresolved.host.caseInsensitiveCompare(host) == .orderedSame {
            return .certificate(unresolved)
        }
        guard let q = failure as? SourceError else { return .unreachable }
        switch q {
        case .unreachable: return .unreachable
        case .signedOut, .denied: return .access
        case .unreadable, .notFound, .notPossible: return .foreignServer
        case .serverDisruption(_, let status): return .serverDisruption(status)
        }
    }
}
