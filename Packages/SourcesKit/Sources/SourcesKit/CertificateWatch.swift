import Bedrock
import Foundation
import Security

/// Decides at connection setup whether a certificate is trusted.
///
/// The three servers speak `https://*.example` with mkcert certificates — a root the phone
/// does not know. Only steps in when the usual evaluation fails; then the fingerprint the
/// user confirmed once counts (`CertificateTrustStore`). Unknown or changed means: abort
/// the connection and ask the question (`CertificateQuestion`), never accept silently.
public final class CertificateWatch: NSObject, URLSessionDelegate, Sendable {

    private let trusts: CertificateTrustStore

    public init(trusts: CertificateTrustStore = CertificateTrustStore()) {
        self.trusts = trusts
    }

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }

        let host = challenge.protectionSpace.host
        var failure: CFError?
        if SecTrustEvaluateWithError(serverTrust, &failure) { return (.performDefaultHandling, nil) }

        guard let fingerprint = Self.fingerprint(from: serverTrust) else {
            Diagnostics.network.error("Certificate of \(host, privacy: .public) not readable — rejected")
            return (.cancelAuthenticationChallenge, nil)
        }

        switch trusts.evaluate(fingerprint, for: host) {
        case .accept:
            return (.useCredential, URLCredential(trust: serverTrust))
        case .askUser:
            Diagnostics.network.error(
                "Certificate of \(host, privacy: .public) unknown (\(fingerprint.short, privacy: .public)) — confirmation needed"
            )
            CertificateQuestion.shared.spot(
                CertificateQuestion.Unresolved(host: host, fingerprint: fingerprint))
            return (.cancelAuthenticationChallenge, nil)
        case .changed(let known, _):
            Diagnostics.network.error(
                "Certificate of \(host, privacy: .public) has changed: known \(known.short, privacy: .public), presented \(fingerprint.short, privacy: .public) — rejected"
            )
            CertificateQuestion.shared.spot(
                CertificateQuestion.Unresolved(host: host, fingerprint: fingerprint, known: known))
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The fingerprint of the presented leaf certificate.
    public static func fingerprint(from trust: SecTrust) -> CertificateFingerprint? {
        guard let kette = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let sheet = kette.first
        else {
            return nil
        }
        return CertificateFingerprint(certificateData: SecCertificateCopyData(sheet) as Data)
    }
}
