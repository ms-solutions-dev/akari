import Foundation

/// Translates an error into **one sentence for the viewer** and thereby
/// separates it from what belongs in the diagnostics.
///
/// **The finding:** on the television, `badRequest`, `badStatus(400)`,
/// `Network error -999`, `containerNotNativelySupported` and `Response 407`
/// stood in 25 pt red, plus twice a roughly 700-character `NSError` dump with
/// memory addresses. And ``Diagnostics/explain(_:)`` prints an instruction to the
/// developer into the living room on a transport security error: "Check: is
/// NSAllowsArbitraryLoads in the Info.plist …". The caption next to it promises
/// "the cause in plain text".
///
/// **Two readers, two texts.** ``Diagnostics/explain(_:)`` stays as it is: it
/// writes into the trace, and there the error code is the information. Here the
/// sentence for the screen is produced, as a **key** and not as text, because
/// translation happens in the app and not in the computing core.
///
/// **What the viewer wants to know is not the code but the direction:** is it
/// them, their network, the server or the provider? No error message carries
/// more, and less is not enough.
public enum ErrorImage {

    /// How long an accompanying addition may be at most.
    ///
    /// Two hundred characters: the `NSError` dump came to around 700, with memory
    /// addresses in it. Nobody reads anything longer on the television, and it is
    /// not needed there either: the whole line is in the trace.
    public static let maxLength = 200

    /// The localization key for an error.
    ///
    /// - Parameter status: The response status, if the error carries one. Which
    ///   error types know a status is known only to the program: the television app
    ///   reads it from its remuxer rejections, the reading app from its server
    ///   responses. That is why it comes from outside and is not guessed here.
    public static func lookupKey(for error: Error, status: Int?) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "error.offline"
            case .timedOut:
                return "error.slow"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "error.unreachable"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .appTransportSecurityRequiresSecureConnection:
                return "error.certificate"
            case .userAuthenticationRequired:
                return "error.access"
            default:
                return "error.general"
            }
        }
        // The provider's rejections: they are not a network question but a question
        // of authorization, and that is the only information the viewer can do
        // anything with.
        if let status {
            if isPermissionDenial(status) { return "error.access" }
            if (500..<600).contains(status) { return "error.serverDisruption" }
            return "error.general"
        }
        return "error.general"
    }

    /// Whether a status is information about **authorization**.
    ///
    /// 401, 402, 403 and 407 say: "You may not." That does not change in the next
    /// few seconds, and every further request goes to the same account. Other error
    /// statuses are not a rejection in this sense: a 500 can succeed on the next
    /// attempt.
    public static func isPermissionDenial(_ status: Int) -> Bool {
        [401, 402, 403, 407].contains(status)
    }

    /// The addition under the sentence, shortened and without an address.
    ///
    /// **Empty instead of raw:** where nothing readable remains, nothing is shown.
    /// A truncated `NSError` dump is not half an answer but a whole confusion.
    public static func extra(_ error: Error) -> String? {
        guard let raw = Diagnostics.withoutAddress("\(error)") else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)) + " …"
    }
}
