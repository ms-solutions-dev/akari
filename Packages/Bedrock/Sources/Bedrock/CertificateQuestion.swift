import Foundation

/// The certificate question nobody asked.
///
/// **The finding:** `cert.title`, `cert.explain`, `cert.trust` and `cert.reject`
/// are translated in the strings file and are **used in no Swift file**. The
/// viewer reads "This server uses a self-issued certificate" and gets no button.
/// On a home server that is the normal case.
///
/// The path there was built and led nowhere:
/// ``CertificateTrustStore/evaluate(_:for:)`` answers `.askUser`, the connection
/// delegate aborts and writes "confirmation needed" to the log, and the UI learns
/// nothing about it, because the error that reaches it is only a `URLError`. The
/// fingerprint is lost on the way.
///
/// **Hence this mailbox.** The delegate puts the question in, the UI takes it out
/// and asks it. A detour through the error would be wrong: `URLError` has no field
/// for it, and passing a custom error type through three packages would mean
/// touching every call site.
public final class CertificateQuestion: @unchecked Sendable {

    public static let shared = CertificateQuestion()

    /// What needs confirming.
    ///
    /// **`Identifiable` over host name and fingerprint.** A sheet bound to a value
    /// needs an identifier, and the two together are one: the same host with a
    /// different fingerprint is a **different** question, namely the one the whole
    /// procedure was built for. Using only the host name would leave the sheet in
    /// place on a change and show the old fingerprint for a new question.
    public struct Unresolved: Sendable, Equatable, Identifiable {

        public var id: String { host + ":" + fingerprint.value }

        public let host: String
        public let fingerprint: CertificateFingerprint
        /// The known fingerprint, if one has **changed**.
        ///
        /// **The difference is half the information:** an unknown certificate is the
        /// normal case on a home network; a **changed** one is the warning the whole
        /// procedure was built for.
        public let known: CertificateFingerprint?

        public init(
            host: String, fingerprint: CertificateFingerprint,
            known: CertificateFingerprint? = nil
        ) {
            self.host = host
            self.fingerprint = fingerprint
            self.known = known
        }
    }

    private let lockZone = NSLock()
    private var unresolved: Unresolved?

    /// Public so that tests can use their own mailbox: tests run side by side, and a
    /// shared `shared` turns two tests into one that empties itself. In production it
    /// stays ``shared``: the guard puts the question in there, the sheet takes it out.
    public init() {}

    /// Puts a question in; the most recent one wins.
    public func spot(_ question: Unresolved) {
        lockZone.lock()
        defer { lockZone.unlock() }
        unresolved = question
    }

    /// Takes out the open question **without** consuming it.
    public var present: Unresolved? {
        lockZone.lock()
        defer { lockZone.unlock() }
        return unresolved
    }

    /// Answered; empties the mailbox.
    ///
    /// **Only the question that was meant.** A second one can arrive between asking
    /// and answering (two servers, two requests); emptying blindly would confirm the
    /// wrong certificate.
    public func respond(_ question: Unresolved) {
        lockZone.lock()
        defer { lockZone.unlock() }
        if unresolved == question { unresolved = nil }
    }

    /// Forgets everything, when the screen is left.
    public func clearOut() {
        lockZone.lock()
        defer { lockZone.unlock() }
        unresolved = nil
    }
}
