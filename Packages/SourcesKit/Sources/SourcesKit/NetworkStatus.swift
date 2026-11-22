import Foundation

/// The three states a source can have — and no fourth.
///
/// **No "waking up".** The servers of this app are running; what remains: the server answers,
/// it does not answer, or it answers through the tunnel — and at 0.3 Mbit/s that means
/// ~19 s per manga page, 34 minutes per volume.
///
/// `slow` is not an error. It is the state in which the UI shows the subline
/// "On the road ~19 s per page" and the keep button names the duration, instead of
/// a spinner turning.
public enum NetworkStatus: Sendable, Hashable {
    case reachable
    case unreachable
    /// Reachable, but with measured bandwidth — the number from the
    /// tunnel measurement, in megabits per second.
    case slow(mbit: Double)

    /// Whether anything arrives at all — `slow` is reachable.
    public var usable: Bool { self != .unreachable }

    /// How long an amount of bytes takes in this state — the number behind
    /// "~19 s per page". `nil` where there is nothing to compute: `reachable` means
    /// at home, and nobody counts seconds at home; `unreachable` means never.
    public func duration(for bytes: Int) -> TimeInterval? {
        guard case .slow(let mbit) = self, mbit > 0, bytes > 0 else { return nil }
        return Double(bytes) * 8 / (mbit * 1_000_000)
    }
}

/// What a source returns when it cannot deliver — sorted by the direction the viewer
/// should look in.
///
/// **Four directions:** the network, the account, the server, the title. The addition is
/// the trace; the sentence comes from the catalog via ``lookupKey``. No raw `NSError` dump
/// reaches the screen.
public enum SourceError: Error, Sendable, Hashable {
    /// The connection fails or stays silent — nothing arrives.
    case unreachable(SourceID)
    /// 401: the account has expired or the credentials are no longer valid —
    /// the red dot on the account button.
    case signedOut(SourceID)
    /// 403: the account may not do this — it may not fetch files.
    case denied(SourceID)
    /// 404: the server no longer knows the title.
    case notFound(TitleID)
    /// 5xx: the server is there, but not itself.
    case serverDisruption(SourceID, status: Int)
    /// The server answers in a form the kit does not read — a version
    /// problem, not a network question. The text is for the trace.
    case unreadable(SourceID, String)
    /// The source cannot do that — write a CFI to Komga, a page to
    /// Audiobookshelf. An error above the kit, not a server question; the
    /// capabilities would have said so beforehand.
    case notPossible(SourceID, String)

    /// The source in question — also for a title error.
    public var source: SourceID {
        switch self {
        case .unreachable(let q), .signedOut(let q), .denied(let q),
            .serverDisruption(let q, _), .unreadable(let q, _), .notPossible(let q, _):
            return q
        case .notFound(let title):
            return title.source
        }
    }

    /// The localization key for the sentence on screen.
    public var messageKey: String {
        switch self {
        case .unreachable: return "error.unreachable"
        case .signedOut, .denied: return "error.access"
        case .notFound: return "error.notFound"
        case .serverDisruption: return "error.serverDisruption"
        case .unreadable: return "error.unreadable"
        case .notPossible: return "error.notPossible"
        }
    }

    /// Whether it makes no sense to send the same request again right away.
    ///
    /// An account that has expired does not work again in the next few seconds;
    /// a server that is faulty perhaps does. The kits use this to avoid running
    /// into the same wall for 599 volumes after a 401.
    public var final: Bool {
        switch self {
        case .signedOut, .denied, .notFound, .unreadable, .notPossible: return true
        case .unreachable, .serverDisruption: return false
        }
    }

    /// Interprets a response status — the one place where three kits read the same
    /// number the same way. `nil` for everything that is not an error.
    public static func from(status: Int, source: SourceID, title: TitleID? = nil) -> SourceError? {
        switch status {
        case 200..<400: return nil
        case 401, 407: return .signedOut(source)
        case 402, 403: return .denied(source)
        case 404: return title.map { .notFound($0) } ?? .unreadable(source, "404 without title")
        case 500..<600: return .serverDisruption(source, status: status)
        default: return .unreadable(source, "Response \(status)")
        }
    }

    /// Interprets a transport error from `URLSession` — missing response,
    /// lost connection, unknown host: all ``SourceError/unreachable``.
    public static func from(_ error: Error, source: SourceID) -> SourceError {
        if let own = error as? SourceError { return own }
        if error is URLError { return .unreachable(source) }
        return .unreadable(source, String(describing: Swift.type(of: error)))
    }
}
