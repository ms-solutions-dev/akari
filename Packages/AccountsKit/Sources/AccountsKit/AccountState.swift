import Bedrock
import Foundation
import SourcesKit

/// What the row in the accounts sheet says — a green or red dot and a word.
///
/// Four states the user has to tell apart: set up or not, and if so: working,
/// expired, unreachable. "Disrupted" is the fifth, for a server that answers but is
/// not itself (5xx) or not in the expected shape — the address is right, the account
/// too, and still nothing works. "Certificate" is the sixth: the server presents a
/// different certificate than the confirmed one and the guard cut the connection —
/// to the kit that looks like "unreachable", and that is exactly what it must not
/// say: the user has to see the new fingerprint and decide.
public enum AccountState: Sendable, Hashable {
    case notConfigured
    /// Account present, server not asked yet — at launch, before the check is done.
    case unchecked
    case signedIn
    /// Key revoked, token no longer valid, account locked: the red dot on the account
    /// button. The way back is signing in.
    case expired
    case unreachable
    case disrupted
    /// The server presents an unknown or changed certificate — the question sits in the
    /// mailbox, and until it is answered nothing gets through.
    case certificate

    /// The localization key for the word next to the dot.
    public var messageKey: String {
        switch self {
        case .notConfigured: "account.status.notConfigured"
        case .unchecked: "account.status.unchecked"
        case .signedIn: "account.status.signedIn"
        case .expired: "account.status.expired"
        case .unreachable: "account.status.unreachable"
        case .disrupted: "account.status.disrupted"
        case .certificate: "account.status.certificate"
        }
    }

    /// The red dot: only when the user has to do something. A server that is simply not
    /// answering is no task for them — the banner in the section is enough. An expired
    /// account and a changed certificate are one.
    public var needsAttention: Bool { self == .expired || self == .certificate }

    /// The banner in the section: everything that is set up and not working.
    public var disrupted: Bool {
        switch self {
        case .expired, .unreachable, .disrupted, .certificate: true
        case .notConfigured, .unchecked, .signedIn: false
        }
    }

    /// Interprets what `Source.verify()` threw.
    ///
    /// **401 is not 502:** A revoked key is ``expired`` and a task for the user; a server
    /// that answers but is not itself is ``disrupted`` and takes the same path as "off" —
    /// no new sign-in, no red dot. The status number is read once for all kits by the
    /// shared `SourceError` mapping.
    public static func from(_ failure: Error) -> AccountState {
        guard let q = failure as? SourceError else { return .unreachable }
        switch q {
        case .unreachable: return .unreachable
        case .signedOut, .denied: return .expired
        case .serverDisruption, .unreadable, .notFound, .notPossible: return .disrupted
        }
    }

    /// Like ``from(_:)`` — and if a certificate question for this host sits in the
    /// mailbox, "unreachable" is really ``certificate``: the guard aborted, not the
    /// network.
    public static func from(_ failure: Error, host: String, questions: CertificateQuestion) -> AccountState {
        let phase = from(failure)
        guard phase == .unreachable, let unresolved = questions.present,
            unresolved.host.caseInsensitiveCompare(host) == .orderedSame
        else { return phase }
        return .certificate
    }
}
